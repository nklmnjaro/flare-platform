package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL  artifact      %s\n", redactDiagnosticHomePaths(err.Error()))
		os.Exit(1)
	}
}

func run(arguments []string, output io.Writer) error {
	if len(arguments) == 0 {
		return errors.New("usage: artifactarchive <pack|verify> [options]")
	}
	switch arguments[0] {
	case "pack":
		return runPack(arguments[1:], output)
	case "verify":
		return runVerify(arguments[1:], output)
	default:
		return fmt.Errorf("unsupported command %q", arguments[0])
	}
}

func runPack(arguments []string, output io.Writer) error {
	flags := flag.NewFlagSet("pack", flag.ContinueOnError)
	source := flags.String("source", "", "directory to package")
	archive := flags.String("output", "", "output zip path")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *source == "" || *archive == "" {
		return errors.New("pack requires --source and --output")
	}
	if err := packDirectory(*source, *archive); err != nil {
		return err
	}
	fmt.Fprintln(output, "PASS  artifact      packed and verified")
	return nil
}

func runVerify(arguments []string, output io.Writer) error {
	flags := flag.NewFlagSet("verify", flag.ContinueOnError)
	archive := flags.String("archive", "", "zip archive to verify")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *archive == "" {
		return errors.New("verify requires --archive")
	}
	if err := verifyArchive(*archive); err != nil {
		return err
	}
	if err := verifyDetachedChecksum(*archive); err != nil {
		return err
	}
	fmt.Fprintln(output, "PASS  artifact      verified")
	return nil
}
