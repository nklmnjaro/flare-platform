package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	gitCommandTimeout           = 90 * time.Second
	gitTerminationGrace         = 500 * time.Millisecond
	gitTerminationPoll          = 10 * time.Millisecond
	gitWaitAfterKill            = 2 * time.Second
	maxGitOutputBytes           = 128 << 10
	maxStructuralGitOutputBytes = 32 << 20
)

var errOutputCaptureUnfinished = errors.New("output capture did not stop after pipe close")

type gitRunner struct {
	executable    string
	home          string
	homeTemp      *pinnedTempDirectory
	environment   []string
	sourceRoot    string
	sourcePinned  string
	sourceRootFD  *os.File
	sourceGitFD   *os.File
	timeout       time.Duration
	termGrace     time.Duration
	pollEvery     time.Duration
	waitAfterKill time.Duration
	monitorLeader func(ownedProcessGroup, time.Duration, time.Duration) (bool, error)
	abandon       func(*startedGitCommand, time.Duration) error
}

type startedGitCommand struct {
	command *exec.Cmd
	group   ownedProcessGroup
	reader  *os.File
	copied  <-chan error
	output  *boundedBuffer
}

func newGitRunner(repository, explicitGit string) (*gitRunner, func() error, error) {
	if explicitGit == "" {
		return nil, nil, errors.New("admitted absolute Git executable is required")
	}
	executable, err := validateGitExecutable(explicitGit, repository)
	if err != nil {
		return nil, nil, err
	}
	homeTemp, err := newPinnedTempDirectory("flare-recovery-git-home-")
	if err != nil {
		return nil, nil, err
	}
	home := homeTemp.pinnedPath
	if err := os.Mkdir(filepath.Join(home, "template"), 0o700); err != nil {
		return nil, nil, errors.Join(err, homeTemp.cleanup())
	}
	if err := homeTemp.registerCurrentOwnedName("template"); err != nil {
		return nil, nil, errors.Join(err, homeTemp.cleanup())
	}
	runner := &gitRunner{
		executable:    executable,
		home:          home,
		homeTemp:      homeTemp,
		environment:   sanitizedGitEnvironment(home, filepath.Dir(executable)),
		timeout:       gitCommandTimeout,
		termGrace:     gitTerminationGrace,
		pollEvery:     gitTerminationPoll,
		waitAfterKill: gitWaitAfterKill,
		monitorLeader: waitForLeaderTerminal,
		abandon:       abandonUntrustedProcessIdentity,
	}
	cleanup := func() error { return homeTemp.cleanup() }
	return runner, cleanup, nil
}

func (runner *gitRunner) bindSourceRoot(canonical string, root, gitDirectory *os.File) func() {
	previousRoot := runner.sourceRoot
	previousPinned := runner.sourcePinned
	previousRootFD := runner.sourceRootFD
	previousGitFD := runner.sourceGitFD
	runner.sourceRoot = canonical
	runner.sourcePinned = fmt.Sprintf("/proc/%d/fd/%d", os.Getpid(), root.Fd())
	runner.sourceRootFD = root
	runner.sourceGitFD = gitDirectory
	return func() {
		runner.sourceRoot = previousRoot
		runner.sourcePinned = previousPinned
		runner.sourceRootFD = previousRootFD
		runner.sourceGitFD = previousGitFD
	}
}

func (runner *gitRunner) commandDirectory(directory string) string {
	if directory != "" && directory == runner.sourceRoot && runner.sourcePinned != "" {
		return runner.sourcePinned
	}
	return directory
}

func validateGitExecutable(path, repository string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("Git executable path must be absolute")
	}
	if strings.ContainsAny(path, "\r\n\x00") || filepath.Clean(path) != path {
		return "", errors.New("Git executable path must be canonical")
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", err
	}
	if resolved != absolute {
		return "", errors.New("Git executable path must be canonical and symlink-free")
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return "", errors.New("Git path is not a regular executable")
	}
	if pathWithin(resolved, repository) || hasPlatformPathComponent(resolved) {
		return "", errors.New("Git executable resolves inside project-controlled state")
	}
	return resolved, nil
}

func hasPlatformPathComponent(path string) bool {
	for _, component := range strings.Split(filepath.Clean(path), string(os.PathSeparator)) {
		if component == ".platform" {
			return true
		}
	}
	return false
}

