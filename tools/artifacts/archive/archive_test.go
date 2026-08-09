package main

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPackIsDeterministic(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"bin/run.sh": "#!/bin/sh\ntrue\n", "README.md": "ok\n"})
	if err := os.Chmod(filepath.Join(source, "bin/run.sh"), 0o751); err != nil {
		t.Fatal(err)
	}
	first := filepath.Join(t.TempDir(), "first.zip")
	second := filepath.Join(t.TempDir(), "second.zip")
	if err := packDirectory(source, first); err != nil {
		t.Fatal(err)
	}
	if err := packDirectory(source, second); err != nil {
		t.Fatal(err)
	}
	assertSameFile(t, first, second)
}

func TestVerifyRejectsTamperedContent(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "original\n"})
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	if err := packDirectory(source, archive); err != nil {
		t.Fatal(err)
	}
	if err := rewriteEntry(archive, "payload.txt", []byte("tampered\n")); err != nil {
		t.Fatal(err)
	}
	if err := verifyArchive(archive); err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("expected checksum mismatch, got %v", err)
	}
}

func TestPackRejectsOutputInsideSource(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	err := packDirectory(source, filepath.Join(source, "artifact.zip"))
	if err == nil || !strings.Contains(err.Error(), "outside") {
		t.Fatalf("expected output-boundary rejection, got %v", err)
	}
}

func TestPackRejectsAbsoluteHomePath(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"leak.txt": "path=/home/alice/project\n"})
	err := packDirectory(source, filepath.Join(t.TempDir(), "artifact.zip"))
	if err == nil || !strings.Contains(err.Error(), "home path") {
		t.Fatalf("expected home-path rejection, got %v", err)
	}
}

func TestDetachedChecksumRejectsArchiveMutation(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	if err := packDirectory(source, archive); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(archive, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("tamper"); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := verifyDetachedChecksum(archive); err == nil {
		t.Fatal("expected detached checksum mismatch")
	}
}

func TestManifestDoesNotHashItselfOrArchive(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	if err := packDirectory(source, archive); err != nil {
		t.Fatal(err)
	}
	manifest := readNamedEntry(t, archive, manifestName)
	if bytes.Contains(manifest, []byte(manifestName)) || bytes.Contains(manifest, []byte("artifact.zip")) {
		t.Fatalf("manifest contains forbidden self-reference: %s", manifest)
	}
}

func fixtureDirectory(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, content := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func assertSameFile(t *testing.T, left, right string) {
	t.Helper()
	leftData, err := os.ReadFile(left)
	if err != nil {
		t.Fatal(err)
	}
	rightData, err := os.ReadFile(right)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(leftData, rightData) {
		t.Fatal("deterministic packs differ")
	}
}

func readNamedEntry(t *testing.T, archive, name string) []byte {
	t.Helper()
	reader, err := zip.OpenReader(archive)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	for _, file := range reader.File {
		if file.Name == name {
			data, readErr := readZipFile(file)
			if readErr != nil {
				t.Fatal(readErr)
			}
			return data
		}
	}
	t.Fatalf("entry %s not found", name)
	return nil
}

func rewriteEntry(archive, target string, replacement []byte) error {
	reader, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer reader.Close()
	var entries []archiveEntry
	for _, file := range reader.File {
		data, readErr := readZipFile(file)
		if readErr != nil {
			return readErr
		}
		if file.Name == target {
			data = replacement
		}
		entries = append(entries, archiveEntry{name: file.Name, data: data, mode: file.Mode()})
	}
	return writeArchive(archive, entries)
}
