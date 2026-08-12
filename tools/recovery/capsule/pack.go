package main

import (
	"errors"
	"fmt"
	"path/filepath"
)

func packCapsuleWithGit(repository, destination, gitExecutable string) (resultErr error) {
	canonicalRepository, err := canonicalDirectory(repository)
	if err != nil {
		return err
	}
	boundary, err := openRepositoryBoundary(canonicalRepository)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, boundary.close()) }()
	runner, cleanupRunner, err := newGitRunner(canonicalRepository, gitExecutable)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, cleanupRunner()) }()
	restoreBinding := runner.bindSourceRoot(canonicalRepository, boundary.root, boundary.git)
	defer restoreBinding()
	identity, err := inspectRepositoryWithBoundary(canonicalRepository, runner, boundary)
	if err != nil {
		return err
	}
	prepared, err := prepareDestination(destination, canonicalRepository)
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, prepared.parent.Close()) }()
	stage, err := prepared.createStage()
	if err != nil {
		return err
	}
	defer func() { resultErr = errors.Join(resultErr, stage.directory.Close()) }()
	defer func() {
		if !stage.renamed {
			resultErr = errors.Join(resultErr, stage.discard())
		}
	}()
	recoveryFilesystemBarrier(recoveryBarrierBeforePopulate)
	if err := populateCapsule(stage, identity, runner); err != nil {
		return err
	}
	recoveryFilesystemBarrier(recoveryBarrierBeforePublish)
	if err := verifySourceUnchanged(canonicalRepository, identity, runner, boundary); err != nil {
		return err
	}
	if err := verifyPinnedCapsuleWithRunner(stage.directory, runner); err != nil {
		return fmt.Errorf("staged recovery capsule failed final verification: %w", err)
	}
	if err := stage.directory.Sync(); err != nil {
		return err
	}
	if err := verifySourceUnchanged(canonicalRepository, identity, runner, boundary); err != nil {
		return err
	}
	if err := prepared.verifyNamedParent(); err != nil {
		return err
	}
	return stage.publish()
}

func verifySourceUnchanged(
	repository string,
	expected repositoryIdentity,
	runner *gitRunner,
	boundary *repositoryBoundary,
) error {
	current, err := inspectRepositoryWithBoundary(repository, runner, boundary)
	if err != nil {
		return fmt.Errorf("source repository changed during capture: %w", err)
	}
	if !sameRepositoryIdentity(expected, current) {
		return errors.New("source repository changed during capture")
	}
	return nil
}

func populateCapsule(stage *pinnedStage, identity repositoryIdentity, runner *gitRunner) error {
	bundle, err := stage.createFile("repository.bundle")
	if err != nil {
		return err
	}
	arguments := []string{
		"bundle", "create", "-",
		"HEAD", "refs/heads/" + identity.Branch,
	}
	writer := newDrainingCappedWriter(bundle, maxRecoveryBundleBytes)
	runErr := runner.runToWriter(identity.Root, writer, arguments...)
	if writer.overflowedLimit() {
		recoveryFilesystemBarrier(recoveryBarrierBundleOverflow)
		return errors.Join(errRecoveryBundleTooLarge, bundle.Close())
	}
	if runErr != nil {
		return errors.Join(runErr, bundle.Close())
	}
	info, err := bundle.Stat()
	if err != nil {
		return errors.Join(err, bundle.Close())
	}
	if info.Size() > maxRecoveryBundleBytes {
		return errors.Join(errRecoveryBundleTooLarge, bundle.Close())
	}
	if err := bundle.Chmod(0o600); err != nil {
		return errors.Join(err, bundle.Close())
	}
	if err := bundle.Sync(); err != nil {
		return errors.Join(err, bundle.Close())
	}
	if err := bundle.Close(); err != nil {
		return err
	}
	directory := stage.pinnedPath()
	bundlePath := filepath.Join(directory, "repository.bundle")
	bundleSHA256, err := fileSHA256(bundlePath)
	if err != nil {
		return err
	}
	recovery := newRecoveryIdentity(identity, bundleSHA256)
	if err := writeRecoveryIdentity(filepath.Join(directory, "RECOVERY.json"), recovery); err != nil {
		return err
	}
	return writeManifest(directory)
}
