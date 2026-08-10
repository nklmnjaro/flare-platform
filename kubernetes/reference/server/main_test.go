package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestHashFileSHA256(t *testing.T) {
	path := filepath.Join(t.TempDir(), "known.txt")
	if err := os.WriteFile(path, []byte("abc"), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	got, err := hashFileSHA256(path)
	if err != nil {
		t.Fatalf("hash fixture: %v", err)
	}
	const want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	if got != want {
		t.Fatalf("hash = %q, want %q", got, want)
	}
}

func TestHashFileSHA256MissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing")
	if _, err := hashFileSHA256(path); err == nil {
		t.Fatal("hash missing file succeeded, want error")
	}
}

func TestIdentityHandler(t *testing.T) {
	identity := strings.Repeat("a", 64)
	request := httptest.NewRequest(http.MethodGet, "/identity", nil)
	response := httptest.NewRecorder()

	newHandler(identity).ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if got, want := response.Header().Get("Content-Type"), "text/plain; charset=utf-8"; got != want {
		t.Fatalf("Content-Type = %q, want %q", got, want)
	}
	if got, want := response.Body.Len(), 65; got != want {
		t.Fatalf("body length = %d, want %d", got, want)
	}
	if got, want := response.Body.String(), identity+"\n"; got != want {
		t.Fatalf("body = %q, want %q", got, want)
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}\n$`).Match(response.Body.Bytes()) {
		t.Fatalf("body = %q, want 64 lowercase hexadecimal characters plus LF", response.Body.String())
	}
}

func TestHealthHandlerRegression(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()

	newHandler(strings.Repeat("0", 64)).ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if got, want := response.Header().Get("Content-Type"), "text/plain; charset=utf-8"; got != want {
		t.Fatalf("Content-Type = %q, want %q", got, want)
	}
	if got, want := response.Body.String(), "ok\n"; got != want {
		t.Fatalf("body = %q, want %q", got, want)
	}
}
