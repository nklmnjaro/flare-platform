//go:build linux

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

const (
	archiveBarrierSourceRootResolved      = "source-root-resolved"
	archiveBarrierSourceEntryPinned       = "source-entry-pinned"
	archiveBarrierSourceFileRead          = "source-file-read"
	archiveBarrierBeforeArchivePublish    = "before-archive-publish"
	archiveBarrierBeforeChecksumPublish   = "before-checksum-publish"
	archiveBarrierBeforePairVerification  = "before-pair-verification"
	archiveBarrierVerificationArchiveRead = "verification-archive-read"
)

const (
	archiveRenameNoReplace = 1
	archiveOPath           = 0x200000
)

var archiveFilesystemBarrier = func(string) {}

type archiveFileState struct {
	device      uint64
	inode       uint64
	mode        uint32
	size        int64
	links       uint64
	owner       uint32
	group       uint32
	modifiedSec int64
	modifiedNS  int64
	changedSec  int64
	changedNS   int64
}

type archiveDestination struct {
	parent         *os.File
	parentPath     string
	parentIdentity archiveFileState
	archiveName    string
	checksumName   string
}

type stagedArchiveFile struct {
	destination *archiveDestination
	file        *os.File
	identity    archiveFileState
	name        string
	published   bool
}

type archiveVerificationPair struct {
	parent           *os.File
	parentPath       string
	parentIdentity   archiveFileState
	archive          *os.File
	archiveIdentity  archiveFileState
	archiveName      string
	checksum         *os.File
	checksumIdentity archiveFileState
	checksumName     string
}

func archiveState(file *os.File) (archiveFileState, error) {
	var stat syscall.Stat_t
	if err := syscall.Fstat(int(file.Fd()), &stat); err != nil {
		return archiveFileState{}, err
	}
	return archiveStateFromStat(&stat), nil
}

func archiveStateFromStat(stat *syscall.Stat_t) archiveFileState {
	return archiveFileState{
		device:      uint64(stat.Dev),
		inode:       stat.Ino,
		mode:        stat.Mode,
		size:        stat.Size,
		links:       uint64(stat.Nlink),
		owner:       stat.Uid,
		group:       stat.Gid,
		modifiedSec: int64(stat.Mtim.Sec),
		modifiedNS:  int64(stat.Mtim.Nsec),
		changedSec:  int64(stat.Ctim.Sec),
		changedNS:   int64(stat.Ctim.Nsec),
	}
}

func sameArchiveObject(left, right archiveFileState) bool {
	return left.device == right.device && left.inode == right.inode &&
		archiveFileType(left) == archiveFileType(right) &&
		left.owner == right.owner && left.group == right.group
}

func sameStableArchiveFile(left, right archiveFileState) bool {
	return sameArchiveObject(left, right) && left.mode == right.mode && left.size == right.size &&
		left.links == right.links &&
		left.modifiedSec == right.modifiedSec && left.modifiedNS == right.modifiedNS &&
		left.changedSec == right.changedSec && left.changedNS == right.changedNS
}

func archiveFileMode(state archiveFileState) fs.FileMode {
	return fs.FileMode(state.mode & 0o777)
}

func archiveFileType(state archiveFileState) uint32 {
	return state.mode & syscall.S_IFMT
}

