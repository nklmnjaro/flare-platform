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

func TestCheckLinesFailsClosedForOversizedToken(t *testing.T) {
	path := writeFixture(t, "huge.sh", strings.Repeat("x", maxScannedLine+1))
	findings := checkLines(path)
	if len(findings) != 1 || !strings.Contains(findings[0], "scan error") {
		t.Fatalf("expected scan error, got %v", findings)
	}
}

func TestCheckShellFunctionsRejectsLargeFunction(t *testing.T) {
	body := "large() {\n" + strings.Repeat("  true\n", maxFunctionLines) + "}\n"
	path := writeFixture(t, "large.sh", body)
	if findings := checkShellFunctions(path); len(findings) != 1 {
		t.Fatalf("expected one shell-function finding, got %v", findings)
	}
}

func TestCheckShellFunctionsCountsNestedBraceGroups(t *testing.T) {
	body := "large() {\n  {\n    true\n  }\n" + strings.Repeat("  true\n", maxFunctionLines) + "}\n"
	path := writeFixture(t, "nested.sh", body)
	if findings := checkShellFunctions(path); len(findings) != 1 {
		t.Fatalf("expected nested function finding, got %v", findings)
	}
}

func TestCheckShellFunctionsRecognizesKeywordSyntax(t *testing.T) {
	body := "function large {\n" + strings.Repeat("  true\n", maxFunctionLines) + "}\n"
	path := writeFixture(t, "keyword.sh", body)
	if findings := checkShellFunctions(path); len(findings) != 1 {
		t.Fatalf("expected keyword function finding, got %v", findings)
	}
}

func TestShellFunctionNameRecognizesSupportedSyntaxes(t *testing.T) {
	for _, line := range []string{"plain() {", "plain () {", "function keyword {", "function keyword() {"} {
		if _, matched := shellFunctionName(line); !matched {
			t.Fatalf("expected function syntax to match: %s", line)
		}
	}
}

func TestShellBraceDeltaIgnoresQuotesAndParameterExpansion(t *testing.T) {
	line := `printf '%s' "{}" "${value#prefix}" # } ignored`
	if delta := shellBraceDelta(line); delta != 0 {
		t.Fatalf("expected balanced shell line, got delta %d", delta)
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
