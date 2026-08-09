package main

import (
	"bufio"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"unicode/utf8"
)

const (
	maxLineLength    = 120
	maxFunctionLines = 80
	maxScannedLine   = 1024 * 1024
)

func main() {
	root := flag.String("root", ".", "repository root")
	path := flag.String("path", "", "single file to check, including fixtures")
	flag.Parse()

	var findings []string
	if *path == "" {
		findings = checkTree(*root)
	} else {
		findings = checkFile(*path)
	}
	for _, finding := range findings {
		fmt.Fprintln(os.Stderr, finding)
	}
	if len(findings) != 0 {
		os.Exit(1)
	}
}

func checkTree(root string) []string {
	var findings []string
	_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			findings = append(findings, fmt.Sprintf("%s: %v", path, err))
			return nil
		}
		if entry.IsDir() && shouldSkipDir(root, path) {
			return filepath.SkipDir
		}
		if !entry.IsDir() && isSource(path) {
			findings = append(findings, checkFile(path)...)
		}
		return nil
	})
	return findings
}

func shouldSkipDir(root, path string) bool {
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return relative == ".git" || relative == ".platform" || relative == "tests/fixtures"
}

func isSource(path string) bool {
	base := filepath.Base(path)
	extension := filepath.Ext(path)
	return base == "Makefile" || base == "Dockerfile" || extension == ".go" || extension == ".sh" ||
		extension == ".yaml" || extension == ".yml"
}

func checkFile(path string) []string {
	findings := checkLines(path)
	switch filepath.Ext(path) {
	case ".go":
		findings = append(findings, checkGoFunctions(path)...)
	case ".sh":
		findings = append(findings, checkShellFunctions(path)...)
	}
	return findings
}

func checkLines(path string) []string {
	file, err := os.Open(path)
	if err != nil {
		return []string{fmt.Sprintf("%s: %v", path, err)}
	}
	defer file.Close()

	var findings []string
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), maxScannedLine)
	for line := 1; scanner.Scan(); line++ {
		length := utf8.RuneCountInString(scanner.Text())
		if length > maxLineLength {
			findings = append(findings, lineFinding(path, line, length))
		}
	}
	if err := scanner.Err(); err != nil {
		findings = append(findings, fmt.Sprintf("%s: scan error: %v", path, err))
	}
	return findings
}

func lineFinding(path string, line, length int) string {
	return fmt.Sprintf("%s:%d: line has %d chars; max is %d", path, line, length, maxLineLength)
}

func checkGoFunctions(path string) []string {
	set := token.NewFileSet()
	file, err := parser.ParseFile(set, path, nil, 0)
	if err != nil {
		return []string{fmt.Sprintf("%s: parse error: %v", path, err)}
	}
	var findings []string
	ast.Inspect(file, func(node ast.Node) bool {
		function, ok := node.(*ast.FuncDecl)
		if !ok {
			return true
		}
		start := set.Position(function.Pos()).Line
		end := set.Position(function.End()).Line
		if size := end - start + 1; size > maxFunctionLines {
			findings = append(findings, functionFinding(path, function.Name.Name, start, size))
		}
		return false
	})
	return findings
}

func functionFinding(path, name string, start, size int) string {
	return fmt.Sprintf("%s:%d: function %s has %d lines; max is %d", path, start, name, size, maxFunctionLines)
}
