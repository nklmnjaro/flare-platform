package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const recoveryHostTempRoot = "/tmp"

func recoveryMkdirTemp(pattern string) (string, error) {
	if err := validateRecoveryTempRoot(); err != nil {
		return "", err
	}
	return os.MkdirTemp(recoveryHostTempRoot, pattern)
}

func validateRecoveryTempRoot() error {
	info, err := os.Lstat(recoveryHostTempRoot)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("recovery temp root must be a non-symlink directory")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || info.Mode()&os.ModeSticky == 0 {
		return errors.New("recovery temp root must be root-owned and sticky")
	}
	return nil
}

func canonicalDirectory(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fmt.Errorf("path is not a directory: %s", path)
	}
	return filepath.Clean(resolved), nil
}

func canonicalCapsuleDirectory(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("recovery capsule root must not be a symlink")
	}
	return canonicalDirectory(absolute)
}

func pathWithin(path, root string) bool {
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	if relative == "." {
		return true
	}
	outsidePrefix := ".." + string(os.PathSeparator)
	return relative != ".." && !strings.HasPrefix(relative, outsidePrefix)
}

func redactDiagnostic(message string) string {
	for _, value := range []string{os.Getenv("HOME"), os.Getenv("USERPROFILE")} {
		if value != "" {
			message = strings.ReplaceAll(message, value, "<HOME>")
		}
	}
	return message
}
