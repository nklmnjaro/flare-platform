package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type archiveEntry struct {
	name string
	data []byte
	mode fs.FileMode
}

func packDirectory(source, output string) error {
	return packDirectoryWithLimits(source, output, defaultLimits)
}

func packDirectoryWithLimits(source, output string, limits archiveLimits) error {
	if err := limits.validate(); err != nil {
		return err
	}
	root, err := canonicalSourceRoot(source)
	if err != nil {
		return err
	}
	target, err := canonicalOutputPath(root, output)
	if err != nil {
		return err
	}
	entries, err := collectEntries(root, limits)
	if err != nil {
		return err
	}
	manifest := manifestEntry(entries)
	if int64(len(manifest.data)) > limits.maxManifestBytes {
		return fmt.Errorf("archive manifest exceeds %d bytes", limits.maxManifestBytes)
	}
	entries = append(entries, manifest)
	if err := publishArchive(target, entries, limits); err != nil {
		return err
	}
	if err := writeDetachedChecksum(target); err != nil {
		return err
	}
	if err := verifyDetachedChecksum(target); err != nil {
		return fmt.Errorf("detached checksum self-verification failed: %w", err)
	}
	return nil
}

func collectEntries(root string, limits archiveLimits) ([]archiveEntry, error) {
	var entries []archiveEntry
	var payloadBytes int64
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		return collectPath(root, path, entry, walkErr, limits, &payloadBytes, &entries)
	})
	if err != nil {
		return nil, err
	}
	if len(entries) == 0 {
		return nil, fmt.Errorf("source directory contains no regular files")
	}
	sort.Slice(entries, func(left, right int) bool { return entries[left].name < entries[right].name })
	return entries, nil
}

func collectPath(
	root string,
	path string,
	entry fs.DirEntry,
	walkErr error,
	limits archiveLimits,
	payloadBytes *int64,
	entries *[]archiveEntry,
) error {
	if walkErr != nil {
		return walkErr
	}
	if path == root || entry.IsDir() {
		return nil
	}
	if len(*entries) >= limits.maxEntries {
		return fmt.Errorf("archive entry count exceeds %d", limits.maxEntries)
	}
	info, err := entry.Info()
	if err != nil {
		return err
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		return fmt.Errorf("symlinks are not allowed in durable artifacts: %s", path)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("special files are not allowed in durable artifacts: %s", path)
	}
	name, err := archiveEntryName(root, path, limits.maxPathBytes)
	if err != nil {
		return err
	}
	data, err := readSourceFile(path, limits.maxEntryBytes)
	if err != nil {
		return fmt.Errorf("read %s: %w", name, err)
	}
	if int64(len(data)) > limits.maxPayloadBytes-*payloadBytes {
		return fmt.Errorf("archive payload exceeds %d bytes", limits.maxPayloadBytes)
	}
	if containsHomePath(data) {
		return fmt.Errorf("absolute workstation home path detected in %s", name)
	}
	*payloadBytes += int64(len(data))
	*entries = append(*entries, archiveEntry{name: name, data: data, mode: normalizedMode(info.Mode())})
	return nil
}

func archiveEntryName(root, path string, maxPathBytes int) (string, error) {
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return "", err
	}
	name := filepath.ToSlash(relative)
	if err := validateArchivePath(name, maxPathBytes); err != nil {
		return "", err
	}
	if name == manifestName {
		return "", fmt.Errorf("source must not contain reserved file %s", manifestName)
	}
	return name, nil
}

func readSourceFile(path string, limit int64) ([]byte, error) {
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

func manifestEntry(entries []archiveEntry) archiveEntry {
	var manifest strings.Builder
	for _, entry := range entries {
		digest := sha256.Sum256(entry.data)
		fmt.Fprintf(&manifest, "%s  %s\n", hex.EncodeToString(digest[:]), entry.name)
	}
	return archiveEntry{name: manifestName, data: []byte(manifest.String()), mode: 0o644}
}

func publishArchive(output string, entries []archiveEntry, limits archiveLimits) error {
	temporary, err := createTemporary(output)
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)

	writeErr := writeZip(temporary, entries)
	closeErr := closeSynced(temporary)
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	if err := verifyArchiveWithLimits(temporaryName, limits); err != nil {
		return fmt.Errorf("archive self-verification failed: %w", err)
	}
	return os.Rename(temporaryName, output)
}

func createTemporary(output string) (*os.File, error) {
	file, err := os.CreateTemp(filepath.Dir(output), "."+filepath.Base(output)+".tmp-*")
	if err != nil {
		return nil, err
	}
	if err := file.Chmod(0o644); err != nil {
		_ = file.Close()
		_ = os.Remove(file.Name())
		return nil, err
	}
	return file, nil
}

func closeSynced(file *os.File) error {
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

func writeZip(target io.Writer, entries []archiveEntry) error {
	writer := zip.NewWriter(target)
	sort.Slice(entries, func(left, right int) bool { return entries[left].name < entries[right].name })
	for _, entry := range entries {
		if err := writeZipEntry(writer, entry); err != nil {
			_ = writer.Close()
			return err
		}
	}
	return writer.Close()
}

func writeZipEntry(writer *zip.Writer, entry archiveEntry) error {
	header := &zip.FileHeader{Name: entry.name, Method: zip.Store, ModifiedDate: 33, ModifiedTime: 0}
	header.SetMode(entry.mode)
	header.Extra = nil
	file, err := writer.CreateHeader(header)
	if err != nil {
		return err
	}
	_, err = file.Write(entry.data)
	return err
}
