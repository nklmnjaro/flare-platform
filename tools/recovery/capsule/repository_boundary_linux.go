//go:build linux

package main

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

type repositoryBoundary struct {
	path             string
	parent           *os.File
	parentIdentity   stableFileState
	parentSample     stableFileState
	rootName         string
	root             *os.File
	rootIdentity     stableFileState
	rootSample       stableFileState
	git              *os.File
	gitIdentity      stableFileState
	platform         *os.File
	platformIdentity stableFileState
}

func openRepositoryBoundary(path string) (*repositoryBoundary, error) {
	parentPath := filepath.Dir(path)
	parent, parentIdentity, err := openPinnedCanonicalDirectory(parentPath)
	if err != nil {
		return nil, err
	}
	rootName := filepath.Base(path)
	root, err := openDirectoryAt(parent, rootName)
	if err != nil {
		_ = parent.Close()
		return nil, err
	}
	rootIdentity, err := fileState(root)
	if err != nil {
		_ = root.Close()
		_ = parent.Close()
		return nil, err
	}
	gitDirectory, err := openDirectoryAt(root, ".git")
	if err != nil {
		_ = root.Close()
		_ = parent.Close()
		return nil, errors.New("repository .git must be a non-symlink directory")
	}
	gitIdentity, err := fileState(gitDirectory)
	if err != nil {
		_ = gitDirectory.Close()
		_ = root.Close()
		_ = parent.Close()
		return nil, err
	}
	platform, err := openOptionalDirectoryAt(root, ".platform")
	if err != nil {
		_ = gitDirectory.Close()
		_ = root.Close()
		_ = parent.Close()
		return nil, errors.New("repository .platform must be a private non-symlink directory")
	}
	var platformIdentity stableFileState
	if platform != nil {
		platformIdentity, err = fileState(platform)
		if err != nil || platformIdentity.mode&0o777 != 0o700 ||
			platformIdentity.owner != uint32(os.Geteuid()) {
			_ = platform.Close()
			_ = gitDirectory.Close()
			_ = root.Close()
			_ = parent.Close()
			return nil, errors.New("repository .platform must be a private non-symlink directory")
		}
	}
	return &repositoryBoundary{
		path: path, parent: parent, parentIdentity: parentIdentity, rootName: rootName,
		root: root, rootIdentity: rootIdentity,
		git: gitDirectory, gitIdentity: gitIdentity,
		platform: platform, platformIdentity: platformIdentity,
	}, nil
}

func openRepositoryBoundaryAt(parentSource *os.File, parentPath, rootName string) (
	*repositoryBoundary,
	error,
) {
	parentFD, err := syscall.Dup(int(parentSource.Fd()))
	if err != nil {
		return nil, err
	}
	syscall.CloseOnExec(parentFD)
	parent := os.NewFile(uintptr(parentFD), parentPath)
	parentIdentity, err := fileState(parent)
	if err != nil {
		_ = parent.Close()
		return nil, err
	}
	root, err := openDirectoryAt(parent, rootName)
	if err != nil {
		_ = parent.Close()
		return nil, err
	}
	rootIdentity, err := fileState(root)
	if err != nil {
		_ = root.Close()
		_ = parent.Close()
		return nil, err
	}
	gitDirectory, err := openDirectoryAt(root, ".git")
	if err != nil {
		_ = root.Close()
		_ = parent.Close()
		return nil, errors.New("repository .git must be a non-symlink directory")
	}
	gitIdentity, err := fileState(gitDirectory)
	if err != nil {
		_ = gitDirectory.Close()
		_ = root.Close()
		_ = parent.Close()
		return nil, err
	}
	return &repositoryBoundary{
		path: filepath.Join(parentPath, rootName), parent: parent,
		parentIdentity: parentIdentity, rootName: rootName,
		root: root, rootIdentity: rootIdentity,
		git: gitDirectory, gitIdentity: gitIdentity,
	}, nil
}

