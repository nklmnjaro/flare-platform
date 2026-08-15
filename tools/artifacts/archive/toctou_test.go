package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPackRejectsSourceRootSwapAtBarrier(t *testing.T) {
	base := t.TempDir()
	source := filepath.Join(base, "source")
	if err := os.Mkdir(source, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "payload.txt"), []byte("trusted\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	moved := filepath.Join(base, "source.original")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierSourceRootResolved || triggered {
			return
		}
		triggered = true
		if err := os.Rename(source, moved); err != nil {
			hookErr = err
			return
		}
		if err := os.Mkdir(source, 0o755); err != nil {
			hookErr = err
			return
		}
		hookErr = os.WriteFile(filepath.Join(source, "payload.txt"), []byte("replacement\n"), 0o644)
	})

	output := filepath.Join(t.TempDir(), "artifact.zip")
	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("source-root swap barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("source-root swap barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "source directory changed while it was pinned") {
		t.Fatalf("expected source-root race rejection, got %v", err)
	}
	assertPublicationAbsent(t, output)
}

func TestPackRejectsSourceEntrySwapAtBarrier(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	payload := filepath.Join(source, "payload.txt")
	moved := filepath.Join(source, "payload.original")
	outside := filepath.Join(t.TempDir(), "outside.txt")
	if err := os.WriteFile(outside, []byte("outside\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var hookErr error
	triggered := false
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierSourceEntryPinned || triggered {
			return
		}
		triggered = true
		if err := os.Rename(payload, moved); err != nil {
			hookErr = err
			return
		}
		hookErr = os.Symlink(outside, payload)
	})

	output := filepath.Join(t.TempDir(), "artifact.zip")
	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("source swap barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("source swap barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "changed while being opened") {
		t.Fatalf("expected source-entry race rejection, got %v", err)
	}
	assertPublicationAbsent(t, output)
}

func TestPackRejectsSourceMutationAtBarrier(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	payload := filepath.Join(source, "payload.txt")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierSourceFileRead || triggered {
			return
		}
		triggered = true
		hookErr = os.WriteFile(payload, []byte("mutated after read\n"), 0o644)
	})

	output := filepath.Join(t.TempDir(), "artifact.zip")
	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("source mutation barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("source mutation barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "source file changed while being read") {
		t.Fatalf("expected source-mutation race rejection, got %v", err)
	}
	assertPublicationAbsent(t, output)
}

func TestPackRejectsOutputParentSwapAtBarrier(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	base := t.TempDir()
	parent := filepath.Join(base, "published")
	if err := os.Mkdir(parent, 0o755); err != nil {
		t.Fatal(err)
	}
	moved := filepath.Join(base, "published.original")
	output := filepath.Join(parent, "artifact.zip")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierBeforeArchivePublish || triggered {
			return
		}
		triggered = true
		if err := os.Rename(parent, moved); err != nil {
			hookErr = err
			return
		}
		hookErr = os.Mkdir(parent, 0o755)
	})

	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("output-parent swap barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("output-parent swap barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "output parent path changed") {
		t.Fatalf("expected output-parent race rejection, got %v", err)
	}
	assertPublicationAbsent(t, output)
	assertPublicationAbsent(t, filepath.Join(moved, "artifact.zip"))
}

func TestPackDoesNotReplaceRacingArchiveTarget(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	output := filepath.Join(t.TempDir(), "artifact.zip")
	sentinel := []byte("racing owner\n")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierBeforeArchivePublish || triggered {
			return
		}
		triggered = true
		hookErr = os.WriteFile(output, sentinel, 0o644)
	})

	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("archive-target race barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("archive-target race barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "publication target already exists") {
		t.Fatalf("expected no-replace archive rejection, got %v", err)
	}
	assertFileContent(t, output, sentinel)
	if _, statErr := os.Lstat(output + ".sha256"); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("failed archive publication created a checksum: %v", statErr)
	}
}

func TestPackDoesNotReplaceRacingChecksumTarget(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	output := filepath.Join(t.TempDir(), "artifact.zip")
	sentinel := []byte("racing checksum owner\n")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierBeforeChecksumPublish || triggered {
			return
		}
		triggered = true
		hookErr = os.WriteFile(output+".sha256", sentinel, 0o644)
	})

	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("checksum-target race barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("checksum-target race barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "publication target already exists") {
		t.Fatalf("expected no-replace checksum rejection, got %v", err)
	}
	assertFileContent(t, output+".sha256", sentinel)
	if verifyErr := verifyArchive(output); verifyErr != nil {
		t.Fatalf("published archive changed during checksum race: %v", verifyErr)
	}
}

