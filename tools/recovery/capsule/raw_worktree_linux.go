//go:build linux

package main

import (
	"bytes"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"unsafe"
)

const (
	maxTrackedDirectories = 100_000
	worktreeReadBatch     = 256
)

type trackedEntry struct {
	Mode     string
	ObjectID string
	Path     string
}

type trackedNode struct {
	children map[string]*trackedNode
	entry    *trackedEntry
}

type rawWorktreeBudget struct {
	entries int
	bytes   int64
}

func exactHeadIndexEntries(
	identity repositoryIdentity,
	runner *gitRunner,
) ([]trackedEntry, error) {
	treeOutput, err := runner.runLarge(
		identity.Root, nil, "ls-tree", "-r", "-z", "--full-tree", identity.Commit)
	if err != nil {
		return nil, err
	}
	tree, err := parseHeadTreeEntries(treeOutput, identity.ObjectFormat)
	if err != nil {
		return nil, err
	}
	indexOutput, err := runner.runLarge(identity.Root, nil, "ls-files", "--stage", "-z")
	if err != nil {
		return nil, err
	}
	index, err := parseIndexEntries(indexOutput, identity.ObjectFormat)
	if err != nil {
		return nil, err
	}
	if !sameTrackedEntries(tree, index) {
		return nil, errRepositoryNotClean
	}
	return tree, nil
}

func parseHeadTreeEntries(payload []byte, objectFormat string) ([]trackedEntry, error) {
	return parseTrackedRecords(payload, func(record []byte) (trackedEntry, error) {
		header, path, found := bytes.Cut(record, []byte{'\t'})
		if !found {
			return trackedEntry{}, errors.New("HEAD tree entry is malformed")
		}
		fields := bytes.Fields(header)
		if len(fields) != 3 {
			return trackedEntry{}, errors.New("HEAD tree entry header is malformed")
		}
		mode := string(fields[0])
		objectType := string(fields[1])
		if !validTrackedModeAndType(mode, objectType) {
			return trackedEntry{}, errors.New("HEAD tree contains an unsupported entry")
		}
		return newTrackedEntry(mode, string(fields[2]), string(path), objectFormat)
	})
}

func parseIndexEntries(payload []byte, objectFormat string) ([]trackedEntry, error) {
	return parseTrackedRecords(payload, func(record []byte) (trackedEntry, error) {
		header, path, found := bytes.Cut(record, []byte{'\t'})
		if !found {
			return trackedEntry{}, errors.New("index entry is malformed")
		}
		fields := bytes.Fields(header)
		if len(fields) != 3 || string(fields[2]) != "0" {
			return trackedEntry{}, errRepositoryNotClean
		}
		mode := string(fields[0])
		if !validTrackedMode(mode) {
			return trackedEntry{}, errors.New("index contains an unsupported entry")
		}
		return newTrackedEntry(mode, string(fields[1]), string(path), objectFormat)
	})
}

func parseTrackedRecords(
	payload []byte,
	parse func([]byte) (trackedEntry, error),
) ([]trackedEntry, error) {
	records := bytes.Split(payload, []byte{0})
	entries := make([]trackedEntry, 0, len(records))
	seen := make(map[string]struct{}, len(records))
	for _, record := range records {
		if len(record) == 0 {
			continue
		}
		if len(entries) >= maxRecoveredFiles {
			return nil, errors.New("tracked worktree exceeds file-count budget")
		}
		entry, err := parse(record)
		if err != nil {
			return nil, err
		}
		if _, found := seen[entry.Path]; found {
			return nil, errors.New("tracked worktree contains a duplicate path")
		}
		seen[entry.Path] = struct{}{}
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(left, right int) bool {
		return entries[left].Path < entries[right].Path
	})
	return entries, nil
}

