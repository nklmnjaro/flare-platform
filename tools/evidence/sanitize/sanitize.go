package main

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	maximumAllowedOutputBytes = 1 << 20
	maximumLogicalLineBytes   = 64 << 10
	readerBufferBytes         = 16 << 10
)

var (
	sensitiveAssignment = regexp.MustCompile(
		`(?i)["']?[-a-z0-9_.]*(authorization|password|secret|token)[-a-z0-9_.]*["']?[ \t]*[:=][ \t]*`,
	)
	sensitiveFlag = regexp.MustCompile(
		`(?i)--?[-a-z0-9_.]*(password|secret|token)[-a-z0-9_.]*[ \t]+`,
	)
	genericHomePath = regexp.MustCompile(
		`(?i)(^|[^[:alnum:]_])(/(home|users)/[^/\x00[:space:]]+|/` +
			`root([^[:alnum:]_.-]|$)|[a-z]:[\\/]+users[\\/]+[^\\/\x00[:space:]]+)`,
	)
)

type sanitizeOptions struct {
	maximumBytes int
	repository   string
	home         string
	singleLine   bool
}

type sanitizeResult struct {
	truncated bool
}

type boundedWriter struct {
	output    io.Writer
	remaining int
	truncated bool
}

func (writer *boundedWriter) Write(data []byte) (int, error) {
	originalLength := len(data)
	if writer.remaining == 0 {
		writer.truncated = writer.truncated || originalLength > 0
		return originalLength, nil
	}
	allowed := len(data)
	cut := allowed > writer.remaining
	if cut {
		allowed = writer.remaining
		for allowed > 0 && !utf8.RuneStart(data[allowed]) {
			allowed--
		}
		writer.truncated = true
	}
	written, err := writer.output.Write(data[:allowed])
	writer.remaining -= written
	if cut {
		writer.remaining = 0
	}
	if err != nil {
		return written, err
	}
	if written != allowed {
		return written, io.ErrShortWrite
	}
	return originalLength, nil
}

func sanitize(input io.Reader, output io.Writer, options sanitizeOptions) (sanitizeResult, error) {
	if options.maximumBytes < 1 {
		return sanitizeResult{}, errors.New("maximum output size must be positive")
	}
	writer := &boundedWriter{output: output, remaining: options.maximumBytes}
	reader := bufio.NewReaderSize(input, readerBufferBytes)
	line := make([]byte, 0, readerBufferBytes)
	overflow := false
	lineNumber := 0
	lineTruncated := false
	for {
		fragment, err := reader.ReadSlice('\n')
		line, overflow = appendLineFragment(line, fragment, overflow)
		if err == nil || errors.Is(err, io.EOF) {
			lineNumber++
			if !options.singleLine || lineNumber == 1 {
				lineTruncated = lineTruncated || overflow
				if writeErr := writeSanitizedLine(writer, line, overflow, err == nil, options); writeErr != nil {
					return sanitizeResult{}, writeErr
				}
			}
			line = line[:0]
			overflow = false
		}
		if errors.Is(err, io.EOF) {
			return sanitizeResult{truncated: lineTruncated || writer.truncated}, nil
		}
		if err != nil && !errors.Is(err, bufio.ErrBufferFull) {
			return sanitizeResult{}, err
		}
	}
}

func appendLineFragment(line, fragment []byte, overflow bool) ([]byte, bool) {
	if overflow {
		return line, true
	}
	available := maximumLogicalLineBytes - len(line)
	if len(fragment) <= available {
		return append(line, fragment...), false
	}
	line = append(line, fragment[:available]...)
	return line, true
}

func writeSanitizedLine(
	output io.Writer,
	line []byte,
	overflow bool,
	hadNewline bool,
	options sanitizeOptions,
) error {
	line = bytes.TrimSuffix(line, []byte{'\n'})
	line = bytes.TrimSuffix(line, []byte{'\r'})
	value := sanitizeText(line, options)
	if overflow {
		value += " <line-truncated>"
	}
	if _, err := io.WriteString(output, value); err != nil {
		return err
	}
	if hadNewline {
		_, err := io.WriteString(output, "\n")
		return err
	}
	return nil
}