func sanitizedGitEnvironment(home, safePath string) []string {
	environment := make([]string, 0, len(os.Environ())+12)
	for _, entry := range os.Environ() {
		key, _, found := strings.Cut(entry, "=")
		if !found || blockedGitEnvironmentKey(key) {
			continue
		}
		environment = append(environment, entry)
	}
	return append(environment,
		"HOME="+home,
		"XDG_CONFIG_HOME="+filepath.Join(home, "xdg"),
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_TERMINAL_PROMPT=0",
		"GIT_ASKPASS=/bin/false",
		"GIT_SSH_COMMAND=false",
		"GIT_TEMPLATE_DIR="+filepath.Join(home, "template"),
		"GIT_NO_LAZY_FETCH=1",
		"GIT_NO_REPLACE_OBJECTS=1",
		"GIT_LITERAL_PATHSPECS=1",
		"GIT_ALLOW_PROTOCOL=file",
		"LC_ALL=C",
		"PATH="+safePath,
		"TMPDIR="+recoveryHostTempRoot,
	)
}

func blockedGitEnvironmentKey(key string) bool {
	if strings.HasPrefix(key, "GIT_") || strings.HasPrefix(key, "LD_") ||
		strings.HasPrefix(key, "DYLD_") {
		return true
	}
	switch key {
	case "BASH_ENV", "CDPATH", "ENV", "HOME", "LC_ALL", "PAGER",
		"SSH_ASKPASS", "TEMP", "TMP", "TMPDIR", "XDG_CONFIG_HOME":
		return true
	default:
		return false
	}
}

func (runner *gitRunner) run(directory string, input []byte, arguments ...string) ([]byte, error) {
	return runner.runLimited(directory, input, maxGitOutputBytes, arguments...)
}

func (runner *gitRunner) runLarge(directory string, input []byte, arguments ...string) ([]byte, error) {
	return runner.runLimited(directory, input, maxStructuralGitOutputBytes, arguments...)
}

func (runner *gitRunner) runToWriter(
	directory string,
	destination io.Writer,
	arguments ...string,
) error {
	if len(arguments) == 0 {
		return errors.New("Git command arguments are required")
	}
	started, status, err := runner.startGitCommand(
		directory, nil, maxGitOutputBytes, arguments, destination)
	if err != nil {
		return err
	}
	output, status, err := runner.finishGitCommand(started, maxGitOutputBytes, arguments[0])
	if err != nil {
		return err
	}
	if status != 0 {
		return fmt.Errorf("git %s failed with status %d: %s",
			arguments[0], status, strings.TrimSpace(string(output)))
	}
	return nil
}

func (runner *gitRunner) runLimited(
	directory string,
	input []byte,
	limit int,
	arguments ...string,
) ([]byte, error) {
	output, status, err := runner.runStatusLimited(directory, input, limit, arguments...)
	if err != nil {
		return nil, err
	}
	if status != 0 {
		return nil, fmt.Errorf("git %s failed with status %d: %s",
			arguments[0], status, strings.TrimSpace(string(output)))
	}
	return output, nil
}

func (runner *gitRunner) runStatus(
	directory string,
	input []byte,
	arguments ...string,
) ([]byte, int, error) {
	return runner.runStatusLimited(directory, input, maxGitOutputBytes, arguments...)
}

func (runner *gitRunner) runStatusLimited(
	directory string,
	input []byte,
	limit int,
	arguments ...string,
) ([]byte, int, error) {
	if len(arguments) == 0 {
		return nil, 64, errors.New("Git command arguments are required")
	}
	started, status, err := runner.startGitCommand(directory, input, limit, arguments, nil)
	if err != nil {
		return nil, status, err
	}
	return runner.finishGitCommand(started, limit, arguments[0])
}

