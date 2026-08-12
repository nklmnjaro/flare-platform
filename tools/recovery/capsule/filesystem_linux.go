//go:build linux

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

const (
	renameNoReplace = 1
	atRemoveDir     = 0x200
	linuxOPath      = 0x200000
)

const (
	recoveryBarrierBeforePopulate = "before-stage-populate"
	recoveryBarrierBeforePublish  = "before-publish"
	recoveryBarrierBundleOverflow = "bundle-overflow"
	recoveryBarrierMembersOpened  = "verify-members-opened"
	recoveryBarrierRepositoryPath = "repository-path-verify"
	recoveryBarrierTempCleanup    = "temp-cleanup"
	recoveryBarrierTempUnlinkFile = "temp-unlink-file"
	recoveryBarrierTempUnlinkDir  = "temp-unlink-directory"
	recoveryBarrierTempUnlinkLink = "temp-unlink-symlink"
	recoveryBarrierSymlinkPinned  = "tracked-symlink-pinned"
	recoveryBarrierClonePinned    = "recovered-clone-pinned"
)

var recoveryFilesystemBarrier = func(string) {}

type stableFileState struct {
	device      uint64
	inode       uint64
	mode        uint32
	size        int64
	links       uint64
	owner       uint32
	modifiedSec int64
	modifiedNS  int64
	changedSec  int64
	changedNS   int64
}

type preparedDestination struct {
	parent         *os.File
	parentPath     string
	parentIdentity stableFileState
	outputName     string
}

type pinnedStage struct {
	destination *preparedDestination
	directory   *os.File
	identity    stableFileState
	name        string
	renamed     bool
}

func fileState(file *os.File) (stableFileState, error) {
	var stat syscall.Stat_t
	if err := syscall.Fstat(int(file.Fd()), &stat); err != nil {
		return stableFileState{}, err
	}
	return stableStateFromStat(&stat), nil
}

func fileInfoState(info os.FileInfo) (stableFileState, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return stableFileState{}, errors.New("file metadata is unavailable")
	}
	return stableStateFromStat(stat), nil
}

func stableStateFromStat(stat *syscall.Stat_t) stableFileState {
	return stableFileState{
		device:      uint64(stat.Dev),
		inode:       stat.Ino,
		mode:        stat.Mode,
		size:        stat.Size,
		links:       uint64(stat.Nlink),
		owner:       stat.Uid,
		modifiedSec: stat.Mtim.Sec,
		modifiedNS:  stat.Mtim.Nsec,
		changedSec:  stat.Ctim.Sec,
		changedNS:   stat.Ctim.Nsec,
	}
}

func sameFileObject(left, right stableFileState) bool {
	return left.device == right.device && left.inode == right.inode &&
		left.mode == right.mode && left.owner == right.owner
}

func sameStableFile(left, right stableFileState) bool {
	return sameFileObject(left, right) && left.size == right.size &&
		left.links == right.links &&
		left.modifiedSec == right.modifiedSec && left.modifiedNS == right.modifiedNS &&
		left.changedSec == right.changedSec && left.changedNS == right.changedNS
}

