package main

import (
	"bytes"
	"math/rand"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSanitizeRedactsSupportedSensitiveForms(t *testing.T) {
	input := strings.Join([]string{
		"DB_PASSWORD=password-assignment-canary NEXT=visible",
		"api_token: Bearer token-canary visible-assignment",
		"password: Basic password-canary visible-header",
		"command --access-token Bearer flag-canary --verbose",
		`{"client_secret":"Basic json-canary","ok":true}`,
		"Authorization: Bearer authorization-canary visible-authorization",
	}, "\n")
	output, truncated := sanitizeForTest(t, input, sanitizeOptions{maximumBytes: 4096})
	if truncated {
		t.Fatal("supported sensitive-form fixture was truncated")
	}
	for _, secret := range []string{
		"password-assignment-canary", "token-canary", "password-canary", "flag-canary",
		"json-canary", "authorization-canary",
	} {
		if strings.Contains(output, secret) {
			t.Fatalf("sanitized output retained %q: %q", secret, output)
		}
	}
	if count := strings.Count(output, "<redacted>"); count != 6 {
		t.Fatalf("expected six redactions, got %d: %q", count, output)
	}
	for _, visible := range []string{
		"NEXT=visible",
		"Bearer <redacted> visible-assignment",
		"Basic <redacted> visible-header",
		"Bearer <redacted> --verbose",
		`"client_secret":"<redacted>"`,
		`"ok":true`,
		"Bearer <redacted> visible-authorization",
	} {
		if !strings.Contains(output, visible) {
			t.Fatalf("sanitizer removed useful context %q: %q", visible, output)
		}
	}
}

func TestSanitizeLeavesUnknownUnkeyedCredentialTextUnchanged(t *testing.T) {
	input := "Bearer unknown-unkeyed-canary remains prohibited input\n"
	output, truncated := sanitizeForTest(t, input, sanitizeOptions{maximumBytes: 4096})
	if truncated {
		t.Fatal("unknown unkeyed fixture was truncated")
	}
	if output != input {
		t.Fatalf("sanitizer claimed unsupported unkeyed coverage: %q", output)
	}
}

func TestSanitizePreservesBenignSensitiveWords(t *testing.T) {
	input := "secretary approved tokenizer docs and passwordless login\n"
	output, truncated := sanitizeForTest(t, input, sanitizeOptions{maximumBytes: 4096})
	if truncated {
		t.Fatal("benign fixture was truncated")
	}
	if output != input {
		t.Fatalf("benign prose changed: %q", output)
	}
}

func TestSanitizeRemovesControlsAndPaths(t *testing.T) {
	home := "/ho" + "me/alice"
	input := []byte("\x1b[31mred\x1b[0m nul:\x00 repo:/tmp/repo home:" + home + "/cache\n")
	var output bytes.Buffer
	result, err := sanitize(bytes.NewReader(input), &output, sanitizeOptions{
		maximumBytes: 4096,
		repository:   "/tmp/repo",
		home:         home,
	})
	if err != nil {
		t.Fatalf("sanitize: %v", err)
	}
	if result.truncated {
		t.Fatal("control/path fixture was truncated")
	}
	value := output.String()
	if strings.ContainsRune(value, '\x1b') || strings.ContainsRune(value, '\x00') {
		t.Fatalf("control bytes retained: %q", value)
	}
	if strings.Contains(value, "/tmp/repo") || strings.Contains(value, home) {
		t.Fatalf("path retained: %q", value)
	}
	if !strings.Contains(value, "red") ||
		!strings.Contains(value, "repo:<REPO>") ||
		!strings.Contains(value, "home:<HOME>/cache") {
		t.Fatalf("useful context lost: %q", value)
	}
	if !utf8.ValidString(value) {
		t.Fatalf("output is not valid UTF-8: %q", value)
	}
}

func TestSanitizeBoundsOutputAndDrainsLongLine(t *testing.T) {
	input := "TOKEN=" + strings.Repeat("s", maximumLogicalLineBytes*2) + "\nvisible\n"
	output, truncated := sanitizeForTest(t, input, sanitizeOptions{maximumBytes: 128})
	if !truncated {
		t.Fatal("long bounded input was not reported as truncated")
	}
	if len(output) > 128 {
		t.Fatalf("output exceeded bound: %d", len(output))
	}
	if strings.Contains(output, strings.Repeat("s", 8)) {
		t.Fatalf("long secret fragment retained: %q", output)
	}
}

func TestSanitizeSingleLineEmitsFirstLogicalLineAndDrains(t *testing.T) {
	input := strings.NewReader("first\nAuthorization: second-line-secret\n" +
		strings.Repeat("ignored second-line bytes ", maximumLogicalLineBytes))
	var sanitized bytes.Buffer
	result, err := sanitize(input, &sanitized, sanitizeOptions{maximumBytes: 4096, singleLine: true})
	if err != nil {
		t.Fatalf("sanitize: %v", err)
	}
	output := sanitized.String()
	truncated := result.truncated
	if truncated {
		t.Fatal("single-line selection was reported as truncation")
	}
	if output != "first\n" {
		t.Fatalf("unexpected single-line output: %q", output)
	}
	if input.Len() != 0 {
		t.Fatalf("single-line mode did not drain input: %d bytes remain", input.Len())
	}
}

func TestSanitizeSingleLineDrainsAfterTruncatedFirstLine(t *testing.T) {
	input := strings.NewReader(strings.Repeat("x", maximumLogicalLineBytes+1) +
		"\n" + strings.Repeat("ignored", maximumLogicalLineBytes))
	var sanitized bytes.Buffer
	result, err := sanitize(input, &sanitized, sanitizeOptions{maximumBytes: maximumAllowedOutputBytes, singleLine: true})
	if err != nil {
		t.Fatalf("sanitize: %v", err)
	}
	if !result.truncated {
		t.Fatal("truncated first line was not reported")
	}
	if !strings.HasSuffix(sanitized.String(), " <line-truncated>\n") {
		t.Fatalf("first-line truncation marker missing: %q", sanitized.String())
	}
	if input.Len() != 0 {
		t.Fatalf("single-line mode did not drain after overflow: %d bytes remain", input.Len())
	}
}

func TestRunRejectsInvalidArguments(t *testing.T) {
	var output bytes.Buffer
	if _, err := run([]string{"--max-bytes", "0"}, strings.NewReader("x"), &output); err == nil {
		t.Fatal("zero max-bytes was accepted")
	}
	if _, err := run([]string{"extra"}, strings.NewReader("x"), &output); err == nil {
		t.Fatal("positional argument was accepted")
	}
}

func TestPayloadOnlyFlagIsAcceptedAndDetected(t *testing.T) {
	var output bytes.Buffer
	if _, err := run([]string{"--payload-only"}, strings.NewReader("visible\n"), &output); err != nil {
		t.Fatalf("payload-only: %v", err)
	}
	if output.String() != "visible\n" {
		t.Fatalf("unexpected payload: %q", output.String())
	}
	if !payloadOnlyRequested([]string{"--payload-only"}) ||
		!payloadOnlyRequested([]string{"--payload-only=true"}) ||
		payloadOnlyRequested([]string{"--payload-only=false"}) ||
		payloadOnlyRequested(nil) {
		t.Fatal("payload-only request detection failed")
	}
}

func TestSanitizeKeepsBoundedOutputValidUTF8(t *testing.T) {
	input := strings.Repeat("é", 16)
	output, truncated := sanitizeForTest(t, input, sanitizeOptions{maximumBytes: 7})
	if !truncated {
		t.Fatal("multi-byte input was not reported as truncated")
	}
	if len(output) > 7 {
		t.Fatalf("output exceeded byte limit: %d", len(output))
	}
	if !utf8.ValidString(output) {
		t.Fatalf("bounded output is not valid UTF-8: %q", output)
	}
}

func TestSanitizeRemovesControlsBeforeSensitiveMatching(t *testing.T) {
	input := "TO\x00KEN=control-obfuscated-canary\n"
	output, truncated := sanitizeForTest(t, input, sanitizeOptions{maximumBytes: 4096})
	if truncated {
		t.Fatal("control-obfuscation fixture was truncated")
	}
	if strings.Contains(output, "control-obfuscated-canary") {
		t.Fatalf("control-obfuscated secret survived: %q", output)
	}
}

func TestSanitizeDropsInvalidUTF8AndOSCEscapePayload(t *testing.T) {
	input := []byte("visible \x1b]0;osc-secret-canary\x07 TO\xffKEN=invalid-key-canary\n")
	var output bytes.Buffer
	result, err := sanitize(bytes.NewReader(input), &output, sanitizeOptions{maximumBytes: 4096})
	if err != nil {
		t.Fatalf("sanitize: %v", err)
	}
	if result.truncated {
		t.Fatal("invalid UTF-8/OSC fixture was truncated")
	}
	value := output.String()
	for _, forbidden := range []string{"osc-secret-canary", "invalid-key-canary", "\x1b", "\ufffd"} {
		if strings.Contains(value, forbidden) {
			t.Fatalf("unsafe byte or payload survived sanitization: %q", value)
		}
	}
	if !strings.Contains(value, "visible") || !strings.Contains(value, "TOKEN=<redacted>") {
		t.Fatalf("useful or redaction context was lost: %q", value)
	}
	if !utf8.ValidString(value) {
		t.Fatalf("output is not valid UTF-8: %q", value)
	}
}

func TestSanitizeConsumesQuotedTokenSuffix(t *testing.T) {
	input := `TOKEN="quoted-canary"suffix-canary status=visible` + "\n"
	output, truncated := sanitizeForTest(t, input, sanitizeOptions{maximumBytes: 4096})
	if truncated {
		t.Fatal("quoted token fixture was truncated")
	}
	for _, canary := range []string{"quoted-canary", "suffix-canary"} {
		if strings.Contains(output, canary) {
			t.Fatalf("quoted token suffix survived: %q", output)
		}
	}
	if !strings.Contains(output, "status=visible") {
		t.Fatalf("useful context was removed: %q", output)
	}
}

func TestSanitizeRandomBytesAlwaysProducesBoundedUTF8(t *testing.T) {
	random := rand.New(rand.NewSource(23))
	for index := 0; index < 512; index++ {
		input := make([]byte, random.Intn(2048))
		if _, err := random.Read(input); err != nil {
			t.Fatalf("random input: %v", err)
		}
		var output bytes.Buffer
		_, err := sanitize(bytes.NewReader(input), &output, sanitizeOptions{maximumBytes: 257})
		if err != nil {
			t.Fatalf("sanitize random input %d: %v", index, err)
		}
		if output.Len() > 257 {
			t.Fatalf("random output exceeded bound: %d", output.Len())
		}
		if !utf8.Valid(output.Bytes()) {
			t.Fatalf("random output is invalid UTF-8: %q", output.Bytes())
		}
	}
}

func sanitizeForTest(t *testing.T, input string, options sanitizeOptions) (string, bool) {
	t.Helper()
	var output bytes.Buffer
	result, err := sanitize(strings.NewReader(input), &output, options)
	if err != nil {
		t.Fatalf("sanitize: %v", err)
	}
	return output.String(), result.truncated
}
