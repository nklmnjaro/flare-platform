package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
)

var objectIDPattern = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

var errRepositoryNotClean = errors.New("repository worktree or index is not clean")

type repositoryIdentity struct {
	Root         string
	ObjectFormat string
	Branch       string
	Commit       string
	Tree         string
	RootDevice   uint64
	RootInode    uint64
	GitDevice    uint64
	GitInode     uint64
	Config       repositoryConfigSnapshot
}

func inspectRepository(repository string, runner *gitRunner) (
	identity repositoryIdentity,
	resultErr error,
) {
	root, err := canonicalDirectory(repository)
	if err != nil {
		return repositoryIdentity{}, err
	}
	boundary, err := openRepositoryBoundary(root)
	if err != nil {
		return repositoryIdentity{}, err
	}
	defer func() { resultErr = errors.Join(resultErr, boundary.close()) }()
	restoreBinding := runner.bindSourceRoot(root, boundary.root, boundary.git)
	defer restoreBinding()
	return inspectRepositoryWithBoundary(root, runner, boundary)
}

func inspectRepositoryWithBoundary(
	root string,
	runner *gitRunner,
	boundary *repositoryBoundary,
) (repositoryIdentity, error) {
	if err := boundary.beginInspection(); err != nil {
		return repositoryIdentity{}, err
	}
	identity := repositoryIdentity{
		Root:       root,
		RootDevice: boundary.rootIdentity.device, RootInode: boundary.rootIdentity.inode,
		GitDevice: boundary.gitIdentity.device, GitInode: boundary.gitIdentity.inode,
	}
	config, err := inspectRepositoryConfig(boundary.git)
	if err != nil {
		return repositoryIdentity{}, err
	}
	identity.Config = config
	if err := rejectPinnedAlternates(boundary.git); err != nil {
		return repositoryIdentity{}, err
	}
	if err := rejectPinnedCommonDirectory(boundary.git); err != nil {
		return repositoryIdentity{}, err
	}
	if err := rejectDangerousRepositoryConfiguration(identity, runner); err != nil {
		return repositoryIdentity{}, err
	}
	if err := verifyRepositoryRoot(&identity, runner); err != nil {
		return repositoryIdentity{}, err
	}
	if err := verifyRepositoryState(identity, runner, boundary.root); err != nil {
		return repositoryIdentity{}, err
	}
	if err := verifyRepositoryFeatures(identity, runner); err != nil {
		return repositoryIdentity{}, err
	}
	if _, err := runner.run(root, nil, "fsck", "--full", "--strict", "--no-progress"); err != nil {
		return repositoryIdentity{}, fmt.Errorf("repository object verification failed: %w", err)
	}
	if err := verifyRepositoryIdentityCurrent(identity, runner); err != nil {
		return repositoryIdentity{}, err
	}
	if err := recheckRepositoryLocalIndirection(identity, runner); err != nil {
		return repositoryIdentity{}, err
	}
	if err := verifyRepositoryState(identity, runner, boundary.root); err != nil {
		return repositoryIdentity{}, err
	}
	recoveryFilesystemBarrier(recoveryBarrierRepositoryPath)
	if err := verifyRepositoryConfig(boundary.git, identity.Config); err != nil {
		return repositoryIdentity{}, err
	}
	if err := boundary.verify(); err != nil {
		return repositoryIdentity{}, err
	}
	return identity, nil
}

func recheckRepositoryLocalIndirection(identity repositoryIdentity, runner *gitRunner) error {
	if err := rejectPinnedAlternates(runner.sourceGitFD); err != nil {
		return err
	}
	if err := rejectPinnedCommonDirectory(runner.sourceGitFD); err != nil {
		return err
	}
	if err := rejectDangerousRepositoryConfiguration(identity, runner); err != nil {
		return err
	}
	if err := rejectReplaceAndGraftState(identity, runner); err != nil {
		return err
	}
	return rejectPartialClone(identity, runner)
}

