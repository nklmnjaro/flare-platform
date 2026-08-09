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
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

const manifestName = "MANIFEST.sha256"

var homePath = regexp.MustCompile(`(?i)(^|[\s"'"'=])(/(home|users|root)/[^/\s]+/|[a-z]:\\users\\[^\\\s]+\\)`)

type archiveEntry struct {
	name string
	data []byte
	mode fs.FileMode
}

func packDirectory(source, output string) error {
	if err := ensureOutputOutsideSource(source, output); err != nil {
		return err
	}
	entries, err := collectEntries(source)
	if err != nil {
		return err
	}
	entries = append(entries, manifestEntry(entries))
	if err := writeArchive(output, entries); err != nil {
		return err
	}
	if err := verifyArchive(output); err != nil {
		return fmt.Errorf("self-verification failed: %w", err)
	}
	return writeDetachedChecksum(output)
}

func ensureOutputOutsideSource(source, output string) error {
	root, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	target, err := filepath.Abs(output)
	if err != nil {
		return err
	}
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return err
	}
	if relative == "." || (!strings.HasPrefix(relative, ".."+string(filepath.Separator)) && relative != "..") {
		return errors.New("output archive must be outside the source directory")
	}
	return nil
}

func collectEntries(source string) ([]archiveEntry, error) {
	root, err := filepath.Abs(source)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(root)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("source is not a directory: %s", source)
	}
	var entries []archiveEntry
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		return collectPath(root, path, entry, walkErr, &entries)
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(entries, func(left, right int) bool { return entries[left].name < entries[right].name })
	return entries, nil
}

func collectPath(root, path string, entry fs.DirEntry, walkErr error, entries *[]archiveEntry) error {
	if walkErr != nil {
		return walkErr
	}
	if path == root || entry.IsDir() {
		return nil
	}
	if entry.Type()&fs.ModeSymlink != 0 {
		return fmt.Errorf("symlinks are not allowed in durable artifacts: %s", path)
	}
	if !entry.Type().IsRegular() {
		return fmt.Errorf("special files are not allowed in durable artifacts: %s", path)
	}
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return err
	}
	name := filepath.ToSlash(relative)
	if strings.ContainsAny(name, "\r\n") {
		return fmt.Errorf("archive path contains a newline: %q", name)
	}
	if name == manifestName {
		return fmt.Errorf("source must not contain reserved file %s", manifestName)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if containsHomePath(data) {
		return fmt.Errorf("absolute workstation home path detected in %s", name)
	}
	info, err := entry.Info()
	if err != nil {
		return err
	}
	*entries = append(*entries, archiveEntry{name: name, data: data, mode: normalizedMode(info.Mode())})
	return nil
}

func containsHomePath(data []byte) bool {
	if bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data) {
		return false
	}
	return homePath.Find(data) != nil
}

func normalizedMode(mode fs.FileMode) fs.FileMode {
	if mode&0o111 != 0 {
		return 0o755
	}
	return 0o644
}

func manifestEntry(entries []archiveEntry) archiveEntry {
	var manifest strings.Builder
	for _, entry := range entries {
		digest := sha256.Sum256(entry.data)
		fmt.Fprintf(&manifest, "%s  %s\n", hex.EncodeToString(digest[:]), entry.name)
	}
	return archiveEntry{name: manifestName, data: []byte(manifest.String()), mode: 0o644}
}

func writeArchive(output string, entries []archiveEntry) error {
	if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
		return err
	}
	temporary := output + ".tmp"
	file, err := os.OpenFile(temporary, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	writeErr := writeZip(file, entries)
	closeErr := file.Close()
	if writeErr != nil {
		_ = os.Remove(temporary)
		return writeErr
	}
	if closeErr != nil {
		_ = os.Remove(temporary)
		return closeErr
	}
	return os.Rename(temporary, output)
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
	header := &zip.FileHeader{
		Name:         entry.name,
		Method:       zip.Store,
		ModifiedDate: 33,
		ModifiedTime: 0,
	}
	header.SetMode(entry.mode)
	header.Extra = nil
	file, err := writer.CreateHeader(header)
	if err != nil {
		return err
	}
	_, err = file.Write(entry.data)
	return err
}