func (runner *gitRunner) startGitCommand(
	directory string,
	input []byte,
	limit int,
	arguments []string,
	fileOutput io.Writer,
) (*startedGitCommand, int, error) {
	fullArguments := append([]string{
		"--no-pager",
		"-c", "advice.graftFileDeprecated=false",
		"-c", "core.hooksPath=/dev/null",
		"-c", "core.fsmonitor=false",
		"-c", "core.attributesFile=/dev/null",
		"-c", "core.excludesFile=/dev/null",
		"-c", "core.fileMode=true",
		"-c", "core.symlinks=true",
		"-c", "core.trustctime=true",
		"-c", "core.checkStat=default",
	}, runner.bindSourceArguments(directory, arguments)...)
	command := exec.Command(runner.executable, fullArguments...)
	if directory == "" {
		command.Dir = runner.home
	} else {
		command.Dir = runner.commandDirectory(directory)
	}
	command.Env = runner.environment
	if directory == runner.sourceRoot && runner.sourceRootFD != nil && runner.sourceGitFD != nil {
		command.ExtraFiles = []*os.File{runner.sourceRootFD, runner.sourceGitFD}
	}
	command.Stdin = bytes.NewReader(input)
	output := &boundedBuffer{limit: limit}
	outputReader, outputWriter, err := os.Pipe()
	if err != nil {
		return nil, 1, err
	}
	if fileOutput == nil {
		command.Stdout = outputWriter
	} else {
		command.Stdout = fileOutput
	}
	command.Stderr = outputWriter
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		_ = outputReader.Close()
		_ = outputWriter.Close()
		return nil, statusFromError(err), err
	}
	outputCopied := make(chan error, 1)
	go func() {
		_, copyErr := io.Copy(output, outputReader)
		outputCopied <- copyErr
	}()
	if err := outputWriter.Close(); err != nil {
		cleanupErr := abortStartedCommand(
			command, outputReader, outputCopied, runner.waitAfterKill)
		return nil, 70, fmt.Errorf("git %s output setup failed: %w",
			arguments[0], errors.Join(err, cleanupErr))
	}
	group, err := captureOwnedProcessGroup(command.Process.Pid)
	if err != nil {
		cleanupErr := abortStartedCommand(
			command, outputReader, outputCopied, runner.waitAfterKill)
		return nil, 70, fmt.Errorf("git %s process identity unavailable: %w",
			arguments[0], errors.Join(err, cleanupErr))
	}
	return &startedGitCommand{
		command: command,
		group:   group,
		reader:  outputReader,
		copied:  outputCopied,
		output:  output,
	}, 0, nil
}

func (runner *gitRunner) bindSourceArguments(directory string, arguments []string) []string {
	if directory != runner.sourceRoot || runner.sourceRootFD == nil || runner.sourceGitFD == nil {
		return arguments
	}
	bound := []string{
		"--git-dir=/proc/self/fd/4",
		"--work-tree=/proc/self/fd/3",
	}
	return append(bound, arguments...)
}

func (runner *gitRunner) finishGitCommand(
	started *startedGitCommand,
	limit int,
	verb string,
) ([]byte, int, error) {
	command := started.command
	group := started.group
	output := started.output
	timedOut, monitorErr := runner.monitorLeader(group, runner.timeout, runner.pollEvery)
	if monitorErr != nil {
		cleanupErr := runner.abandon(started, runner.waitAfterKill)
		return nil, 70, fmt.Errorf("git %s process identity changed: %w",
			verb, errors.Join(monitorErr, cleanupErr))
	}
	leftDescendants, cleanupErr := terminateOwnedProcessGroup(
		group, !timedOut, runner.termGrace, runner.waitAfterKill, runner.pollEvery)
	if cleanupErr != nil {
		abandonErr := runner.abandon(started, runner.waitAfterKill)
		return nil, 70, fmt.Errorf("git %s process-group cleanup failed: %w",
			verb, errors.Join(cleanupErr, abandonErr))
	}
	waitErr, waitControlErr := waitCommandBounded(command, runner.waitAfterKill)
	copyErr := waitForOutputEOF(started.reader, started.copied, runner.waitAfterKill)
	if errors.Is(copyErr, errOutputCaptureUnfinished) {
		return nil, 70, fmt.Errorf("git %s output capture failed: %w",
			verb, copyErr)
	}
	if waitControlErr != nil {
		return nil, 70, fmt.Errorf("git %s direct wait failed: %w",
			verb, waitControlErr)
	}
	postWaitErr := confirmProcessGroupNonlive(
		group.leader.Group, runner.pollEvery, listLiveProcessGroupMembers)
	if postWaitErr != nil {
		return output.Bytes(), 70, fmt.Errorf("git %s post-wait group check failed: %w",
			verb, postWaitErr)
	}
	if copyErr != nil && !errors.Is(copyErr, os.ErrClosed) {
		return output.Bytes(), 70, fmt.Errorf("git %s output capture failed: %w",
			verb, copyErr)
	}
	if timedOut {
		return output.Bytes(), 124, fmt.Errorf("git %s exceeded %s", verb, runner.timeout)
	}
	if leftDescendants {
		return output.Bytes(), 70, fmt.Errorf("git %s left a descendant process group",
			verb)
	}
	if output.truncated {
		return output.Bytes(), 70, fmt.Errorf("git %s output exceeded %d bytes", verb, limit)
	}
	if waitErr == nil {
		return output.Bytes(), 0, nil
	}
	var exitError *exec.ExitError
	if errors.As(waitErr, &exitError) {
		return output.Bytes(), exitError.ExitCode(), nil
	}
	return output.Bytes(), statusFromError(waitErr), waitErr
}