func rejectDangerousRepositoryConfiguration(
	identity repositoryIdentity,
	runner *gitRunner,
) error {
	if err := verifyRepositoryConfig(runner.sourceGitFD, identity.Config); err != nil {
		return err
	}
	queries := []struct {
		pattern string
		reason  string
	}{
		{
			`^[cC][oO][rR][eE]\.[aA][lL][tT][eE][rR][nN][aA][tT][eE][rR][eE][fF][sS][cC][oO][mM][mM][aA][nN][dD]$`,
			"core.alternateRefsCommand is unsupported in recovery source",
		},
		{
			`^[fF][sS][cC][kK]\.`,
			"fsck configuration is unsupported in recovery source",
		},
	}
	for _, query := range queries {
		output, status, err := runner.runStatus(
			identity.Root, nil, "config", "--get-regexp", query.pattern)
		if err != nil {
			return err
		}
		if status == 0 && len(bytes.TrimSpace(output)) != 0 {
			return errors.New(query.reason)
		}
		if status != 0 && status != 1 {
			return fmt.Errorf("Git safety configuration inspection failed with status %d", status)
		}
	}
	return verifyRepositoryConfig(runner.sourceGitFD, identity.Config)
}

func verifyRepositoryIdentityCurrent(expected repositoryIdentity, runner *gitRunner) error {
	current := repositoryIdentity{Root: expected.Root}
	if err := verifyRepositoryRoot(&current, runner); err != nil {
		return fmt.Errorf("repository identity changed during inspection: %w", err)
	}
	if current.ObjectFormat != expected.ObjectFormat || current.Branch != expected.Branch ||
		current.Commit != expected.Commit || current.Tree != expected.Tree {
		return errors.New("repository identity changed during inspection")
	}
	return nil
}

func verifyRepositoryRoot(identity *repositoryIdentity, runner *gitRunner) error {
	inside, err := runner.run(identity.Root, nil, "rev-parse", "--is-inside-work-tree")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(inside)) != "true" {
		return errors.New("repository root does not match Git top-level")
	}
	headRef, err := runner.run(identity.Root, nil, "symbolic-ref", "--quiet", "HEAD")
	if err != nil {
		return errors.New("repository HEAD must name a local branch")
	}
	ref := strings.TrimSpace(string(headRef))
	if !strings.HasPrefix(ref, "refs/heads/") {
		return errors.New("repository HEAD must name a local branch")
	}
	identity.Branch = strings.TrimPrefix(ref, "refs/heads/")
	if identity.Branch == "" || strings.ContainsAny(identity.Branch, "\r\n\x00") {
		return errors.New("repository branch name is unsafe")
	}
	if _, err := runner.run(identity.Root, nil, "check-ref-format", "--branch", identity.Branch); err != nil {
		return errors.New("repository branch name is invalid")
	}
	return loadRepositoryObjectIdentity(identity, runner)
}

func loadRepositoryObjectIdentity(identity *repositoryIdentity, runner *gitRunner) error {
	commit, err := runner.run(identity.Root, nil, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		return err
	}
	tree, err := runner.run(identity.Root, nil, "rev-parse", "--verify", "HEAD^{tree}")
	if err != nil {
		return err
	}
	format, err := runner.run(identity.Root, nil, "rev-parse", "--show-object-format")
	if err != nil {
		return err
	}
	identity.Commit = strings.TrimSpace(string(commit))
	identity.Tree = strings.TrimSpace(string(tree))
	identity.ObjectFormat = strings.TrimSpace(string(format))
	if err := validateObjectIdentity(*identity); err != nil {
		return err
	}
	branchCommit, err := runner.run(identity.Root, nil, "rev-parse", "--verify",
		"refs/heads/"+identity.Branch+"^{commit}")
	if err != nil || strings.TrimSpace(string(branchCommit)) != identity.Commit {
		return errors.New("local branch does not resolve to HEAD")
	}
	return nil
}

func validateObjectIdentity(identity repositoryIdentity) error {
	if identity.ObjectFormat != "sha1" && identity.ObjectFormat != "sha256" {
		return fmt.Errorf("unsupported Git object format %q", identity.ObjectFormat)
	}
	for label, value := range map[string]string{"commit": identity.Commit, "tree": identity.Tree} {
		if !objectIDPattern.MatchString(value) {
			return fmt.Errorf("invalid %s object ID", label)
		}
		if identity.ObjectFormat == "sha1" && len(value) != 40 {
			return fmt.Errorf("%s object ID does not match sha1 format", label)
		}
		if identity.ObjectFormat == "sha256" && len(value) != 64 {
			return fmt.Errorf("%s object ID does not match sha256 format", label)
		}
	}
	return nil
}