func newTrackedEntry(
	mode string,
	objectID string,
	path string,
	objectFormat string,
) (trackedEntry, error) {
	if !validObjectIDForFormat(objectID, objectFormat) {
		return trackedEntry{}, errors.New("tracked object ID is malformed")
	}
	if err := validateTrackedPath(path); err != nil {
		return trackedEntry{}, err
	}
	return trackedEntry{Mode: mode, ObjectID: objectID, Path: path}, nil
}

func validTrackedMode(mode string) bool {
	switch mode {
	case "100644", "100755", "120000", "160000":
		return true
	default:
		return false
	}
}

func validTrackedModeAndType(mode, objectType string) bool {
	if mode == "160000" {
		return objectType == "commit"
	}
	return validTrackedMode(mode) && objectType == "blob"
}

func validateTrackedPath(path string) error {
	if path == "" || len(path) > maxRecoveredPathBytes || filepath.IsAbs(path) ||
		filepath.Clean(path) != path {
		return errors.New("tracked worktree path is unsafe")
	}
	for _, component := range strings.Split(path, "/") {
		if component == "" || component == "." || component == ".." {
			return errors.New("tracked worktree path is unsafe")
		}
	}
	return nil
}

func sameTrackedEntries(left, right []trackedEntry) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func verifyRawTrackedWorktree(
	root *os.File,
	entries []trackedEntry,
	objectFormat string,
) error {
	tree, err := buildTrackedTree(entries)
	if err != nil {
		return err
	}
	budget := &rawWorktreeBudget{}
	return verifyTrackedDirectory(root, tree, true, objectFormat, budget)
}

func buildTrackedTree(entries []trackedEntry) (*trackedNode, error) {
	root := &trackedNode{children: make(map[string]*trackedNode)}
	directories := 0
	for index := range entries {
		components := strings.Split(entries[index].Path, "/")
		if components[0] == ".git" || components[0] == ".platform" {
			return nil, errors.New("tracked worktree uses a reserved root path")
		}
		current := root
		for componentIndex, component := range components {
			child, found := current.children[component]
			if !found {
				child = &trackedNode{children: make(map[string]*trackedNode)}
				current.children[component] = child
				if componentIndex != len(components)-1 {
					directories++
				}
			}
			if componentIndex != len(components)-1 && child.entry != nil {
				return nil, errors.New("tracked worktree path hierarchy is malformed")
			}
			current = child
		}
		if current.entry != nil || len(current.children) != 0 {
			return nil, errors.New("tracked worktree path hierarchy is malformed")
		}
		current.entry = &entries[index]
	}
	if directories > maxTrackedDirectories {
		return nil, errors.New("tracked worktree exceeds directory-count budget")
	}
	return root, nil
}

