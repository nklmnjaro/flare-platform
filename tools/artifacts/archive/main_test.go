package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunReportsPathFreeSuccess(t *testing.T) {
	source := fixtureDirectory(t, map[string]string{"payload.txt": "safe\n"})
	archive := filepath.Join(t.TempDir(), "artifact.zip")
	var output bytes.Buffer

	if err := run([]string{"pack", "--source", source, "--output", archive}, &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "PASS  artifact      packed and verified\n" {
		t.Fatalf("unexpected pack output %q", output.String())
	}

	output.Reset()
	if err := run([]string{"verify", "--archive", archive}, &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "PASS  artifact      verified\n" {
		t.Fatalf("unexpected verify output %q", output.String())
	}
}

func TestDiagnosticHomePathsAreRedacted(t *testing.T) {
	input := strings.Join([]string{
		"source=" + unixHome("alice") + "/project",
		"windows=" + windowsHomeBackslash("Alice") + `\project`,
		"root=" + rootHome() + "/.config",
	}, " ")
	redacted := redactDiagnosticHomePaths(input)
	if containsHomePath([]byte(redacted)) {
		t.Fatalf("redacted diagnostic still contains a home path: %q", redacted)
	}
	if strings.Contains(strings.ToLower(redacted), "alice") {
		t.Fatalf("redacted diagnostic still contains a synthetic username: %q", redacted)
	}
	if strings.Count(redacted, "<home>") != 3 {
		t.Fatalf("unexpected redacted diagnostic %q", redacted)
	}
	for _, suffix := range []string{"<home>/project", `<home>\project`, "<home>/.config"} {
		if !strings.Contains(redacted, suffix) {
			t.Fatalf("redacted diagnostic lost useful suffix %q: %q", suffix, redacted)
		}
	}
}