func openDirectoryNoFollow(path string) (*os.File, error) {
	flags := syscall.O_RDONLY | syscall.O_DIRECTORY | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	fd, err := syscall.Open(path, flags, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}

func openDirectoryAt(parent *os.File, name string) (*os.File, error) {
	flags := syscall.O_RDONLY | syscall.O_DIRECTORY | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(parent.Fd()), name, flags, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}

func openPinnedCanonicalDirectory(path string) (*os.File, stableFileState, error) {
	directory, err := openDirectoryNoFollow(path)
	if err != nil {
		return nil, stableFileState{}, err
	}
	state, err := fileState(directory)
	if err != nil {
		_ = directory.Close()
		return nil, stableFileState{}, err
	}
	reopened, err := openDirectoryNoFollow(path)
	if err != nil {
		_ = directory.Close()
		return nil, stableFileState{}, err
	}
	reopenedState, stateErr := fileState(reopened)
	closeErr := reopened.Close()
	if stateErr != nil || closeErr != nil {
		_ = directory.Close()
		return nil, stableFileState{}, errors.Join(stateErr, closeErr)
	}
	if !sameFileObject(state, reopenedState) {
		_ = directory.Close()
		return nil, stableFileState{}, errors.New("directory changed while it was pinned")
	}
	return directory, state, nil
}

func prepareDestination(path, repository string) (*preparedDestination, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if strings.ContainsAny(absolute, "\r\n\x00") {
		return nil, errors.New("output path contains a control byte")
	}
	parentPath := filepath.Dir(absolute)
	canonicalParent, err := canonicalDirectory(parentPath)
	if err != nil {
		return nil, err
	}
	if filepath.Clean(parentPath) != canonicalParent {
		return nil, errors.New("output parent must not traverse a symlink")
	}
	outputName := filepath.Base(absolute)
	outputPath := filepath.Join(canonicalParent, outputName)
	if err := validateOutputLocation(outputPath, repository); err != nil {
		return nil, err
	}
	parent, parentIdentity, err := openPinnedCanonicalDirectory(canonicalParent)
	if err != nil {
		return nil, err
	}
	prepared := &preparedDestination{
		parent: parent, parentPath: canonicalParent, parentIdentity: parentIdentity,
		outputName: outputName,
	}
	if err := prepared.requireOutputAbsent(); err != nil {
		_ = parent.Close()
		return nil, err
	}
	return prepared, nil
}

func (destination *preparedDestination) verifyNamedParent() error {
	canonical, err := canonicalDirectory(destination.parentPath)
	if err != nil || canonical != destination.parentPath {
		return errors.New("output parent path changed during publication")
	}
	reopened, err := openDirectoryNoFollow(destination.parentPath)
	if err != nil {
		return errors.New("output parent path changed during publication")
	}
	defer reopened.Close()
	observed, err := fileState(reopened)
	if err != nil || !sameFileObject(destination.parentIdentity, observed) {
		return errors.New("output parent path changed during publication")
	}
	pinned, err := fileState(destination.parent)
	if err != nil || !sameFileObject(destination.parentIdentity, pinned) {
		return errors.New("output parent identity changed during publication")
	}
	return nil
}

func validateOutputLocation(output, repository string) error {
	if !pathWithin(output, repository) {
		return nil
	}
	stateRoot := filepath.Join(repository, ".platform")
	if !pathWithin(output, stateRoot) {
		return errors.New("output inside repository must be under .platform")
	}
	return nil
}

func (destination *preparedDestination) requireOutputAbsent() error {
	flags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_NONBLOCK | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(destination.parent.Fd()), destination.outputName, flags, 0)
	if err == nil {
		_ = syscall.Close(fd)
		return errors.New("output path already exists")
	}
	if errors.Is(err, syscall.ENOENT) {
		return nil
	}
	if errors.Is(err, syscall.ELOOP) || errors.Is(err, syscall.ENXIO) {
		return errors.New("output path already exists")
	}
	return fmt.Errorf("output path cannot be inspected safely: %w", err)
}

func (destination *preparedDestination) createStage() (*pinnedStage, error) {
	for attempt := 0; attempt < 64; attempt++ {
		name, err := randomStageName()
		if err != nil {
			return nil, err
		}
		if err := syscall.Mkdirat(int(destination.parent.Fd()), name, 0o700); err != nil {
			if errors.Is(err, syscall.EEXIST) {
				continue
			}
			return nil, err
		}
		directory, err := openDirectoryAt(destination.parent, name)
		if err != nil {
			_ = unlinkDirectoryAt(int(destination.parent.Fd()), name)
			return nil, err
		}
		identity, err := fileState(directory)
		if err != nil {
			_ = directory.Close()
			_ = unlinkDirectoryAt(int(destination.parent.Fd()), name)
			return nil, err
		}
		return &pinnedStage{
			destination: destination, directory: directory, identity: identity,
			name: name,
		}, nil
	}
	return nil, errors.New("could not allocate a private recovery staging directory")
}

func randomStageName() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return ".flare-recovery-stage-" + hex.EncodeToString(value), nil
}

func (stage *pinnedStage) ensureNamed(name string) error {
	directory, err := openDirectoryAt(stage.destination.parent, name)
	if err != nil {
		return err
	}
	defer directory.Close()
	observed, err := fileState(directory)
	if err != nil {
		return err
	}
	if !sameFileObject(stage.identity, observed) {
		return errors.New("recovery staging directory identity changed")
	}
	return nil
}

