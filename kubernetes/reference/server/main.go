package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	executablePath, err := os.Executable()
	if err != nil {
		log.Fatalf("resolve executable path: %v", err)
	}
	executableIdentity, err := hashFileSHA256(executablePath)
	if err != nil {
		log.Fatalf("hash executable identity: %v", err)
	}
	if os.Getenv("PLATFORM_FAIL_STARTUP") == "1" {
		log.Print("intentional startup failure requested")
		os.Exit(42)
	}

	server := &http.Server{
		Addr:              ":8080",
		Handler:           newHandler(executableIdentity),
		ReadHeaderTimeout: 2 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}

func hashFileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open %q: %w", path, err)
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", fmt.Errorf("hash %q: %w", path, err)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func newHandler(executableIdentity string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", respondOK)
	mux.HandleFunc("/healthz", respondOK)
	mux.HandleFunc("/identity", respondIdentity(executableIdentity))
	return mux
}

func respondOK(writer http.ResponseWriter, _ *http.Request) {
	writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
	writer.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprintln(writer, "ok")
}

func respondIdentity(executableIdentity string) http.HandlerFunc {
	return func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
		writer.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(writer, executableIdentity)
	}
}
