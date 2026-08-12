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
		fmt.Fprintf(os.Stderr, "FAIL  recovery      %s\n", redactDiagnostic(err.Error()))
		os.Exit(1)
	}
}

func run(arguments []string, output io.Writer) error {
	if len(arguments) == 0 {
		return errors.New("usage: recoverycapsule <pack|verify> [options]")
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
	repository := flags.String("repository", "", "clean Git repository to capture")
	destination := flags.String("output", "", "new recovery capsule directory")
	gitExecutable := flags.String("git", "", "admitted absolute Git executable")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("pack does not accept positional arguments")
	}
	if *repository == "" || *destination == "" || *gitExecutable == "" {
		return errors.New("pack requires --repository, --output, and --git")
	}
	if err := packCapsuleWithGit(*repository, *destination, *gitExecutable); err != nil {
		return err
	}
	fmt.Fprintln(output, "PASS  recovery      capsule packed and verified")
	return nil
}

func runVerify(arguments []string, output io.Writer) error {
	flags := flag.NewFlagSet("verify", flag.ContinueOnError)
	capsule := flags.String("capsule", "", "recovery capsule directory")
	gitExecutable := flags.String("git", "", "admitted absolute Git executable")
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("verify does not accept positional arguments")
	}
	if *capsule == "" || *gitExecutable == "" {
		return errors.New("verify requires --capsule and --git")
	}
	if err := verifyCapsuleWithGit(*capsule, *gitExecutable); err != nil {
		return err
	}
	fmt.Fprintln(output, "PASS  recovery      capsule restored and verified")
	return nil
}