func verifyTrackedDirectory(
	directory *os.File,
	expected *trackedNode,
	root bool,
	objectFormat string,
	budget *rawWorktreeBudget,
) error {
	before, err := fileState(directory)
	if err != nil {
		return err
	}
	if _, err := directory.Seek(0, 0); err != nil {
		return err
	}
	seen := make(map[string]struct{}, len(expected.children))
	for {
		entries, readErr := directory.ReadDir(worktreeReadBatch)
		for _, entry := range entries {
			if root && entry.Name() == ".git" {
				continue
			}
			if root && entry.Name() == ".platform" {
				if err := verifyPrivatePlatformDirectory(directory); err != nil {
					return err
				}
				continue
			}
			budget.entries++
			if budget.entries > maxRecoveredFiles+maxTrackedDirectories {
				return errors.New("worktree exceeds entry-count budget")
			}
			child, found := expected.children[entry.Name()]
			if !found {
				return errRepositoryNotClean
			}
			if _, duplicate := seen[entry.Name()]; duplicate {
				return errors.New("worktree directory contains a duplicate entry")
			}
			seen[entry.Name()] = struct{}{}
			if err := verifyTrackedNode(directory, entry.Name(), child, objectFormat, budget); err != nil {
				return err
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return readErr
		}
	}
	if len(seen) != len(expected.children) {
		return errRepositoryNotClean
	}
	after, err := fileState(directory)
	if err != nil {
		return err
	}
	if !sameStableFile(before, after) {
		return errors.New("worktree changed during raw inspection")
	}
	return nil
}

func verifyPrivatePlatformDirectory(root *os.File) error {
	directory, err := openDirectoryAt(root, ".platform")
	if err != nil {
		return errors.New("repository .platform must be a private non-symlink directory")
	}
	defer directory.Close()
	before, err := fileState(directory)
	if err != nil {
		return err
	}
	if before.mode&syscall.S_IFMT != syscall.S_IFDIR || before.mode&0o777 != 0o700 ||
		before.links < 2 {
		return errors.New("repository .platform must be a private non-symlink directory")
	}
	var stat syscall.Stat_t
	if err := syscall.Fstat(int(directory.Fd()), &stat); err != nil {
		return err
	}
	if int(stat.Uid) != os.Geteuid() {
		return errors.New("repository .platform must be owned by the effective user")
	}
	reopened, err := openDirectoryAt(root, ".platform")
	if err != nil {
		return errors.New("repository .platform changed during inspection")
	}
	defer reopened.Close()
	after, err := fileState(reopened)
	if err != nil {
		return err
	}
	if !sameFileObject(before, after) {
		return errors.New("repository .platform changed during inspection")
	}
	return nil
}

func verifyTrackedNode(
	parent *os.File,
	name string,
	node *trackedNode,
	objectFormat string,
	budget *rawWorktreeBudget,
) error {
	if node.entry != nil {
		if len(node.children) != 0 {
			return errors.New("tracked worktree path hierarchy is malformed")
		}
		return verifyTrackedLeaf(parent, name, *node.entry, objectFormat, budget)
	}
	directory, err := openDirectoryAt(parent, name)
	if err != nil {
		return errRepositoryNotClean
	}
	defer directory.Close()
	return verifyTrackedDirectory(directory, node, false, objectFormat, budget)
}

func verifyTrackedLeaf(
	parent *os.File,
	name string,
	entry trackedEntry,
	objectFormat string,
	budget *rawWorktreeBudget,
) error {
	switch entry.Mode {
	case "100644", "100755":
		return verifyTrackedRegularFile(parent, name, entry, objectFormat, budget)
	case "120000":
		return verifyTrackedSymlink(parent, name, entry, objectFormat, budget)
	case "160000":
		return errors.New("submodule gitlinks are unsupported in reachable recovery history")
	default:
		return errors.New("tracked worktree entry mode is unsupported")
	}
}

func verifyTrackedRegularFile(
	parent *os.File,
	name string,
	entry trackedEntry,
	objectFormat string,
	budget *rawWorktreeBudget,
) error {
	flags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_NONBLOCK | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(parent.Fd()), name, flags, 0)
	if err != nil {
		return errRepositoryNotClean
	}
	file := os.NewFile(uintptr(fd), name)
	defer file.Close()
	before, err := fileState(file)
	if err != nil {
		return err
	}
	if before.mode&syscall.S_IFMT != syscall.S_IFREG || before.links != 1 ||
		!trackedExecutableModeMatches(before.mode, entry.Mode) {
		return errRepositoryNotClean
	}
	if err := addRawFileBudget(budget, before.size); err != nil {
		return err
	}
	observed, err := hashOpenGitBlob(file, before.size, objectFormat)
	if err != nil {
		return err
	}
	after, err := fileState(file)
	if err != nil {
		return err
	}
	if !sameStableFile(before, after) {
		return errors.New("tracked file changed during raw inspection")
	}
	if observed != entry.ObjectID {
		return errRepositoryNotClean
	}
	return nil
}

func trackedExecutableModeMatches(observed uint32, expected string) bool {
	executable := observed&0o111 != 0
	return executable == (expected == "100755")
}