func (boundary *repositoryBoundary) beginInspection() error {
	parent, err := fileState(boundary.parent)
	if err != nil {
		return err
	}
	if !sameFileObject(boundary.parentIdentity, parent) {
		return errors.New("repository parent identity changed")
	}
	root, err := fileState(boundary.root)
	if err != nil {
		return err
	}
	if !sameFileObject(boundary.rootIdentity, root) {
		return errors.New("repository root identity changed")
	}
	boundary.parentSample = parent
	boundary.rootSample = root
	return boundary.verifyNamedObjects()
}

func (boundary *repositoryBoundary) verify() error {
	parentAfter, err := fileState(boundary.parent)
	if err != nil {
		return err
	}
	if !sameFileObject(boundary.parentSample, parentAfter) {
		return errors.New("repository parent identity changed during inspection")
	}
	rootAfter, err := fileState(boundary.root)
	if err != nil {
		return err
	}
	if !sameStableFile(boundary.rootSample, rootAfter) {
		return errors.New("repository root changed during inspection")
	}
	return boundary.verifyNamedObjects()
}

func (boundary *repositoryBoundary) verifyNamedObjects() error {
	reopenedRoot, err := openDirectoryAt(boundary.parent, boundary.rootName)
	if err != nil {
		return errors.New("repository path changed during inspection")
	}
	defer reopenedRoot.Close()
	reopenedRootIdentity, err := fileState(reopenedRoot)
	if err != nil {
		return err
	}
	if !sameFileObject(boundary.rootIdentity, reopenedRootIdentity) {
		return errors.New("repository path changed during inspection")
	}
	pathRoot, err := openDirectoryNoFollow(boundary.path)
	if err != nil {
		return errors.New("repository path changed during inspection")
	}
	defer pathRoot.Close()
	pathRootIdentity, err := fileState(pathRoot)
	if err != nil || !sameFileObject(boundary.rootIdentity, pathRootIdentity) {
		return errors.New("repository path changed during inspection")
	}
	if err := boundary.verifyGitDirectory(boundary.root); err != nil {
		return err
	}
	if err := boundary.verifyGitDirectory(reopenedRoot); err != nil {
		return err
	}
	if err := boundary.verifyPlatformDirectory(boundary.root); err != nil {
		return err
	}
	return boundary.verifyPlatformDirectory(reopenedRoot)
}

func (boundary *repositoryBoundary) verifyGitDirectory(root *os.File) error {
	reopened, err := openDirectoryAt(root, ".git")
	if err != nil {
		return errors.New("repository .git changed during inspection")
	}
	defer reopened.Close()
	reopenedIdentity, err := fileState(reopened)
	if err != nil {
		return err
	}
	if !sameFileObject(boundary.gitIdentity, reopenedIdentity) {
		return errors.New("repository .git changed during inspection")
	}
	return nil
}

func (boundary *repositoryBoundary) verifyPlatformDirectory(root *os.File) error {
	reopened, err := openOptionalDirectoryAt(root, ".platform")
	if boundary.platform == nil {
		if err != nil {
			return err
		}
		if reopened != nil {
			_ = reopened.Close()
			return errors.New("repository .platform changed during inspection")
		}
		return nil
	}
	if err != nil || reopened == nil {
		return errors.New("repository .platform changed during inspection")
	}
	defer reopened.Close()
	observed, err := fileState(reopened)
	if err != nil || !sameFileObject(boundary.platformIdentity, observed) {
		return errors.New("repository .platform changed during inspection")
	}
	return nil
}

func (boundary *repositoryBoundary) close() error {
	return errors.Join(
		closeOptionalFile(boundary.platform),
		boundary.git.Close(),
		boundary.root.Close(),
		boundary.parent.Close(),
	)
}

func closeOptionalFile(file *os.File) error {
	if file == nil {
		return nil
	}
	return file.Close()
}
