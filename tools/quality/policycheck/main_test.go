package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCheckLinesRejectsLongLine(t *testing.T) {
	path := writeFixture(t, "line.sh", "# "+strings.Repeat("x", maxLineLength)+"\n")
	if findings := checkLines(path); len(findings) != 1 {
		t.Fatalf("expected one long-line finding, got %v", findings)
	}
}

func TestCheckShellFunctionsRejectsLargeFunction(t *testing.T) {
	body := "large() {\n" + strings.Repeat("  true\n", maxFunctionLines) + "}\n"
	path := writeFixture(t, "large.sh", body)
	if findings := checkShellFunctions(path); len(findings) != 1 {
		t.Fatalf("expected one shell-function finding, got %v", findings)
	}
}

func TestCheckGoFunctionsRejectsLargeFunction(t *testing.T) {
	body := "package fixture\nfunc large() {\n" + strings.Repeat("println(1)\n", maxFunctionLines) + "}\n"
	path := writeFixture(t, "large.go", body)
	if findings := checkGoFunctions(path); len(findings) != 1 {
		t.Fatalf("expected one Go-function finding, got %v", findings)
	}
}

func writeFixture(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