func sanitizeText(data []byte, options sanitizeOptions) string {
	value := stripTerminalControls(data)
	value = redactLiteralPaths(value, options.repository, options.home)
	value = genericHomePath.ReplaceAllString(value, `${1}<home>${4}`)
	value = redactSensitiveValues(value, sensitiveAssignment)
	return redactSensitiveValues(value, sensitiveFlag)
}

func redactLiteralPaths(value string, paths ...string) string {
	filtered := make([]string, 0, len(paths))
	for _, path := range paths {
		if path != "" && path != "/" {
			filtered = append(filtered, path)
		}
	}
	sort.Slice(filtered, func(left, right int) bool {
		return len(filtered[left]) > len(filtered[right])
	})
	for _, path := range filtered {
		value = strings.ReplaceAll(value, path, "<path>")
	}
	return value
}

func redactSensitiveValues(value string, pattern *regexp.Regexp) string {
	var result strings.Builder
	for {
		location := pattern.FindStringIndex(value)
		if location == nil {
			result.WriteString(value)
			return result.String()
		}
		result.WriteString(value[:location[1]])
		replacement, end := sensitiveReplacement(value[location[1]:])
		result.WriteString(replacement)
		value = value[location[1]+end:]
	}
}

func sensitiveReplacement(value string) (string, int) {
	if value == "" {
		return "<redacted>", 0
	}
	if value[0] == '\'' || value[0] == '"' {
		end := sensitiveTokenEnd(value, quotedValueEnd(value, value[0]))
		return string(value[0]) + "<redacted>" + string(value[0]), end
	}
	end := unquotedSensitiveValueEnd(value)
	scheme, credentialStart, compound := credentialScheme(value)
	if compound {
		credentialEnd := credentialStart + unquotedSensitiveValueEnd(value[credentialStart:])
		return scheme + " <redacted>", credentialEnd
	}
	return "<redacted>", end
}

func credentialScheme(value string) (string, int, bool) {
	for _, scheme := range []string{"Bearer", "Basic"} {
		if len(value) <= len(scheme) || !strings.EqualFold(value[:len(scheme)], scheme) {
			continue
		}
		index := len(scheme)
		if value[index] != ' ' && value[index] != '\t' {
			continue
		}
		for index < len(value) && (value[index] == ' ' || value[index] == '\t') {
			index++
		}
		if index < len(value) {
			return value[:len(scheme)], index, true
		}
	}
	return "", 0, false
}

func unquotedSensitiveValueEnd(value string) int {
	for index, character := range value {
		if unicode.IsSpace(character) || strings.ContainsRune(",;}]&", character) {
			return index
		}
	}
	return len(value)
}

func sensitiveTokenEnd(value string, start int) int {
	for index, character := range value[start:] {
		if unicode.IsSpace(character) || strings.ContainsRune(",;}]&", character) {
			return start + index
		}
	}
	return len(value)
}

func quotedValueEnd(value string, quote byte) int {
	escaped := false
	for index := 1; index < len(value); index++ {
		if escaped {
			escaped = false
			continue
		}
		if value[index] == '\\' && quote == '"' {
			escaped = true
			continue
		}
		if value[index] == quote {
			return index + 1
		}
	}
	return len(value)
}

func stripTerminalControls(data []byte) string {
	clean := make([]byte, 0, len(data))
	for index := 0; index < len(data); {
		if data[index] == 0x1b {
			index = skipEscapeSequence(data, index)
			continue
		}
		clean = append(clean, data[index])
		index++
	}
	value := strings.ToValidUTF8(string(clean), "")
	var result strings.Builder
	for _, character := range value {
		if unicode.IsControl(character) && character != '\t' {
			continue
		}
		result.WriteRune(character)
	}
	return result.String()
}

func skipEscapeSequence(data []byte, index int) int {
	index++
	if index >= len(data) {
		return index
	}
	switch data[index] {
	case '[':
		for index++; index < len(data); index++ {
			if data[index] >= 0x40 && data[index] <= 0x7e {
				return index + 1
			}
		}
	case ']':
		for index++; index < len(data); index++ {
			if data[index] == 0x07 {
				return index + 1
			}
			if data[index] == 0x1b && index+1 < len(data) && data[index+1] == '\\' {
				return index + 2
			}
		}
	default:
		return index + 1
	}
	return len(data)
}
