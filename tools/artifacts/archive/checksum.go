package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const maxDetachedChecksumBytes = 512

func verifyDetachedChecksum(path string) error {
	if err := validateVerificationInput(path); err != nil {
		return err
	}
	if err := validateVerificationInput(path + ".sha256"); err != nil {
		return fmt.Errorf("detached checksum: %w", err)
	}
	data, err := readSmallFile(path+".sha256", maxDetachedChecksumBytes)
	if err != nil {
		return fmt.Errorf("detached checksum: %w", err)
	}
	parts, err := parseDetachedChecksum(data)
	if err != nil {
		return err
	}
	if parts[1] != filepath.Base(path) {
		return errors.New("detached checksum filename does not match archive")
	}
	actual, err := hashFile(path)
	if err != nil {
		return err
	}
	if parts[0] != actual {
		return errors.New("detached archive checksum mismatch")
	}
	return nil
}

func parseDetachedChecksum(data []byte) ([2]string, error) {
	var result [2]string
	if !bytes.HasSuffix(data, []byte("\n")) || bytes.Count(data, []byte("\n")) != 1 {
		return result, errors.New("detached checksum must contain exactly one newline-terminated record")
	}
	line := strings.TrimSuffix(string(data), "\n")
	parts := strings.SplitN(line, "  ", 2)
	if len(parts) != 2 || !validDigest(parts[0]) || parts[1] == "" || strings.ContainsAny(parts[1], "/\\\r\n") {
		return result, errors.New("detached checksum has invalid format")
	}
	result[0], result[1] = parts[0], parts[1]
	return result, nil
}

func writeDetachedChecksum(path string) error {
	digest, err := hashFile(path)
	if err != nil {
		return err
	}
	line := fmt.Sprintf("%s  %s\n", digest, filepath.Base(path))
	return writeAtomicFile(path+".sha256", []byte(line), 0o644)
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func readSmallFile(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("file exceeds %d bytes", limit)
	}
	return data, nil
}

func writeAtomicFile(path string, data []byte, mode os.FileMode) error {
	file, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(mode); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	if err := closeSynced(file); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}
