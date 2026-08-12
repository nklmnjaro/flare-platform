//go:build linux

package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"syscall"
)

const maxRepositoryConfigBytes = 1 << 20

var includeSectionPattern = regexp.MustCompile(
	`(?i)^include(?:if[[:space:]]+"(?:[^"\\]|\\.)*")?$`)

type repositoryConfigSnapshot struct {
	state  stableFileState
	digest string
}

func inspectRepositoryConfig(gitDirectory *os.File) (repositoryConfigSnapshot, error) {
	config, err := openRegularAt(gitDirectory, "config", maxRepositoryConfigBytes)
	if err != nil {
		return repositoryConfigSnapshot{}, err
	}
	defer config.Close()
	before, err := fileState(config)
	if err != nil {
		return repositoryConfigSnapshot{}, err
	}
	payload, err := io.ReadAll(io.LimitReader(config, maxRepositoryConfigBytes+1))
	if err != nil {
		return repositoryConfigSnapshot{}, err
	}
	if len(payload) > maxRepositoryConfigBytes {
		return repositoryConfigSnapshot{}, errors.New("repository config exceeds size budget")
	}
	after, err := fileState(config)
	if err != nil || !sameStableFile(before, after) {
		return repositoryConfigSnapshot{}, errors.New("repository config changed during inspection")
	}
	if err := rejectConfigIncludes(payload); err != nil {
		return repositoryConfigSnapshot{}, err
	}
	digest, err := hashGitBlobBytes(payload, "sha256")
	return repositoryConfigSnapshot{state: before, digest: digest}, err
}

func rejectConfigIncludes(payload []byte) error {
	section := ""
	for _, rawLine := range bytes.Split(payload, []byte{'\n'}) {
		line := strings.TrimSpace(string(bytes.TrimSuffix(rawLine, []byte{'\r'})))
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			end := strings.IndexByte(line, ']')
			if end < 1 {
				return errors.New("repository config is malformed")
			}
			trailing := strings.TrimSpace(line[end+1:])
			if trailing != "" && !strings.HasPrefix(trailing, "#") &&
				!strings.HasPrefix(trailing, ";") {
				return errors.New("repository config is malformed")
			}
			section = strings.TrimSpace(line[1:end])
			continue
		}
		key := line
		if before, _, found := strings.Cut(line, "="); found {
			key = before
		}
		fields := strings.Fields(key)
		if len(fields) == 0 {
			return errors.New("repository config is malformed")
		}
		key = strings.ToLower(fields[0])
		if includeSectionPattern.MatchString(section) && key == "path" {
			return errors.New("repository config includes are unsupported in recovery source")
		}
		if strings.EqualFold(section, "extensions") && key == "worktreeconfig" {
			return errors.New("extensions.worktreeConfig is unsupported in recovery source")
		}
	}
	return nil
}

func rejectPinnedAlternates(gitDirectory *os.File) error {
	objects, err := openDirectoryAt(gitDirectory, "objects")
	if err != nil {
		return err
	}
	defer objects.Close()
	info, err := openOptionalDirectoryAt(objects, "info")
	if err != nil || info == nil {
		return err
	}
	defer info.Close()
	before, err := fileState(info)
	if err != nil {
		return err
	}
	flags := linuxOPath | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(info.Fd()), "alternates", flags, 0)
	if err == nil {
		_ = syscall.Close(fd)
		return errors.New("Git object alternates are unsupported in recovery source")
	}
	if !errors.Is(err, syscall.ENOENT) {
		return fmt.Errorf("repository object alternates cannot be inspected safely: %w", err)
	}
	after, err := fileState(info)
	if err != nil || !sameStableFile(before, after) {
		return errors.New("repository object info directory changed during inspection")
	}
	return nil
}

func rejectPinnedCommonDirectory(gitDirectory *os.File) error {
	flags := linuxOPath | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(gitDirectory.Fd()), "commondir", flags, 0)
	if err == nil {
		_ = syscall.Close(fd)
		return errors.New("Git common-directory indirection is unsupported in recovery source")
	}
	if errors.Is(err, syscall.ENOENT) {
		return nil
	}
	return fmt.Errorf("Git common-directory metadata cannot be inspected safely: %w", err)
}

func verifyRepositoryConfig(
	gitDirectory *os.File,
	expected repositoryConfigSnapshot,
) error {
	current, err := inspectRepositoryConfig(gitDirectory)
	if err != nil {
		return err
	}
	if !sameStableFile(expected.state, current.state) || expected.digest != current.digest {
		return fmt.Errorf("repository config changed during capture")
	}
	return nil
}

func rejectPinnedGrafts(gitDirectory *os.File) error {
	infoDirectory, err := openOptionalDirectoryAt(gitDirectory, "info")
	if err != nil || infoDirectory == nil {
		return err
	}
	defer infoDirectory.Close()
	grafts, err := openOptionalRegularAt(infoDirectory, "grafts", maxRepositoryConfigBytes)
	if err != nil || grafts == nil {
		return err
	}
	defer grafts.Close()
	state, err := fileState(grafts)
	if err != nil {
		return err
	}
	if state.size != 0 {
		return errors.New("Git grafts are unsupported in recovery source")
	}
	return nil
}

func rejectPinnedPromisorMarkers(gitDirectory *os.File) error {
	objects, err := openDirectoryAt(gitDirectory, "objects")
	if err != nil {
		return err
	}
	defer objects.Close()
	pack, err := openOptionalDirectoryAt(objects, "pack")
	if err != nil || pack == nil {
		return err
	}
	defer pack.Close()
	before, err := fileState(pack)
	if err != nil {
		return err
	}
	if _, err := pack.Seek(0, 0); err != nil {
		return err
	}
	entries, err := pack.ReadDir(-1)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".promisor") {
			return errors.New("partial or promisor clone is unsupported in recovery source")
		}
	}
	after, err := fileState(pack)
	if err != nil {
		return err
	}
	if !sameStableFile(before, after) {
		return errors.New("repository object pack directory changed during inspection")
	}
	return nil
}

func openOptionalDirectoryAt(parent *os.File, name string) (*os.File, error) {
	directory, err := openDirectoryAt(parent, name)
	if errors.Is(err, syscall.ENOENT) {
		return nil, nil
	}
	return directory, err
}

func openRegularAt(parent *os.File, name string, limit int64) (*os.File, error) {
	file, err := openOptionalRegularAt(parent, name, limit)
	if err != nil {
		return nil, err
	}
	if file == nil {
		return nil, errors.New("required repository metadata file is absent")
	}
	return file, nil
}

func openOptionalRegularAt(parent *os.File, name string, limit int64) (*os.File, error) {
	flags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_NONBLOCK | syscall.O_CLOEXEC
	fd, err := syscall.Openat(int(parent.Fd()), name, flags, 0)
	if errors.Is(err, syscall.ENOENT) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	state, err := fileState(file)
	if err != nil {
		_ = file.Close()
		return nil, err
	}
	if state.mode&syscall.S_IFMT != syscall.S_IFREG || state.links != 1 ||
		state.size < 0 || state.size > limit {
		_ = file.Close()
		return nil, errors.New("repository metadata file is unsafe")
	}
	return file, nil
}