func statusFromError(err error) int {
	var pathError *os.PathError
	if errors.As(err, &pathError) {
		return int(syscall.ENOENT)
	}
	return 1
}

func forceKillStartedProcessGroup(command *exec.Cmd) error {
	// Start returned with Setpgid applied and Wait has not run, so this PID still
	// pins the process-group identity even when /proc inspection itself failed.
	processGroup := command.Process.Pid
	groupErr := syscall.Kill(-processGroup, syscall.SIGKILL)
	if errors.Is(groupErr, syscall.ESRCH) {
		groupErr = nil
	}
	leaderErr := command.Process.Kill()
	if errors.Is(leaderErr, os.ErrProcessDone) {
		leaderErr = nil
	}
	return errors.Join(groupErr, leaderErr)
}

func waitCommandBounded(command *exec.Cmd, budget time.Duration) (error, error) {
	waited := make(chan error, 1)
	go func() {
		waited <- command.Wait()
	}()
	timer := time.NewTimer(budget)
	defer timer.Stop()
	select {
	case err := <-waited:
		return err, nil
	case <-timer.C:
		return nil, fmt.Errorf("direct wait exceeded %s", budget)
	}
}

func waitForOutputEOF(reader *os.File, copied <-chan error, budget time.Duration) error {
	timer := time.NewTimer(budget)
	defer timer.Stop()
	select {
	case err := <-copied:
		closeErr := reader.Close()
		return errors.Join(err, closeErr)
	case <-timer.C:
		_ = reader.Close()
		drainTimer := time.NewTimer(budget)
		defer drainTimer.Stop()
		select {
		case <-copied:
		case <-drainTimer.C:
			return errors.Join(
				fmt.Errorf("output capture exceeded %s", budget),
				errOutputCaptureUnfinished,
			)
		}
		return fmt.Errorf("output capture exceeded %s", budget)
	}
}

func abortStartedCommand(
	command *exec.Cmd,
	reader *os.File,
	copied <-chan error,
	budget time.Duration,
) error {
	killErr := forceKillStartedProcessGroup(command)
	_, waitErr := waitCommandBounded(command, budget)
	outputErr := waitForOutputEOF(reader, copied, budget)
	return errors.Join(killErr, waitErr, outputErr)
}

func abandonUntrustedProcessIdentity(started *startedGitCommand, budget time.Duration) error {
	// Once the captured identity cannot be revalidated, neither the old PGID nor
	// the numeric PID may be signaled. Wait and output closure remain bounded.
	_, waitErr := waitCommandBounded(started.command, budget)
	outputErr := waitForOutputEOF(started.reader, started.copied, budget)
	return errors.Join(waitErr, outputErr)
}

type boundedBuffer struct {
	buffer    bytes.Buffer
	limit     int
	truncated bool
}

func (buffer *boundedBuffer) Write(data []byte) (int, error) {
	if buffer.buffer.Len() >= buffer.limit {
		buffer.truncated = true
		return len(data), nil
	}
	remaining := buffer.limit - buffer.buffer.Len()
	if len(data) > remaining {
		buffer.truncated = true
		_, _ = buffer.buffer.Write(data[:remaining])
		return len(data), nil
	}
	return buffer.buffer.Write(data)
}

func (buffer *boundedBuffer) Bytes() []byte {
	return buffer.buffer.Bytes()
}