func verifyRepositoryState(
	identity repositoryIdentity,
	runner *gitRunner,
	root *os.File,
) error {
	if err := rejectConfiguredFilters(identity, runner); err != nil {
		return err
	}
	flags, err := runner.runLarge(identity.Root, nil, "ls-files", "-v", "-z")
	if err != nil {
		return err
	}
	for _, record := range bytes.Split(flags, []byte{0}) {
		if len(record) == 0 {
			continue
		}
		if record[0] == 'S' || (record[0] >= 'a' && record[0] <= 'z') {
			return errors.New("repository contains hidden index flags")
		}
	}
	entries, err := exactHeadIndexEntries(identity, runner)
	if err != nil {
		return err
	}
	if err := verifyRawTrackedWorktree(root, entries, identity.ObjectFormat); err != nil {
		return err
	}
	shallow, err := runner.run(identity.Root, nil, "rev-parse", "--is-shallow-repository")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(shallow)) != "false" {
		return errors.New("shallow repository cannot produce a recovery capsule")
	}
	return nil
}

func rejectConfiguredFilters(identity repositoryIdentity, runner *gitRunner) error {
	if err := verifyRepositoryConfig(runner.sourceGitFD, identity.Config); err != nil {
		return err
	}
	pattern := `^[fF][iI][lL][tT][eE][rR]\.`
	output, status, err := runner.runStatus(
		identity.Root, nil, "config", "--get-regexp", pattern)
	if err != nil {
		return err
	}
	if status == 0 && len(bytes.TrimSpace(output)) != 0 {
		return errors.New("configured Git filters are unsupported in recovery source")
	}
	if status != 0 && status != 1 {
		return fmt.Errorf("Git filter configuration inspection failed with status %d", status)
	}
	return verifyRepositoryConfig(runner.sourceGitFD, identity.Config)
}

func verifyRepositoryFeatures(identity repositoryIdentity, runner *gitRunner) error {
	if err := rejectReplaceAndGraftState(identity, runner); err != nil {
		return err
	}
	if err := rejectPartialClone(identity, runner); err != nil {
		return err
	}
	if err := rejectReachableHistoryIndirection(identity, runner); err != nil {
		return err
	}
	return rejectLFSAttributes(identity, runner)
}

func rejectReplaceAndGraftState(identity repositoryIdentity, runner *gitRunner) error {
	replaceRefs, err := runner.run(identity.Root, nil, "for-each-ref", "--format=%(refname)", "refs/replace/")
	if err != nil {
		return err
	}
	if len(bytes.TrimSpace(replaceRefs)) != 0 {
		return errors.New("Git replace refs are unsupported in recovery source")
	}
	return rejectPinnedGrafts(runner.sourceGitFD)
}

func rejectPartialClone(identity repositoryIdentity, runner *gitRunner) error {
	if err := verifyRepositoryConfig(runner.sourceGitFD, identity.Config); err != nil {
		return err
	}
	for _, arguments := range [][]string{
		{"config", "--local", "--get", "extensions.partialClone"},
		{"config", "--local", "--get-regexp", `^remote\..*\.promisor$`},
	} {
		output, status, err := runner.runStatus(identity.Root, nil, arguments...)
		if err != nil {
			return err
		}
		if status == 0 && len(bytes.TrimSpace(output)) != 0 {
			return errors.New("partial or promisor clone is unsupported in recovery source")
		}
		if status != 0 && status != 1 {
			return fmt.Errorf("git config inspection failed with status %d", status)
		}
	}
	if err := verifyRepositoryConfig(runner.sourceGitFD, identity.Config); err != nil {
		return err
	}
	return rejectPinnedPromisorMarkers(runner.sourceGitFD)
}

func rejectLFSAttributes(identity repositoryIdentity, runner *gitRunner) error {
	if err := verifyRepositoryConfig(runner.sourceGitFD, identity.Config); err != nil {
		return err
	}
	paths, err := runner.runLarge(identity.Root, nil, "ls-files", "-z")
	if err != nil {
		return err
	}
	if err := verifyRepositoryConfig(runner.sourceGitFD, identity.Config); err != nil {
		return err
	}
	attributes, err := runner.runLarge(identity.Root, paths,
		"check-attr", "--cached", "-z", "filter", "--stdin")
	if err != nil {
		return err
	}
	fields := bytes.Split(attributes, []byte{0})
	for index := 0; index+2 < len(fields); index += 3 {
		if string(fields[index+2]) == "lfs" {
			return errors.New("Git LFS content is unsupported in recovery capsule")
		}
	}
	return verifyRepositoryConfig(runner.sourceGitFD, identity.Config)
}
