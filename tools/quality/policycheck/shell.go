package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

var (
	plainShellFunction = regexp.MustCompile(
		`^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{$`,
	)
	keywordShellFunction = regexp.MustCompile(
		`^function[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)([[:space:]]*\(\))?[[:space:]]*\{$`,
	)
)

func checkShellFunctions(path string) []string {
	content, err := os.ReadFile(path)
	if err != nil {
		return []string{fmt.Sprintf("%s: %v", path, err)}
	}
	lines := strings.Split(string(content), "\n")
	var findings []string
	for index := 0; index < len(lines); index++ {
		name, matched := shellFunctionName(strings.TrimSpace(lines[index]))
		if !matched {
			continue
		}
		end := shellFunctionEnd(lines, index)
		size := end - index + 1
		if size > maxFunctionLines {
			findings = append(findings, functionFinding(path, name, index+1, size))
		}
		index = end
	}
	return findings
}

func shellFunctionName(line string) (string, bool) {
	for _, expression := range []*regexp.Regexp{plainShellFunction, keywordShellFunction} {
		match := expression.FindStringSubmatch(line)
		if len(match) > 1 {
			return match[1], true
		}
	}
	return "", false
}

func shellFunctionEnd(lines []string, start int) int {
	depth := 0
	for index := start; index < len(lines); index++ {
		depth += shellBraceDelta(lines[index])
		if index > start && depth <= 0 {
			return index
		}
	}
	return len(lines) - 1
}

func shellBraceDelta(line string) int {
	depth := 0
	var quote rune
	escaped := false
	for index, current := range line {
		if escaped {
			escaped = false
			continue
		}
		if quote != 0 {
			if quote == '"' && current == '\\' {
				escaped = true
				continue
			}
			if current == quote {
				quote = 0
			}
			continue
		}
		switch current {
		case '\\':
			escaped = true
		case '\'', '"':
			quote = current
		case '#':
			if shellCommentStarts(line, index) {
				return depth
			}
		case '{':
			depth++
		case '}':
			depth--
		}
	}
	return depth
}

func shellCommentStarts(line string, index int) bool {
	if index == 0 {
		return true
	}
	previous, _ := utf8.DecodeLastRuneInString(line[:index])
	return unicode.IsSpace(previous) || strings.ContainsRune(";|&()", previous)
}
