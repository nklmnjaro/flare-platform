package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL  artifact      %v\n", err)
		os.Exit(1)
	}
}

func run(arguments []string) error {
	if len(arguments) == 0 {
		return errors.New("usage: artifactarchive <pack|verify> [options]")
	}
	switch arguments[0] {
	case "pack":
		return runPack(arguments[1:])
	case "verify":
		return runVerify(arguments[1:])
	default:
		return fmt.Errorf("unsupported command %q", arguments[0])
	}
}

func runPack(arguments []string) error {
	flags := flag.NewFlagSet("pack", flag.ContinueOnError)
	source := flags.String("source", "", "directory to package")
	output := flags.String("output", "", "output zip path")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if *source == "" || *output == "" {
		return errors.New("pack requires --source and --output")
	}
	if err := packDirectory(*source, *output); err != nil {
		return err
	}
	fmt.Printf("PASS  artifact      packed and verified %s\n", *output)
	return nil
}

func runVerify(arguments []string) error {
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
	fmt.Printf("PASS  artifact      verified %s\n", *archive)
	return nil
}