func openArchiveDirectoryPath(path string) (*os.File, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if !filepath.IsAbs(absolute) {
		return nil, errors.New("directory path must be absolute")
	}
	rootFD, err := syscall.Open(
		string(filepath.Separator),
		syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	current := os.NewFile(uintptr(rootFD), string(filepath.Separator))
	components := splitAbsoluteArchivePath(absolute)
	for _, component := range components {
		nextFD, openErr := syscall.Openat(
			int(current.Fd()),
			component,
			syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC,
			0,
		)
		if openErr != nil {
			_ = current.Close()
			return nil, openErr
		}
		next := os.NewFile(uintptr(nextFD), component)
		if closeErr := current.Close(); closeErr != nil {
			_ = next.Close()
			return nil, closeErr
		}
		current = next
	}
	return current, nil
}

func ensureArchiveDirectoryPath(path string, mode fs.FileMode) error {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	rootFD, err := syscall.Open(
		string(filepath.Separator),
		syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC,
		0,
	)
	if err != nil {
		return err
	}
	current := os.NewFile(uintptr(rootFD), string(filepath.Separator))
	for _, component := range splitAbsoluteArchivePath(absolute) {
		next, openErr := openArchiveDirectoryAt(current, component)
		if errors.Is(openErr, syscall.ENOENT) {
			mkdirErr := syscall.Mkdirat(int(current.Fd()), component, uint32(mode.Perm()))
			if mkdirErr != nil && !errors.Is(mkdirErr, syscall.EEXIST) {
				_ = current.Close()
				return mkdirErr
			}
			next, openErr = openArchiveDirectoryAt(current, component)
			if openErr == nil {
				if syncErr := current.Sync(); syncErr != nil {
					_ = next.Close()
					_ = current.Close()
					return syncErr
				}
			}
		}
		if openErr != nil {
			_ = current.Close()
			return openErr
		}
		if closeErr := current.Close(); closeErr != nil {
			_ = next.Close()
			return closeErr
		}
		current = next
	}
	return current.Close()
}

func splitAbsoluteArchivePath(path string) []string {
	clean := filepath.Clean(path)
	if clean == string(filepath.Separator) {
		return nil
	}
	return strings.Split(strings.TrimPrefix(clean, string(filepath.Separator)), string(filepath.Separator))
}

func openArchiveDirectoryAt(parent *os.File, name string) (*os.File, error) {
	fd, err := syscall.Openat(
		int(parent.Fd()),
		name,
		syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}

func openArchivePathReference(parent *os.File, name string) (*os.File, error) {
	fd, err := syscall.Openat(
		int(parent.Fd()),
		name,
		archiveOPath|syscall.O_NOFOLLOW|syscall.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}

func openArchiveRegularAt(parent *os.File, name string) (*os.File, error) {
	fd, err := syscall.Openat(
		int(parent.Fd()),
		name,
		syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), name), nil
}

func openArchiveRegularPath(path string) (*os.File, error) {
	fd, err := syscall.Open(
		path,
		syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW|syscall.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	state, stateErr := archiveState(file)
	if stateErr != nil {
		_ = file.Close()
		return nil, stateErr
	}
	if archiveFileType(state) != syscall.S_IFREG {
		_ = file.Close()
		return nil, fmt.Errorf("verification input is not a regular file: %s", path)
	}
	return file, nil
}

func openPinnedArchiveDirectory(path string) (*os.File, archiveFileState, error) {
	directory, err := openArchiveDirectoryPath(path)
	if err != nil {
		return nil, archiveFileState{}, err
	}
	identity, err := archiveState(directory)
	if err != nil {
		_ = directory.Close()
		return nil, archiveFileState{}, err
	}
	reopened, err := openArchiveDirectoryPath(path)
	if err != nil {
		_ = directory.Close()
		return nil, archiveFileState{}, err
	}
	reopenedIdentity, stateErr := archiveState(reopened)
	closeErr := reopened.Close()
	if stateErr != nil || closeErr != nil {
		_ = directory.Close()
		return nil, archiveFileState{}, errors.Join(stateErr, closeErr)
	}
	if !sameArchiveObject(identity, reopenedIdentity) {
		_ = directory.Close()
		return nil, archiveFileState{}, errors.New("directory changed while it was pinned")
	}
	return directory, identity, nil
}

func openPinnedArchiveSource(source string) (string, *os.File, error) {
	absolute, err := filepath.Abs(source)
	if err != nil {
		return "", nil, err
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return "", nil, fmt.Errorf("source directory must not be a symlink: %s", source)
	}
	if !info.IsDir() {
		return "", nil, fmt.Errorf("source is not a directory: %s", source)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", nil, errors.New("source directory metadata is unavailable")
	}
	expected := archiveStateFromStat(stat)
	canonical, err := canonicalSourceRoot(source)
	if err != nil {
		return "", nil, err
	}
	archiveFilesystemBarrier(archiveBarrierSourceRootResolved)
	directory, observed, err := openPinnedArchiveDirectory(canonical)
	if err != nil {
		return "", nil, err
	}
	if !sameArchiveObject(expected, observed) {
		_ = directory.Close()
		return "", nil, errors.New("source directory changed while it was pinned")
	}
	return canonical, directory, nil
}

func prepareArchiveDestination(path string) (*archiveDestination, error) {
	parentPath := filepath.Dir(path)
	parent, identity, err := openPinnedArchiveDirectory(parentPath)
	if err != nil {
		return nil, err
	}
	destination := &archiveDestination{
		parent:         parent,
		parentPath:     parentPath,
		parentIdentity: identity,
		archiveName:    filepath.Base(path),
		checksumName:   filepath.Base(path) + ".sha256",
	}
	for _, name := range []string{destination.archiveName, destination.checksumName} {
		if err := destination.requireAbsent(name); err != nil {
			_ = parent.Close()
			return nil, err
		}
	}
	return destination, nil
}

func ensurePinnedArchiveOutputOutsideSource(source, outputParent *os.File) error {
	sourceIdentity, err := archiveState(source)
	if err != nil {
		return err
	}
	current, err := openArchiveDirectoryAt(outputParent, ".")
	if err != nil {
		return err
	}
	for depth := 0; depth < 4096; depth++ {
		currentIdentity, err := archiveState(current)
		if err != nil {
			return errors.Join(err, current.Close())
		}
		if sameArchiveObject(sourceIdentity, currentIdentity) {
			return errors.Join(
				errors.New("output archive must be outside the source directory"),
				current.Close(),
			)
		}
		parent, err := openArchiveDirectoryAt(current, "..")
		if err != nil {
			return errors.Join(err, current.Close())
		}
		parentIdentity, stateErr := archiveState(parent)
		if stateErr != nil {
			return errors.Join(stateErr, parent.Close(), current.Close())
		}
		if sameArchiveObject(currentIdentity, parentIdentity) {
			return errors.Join(parent.Close(), current.Close())
		}
		if err := current.Close(); err != nil {
			_ = parent.Close()
			return err
		}
		current = parent
	}
	return errors.Join(
		errors.New("output parent ancestry exceeds the safety limit"),
		current.Close(),
	)
}

func (destination *archiveDestination) requireAbsent(name string) error {
	reference, err := openArchivePathReference(destination.parent, name)
	if err == nil {
		state, stateErr := archiveState(reference)
		closeErr := reference.Close()
		if stateErr != nil || closeErr != nil {
			return errors.Join(stateErr, closeErr)
		}
		path := filepath.Join(destination.parentPath, name)
		if archiveFileType(state) == syscall.S_IFLNK {
			return fmt.Errorf("refusing symlink publication target: %s", path)
		}
		return fmt.Errorf("publication target already exists: %s", path)
	}
	if errors.Is(err, syscall.ENOENT) {
		return nil
	}
	return fmt.Errorf("publication target cannot be inspected safely: %w", err)
}

func (destination *archiveDestination) verifyNamedParent() error {
	return verifyPinnedArchiveDirectory(
		destination.parent,
		destination.parentPath,
		destination.parentIdentity,
		"output parent",
	)
}

func verifyPinnedArchiveDirectory(
	pinnedDirectory *os.File,
	path string,
	identity archiveFileState,
	label string,
) error {
	pinned, err := archiveState(pinnedDirectory)
	if err != nil || !sameArchiveObject(identity, pinned) {
		return fmt.Errorf("%s identity changed", label)
	}
	reopened, err := openArchiveDirectoryPath(path)
	if err != nil {
		return fmt.Errorf("%s path changed", label)
	}
	defer reopened.Close()
	observed, err := archiveState(reopened)
	if err != nil || !sameArchiveObject(identity, observed) {
		return fmt.Errorf("%s path changed", label)
	}
	return nil
}

func openArchiveVerificationPair(path string) (*archiveVerificationPair, error) {
	if err := validateVerificationInput(path); err != nil {
		return nil, err
	}
	if err := validateVerificationInput(path + ".sha256"); err != nil {
		return nil, fmt.Errorf("detached checksum: %w", err)
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	parentPath, err := filepath.EvalSymlinks(filepath.Dir(absolute))
	if err != nil {
		return nil, err
	}
	parent, parentIdentity, err := openPinnedArchiveDirectory(parentPath)
	if err != nil {
		return nil, err
	}
	pair := &archiveVerificationPair{
		parent:         parent,
		parentPath:     parentPath,
		parentIdentity: parentIdentity,
		archiveName:    filepath.Base(absolute),
		checksumName:   filepath.Base(absolute) + ".sha256",
	}
	pair.archive, pair.archiveIdentity, err = openNamedArchiveRegular(parent, pair.archiveName)
	if err != nil {
		_ = parent.Close()
		return nil, err
	}
	pair.checksum, pair.checksumIdentity, err = openNamedArchiveRegular(parent, pair.checksumName)
	if err != nil {
		_ = pair.archive.Close()
		_ = parent.Close()
		return nil, fmt.Errorf("detached checksum: %w", err)
	}
	return pair, nil
}

func openNamedArchiveRegular(
	parent *os.File,
	name string,
) (*os.File, archiveFileState, error) {
	file, err := openArchiveRegularAt(parent, name)
	if err != nil {
		return nil, archiveFileState{}, err
	}
	identity, err := archiveState(file)
	if err != nil {
		_ = file.Close()
		return nil, archiveFileState{}, err
	}
	return file, identity, nil
}

func (pair *archiveVerificationPair) verifyNames() error {
	if err := verifyPinnedArchiveDirectory(
		pair.parent,
		pair.parentPath,
		pair.parentIdentity,
		"verification parent",
	); err != nil {
		return err
	}
	if err := ensureOpenArchiveStable(
		pair.archive,
		pair.archiveIdentity,
		"verification archive",
	); err != nil {
		return err
	}
	if err := ensureOpenArchiveStable(
		pair.checksum,
		pair.checksumIdentity,
		"verification checksum",
	); err != nil {
		return err
	}
	if err := ensureArchiveNamedStableObject(
		pair.parent,
		pair.archiveName,
		pair.archiveIdentity,
		"verification archive",
	); err != nil {
		return err
	}
	return ensureArchiveNamedStableObject(
		pair.parent,
		pair.checksumName,
		pair.checksumIdentity,
		"verification checksum",
	)
}

func ensureOpenArchiveStable(file *os.File, identity archiveFileState, label string) error {
	observed, err := archiveState(file)
	if err != nil {
		return err
	}
	if !sameStableArchiveFile(identity, observed) {
		return fmt.Errorf("%s identity or contents changed", label)
	}
	return nil
}

func (pair *archiveVerificationPair) close() error {
	return errors.Join(pair.checksum.Close(), pair.archive.Close(), pair.parent.Close())
}

func (destination *archiveDestination) createStagedFile(label string) (*stagedArchiveFile, error) {
	for attempt := 0; attempt < 64; attempt++ {
		name, err := randomArchiveStageName(label)
		if err != nil {
			return nil, err
		}
		fd, err := syscall.Openat(
			int(destination.parent.Fd()),
			name,
			syscall.O_RDWR|syscall.O_CREAT|syscall.O_EXCL|syscall.O_NOFOLLOW|syscall.O_CLOEXEC,
			0o600,
		)
		if errors.Is(err, syscall.EEXIST) {
			continue
		}
		if err != nil {
			return nil, err
		}
		file := os.NewFile(uintptr(fd), name)
		identity, stateErr := archiveState(file)
		if stateErr != nil {
			_ = file.Close()
			_ = syscall.Unlinkat(int(destination.parent.Fd()), name)
			return nil, stateErr
		}
		return &stagedArchiveFile{
			destination: destination,
			file:        file,
			identity:    identity,
			name:        name,
		}, nil
	}
	return nil, errors.New("could not allocate a private archive staging file")
}

func randomArchiveStageName(label string) (string, error) {
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	return ".flare-artifact-" + label + "-" + hex.EncodeToString(random), nil
}

func (stage *stagedArchiveFile) seal(mode fs.FileMode) error {
	if err := stage.file.Chmod(mode); err != nil {
		return err
	}
	if err := stage.file.Sync(); err != nil {
		return err
	}
	identity, err := archiveState(stage.file)
	if err != nil {
		return err
	}
	stage.identity = identity
	return nil
}

func (stage *stagedArchiveFile) ensureNamed() error {
	current, err := archiveState(stage.file)
	if err != nil {
		return err
	}
	if !sameStableArchiveFile(stage.identity, current) {
		return errors.New("archive staging file changed")
	}
	return ensureArchiveNamedStableObject(
		stage.destination.parent,
		stage.name,
		stage.identity,
		"archive staging file",
	)
}

func ensureArchiveNamedStableObject(
	parent *os.File,
	name string,
	identity archiveFileState,
	label string,
) error {
	reference, err := openArchivePathReference(parent, name)
	if err != nil {
		return err
	}
	defer reference.Close()
	observed, err := archiveState(reference)
	if err != nil {
		return err
	}
	if !sameStableArchiveFile(identity, observed) {
		return fmt.Errorf("%s identity or contents changed", label)
	}
	return nil
}

func ensureArchiveNamedObject(
	parent *os.File,
	name string,
	identity archiveFileState,
	label string,
) error {
	reference, err := openArchivePathReference(parent, name)
	if err != nil {
		return err
	}
	defer reference.Close()
	observed, err := archiveState(reference)
	if err != nil {
		return err
	}
	if !sameArchiveObject(identity, observed) {
		return fmt.Errorf("%s identity changed", label)
	}
	return nil
}

func (stage *stagedArchiveFile) publish(target, barrier string) error {
	archiveFilesystemBarrier(barrier)
	if err := stage.destination.verifyNamedParent(); err != nil {
		return err
	}
	if err := stage.ensureNamed(); err != nil {
		return err
	}
	if err := archiveRenameAtNoReplace(
		int(stage.destination.parent.Fd()), stage.name,
		int(stage.destination.parent.Fd()), target,
	); err != nil {
		if errors.Is(err, syscall.EEXIST) {
			return errors.New("publication target already exists")
		}
		return err
	}
	stage.published = true
	stage.name = target
	identity, err := archiveState(stage.file)
	if err != nil {
		return fmt.Errorf("artifact was published but its identity could not be captured: %w", err)
	}
	stage.identity = identity
	if err := stage.ensureNamed(); err != nil {
		return fmt.Errorf("artifact was published but its identity could not be confirmed: %w", err)
	}
	if err := stage.destination.parent.Sync(); err != nil {
		return fmt.Errorf("artifact was published but parent durability could not be confirmed: %w", err)
	}
	if err := stage.destination.verifyNamedParent(); err != nil {
		return fmt.Errorf("artifact was published but parent identity could not be confirmed: %w", err)
	}
	return nil
}

func (stage *stagedArchiveFile) closeAndDiscard() error {
	var unlinkErr error
	if !stage.published {
		if err := ensureArchiveNamedObject(
			stage.destination.parent,
			stage.name,
			stage.identity,
			"archive staging file",
		); err != nil {
			unlinkErr = err
		} else {
			unlinkErr = syscall.Unlinkat(int(stage.destination.parent.Fd()), stage.name)
			if unlinkErr == nil {
				unlinkErr = stage.destination.parent.Sync()
			}
		}
	}
	return errors.Join(stage.file.Close(), unlinkErr)
}

func archiveRenameAtNoReplace(oldDirectory int, oldName string, newDirectory int, newName string) error {
	number, ok := archiveRenameAt2SystemCallNumber()
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
	_, _, errno := syscall.Syscall6(
		number,
		uintptr(oldDirectory), uintptr(unsafe.Pointer(oldPointer)),
		uintptr(newDirectory), uintptr(unsafe.Pointer(newPointer)),
		archiveRenameNoReplace, 0,
	)
	if errno != 0 {
		return errno
	}
	return nil
}

func archiveRenameAt2SystemCallNumber() (uintptr, bool) {
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
