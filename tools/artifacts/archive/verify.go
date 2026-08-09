package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

func verifyArchive(path string) error {
	return verifyArchiveWithLimits(path, defaultLimits)
}

func verifyArchiveWithLimits(path string, limits archiveLimits) error {
	if err := validateVerificationInput(path); err != nil {
		return err
	}
	if err := limits.validate(); err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.Size() > limits.maxArchiveBytes {
		return fmt.Errorf("archive exceeds %d bytes", limits.maxArchiveBytes)
	}
	reader, err := zip.OpenReader(path)
	if err != nil {
		return err
	}
	defer reader.Close()
	if reader.Comment != "" {
		return errors.New("archive comment is not allowed")
	}
	files, manifest, err := readArchive(reader.File, limits)
	if err != nil {
		return err
	}
	expected, err := parseManifest(manifest, limits)
	if err != nil {
		return err
	}
	return compareManifest(files, expected)
}

func readArchive(files []*zip.File, limits archiveLimits) (map[string][]byte, []byte, error) {
	if len(files) > limits.maxEntries+1 {
		return nil, nil, fmt.Errorf("archive entry count exceeds %d", limits.maxEntries)
	}
	contents := make(map[string][]byte, len(files))
	var manifest []byte
	var payloadBytes int64
	previousName := ""
	for _, file := range files {
		if err := validateZipHeader(file, limits.maxPathBytes); err != nil {
			return nil, nil, err
		}
		if previousName != "" && file.Name <= previousName {
			return nil, nil, fmt.Errorf("archive entries are not strictly sorted: %s", file.Name)
		}
		previousName = file.Name
		if _, exists := contents[file.Name]; exists || (file.Name == manifestName && manifest != nil) {
			return nil, nil, fmt.Errorf("duplicate archive path %s", file.Name)
		}
		limit := limits.maxEntryBytes
		if file.Name == manifestName {
			limit = limits.maxManifestBytes
		}
		data, err := readZipFileBounded(file, limit)
		if err != nil {
			return nil, nil, err
		}
		if file.Name == manifestName {
			manifest = data
			continue
		}
		if int64(len(data)) > limits.maxPayloadBytes-payloadBytes {
			return nil, nil, fmt.Errorf("archive payload exceeds %d bytes", limits.maxPayloadBytes)
		}
		if containsHomePath(data) {
			return nil, nil, fmt.Errorf("absolute workstation home path detected in %s", file.Name)
		}
		payloadBytes += int64(len(data))
		contents[file.Name] = data
	}
	if manifest == nil {
		return nil, nil, errors.New("archive manifest is missing")
	}
	return contents, manifest, nil
}

func validateZipHeader(file *zip.File, maxPathBytes int) error {
	clean := filepath.ToSlash(filepath.Clean(file.Name))
	if file.Name == "" || len(file.Name) > maxPathBytes || strings.ContainsAny(file.Name, "\r\n") ||
		strings.HasPrefix(file.Name, "/") || clean != file.Name || strings.HasPrefix(clean, "../") {
		return fmt.Errorf("unsafe archive path %q", file.Name)
	}
	if file.FileInfo().IsDir() || !file.Mode().IsRegular() || file.Mode()&fs.ModeSymlink != 0 {
		return fmt.Errorf("unsupported archive entry %s", file.Name)
	}
	if file.Method != zip.Store || file.CompressedSize64 != file.UncompressedSize64 {
		return fmt.Errorf("noncanonical compression for %s", file.Name)
	}
	if file.ModifiedDate != 33 || file.ModifiedTime != 0 || len(file.Extra) != 0 || file.Comment != "" || file.NonUTF8 {
		return fmt.Errorf("non-normalized metadata for %s", file.Name)
	}
	if mode := file.Mode().Perm(); mode != 0o644 && mode != 0o755 {
		return fmt.Errorf("non-normalized mode %o for %s", mode, file.Name)
	}
	return nil
}

func readZipFileBounded(file *zip.File, limit int64) ([]byte, error) {
	if file.UncompressedSize64 > uint64(limit) {
		return nil, fmt.Errorf("archive entry %s exceeds %d bytes", file.Name, limit)
	}
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("archive entry %s exceeds %d bytes", file.Name, limit)
	}
	return data, nil
}

func parseManifest(data []byte, limits archiveLimits) (map[string]string, error) {
	if len(data) > 0 && !bytes.HasSuffix(data, []byte("\n")) {
		return nil, errors.New("archive manifest must end with a newline")
	}
	expected := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), int(limits.maxManifestBytes))
	previousName := ""
	for scanner.Scan() {
		parts := strings.SplitN(scanner.Text(), "  ", 2)
		if len(parts) != 2 || !validDigest(parts[0]) {
			return nil, fmt.Errorf("invalid manifest line %q", scanner.Text())
		}
		if parts[1] == manifestName {
			return nil, fmt.Errorf("forbidden manifest entry %s", parts[1])
		}
		if err := validateManifestPath(parts[1], limits.maxPathBytes); err != nil {
			return nil, err
		}
		if previousName != "" && parts[1] <= previousName {
			return nil, fmt.Errorf("manifest entries are not strictly sorted: %s", parts[1])
		}
		previousName = parts[1]
		if len(expected) >= limits.maxEntries {
			return nil, fmt.Errorf("manifest entry count exceeds %d", limits.maxEntries)
		}
		if _, exists := expected[parts[1]]; exists {
			return nil, fmt.Errorf("duplicate manifest entry %s", parts[1])
		}
		expected[parts[1]] = parts[0]
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return expected, nil
}

func validDigest(value string) bool {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func validateManifestPath(name string, maxPathBytes int) error {
	clean := filepath.ToSlash(filepath.Clean(name))
	if name == "" || len(name) > maxPathBytes || strings.ContainsAny(name, "\r\n") ||
		strings.HasPrefix(name, "/") || clean != name || strings.HasPrefix(clean, "../") {
		return fmt.Errorf("unsafe manifest path %q", name)
	}
	return nil
}

func compareManifest(files map[string][]byte, expected map[string]string) error {
	if len(files) != len(expected) {
		return fmt.Errorf("manifest/file count mismatch: manifest=%d files=%d", len(expected), len(files))
	}
	for name, data := range files {
		digest := sha256.Sum256(data)
		actual := hex.EncodeToString(digest[:])
		if expected[name] != actual {
			return fmt.Errorf("checksum mismatch for %s", name)
		}
	}
	return nil
}