func verifyTrackedSymlink(
	parent *os.File,
	name string,
	entry trackedEntry,
	objectFormat string,
	budget *rawWorktreeBudget,
) error {
	flags := linuxOPath | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(parent.Fd()), name, flags, 0)
	if err != nil {
		return errRepositoryNotClean
	}
	file := os.NewFile(uintptr(fd), name)
	defer file.Close()
	before, err := fileState(file)
	if err != nil {
		return err
	}
	if before.mode&syscall.S_IFMT != syscall.S_IFLNK || before.links != 1 {
		return errRepositoryNotClean
	}
	recoveryFilesystemBarrier(recoveryBarrierSymlinkPinned)
	target, err := readPinnedSymlink(fd)
	if err != nil {
		return err
	}
	if err := addRawFileBudget(budget, int64(len(target))); err != nil {
		return err
	}
	after, err := fileState(file)
	if err != nil {
		return err
	}
	if !sameStableFile(before, after) || before.size != int64(len(target)) {
		return errors.New("tracked symlink changed during raw inspection")
	}
	reopenedFD, err := syscall.Openat(int(parent.Fd()), name, flags, 0)
	if err != nil {
		return errors.New("tracked symlink name changed during raw inspection")
	}
	reopened := os.NewFile(uintptr(reopenedFD), name)
	reopenedState, stateErr := fileState(reopened)
	closeErr := reopened.Close()
	if stateErr != nil || closeErr != nil || !sameFileObject(before, reopenedState) {
		return errors.New("tracked symlink name changed during raw inspection")
	}
	observed, err := hashGitBlobBytes([]byte(target), objectFormat)
	if err != nil {
		return err
	}
	if observed != entry.ObjectID {
		return errRepositoryNotClean
	}
	return nil
}

func readPinnedSymlink(fd int) (string, error) {
	empty, err := syscall.BytePtrFromString("")
	if err != nil {
		return "", err
	}
	buffer := make([]byte, maxRecoveredPathBytes+1)
	count, _, errno := syscall.Syscall6(syscall.SYS_READLINKAT,
		uintptr(fd), uintptr(unsafe.Pointer(empty)),
		uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)), 0, 0)
	if errno != 0 {
		return "", errno
	}
	if count == 0 || count >= uintptr(len(buffer)) {
		return "", errors.New("tracked symlink target exceeds length budget")
	}
	return string(buffer[:count]), nil
}

func addRawFileBudget(budget *rawWorktreeBudget, size int64) error {
	if size < 0 || size > maxRecoveredFileBytes {
		return errors.New("recovery source file exceeds size budget")
	}
	budget.bytes += size
	if budget.bytes > maxRecoveredTreeBytes {
		return errors.New("recovery source worktree exceeds total-size budget")
	}
	return nil
}

func hashOpenGitBlob(file *os.File, size int64, objectFormat string) (string, error) {
	digest, err := newGitObjectHash(objectFormat)
	if err != nil {
		return "", err
	}
	if _, err := fmt.Fprintf(digest, "blob %d%c", size, byte(0)); err != nil {
		return "", err
	}
	written, err := io.CopyN(digest, file, size)
	if err != nil || written != size {
		return "", errors.New("tracked file changed during raw inspection")
	}
	var tail [1]byte
	count, tailErr := file.Read(tail[:])
	if count != 0 || !errors.Is(tailErr, io.EOF) {
		return "", errors.New("tracked file changed during raw inspection")
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func hashGitBlobBytes(content []byte, objectFormat string) (string, error) {
	digest, err := newGitObjectHash(objectFormat)
	if err != nil {
		return "", err
	}
	if _, err := fmt.Fprintf(digest, "blob %d%c", len(content), byte(0)); err != nil {
		return "", err
	}
	if _, err := digest.Write(content); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func newGitObjectHash(objectFormat string) (hash.Hash, error) {
	switch objectFormat {
	case "sha1":
		return sha1.New(), nil
	case "sha256":
		return sha256.New(), nil
	default:
		return nil, errors.New("unsupported Git object format for raw worktree hashing")
	}
}