func TestPackRejectsArchiveReplacementBetweenPairPublications(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	output := filepath.Join(t.TempDir(), "artifact.zip")
	displaced := output + ".original"
	sentinel := []byte("replacement archive\n")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierBeforeChecksumPublish || triggered {
			return
		}
		triggered = true
		if err := os.Rename(output, displaced); err != nil {
			hookErr = err
			return
		}
		hookErr = os.WriteFile(output, sentinel, 0o644)
	})

	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("between-publication replacement barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("between-publication replacement barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "published archive") {
		t.Fatalf("expected final archive identity rejection, got %v", err)
	}
	assertFileContent(t, output, sentinel)
	if verifyErr := verifyArchive(displaced); verifyErr != nil {
		t.Fatalf("original published archive was altered: %v", verifyErr)
	}
}

func TestPackRejectsPublishedChecksumReplacementAtFinalBarrier(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	output := filepath.Join(t.TempDir(), "artifact.zip")
	checksum := output + ".sha256"
	displaced := checksum + ".original"
	sentinel := []byte("replacement checksum\n")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierBeforePairVerification || triggered {
			return
		}
		triggered = true
		if err := os.Rename(checksum, displaced); err != nil {
			hookErr = err
			return
		}
		hookErr = os.WriteFile(checksum, sentinel, 0o644)
	})

	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("published-checksum replacement barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("published-checksum replacement barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "published checksum") {
		t.Fatalf("expected final checksum identity rejection, got %v", err)
	}
	assertFileContent(t, checksum, sentinel)
}

func TestVerifyPinsArchiveAndChecksumAcrossEntireOperation(t *testing.T) {
	firstSource := fixtureDirectory(t, map[string]string{"payload.txt": "first\n"})
	secondSource := fixtureDirectory(t, map[string]string{"payload.txt": "second\n"})
	directory := t.TempDir()
	first := filepath.Join(directory, "first.zip")
	second := filepath.Join(directory, "second.zip")
	if err := packDirectory(firstSource, first); err != nil {
		t.Fatal(err)
	}
	if err := packDirectory(secondSource, second); err != nil {
		t.Fatal(err)
	}
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierVerificationArchiveRead || triggered {
			return
		}
		triggered = true
		operations := [][2]string{
			{first, first + ".original"},
			{first + ".sha256", first + ".sha256.original"},
			{second, first},
			{second + ".sha256", first + ".sha256"},
		}
		for _, operation := range operations {
			if err := os.Rename(operation[0], operation[1]); err != nil {
				hookErr = err
				return
			}
		}
	})

	err := run([]string{"verify", "--archive", first}, io.Discard)
	if hookErr != nil {
		t.Fatalf("verification pair-swap barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("verification pair-swap barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "verification archive identity or contents changed") {
		t.Fatalf("expected pinned verification-pair rejection, got %v", err)
	}
}

func TestVerifyRejectsInPlacePairMutationAfterArchiveValidation(t *testing.T) {
	firstSource := fixtureDirectory(t, map[string]string{"payload.txt": "first\n"})
	secondSource := fixtureDirectory(t, map[string]string{"payload.txt": "second\n"})
	first := filepath.Join(t.TempDir(), "artifact.zip")
	second := filepath.Join(t.TempDir(), "artifact.zip")
	if err := packDirectory(firstSource, first); err != nil {
		t.Fatal(err)
	}
	if err := packDirectory(secondSource, second); err != nil {
		t.Fatal(err)
	}
	secondArchive, err := os.ReadFile(second)
	if err != nil {
		t.Fatal(err)
	}
	secondChecksum, err := os.ReadFile(second + ".sha256")
	if err != nil {
		t.Fatal(err)
	}
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierVerificationArchiveRead || triggered {
			return
		}
		triggered = true
		if err := os.WriteFile(first, secondArchive, 0o644); err != nil {
			hookErr = err
			return
		}
		hookErr = os.WriteFile(first+".sha256", secondChecksum, 0o644)
	})

	err = run([]string{"verify", "--archive", first}, io.Discard)
	if hookErr != nil {
		t.Fatalf("in-place verification mutation barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("in-place verification mutation barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "identity or contents changed") {
		t.Fatalf("expected in-place verification rejection, got %v", err)
	}
}

