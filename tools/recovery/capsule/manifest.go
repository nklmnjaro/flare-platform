package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const maxRecoveryBundleBytes = 64 << 20

var errRecoveryBundleTooLarge = errors.New("recovery bundle exceeds 64 MiB")

var recoveryFiles = []string{"RECOVERY.json", "repository.bundle"}

func writeManifest(directory string) error {
	manifestPath := filepath.Join(directory, "MANIFEST.sha256")
	file, err := os.OpenFile(manifestPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	for _, name := range recoveryFiles {
		digest, err := fileSHA256(filepath.Join(directory, name))
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintf(file, "%s  %s\n", digest, name); err != nil {
			return err
		}
	}
	return file.Sync()
}

func verifyManifest(directory string) error {
	manifestPath := filepath.Join(directory, "MANIFEST.sha256")
	file, err := os.Open(manifestPath)
	if err != nil {
		return err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for _, expectedName := range recoveryFiles {
		if !scanner.Scan() {
			return errors.New("recovery manifest is incomplete")
		}
		line := scanner.Text()
		digest, name, found := strings.Cut(line, "  ")
		if !found || name != expectedName || !bundleSHA256Pattern.MatchString(digest) {
			return errors.New("recovery manifest entry is not canonical")
		}
		actual, err := fileSHA256(filepath.Join(directory, name))
		if err != nil {
			return err
		}
		if actual != digest {
			return fmt.Errorf("recovery manifest mismatch for %s", name)
		}
	}
	if scanner.Scan() {
		return errors.New("recovery manifest contains extra entries")
	}
	return scanner.Err()
}

func verifyCapsuleFileSet(directory string) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	expected := map[string]bool{
		"MANIFEST.sha256":   true,
		"RECOVERY.json":     true,
		"repository.bundle": true,
	}
	if len(entries) != len(expected) {
		return errors.New("recovery capsule file set is not exact")
	}
	for _, entry := range entries {
		if !expected[entry.Name()] || entry.Type()&os.ModeSymlink != 0 {
			return errors.New("recovery capsule contains an unexpected entry")
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return errors.New("recovery capsule entries must be regular files")
		}
		if entry.Name() == "repository.bundle" && info.Size() > maxRecoveryBundleBytes {
			return errRecoveryBundleTooLarge
		}
	}
	return nil
}
