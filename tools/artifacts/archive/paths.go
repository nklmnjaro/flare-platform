package main

import (
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
)

func canonicalSourceRoot(source string) (string, error) {
	root, err := filepath.Abs(source)
	if err != nil {
		return "", err
	}
	info, err := os.Lstat(root)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return "", fmt.Errorf("source directory must not be a symlink: %s", source)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("source is not a directory: %s", source)
	}
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	return resolved, nil
}

func canonicalOutputPath(root, output string) (string, error) {
	target, err := filepath.Abs(output)
	if err != nil {
		return "", err
	}
	resolvedParent, err := resolveProspectiveDirectory(filepath.Dir(target))
	if err != nil {
		return "", err
	}
	base := filepath.Base(target)
	if strings.ContainsAny(base, "\r\n") {
		return "", fmt.Errorf("output archive name contains a newline: %q", base)
	}
	target = filepath.Join(resolvedParent, base)
	if err := ensureOutputOutsideSource(root, target); err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return "", err
	}
	if err := validatePublishTarget(target); err != nil {
		return "", err
	}
	if err := validatePublishTarget(target + ".sha256"); err != nil {
		return "", err
	}
	return target, nil
}

func resolveProspectiveDirectory(path string) (string, error) {
	current := filepath.Clean(path)
	var missing []string
	for {
		info, err := os.Stat(current)
		if err == nil {
			if !info.IsDir() {
				return "", fmt.Errorf("output parent is not a directory: %s", current)
			}
			resolved, resolveErr := filepath.EvalSymlinks(current)
			if resolveErr != nil {
				return "", resolveErr
			}
			for index := len(missing) - 1; index >= 0; index-- {
				resolved = filepath.Join(resolved, missing[index])
			}
			return resolved, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("unable to resolve output parent: %s", path)
		}
		missing = append(missing, filepath.Base(current))
		current = parent
	}
}

func ensureOutputOutsideSource(root, target string) error {
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return err
	}
	if relative == "." || (!strings.HasPrefix(relative, ".."+string(filepath.Separator)) && relative != "..") {
		return errors.New("output archive must be outside the source directory")
	}
	return nil
}

func validatePublishTarget(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing symlink publication target: %s", path)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("publication target is not a regular file: %s", path)
	}
	return nil
}

func validateVerificationInput(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("verification input must not be a symlink: %s", path)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("verification input is not a regular file: %s", path)
	}
	return nil
}

func validateArchivePath(name string, maxPathBytes int) error {
	clean := path.Clean(name)
	if name == "" || len(name) > maxPathBytes || containsControlByte(name) ||
		strings.Contains(name, `\`) || strings.HasPrefix(name, "/") ||
		clean != name || clean == "." || clean == ".." || strings.HasPrefix(clean, "../") ||
		hasWindowsDrivePrefix(name) {
		return fmt.Errorf("unsafe archive path %q", name)
	}
	return nil
}

func containsControlByte(value string) bool {
	for index := 0; index < len(value); index++ {
		if value[index] < 0x20 || value[index] == 0x7f {
			return true
		}
	}
	return false
}

func hasWindowsDrivePrefix(value string) bool {
	if len(value) < 2 || value[1] != ':' {
		return false
	}
	letter := value[0]
	return letter >= 'A' && letter <= 'Z' || letter >= 'a' && letter <= 'z'
}
