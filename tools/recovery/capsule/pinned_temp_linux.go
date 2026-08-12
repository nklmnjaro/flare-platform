//go:build linux

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

type pinnedTempDirectory struct {
	parent     *os.File
	directory  *os.File
	identity   stableFileState
	name       string
	path       string
	pinnedPath string
	ownedNames map[string]stableFileState
}

var recoveryPinnedTempCreated = func(*pinnedTempDirectory) {}

func newPinnedTempDirectory(prefix string) (*pinnedTempDirectory, error) {
	if err := validateRecoveryTempRoot(); err != nil {
		return nil, err
	}
	parent, _, err := openPinnedCanonicalDirectory(recoveryHostTempRoot)
	if err != nil {
		return nil, err
	}
	for attempt := 0; attempt < 64; attempt++ {
		name, err := randomTempName(prefix)
		if err != nil {
			_ = parent.Close()
			return nil, err
		}
		if err := syscall.Mkdirat(int(parent.Fd()), name, 0o700); err != nil {
			if errors.Is(err, syscall.EEXIST) {
				continue
			}
			_ = parent.Close()
			return nil, err
		}
		directory, err := openDirectoryAt(parent, name)
		if err != nil {
			_ = unlinkDirectoryAt(int(parent.Fd()), name)
			_ = parent.Close()
			return nil, err
		}
		identity, err := fileState(directory)
		if err != nil {
			_ = directory.Close()
			_ = unlinkDirectoryAt(int(parent.Fd()), name)
			_ = parent.Close()
			return nil, err
		}
		temporary := &pinnedTempDirectory{
			parent: parent, directory: directory, identity: identity, name: name,
			path: filepath.Join(recoveryHostTempRoot, name),
			pinnedPath: filepath.Join("/proc", strconv.Itoa(os.Getpid()), "fd",
				strconv.FormatUint(uint64(directory.Fd()), 10)),
			ownedNames: make(map[string]stableFileState),
		}
		recoveryPinnedTempCreated(temporary)
		return temporary, nil
	}
	_ = parent.Close()
	return nil, errors.New("could not allocate pinned recovery temp directory")
}

func randomTempName(prefix string) (string, error) {
	payload := make([]byte, 16)
	if _, err := rand.Read(payload); err != nil {
		return "", err
	}
	return prefix + hex.EncodeToString(payload), nil
}

func (temporary *pinnedTempDirectory) cleanup() error {
	recoveryFilesystemBarrier(recoveryBarrierTempCleanup)
	cleanupErr := removeDirectoryContentsWithOwnership(
		temporary.directory, temporary.ownedNames)
	nameErr := temporary.ensureNamed()
	if nameErr == nil {
		nameErr = unlinkDirectoryAt(int(temporary.parent.Fd()), temporary.name)
	}
	closeErr := errors.Join(temporary.directory.Close(), temporary.parent.Close())
	return errors.Join(cleanupErr, nameErr, closeErr)
}

func (temporary *pinnedTempDirectory) registerOwnedName(
	name string,
	identity stableFileState,
) error {
	if name == "" || name == "." || name == ".." || filepath.Base(name) != name {
		return errors.New("recovery temp owned name is unsafe")
	}
	if _, duplicate := temporary.ownedNames[name]; duplicate {
		return errors.New("recovery temp owned name is already registered")
	}
	temporary.ownedNames[name] = identity
	return nil
}

func (temporary *pinnedTempDirectory) registerCurrentOwnedName(name string) error {
	file, identity, err := openPinnedTempEntry(temporary.directory, name)
	if err != nil {
		return err
	}
	closeErr := file.Close()
	if closeErr != nil {
		return closeErr
	}
	return temporary.registerOwnedName(name, identity)
}

func (temporary *pinnedTempDirectory) ensureNamed() error {
	directory, err := openDirectoryAt(temporary.parent, temporary.name)
	if err != nil {
		return err
	}
	defer directory.Close()
	observed, err := fileState(directory)
	if err != nil {
		return err
	}
	if !sameFileObject(temporary.identity, observed) {
		return errors.New("recovery temp directory identity changed")
	}
	return nil
}

func removeDirectoryContents(directory *os.File) error {
	return removeDirectoryContentsWithOwnership(directory, nil)
}

func removeDirectoryContentsWithOwnership(
	directory *os.File,
	ownedNames map[string]stableFileState,
) error {
	if _, err := directory.Seek(0, 0); err != nil {
		return err
	}
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return err
	}
	preserve, ownershipErr := classifyPinnedTempOwnership(directory, entries, ownedNames)
	var cleanupErr error
	for _, entry := range entries {
		if preserve[entry.Name()] {
			continue
		}
		if err := removePinnedTempEntry(directory, entry.Name()); err != nil {
			cleanupErr = errors.Join(cleanupErr, err)
		}
	}
	return errors.Join(ownershipErr, cleanupErr, directory.Sync())
}