func verifyArchive(path string) error {
	reader, err := zip.OpenReader(path)
	if err != nil {
		return err
	}
	defer reader.Close()
	files, manifest, err := readArchive(reader.File)
	if err != nil {
		return err
	}
	expected, err := parseManifest(manifest)
	if err != nil {
		return err
	}
	return compareManifest(files, expected)
}

func readArchive(files []*zip.File) (map[string][]byte, []byte, error) {
	contents := make(map[string][]byte, len(files))
	var manifest []byte
	for _, file := range files {
		if err := validateZipHeader(file); err != nil {
			return nil, nil, err
		}
		if _, exists := contents[file.Name]; exists || (file.Name == manifestName && manifest != nil) {
			return nil, nil, fmt.Errorf("duplicate archive path %s", file.Name)
		}
		data, err := readZipFile(file)
		if err != nil {
			return nil, nil, err
		}
		if file.Name == manifestName {
			manifest = data
			continue
		}
		if containsHomePath(data) {
			return nil, nil, fmt.Errorf("absolute workstation home path detected in %s", file.Name)
		}
		contents[file.Name] = data
	}
	if manifest == nil {
		return nil, nil, errors.New("archive manifest is missing")
	}
	return contents, manifest, nil
}

func validateZipHeader(file *zip.File) error {
	clean := filepath.ToSlash(filepath.Clean(file.Name))
	if file.Name == "" || strings.ContainsAny(file.Name, "\r\n") || strings.HasPrefix(file.Name, "/") ||
		clean != file.Name || strings.HasPrefix(clean, "../") {
		return fmt.Errorf("unsafe archive path %q", file.Name)
	}
	if file.FileInfo().IsDir() || file.Mode()&fs.ModeSymlink != 0 {
		return fmt.Errorf("unsupported archive entry %s", file.Name)
	}
	if file.ModifiedDate != 33 || file.ModifiedTime != 0 || len(file.Extra) != 0 {
		return fmt.Errorf("non-normalized metadata for %s", file.Name)
	}
	if mode := file.Mode().Perm(); mode != 0o644 && mode != 0o755 {
		return fmt.Errorf("non-normalized mode %o for %s", mode, file.Name)
	}
	return nil
}

func readZipFile(file *zip.File) ([]byte, error) {
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	return io.ReadAll(reader)
}

func parseManifest(data []byte) (map[string]string, error) {
	expected := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		parts := strings.SplitN(scanner.Text(), "  ", 2)
		if len(parts) != 2 || len(parts[0]) != sha256.Size*2 {
			return nil, fmt.Errorf("invalid manifest line %q", scanner.Text())
		}
		if parts[1] == manifestName || strings.HasSuffix(parts[1], ".zip") {
			return nil, fmt.Errorf("forbidden manifest entry %s", parts[1])
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

func verifyDetachedChecksum(path string) error {
	data, err := os.ReadFile(path + ".sha256")
	if err != nil {
		return fmt.Errorf("detached checksum: %w", err)
	}
	parts := strings.SplitN(strings.TrimSpace(string(data)), "  ", 2)
	if len(parts) != 2 || parts[1] != filepath.Base(path) {
		return errors.New("detached checksum has invalid format or filename")
	}
	archive, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(archive)
	if parts[0] != hex.EncodeToString(digest[:]) {
		return errors.New("detached archive checksum mismatch")
	}
	return nil
}

func writeDetachedChecksum(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(data)
	line := fmt.Sprintf("%s  %s\n", hex.EncodeToString(digest[:]), filepath.Base(path))
	return os.WriteFile(path+".sha256", []byte(line), 0o644)
}
