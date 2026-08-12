package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
)

const defaultMaximumBytes = 131073

func main() {
	var sanitized bytes.Buffer
	result, err := run(os.Args[1:], os.Stdin, &sanitized)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL  evidence      sanitizer: %s\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stdout, "sanitizer_truncated=%t\n", result.truncated)
	if _, err := io.Copy(os.Stdout, &sanitized); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL  evidence      sanitizer: unable to write output")
		os.Exit(1)
	}
}

func run(arguments []string, input io.Reader, output io.Writer) (sanitizeResult, error) {
	flags := flag.NewFlagSet("evidence-sanitize", flag.ContinueOnError)
	maximumBytes := flags.Int("max-bytes", defaultMaximumBytes, "maximum emitted bytes")
	repository := flags.String("repository", "", "repository path to redact")
	home := flags.String("home", "", "current home path to redact")
	singleLine := flags.Bool("single-line", false, "emit only the first logical line")
	if err := flags.Parse(arguments); err != nil {
		return sanitizeResult{}, err
	}
	if flags.NArg() != 0 {
		return sanitizeResult{}, errors.New("positional arguments are not supported")
	}
	if *maximumBytes < 1 || *maximumBytes > maximumAllowedOutputBytes {
		return sanitizeResult{}, fmt.Errorf(
			"max-bytes must be between 1 and %d",
			maximumAllowedOutputBytes,
		)
	}
	options := sanitizeOptions{
		maximumBytes: *maximumBytes,
		repository:   *repository,
		home:         *home,
		singleLine:   *singleLine,
	}
	return sanitize(input, output, options)
}
