package main

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func unixHome(user string) string {
	return "/" + "home/" + user
}

func macHome(user string) string {
	return "/" + "Users/" + user
}

func rootHome() string {
	return "/" + "root"
}

func windowsHomeBackslash(user string) string {
	return "C:" + `\Users\` + user
}

func windowsHomeSlash(user string) string {
	return "C:" + "/" + "Users/" + user
}

func TestPackRejectsBinaryHomePath(t *testing.T) {
	source := t.TempDir()
	payload := append([]byte{0}, []byte("prefix "+unixHome("alice")+"/private/project")...)
	payload = append(payload, 0)
	if err := os.WriteFile(filepath.Join(source, "blob.bin"), payload, 0o644); err != nil {
		t.Fatal(err)
	}
	err := packDirectory(source, filepath.Join(t.TempDir(), "artifact.zip"))
	if err == nil || !strings.Contains(err.Error(), "home path") {
		t.Fatalf("expected binary home-path rejection, got %v", err)
	}
}

func TestVerifyRejectsBinaryHomePath(t *testing.T) {
	payload := append([]byte{0}, []byte("prefix "+unixHome("alice")+"/private/project")...)
	payload = append(payload, 0)
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	if err := writeRawArchive(archive, entriesWithManifest(map[string][]byte{"blob.bin": payload})); err != nil {
		t.Fatal(err)
	}
	err := verifyArchive(archive)
	if err == nil || !strings.Contains(err.Error(), "home path") {
		t.Fatalf("expected binary home-path rejection, got %v", err)
	}
}

func TestPackRejectsSymlinkSource(t *testing.T) {
	realSource := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	link := filepath.Join(t.TempDir(), "source-link")
	if err := os.Symlink(realSource, link); err != nil {
		t.Fatal(err)
	}
	err := packDirectory(link, filepath.Join(t.TempDir(), "artifact.zip"))
	if err == nil || !strings.Contains(err.Error(), "must not be a symlink") {
		t.Fatalf("expected source-symlink rejection, got %v", err)
	}
}

func TestPackResolvesOutputParentBeforeBoundaryCheck(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	inside := filepath.Join(source, "published")
	if err := os.Mkdir(inside, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "output-link")
	if err := os.Symlink(inside, link); err != nil {
		t.Fatal(err)
	}
	err := packDirectory(source, filepath.Join(link, "artifact.zip"))
	if err == nil || !strings.Contains(err.Error(), "outside") {
		t.Fatalf("expected resolved output-boundary rejection, got %v", err)
	}
}

func TestPackRejectsInsideOutputWithoutCreatingParent(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	parent := filepath.Join(source, "must-not-be-created")
	err := packDirectory(source, filepath.Join(parent, "artifact.zip"))
	if err == nil || !strings.Contains(err.Error(), "outside") {
		t.Fatalf("expected output-boundary rejection, got %v", err)
	}
	if _, statErr := os.Lstat(parent); !os.IsNotExist(statErr) {
		t.Fatalf("rejected pack created output parent: %v", statErr)
	}
}

func TestHomePathPolicyCatchesDelimitedPathsWithoutMatchingURLs(t *testing.T) {
	for _, payload := range [][]byte{
		[]byte("path:" + unixHome("alice") + "/project/file"),
		[]byte{0, '/', 'r', 'o', 'o', 't', '/', '.', 's', 's', 'h', '/', 'i', 'd'},
		[]byte("value=" + windowsHomeBackslash("Alice") + `\project\file`),
	} {
		if !containsHomePath(payload) {
			t.Fatalf("expected home path detection for %q", payload)
		}
	}
	if containsHomePath([]byte("https://example.test" + unixHome("alice") + "/index")) {
		t.Fatal("URL path was incorrectly treated as a workstation home path")
	}
}

func TestPackDoesNotClobberPredictableTemporarySymlink(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	output := filepath.Join(t.TempDir(), "artifact.zip")
	sentinel := filepath.Join(t.TempDir(), "sentinel.txt")
	if err := os.WriteFile(sentinel, []byte("do-not-touch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(sentinel, output+".tmp"); err != nil {
		t.Fatal(err)
	}
	if err := packDirectory(source, output); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(sentinel)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, []byte("do-not-touch\n")) {
		t.Fatalf("predictable temporary symlink was followed: %q", data)
	}
}

func TestPackRejectsDetachedChecksumSymlink(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	output := filepath.Join(t.TempDir(), "artifact.zip")
	sentinel := filepath.Join(t.TempDir(), "sentinel.txt")
	if err := os.WriteFile(sentinel, []byte("do-not-touch\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(sentinel, output+".sha256"); err != nil {
		t.Fatal(err)
	}
	err := packDirectory(source, output)
	if err == nil || !strings.Contains(err.Error(), "symlink publication target") {
		t.Fatalf("expected checksum-symlink rejection, got %v", err)
	}
	data, readErr := os.ReadFile(sentinel)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Equal(data, []byte("do-not-touch\n")) {
		t.Fatalf("detached checksum symlink was followed: %q", data)
	}
}

func TestVerifyRejectsDeflatedArchive(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	files := map[string][]byte{"payload.txt": bytes.Repeat([]byte("A"), 4096)}
	if err := writeCompressedArchive(archive, files); err != nil {
		t.Fatal(err)
	}
	err := verifyArchive(archive)
	if err == nil || !strings.Contains(err.Error(), "noncanonical compression") {
		t.Fatalf("expected compressed-entry rejection, got %v", err)
	}
}

func TestPackAllowsNestedArchive(t *testing.T) {
	source := t.TempDir()
	if err := os.WriteFile(filepath.Join(source, "nested.zip"), []byte("nested fixture\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	if err := packDirectory(source, archive); err != nil {
		t.Fatal(err)
	}
	if err := verifyArchive(archive); err != nil {
		t.Fatal(err)
	}
}

func TestPackRejectsConfiguredEntryLimit(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "12345"})
	limits := defaultLimits
	limits.maxEntryBytes = 4
	err := packDirectoryWithLimits(source, filepath.Join(t.TempDir(), "artifact.zip"), limits)
	if err == nil || !strings.Contains(err.Error(), "exceeds 4 bytes") {
		t.Fatalf("expected entry-size rejection, got %v", err)
	}
}

func TestVerifyRejectsConfiguredPayloadLimit(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"first.txt": "123", "second.txt": "456"})
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	if err := packDirectory(source, archive); err != nil {
		t.Fatal(err)
	}
	limits := defaultLimits
	limits.maxPayloadBytes = 5
	err := verifyArchiveWithLimits(archive, limits)
	if err == nil || !strings.Contains(err.Error(), "payload exceeds 5 bytes") {
		t.Fatalf("expected total-payload rejection, got %v", err)
	}
}

func TestVerifyRejectsConfiguredArchiveFileLimit(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "ok\n"})
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	if err := packDirectory(source, archive); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(archive)
	if err != nil {
		t.Fatal(err)
	}
	limits := defaultLimits
	limits.maxArchiveBytes = info.Size() - 1
	err = verifyArchiveWithLimits(archive, limits)
	if err == nil || !strings.Contains(err.Error(), "archive exceeds") {
		t.Fatalf("expected archive-file-size rejection, got %v", err)
	}
}

func TestVerifyRejectsConfiguredEntryCount(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"first.txt": "1", "second.txt": "2"})
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	if err := packDirectory(source, archive); err != nil {
		t.Fatal(err)
	}
	limits := defaultLimits
	limits.maxEntries = 1
	err := verifyArchiveWithLimits(archive, limits)
	if err == nil || !strings.Contains(err.Error(), "entry count exceeds 1") {
		t.Fatalf("expected entry-count rejection, got %v", err)
	}
}

func entriesWithManifest(files map[string][]byte) []archiveEntry {
	entries := make([]archiveEntry, 0, len(files)+1)
	for name, data := range files {
		entries = append(entries, archiveEntry{name: name, data: data, mode: 0o644})
	}
	return append(entries, manifestEntry(entries))
}

func writeCompressedArchive(path string, files map[string][]byte) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	writer := zip.NewWriter(file)
	entries := entriesWithManifest(files)
	for _, entry := range entries {
		header := &zip.FileHeader{Name: entry.name, Method: zip.Deflate, ModifiedDate: 33, ModifiedTime: 0}
		header.SetMode(entry.mode)
		target, createErr := writer.CreateHeader(header)
		if createErr != nil {
			_ = writer.Close()
			_ = file.Close()
			return createErr
		}
		if _, writeErr := target.Write(entry.data); writeErr != nil {
			_ = writer.Close()
			_ = file.Close()
			return writeErr
		}
	}
	if err := writer.Close(); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

func TestVerifyRejectsHiddenBytesOutsideEntries(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "safe\n"})
	original := filepath.Join(t.TempDir(), "original.zip")
	if err := packDirectory(source, original); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(original)
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string][]byte{
		"prefix": append([]byte("hidden-prefix "+unixHome("alice")+"\n"), data...),
		"suffix": append(append([]byte(nil), data...), []byte("hidden-suffix "+unixHome("alice")+"\n")...),
	}
	for name, mutated := range cases {
		t.Run(name, func(t *testing.T) {
			archive := filepath.Join(t.TempDir(), name+".zip")
			if err := os.WriteFile(archive, mutated, 0o644); err != nil {
				t.Fatal(err)
			}
			err := verifyArchive(archive)
			if err == nil || !strings.Contains(err.Error(), "byte encoding is not canonical") {
				t.Fatalf("expected hidden-byte rejection, got %v", err)
			}
		})
	}
}

func TestPackRejectsNonportableSourcePaths(t *testing.T) {
	cases := map[string]func(string) error{
		"backslash": func(source string) error {
			return os.WriteFile(filepath.Join(source, `..\escape.txt`), []byte("unsafe\n"), 0o644)
		},
		"drive-prefix": func(source string) error {
			if err := os.Mkdir(filepath.Join(source, "C:"), 0o755); err != nil {
				return err
			}
			return os.WriteFile(filepath.Join(source, "C:", "escape.txt"), []byte("unsafe\n"), 0o644)
		},
	}
	for name, prepare := range cases {
		t.Run(name, func(t *testing.T) {
			source := t.TempDir()
			if err := prepare(source); err != nil {
				t.Fatal(err)
			}
			err := packDirectory(source, filepath.Join(t.TempDir(), "artifact.zip"))
			if err == nil || !strings.Contains(err.Error(), "unsafe archive path") {
				t.Fatalf("expected portable-path rejection, got %v", err)
			}
		})
	}
}

func TestVerifyRejectsNonportableArchivePaths(t *testing.T) {
	for _, name := range []string{`..\escape.txt`, "C:/escape.txt", "C:escape.txt", "."} {
		t.Run(name, func(t *testing.T) {
			archive := filepath.Join(t.TempDir(), "artifact.zip")
			entries := entriesWithManifest(map[string][]byte{name: []byte("unsafe\n")})
			if err := writeRawArchive(archive, entries); err != nil {
				t.Fatal(err)
			}
			err := verifyArchive(archive)
			if err == nil || !strings.Contains(err.Error(), "unsafe archive path") {
				t.Fatalf("expected portable-path rejection, got %v", err)
			}
		})
	}
}

func TestHomePathPolicyRejectsTerminalHomeDirectories(t *testing.T) {
	for _, payload := range [][]byte{
		[]byte("path=" + unixHome("alice")),
		[]byte("path=" + macHome("Alice")),
		[]byte("path=" + rootHome()),
		[]byte("path=" + windowsHomeBackslash("Alice")),
		[]byte("path=" + windowsHomeSlash("Alice")),
	} {
		if !containsHomePath(payload) {
			t.Fatalf("expected terminal home-path detection for %q", payload)
		}
	}
	for _, payload := range [][]byte{
		[]byte("https://example.test" + unixHome("alice")),
		[]byte("relative/rooted"),
		[]byte("/rooted/path"),
		[]byte("/root-symlink"),
		[]byte("/root.state"),
	} {
		if containsHomePath(payload) {
			t.Fatalf("unexpected home-path detection for %q", payload)
		}
	}
}