func TestPackRejectsInPlaceArchiveStageMutation(t *testing.T) {
	replacementSource := fixtureDirectory(t, map[string]string{"payload.txt": "replacement\n"})
	replacement := filepath.Join(t.TempDir(), "replacement.zip")
	if err := packDirectory(replacementSource, replacement); err != nil {
		t.Fatal(err)
	}
	replacementBytes, err := os.ReadFile(replacement)
	if err != nil {
		t.Fatal(err)
	}
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	output := filepath.Join(t.TempDir(), "artifact.zip")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierBeforeArchivePublish || triggered {
			return
		}
		triggered = true
		hookErr = overwriteArchiveStage(filepath.Dir(output), "zip", replacementBytes)
	})

	err = packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("archive-stage mutation barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("archive-stage mutation barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "archive staging file changed") {
		t.Fatalf("expected archive-stage mutation rejection, got %v", err)
	}
	assertPublicationAbsent(t, output)
}

func TestPackRejectsInPlaceChecksumStageMutation(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
	output := filepath.Join(t.TempDir(), "artifact.zip")
	triggered := false
	var hookErr error
	installArchiveBarrier(t, func(point string) {
		if point != archiveBarrierBeforeChecksumPublish || triggered {
			return
		}
		triggered = true
		hookErr = overwriteArchiveStage(
			filepath.Dir(output),
			"sha256",
			[]byte("mutated checksum stage\n"),
		)
	})

	err := packDirectory(source, output)
	if hookErr != nil {
		t.Fatalf("checksum-stage mutation barrier: %v", hookErr)
	}
	if !triggered {
		t.Fatal("checksum-stage mutation barrier was not reached")
	}
	if err == nil || !strings.Contains(err.Error(), "archive staging file changed") {
		t.Fatalf("expected checksum-stage mutation rejection, got %v", err)
	}
	if verifyErr := verifyArchive(output); verifyErr != nil {
		t.Fatalf("archive published before checksum rejection was altered: %v", verifyErr)
	}
	if _, statErr := os.Lstat(output + ".sha256"); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("mutated checksum stage was published: %v", statErr)
	}
}

func TestPackRejectsExistingPublicationTargetsWithoutClobbering(t *testing.T) {
	for _, suffix := range []string{"", ".sha256"} {
		t.Run("suffix="+suffix, func(t *testing.T) {
			source := fixtureDirectory(t, map[string]string{"payload.txt": "trusted\n"})
			output := filepath.Join(t.TempDir(), "artifact.zip")
			target := output + suffix
			sentinel := []byte("existing owner\n")
			if err := os.WriteFile(target, sentinel, 0o644); err != nil {
				t.Fatal(err)
			}

			err := packDirectory(source, output)
			if err == nil || !strings.Contains(err.Error(), "publication target already exists") {
				t.Fatalf("expected existing-target rejection, got %v", err)
			}
			assertFileContent(t, target, sentinel)
		})
	}
}

func installArchiveBarrier(t *testing.T, hook func(string)) {
	t.Helper()
	previous := archiveFilesystemBarrier
	archiveFilesystemBarrier = hook
	t.Cleanup(func() { archiveFilesystemBarrier = previous })
}

func assertPublicationAbsent(t *testing.T, output string) {
	t.Helper()
	for _, path := range []string{output, output + ".sha256"} {
		if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("unexpected publication %s: %v", path, err)
		}
	}
}

func assertFileContent(t *testing.T, path string, expected []byte) {
	t.Helper()
	actual, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, expected) {
		t.Fatalf("file %s was replaced: got %q want %q", path, actual, expected)
	}
}

func overwriteArchiveStage(directory, label string, data []byte) error {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	prefix := ".flare-artifact-" + label + "-"
	var matches []string
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), prefix) {
			matches = append(matches, filepath.Join(directory, entry.Name()))
		}
	}
	if len(matches) != 1 {
		return fmt.Errorf("expected one %s stage, found %d", label, len(matches))
	}
	return os.WriteFile(matches[0], data, 0o644)
}
