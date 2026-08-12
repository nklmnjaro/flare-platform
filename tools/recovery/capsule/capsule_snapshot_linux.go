//go:build linux

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

const (
	maxRecoveryManifestBytes = 4 << 10
	maxRecoveryIdentityBytes = 16 << 10
)

var capsuleFileNames = []string{
	"MANIFEST.sha256",
	"RECOVERY.json",
	"repository.bundle",
}

type pinnedCapsuleMember struct {
	name     string
	file     *os.File
	identity stableFileState
}

func verifyPinnedCapsuleWithRunner(
	directory *os.File,
	runner *gitRunner,
) (resultErr error) {
	snapshot, err := snapshotPinnedCapsule(directory)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, snapshot.cleanup()) }()
	return verifyCapsuleSnapshot(snapshot.pinnedPath, runner)
}

func snapshotPinnedCapsule(directory *os.File) (
	result *pinnedTempDirectory,
	resultErr error,
) {
	rootBefore, err := fileState(directory)
	if err != nil {
		return nil, err
	}
	if err := verifyPinnedCapsuleFileSet(directory); err != nil {
		return nil, err
	}
	members, err := openPinnedCapsuleMembers(directory)
	if err != nil {
		return nil, err
	}
	defer closePinnedCapsuleMembers(members)
	recoveryFilesystemBarrier(recoveryBarrierMembersOpened)
	snapshot, err := newPinnedTempDirectory("flare-recovery-snapshot-")
	if err != nil {
		return nil, err
	}
	complete := false
	defer func() {
		if !complete {
			resultErr = errors.Join(resultErr, snapshot.cleanup())
		}
	}()
	if err := copyPinnedCapsuleMembers(snapshot.pinnedPath, members); err != nil {
		return nil, err
	}
	for _, name := range capsuleFileNames {
		if err := snapshot.registerCurrentOwnedName(name); err != nil {
			return nil, err
		}
	}
	if err := verifyPinnedMemberNames(directory, members); err != nil {
		return nil, err
	}
	if err := verifyPinnedCapsuleFileSet(directory); err != nil {
		return nil, errors.New("recovery capsule changed during snapshot")
	}
	rootAfter, err := fileState(directory)
	if err != nil {
		return nil, err
	}
	if !sameStableFile(rootBefore, rootAfter) {
		return nil, errors.New("recovery capsule changed during snapshot")
	}
	complete = true
	return snapshot, nil
}

func verifyPinnedCapsuleFileSet(directory *os.File) error {
	if _, err := directory.Seek(0, 0); err != nil {
		return err
	}
	entries, err := directory.ReadDir(-1)
	if err != nil {
		return err
	}
	if len(entries) != len(capsuleFileNames) {
		return errors.New("recovery capsule file set is not exact")
	}
	expected := make(map[string]bool, len(capsuleFileNames))
	for _, name := range capsuleFileNames {
		expected[name] = true
	}
	for _, entry := range entries {
		if !expected[entry.Name()] {
			return errors.New("recovery capsule contains an unexpected entry")
		}
		delete(expected, entry.Name())
	}
	if len(expected) != 0 {
		return errors.New("recovery capsule file set is not exact")
	}
	return nil
}

func openPinnedCapsuleMembers(directory *os.File) ([]pinnedCapsuleMember, error) {
	members := make([]pinnedCapsuleMember, 0, len(capsuleFileNames))
	for _, name := range capsuleFileNames {
		member, err := openPinnedCapsuleMember(directory, name)
		if err != nil {
			closePinnedCapsuleMembers(members)
			return nil, err
		}
		members = append(members, member)
	}
	return members, nil
}

func openPinnedCapsuleMember(directory *os.File, name string) (pinnedCapsuleMember, error) {
	flags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_NONBLOCK | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(directory.Fd()), name, flags, 0)
	if err != nil {
		return pinnedCapsuleMember{}, errors.New("recovery capsule entries must be regular files")
	}
	file := os.NewFile(uintptr(fd), name)
	identity, err := fileState(file)
	if err != nil {
		_ = file.Close()
		return pinnedCapsuleMember{}, err
	}
	if identity.mode&syscall.S_IFMT != syscall.S_IFREG {
		_ = file.Close()
		return pinnedCapsuleMember{}, errors.New("recovery capsule entries must be regular files")
	}
	if identity.links != 1 {
		_ = file.Close()
		return pinnedCapsuleMember{}, errors.New("recovery capsule entries must have one link")
	}
	if identity.size < 0 || identity.size > capsuleMemberLimit(name) {
		_ = file.Close()
		return pinnedCapsuleMember{}, fmt.Errorf("recovery capsule member %s exceeds its size budget", name)
	}
	return pinnedCapsuleMember{name: name, file: file, identity: identity}, nil
}

func capsuleMemberLimit(name string) int64 {
	switch name {
	case "MANIFEST.sha256":
		return maxRecoveryManifestBytes
	case "RECOVERY.json":
		return maxRecoveryIdentityBytes
	case "repository.bundle":
		return maxRecoveryBundleBytes
	default:
		return 0
	}
}

func closePinnedCapsuleMembers(members []pinnedCapsuleMember) {
	for _, member := range members {
		_ = member.file.Close()
	}
}

func copyPinnedCapsuleMembers(snapshot string, members []pinnedCapsuleMember) error {
	for _, member := range members {
		path := filepath.Join(snapshot, member.name)
		if err := copyPinnedCapsuleMember(path, member); err != nil {
			return err
		}
	}
	return syncDirectory(snapshot)
}

func copyPinnedCapsuleMember(path string, member pinnedCapsuleMember) error {
	if _, err := member.file.Seek(0, 0); err != nil {
		return err
	}
	destination, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	written, copyErr := io.CopyN(destination, member.file, member.identity.size)
	var extra [1]byte
	extraCount, tailErr := member.file.Read(extra[:])
	syncErr := destination.Sync()
	closeErr := destination.Close()
	if copyErr != nil && !errors.Is(copyErr, io.EOF) {
		return copyErr
	}
	if written != member.identity.size || extraCount != 0 || !errors.Is(tailErr, io.EOF) {
		return errors.New("recovery capsule member changed during snapshot")
	}
	if syncErr != nil || closeErr != nil {
		return errors.Join(syncErr, closeErr)
	}
	after, err := fileState(member.file)
	if err != nil {
		return err
	}
	if !sameStableFile(member.identity, after) {
		return errors.New("recovery capsule member changed during snapshot")
	}
	return nil
}

func verifyPinnedMemberNames(directory *os.File, members []pinnedCapsuleMember) error {
	for _, member := range members {
		reopened, err := openPinnedCapsuleMember(directory, member.name)
		if err != nil {
			return errors.New("recovery capsule changed during snapshot")
		}
		if err := reopened.file.Close(); err != nil {
			return err
		}
		if !sameFileObject(member.identity, reopened.identity) {
			return errors.New("recovery capsule changed during snapshot")
		}
	}
	return nil
}
