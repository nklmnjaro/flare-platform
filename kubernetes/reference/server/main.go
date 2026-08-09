package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	if os.Getenv("PLATFORM_FAIL_STARTUP") == "1" {
		log.Print("intentional startup failure requested")
		os.Exit(42)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", respondOK)
	mux.HandleFunc("/healthz", respondOK)

	server := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}

func respondOK(writer http.ResponseWriter, _ *http.Request) {
	writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
	writer.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprintln(writer, "ok")
}