func (stage *pinnedStage) pinnedPath() string {
	return fmt.Sprintf("/proc/self/fd/%d", stage.directory.Fd())
}

func (stage *pinnedStage) createFile(name string) (*os.File, error) {
	flags := syscall.O_WRONLY | syscall.O_CREAT | syscall.O_EXCL |
		syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(stage.directory.Fd()), name, flags, 0o600)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}

func (stage *pinnedStage) publish() error {
	if err := stage.ensureNamed(stage.name); err != nil {
		return err
	}
	if err := stage.destination.verifyNamedParent(); err != nil {
		return err
	}
	err := renameAtNoReplace(
		int(stage.destination.parent.Fd()), stage.name,
		int(stage.destination.parent.Fd()), stage.destination.outputName,
	)
	if errors.Is(err, syscall.EEXIST) {
		return errors.New("output path already exists")
	}
	if err != nil {
		return err
	}
	stage.renamed = true
	stage.name = stage.destination.outputName
	if err := stage.ensureNamed(stage.name); err != nil {
		return fmt.Errorf(
			"recovery capsule was published but its destination identity could not be confirmed: %w", err)
	}
	if err := stage.destination.parent.Sync(); err != nil {
		return fmt.Errorf(
			"recovery capsule was published but parent durability could not be confirmed: %w", err)
	}
	if err := stage.destination.verifyNamedParent(); err != nil {
		return fmt.Errorf(
			"recovery capsule was published but parent identity could not be confirmed: %w", err)
	}
	return nil
}

func (stage *pinnedStage) discard() error {
	if _, err := stage.directory.Seek(0, 0); err != nil {
		return err
	}
	entries, err := stage.directory.ReadDir(-1)
	if err != nil {
		return err
	}
	unexpected := false
	for _, entry := range entries {
		if !recoveryCapsuleMemberName(entry.Name()) {
			unexpected = true
			continue
		}
		if err := syscall.Unlinkat(int(stage.directory.Fd()), entry.Name()); err != nil {
			return err
		}
	}
	if err := stage.directory.Sync(); err != nil {
		return err
	}
	if unexpected {
		return errors.New("recovery staging directory contains an unexpected entry")
	}
	if err := stage.ensureNamed(stage.name); err != nil {
		return err
	}
	if err := unlinkDirectoryAt(int(stage.destination.parent.Fd()), stage.name); err != nil {
		return err
	}
	return stage.destination.parent.Sync()
}

func recoveryCapsuleMemberName(name string) bool {
	for _, expected := range capsuleFileNames {
		if name == expected {
			return true
		}
	}
	return false
}

func renameAtNoReplace(oldDirectory int, oldName string, newDirectory int, newName string) error {
	number, ok := renameAt2SystemCallNumber()
	if !ok {
		return errors.New("atomic no-replace publication is unavailable on this architecture")
	}
	oldPointer, err := syscall.BytePtrFromString(oldName)
	if err != nil {
		return err
	}
	newPointer, err := syscall.BytePtrFromString(newName)
	if err != nil {
		return err
	}
	_, _, errno := syscall.Syscall6(number,
		uintptr(oldDirectory), uintptr(unsafe.Pointer(oldPointer)),
		uintptr(newDirectory), uintptr(unsafe.Pointer(newPointer)), renameNoReplace, 0)
	if errno != 0 {
		return errno
	}
	return nil
}

func renameAt2SystemCallNumber() (uintptr, bool) {
	switch runtime.GOARCH {
	case "amd64":
		return 316, true
	case "arm64", "loong64", "riscv64":
		return 276, true
	case "386":
		return 353, true
	case "arm":
		return 382, true
	case "ppc", "ppc64", "ppc64le":
		return 357, true
	case "s390x":
		return 347, true
	case "sparc64":
		return 345, true
	case "mips", "mipsle":
		return 4351, true
	case "mips64", "mips64le":
		return 5311, true
	default:
		return 0, false
	}
}

func unlinkDirectoryAt(directory int, name string) error {
	pointer, err := syscall.BytePtrFromString(name)
	if err != nil {
		return err
	}
	_, _, errno := syscall.Syscall(
		syscall.SYS_UNLINKAT, uintptr(directory),
		uintptr(unsafe.Pointer(pointer)), atRemoveDir,
	)
	if errno != 0 {
		return errno
	}
	return nil
}