func classifyPinnedTempOwnership(
	directory *os.File,
	entries []os.DirEntry,
	ownedNames map[string]stableFileState,
) (map[string]bool, error) {
	preserve := make(map[string]bool)
	if len(ownedNames) == 0 {
		return preserve, nil
	}
	observed := make(map[string]stableFileState, len(entries))
	for _, entry := range entries {
		file, state, err := openPinnedTempEntry(directory, entry.Name())
		if err != nil {
			return nil, err
		}
		closeErr := file.Close()
		if closeErr != nil {
			return nil, closeErr
		}
		observed[entry.Name()] = state
	}
	var resultErr error
	for name, expected := range ownedNames {
		current, present := observed[name]
		if present && sameFileObject(expected, current) {
			continue
		}
		if present {
			preserve[name] = true
		}
		foundMoved := false
		for observedName, state := range observed {
			if observedName != name && sameFileObject(expected, state) {
				foundMoved = true
				break
			}
		}
		if !foundMoved {
			resultErr = errors.Join(resultErr,
				errors.New("registered recovery temp entry is absent"))
		}
		resultErr = errors.Join(resultErr,
			errors.New("recovery temp entry identity changed"))
	}
	return preserve, resultErr
}

func removePinnedTempEntry(parent *os.File, name string) error {
	pinned, pinnedState, err := openPinnedTempEntry(parent, name)
	if err != nil {
		return err
	}
	defer pinned.Close()
	switch pinnedState.mode & syscall.S_IFMT {
	case syscall.S_IFDIR:
		return removePinnedTempDirectory(parent, name, pinnedState)
	case syscall.S_IFREG:
		return removePinnedTempRegular(parent, name, pinned, pinnedState)
	case syscall.S_IFLNK:
		if pinnedState.links != 1 {
			return errors.New("recovery temp contains an unsafe symlink")
		}
		recoveryFilesystemBarrier(recoveryBarrierTempUnlinkLink)
		if err := ensurePinnedTempEntryNamed(parent, name, pinnedState); err != nil {
			return err
		}
		return syscall.Unlinkat(int(parent.Fd()), name)
	default:
		return errors.New("recovery temp contains an unsafe entry")
	}
}

func removePinnedTempDirectory(parent *os.File, name string, pinnedState stableFileState) error {
	child, err := openDirectoryAt(parent, name)
	if err != nil {
		return err
	}
	defer child.Close()
	childState, err := fileState(child)
	if err != nil || !sameFileObject(pinnedState, childState) {
		return errors.New("recovery temp entry identity changed")
	}
	if err := child.Chmod(0o700); err != nil {
		return err
	}
	if err := removeDirectoryContents(child); err != nil {
		return err
	}
	current, err := fileState(child)
	if err != nil {
		return err
	}
	recoveryFilesystemBarrier(recoveryBarrierTempUnlinkDir)
	if err := ensurePinnedTempEntryNamed(parent, name, current); err != nil {
		return err
	}
	if err := child.Close(); err != nil {
		return err
	}
	return unlinkDirectoryAt(int(parent.Fd()), name)
}

func removePinnedTempRegular(
	parent *os.File,
	name string,
	pinned *os.File,
	pinnedState stableFileState,
) error {
	if pinnedState.links != 1 {
		return errors.New("recovery temp contains an unsafe regular file")
	}
	readFlags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_NONBLOCK | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(parent.Fd()), name, readFlags, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), name)
	defer file.Close()
	state, err := fileState(file)
	if err != nil || !sameFileObject(pinnedState, state) {
		return errors.New("recovery temp entry identity changed")
	}
	if err := file.Chmod(0o600); err != nil {
		return err
	}
	writable, err := os.OpenFile(
		filepath.Join("/proc", strconv.Itoa(os.Getpid()), "fd",
			strconv.FormatUint(uint64(file.Fd()), 10)), os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	truncateErr := writable.Truncate(0)
	syncErr := writable.Sync()
	closeErr := writable.Close()
	if err := errors.Join(truncateErr, syncErr, closeErr); err != nil {
		return err
	}
	current, err := fileState(file)
	if err != nil {
		return err
	}
	recoveryFilesystemBarrier(recoveryBarrierTempUnlinkFile)
	if err := ensurePinnedTempEntryNamed(parent, name, current); err != nil {
		return err
	}
	return syscall.Unlinkat(int(parent.Fd()), name)
}

func openPinnedTempEntry(parent *os.File, name string) (*os.File, stableFileState, error) {
	flags := linuxOPath | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(parent.Fd()), name, flags, 0)
	if err != nil {
		return nil, stableFileState{}, err
	}
	file := os.NewFile(uintptr(fd), name)
	state, err := fileState(file)
	if err != nil {
		_ = file.Close()
		return nil, stableFileState{}, err
	}
	return file, state, nil
}

func ensurePinnedTempEntryNamed(
	parent *os.File,
	name string,
	expected stableFileState,
) error {
	reopened, observed, err := openPinnedTempEntry(parent, name)
	if err != nil {
		return errors.New("recovery temp entry identity changed")
	}
	closeErr := reopened.Close()
	if closeErr != nil || !sameFileObject(expected, observed) {
		return errors.New("recovery temp entry identity changed")
	}
	return nil
}
