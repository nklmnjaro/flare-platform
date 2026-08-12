package main

import (
	"bytes"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

func verifyCapsuleWithGit(capsule, gitExecutable string) error {
	directory, err := canonicalCapsuleDirectory(capsule)
	if err != nil {
		return err
	}
	runner, cleanupRunner, err := newGitRunner(directory, gitExecutable)
	if err != nil {
		return err
	}
	resultErr := verifyCapsuleWithRunner(directory, runner)
	return errors.Join(resultErr, cleanupRunner())
}

func verifyCapsuleWithRunner(directory string, runner *gitRunner) error {
	pinned, err := openDirectoryNoFollow(directory)
	if err != nil {
		return err
	}
	defer pinned.Close()
	return verifyPinnedCapsuleWithRunner(pinned, runner)
}

func verifyCapsuleSnapshot(directory string, runner *gitRunner) error {
	if err := verifyCapsuleFileSet(directory); err != nil {
		return err
	}
	if err := verifyManifest(directory); err != nil {
		return err
	}
	identity, err := readRecoveryIdentity(filepath.Join(directory, "RECOVERY.json"))
	if err != nil {
		return err
	}
	bundlePath := filepath.Join(directory, identity.BundleFile)
	digest, err := fileSHA256(bundlePath)
	if err != nil {
		return err
	}
	if digest != identity.BundleSHA256 {
		return errors.New("bundle hash does not match RECOVERY.json")
	}
	if err := verifyBundleHeads(bundlePath, identity, runner); err != nil {
		return err
	}
	return verifyRecoveredClone(bundlePath, identity, runner)
}

func verifyBundleHeads(bundlePath string, identity recoveryIdentity, runner *gitRunner) error {
	if _, err := runner.run("", nil, "check-ref-format", "--branch", identity.Branch); err != nil {
		return errors.New("recovery branch name is invalid")
	}
	output, err := runner.run("", nil, "bundle", "list-heads", bundlePath)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	sort.Strings(lines)
	expected := []string{
		identity.Commit + " HEAD",
		identity.Commit + " refs/heads/" + identity.Branch,
	}
	sort.Strings(expected)
	if len(lines) != len(expected) {
		return errors.New("bundle refs are not exact")
	}
	for index := range expected {
		if lines[index] != expected[index] {
			return errors.New("bundle HEAD or branch ref does not match recovery identity")
		}
	}
	return nil
}

func verifyRecoveredClone(
	bundlePath string,
	expected recoveryIdentity,
	runner *gitRunner,
) (resultErr error) {
	workspace, err := newPinnedTempDirectory("flare-recovery-clone-")
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, workspace.cleanup()) }()
	bare := filepath.Join(workspace.pinnedPath, "verify.git")
	if _, err := runner.run("", nil, "init", "--bare", "--quiet", bare); err != nil {
		return err
	}
	if err := workspace.registerCurrentOwnedName("verify.git"); err != nil {
		return err
	}
	if _, err := runner.run(bare, nil, "bundle", "verify", bundlePath); err != nil {
		return fmt.Errorf("bundle verification failed: %w", err)
	}
	cloneName := "restored checkout #[]&"
	clone := filepath.Join(workspace.pinnedPath, cloneName)
	if _, err := runner.run("", nil, "clone", "--quiet", "--no-checkout", bundlePath, clone); err != nil {
		return fmt.Errorf("direct recovery clone failed: %w", err)
	}
	canonicalClone := filepath.Join(workspace.path, cloneName)
	cloneBoundary, err := openRepositoryBoundaryAt(workspace.directory, workspace.path, cloneName)
	if err != nil {
		return fmt.Errorf("recovered repository boundary is unsafe: %w", err)
	}
	if err := workspace.registerOwnedName(cloneName, cloneBoundary.rootIdentity); err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, cloneBoundary.close()) }()
	restoreBinding := runner.bindSourceRoot(canonicalClone, cloneBoundary.root, cloneBoundary.git)
	defer restoreBinding()
	recoveryFilesystemBarrier(recoveryBarrierClonePinned)
	config, err := inspectRepositoryConfig(cloneBoundary.git)
	if err != nil {
		return fmt.Errorf("recovered repository config is unsafe: %w", err)
	}
	admission := repositoryIdentity{Root: canonicalClone, Config: config}
	if err := rejectPinnedAlternates(cloneBoundary.git); err != nil {
		return fmt.Errorf("recovered repository object store is unsafe: %w", err)
	}
	if err := rejectPinnedCommonDirectory(cloneBoundary.git); err != nil {
		return fmt.Errorf("recovered repository metadata is unsafe: %w", err)
	}
	if err := rejectDangerousRepositoryConfiguration(admission, runner); err != nil {
		return fmt.Errorf("recovered repository config is unsafe: %w", err)
	}
	if err := rejectConfiguredFilters(admission, runner); err != nil {
		return fmt.Errorf("recovered repository config is unsafe: %w", err)
	}
	if err := verifyRecoveredTreeBudget(canonicalClone, runner); err != nil {
		return err
	}
	if _, err := runner.run(canonicalClone, nil, "reset", "--hard", "--quiet", "HEAD"); err != nil {
		return fmt.Errorf("recovered worktree materialization failed: %w", err)
	}
	observed, err := inspectRepositoryWithBoundary(canonicalClone, runner, cloneBoundary)
	if err != nil {
		return fmt.Errorf("restored repository failed inspection: %w", err)
	}
	return compareRecoveredIdentity(observed, expected)
}

func sameRepositoryIdentity(left, right repositoryIdentity) bool {
	return left.ObjectFormat == right.ObjectFormat && left.Branch == right.Branch &&
		left.Commit == right.Commit && left.Tree == right.Tree &&
		left.RootDevice == right.RootDevice && left.RootInode == right.RootInode &&
		left.GitDevice == right.GitDevice && left.GitInode == right.GitInode &&
		left.Config.digest == right.Config.digest &&
		sameStableFile(left.Config.state, right.Config.state)
}

func compareRecoveredIdentity(observed repositoryIdentity, expected recoveryIdentity) error {
	pairs := []struct {
		label    string
		observed string
		expected string
	}{
		{"object format", observed.ObjectFormat, expected.ObjectFormat},
		{"branch", observed.Branch, expected.Branch},
		{"commit", observed.Commit, expected.Commit},
		{"tree", observed.Tree, expected.Tree},
	}
	for _, pair := range pairs {
		if !bytes.Equal([]byte(pair.observed), []byte(pair.expected)) {
			return fmt.Errorf("restored %s does not match recovery identity", pair.label)
		}
	}
	return nil
}
