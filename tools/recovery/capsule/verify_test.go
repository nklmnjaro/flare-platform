package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRecoveryClosureVerifyRejectsTamperAndUnexpectedFiles(t *testing.T) {
	t.Run("tampered-bundle", func(t *testing.T) {
		capsule := createTestCapsule(t)
		appendFile(t, filepath.Join(capsule, "repository.bundle"), "tamper")
		err := verifyTestCapsule(t, capsule)
		assertErrorContains(t, err, "manifest mismatch")
	})
	t.Run("unexpected-file", func(t *testing.T) {
		capsule := createTestCapsule(t)
		writeFile(t, filepath.Join(capsule, "extra.txt"), "unexpected\n")
		err := verifyTestCapsule(t, capsule)
		assertErrorContains(t, err, "file set is not exact")
	})
}

func TestRecoveryClosureVerifyRejectsBundleWithoutExplicitHEAD(t *testing.T) {
	repository := createTestRepository(t, 3)
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatal(err)
	}
	runner := testGitRunner(t, repository)
	bundle := filepath.Join(capsule, "repository.bundle")
	if err := os.Remove(bundle); err != nil {
		t.Fatal(err)
	}
	mustGit(t, runner, repository, "bundle", "create", bundle, "refs/heads/main")
	rebindCapsule(t, capsule)
	err := verifyTestCapsule(t, capsule)
	assertErrorContains(t, err, "bundle refs are not exact")
}

func TestRecoveryClosureVerifyRejectsIdentityMismatch(t *testing.T) {
	capsule := createTestCapsule(t)
	identityPath := filepath.Join(capsule, "RECOVERY.json")
	identity, err := readRecoveryIdentity(identityPath)
	if err != nil {
		t.Fatal(err)
	}
	identity.Commit = strings.Repeat("0", len(identity.Commit))
	if err := os.Remove(identityPath); err != nil {
		t.Fatal(err)
	}
	if err := writeRecoveryIdentity(identityPath, identity); err != nil {
		t.Fatal(err)
	}
	rewriteManifest(t, capsule)
	err = verifyTestCapsule(t, capsule)
	assertErrorContains(t, err, "bundle HEAD or branch ref")
}

func TestRecoveryClosureVerifyRejectsInvalidRecordedBranch(t *testing.T) {
	capsule := createTestCapsule(t)
	identityPath := filepath.Join(capsule, "RECOVERY.json")
	identity, err := readRecoveryIdentity(identityPath)
	if err != nil {
		t.Fatal(err)
	}
	identity.Branch = "invalid..branch"
	if err := os.Remove(identityPath); err != nil {
		t.Fatal(err)
	}
	if err := writeRecoveryIdentity(identityPath, identity); err != nil {
		t.Fatal(err)
	}
	rewriteManifest(t, capsule)
	err = verifyTestCapsule(t, capsule)
	assertErrorContains(t, err, "branch name is invalid")
}

func TestRecoveryClosureVerifyRejectsShallowBundleThatGitBundleVerifyAccepts(t *testing.T) {
	origin := createTestRepository(t, 3)
	shallow := filepath.Join(t.TempDir(), "shallow")
	runner := testGitRunner(t, origin)
	mustGit(t, runner, "", "clone", "--quiet", "--depth=1", "file://"+origin, shallow)
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := os.Mkdir(capsule, 0o700); err != nil {
		t.Fatal(err)
	}
	shallowRunner := testGitRunner(t, shallow)
	commit := strings.TrimSpace(string(mustGit(t, shallowRunner, shallow, "rev-parse", "HEAD")))
	tree := strings.TrimSpace(string(mustGit(t, shallowRunner, shallow, "rev-parse", "HEAD^{tree}")))
	bundle := filepath.Join(capsule, "repository.bundle")
	mustGit(t, shallowRunner, shallow, "bundle", "create", bundle, "HEAD", "refs/heads/main")
	digest, err := fileSHA256(bundle)
	if err != nil {
		t.Fatal(err)
	}
	identity := newRecoveryIdentity(repositoryIdentity{
		ObjectFormat: "sha1",
		Branch:       "main",
		Commit:       commit,
		Tree:         tree,
	}, digest)
	if err := writeRecoveryIdentity(filepath.Join(capsule, "RECOVERY.json"), identity); err != nil {
		t.Fatal(err)
	}
	if err := writeManifest(capsule); err != nil {
		t.Fatal(err)
	}
	err = verifyTestCapsule(t, capsule)
	assertErrorContains(t, err, "direct recovery clone failed")
}

func TestRecoveryClosureVerifyRejectsCapsuleRootSymlink(t *testing.T) {
	capsule := createTestCapsule(t)
	link := filepath.Join(t.TempDir(), "capsule-link")
	if err := os.Symlink(capsule, link); err != nil {
		t.Fatal(err)
	}
	err := verifyTestCapsule(t, link)
	assertErrorContains(t, err, "capsule root must not be a symlink")
}

func TestRecoveryClosureVerifyRejectsMemberNameSwapDuringSnapshot(t *testing.T) {
	capsule := createTestCapsule(t)
	bundle := filepath.Join(capsule, "repository.bundle")
	payload, err := os.ReadFile(bundle)
	if err != nil {
		t.Fatal(err)
	}
	replacement := filepath.Join(filepath.Dir(capsule), "replacement.bundle")
	if err := os.WriteFile(replacement, append(payload, []byte("tamper")...), 0o600); err != nil {
		t.Fatal(err)
	}
	parked := filepath.Join(filepath.Dir(capsule), "parked.bundle")
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	var swapErr error
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierMembersOpened || swapErr != nil {
			return
		}
		if err := os.Rename(bundle, parked); err != nil {
			swapErr = err
			return
		}
		swapErr = os.Rename(replacement, bundle)
	}
	err = verifyTestCapsule(t, capsule)
	if swapErr != nil {
		t.Fatalf("swap capsule member: %v", swapErr)
	}
	assertErrorContains(t, err, "changed during snapshot")
}

func TestRecoveryClosureVerifyWorksFromSpecialCharacterPath(t *testing.T) {
	repository := createTestRepository(t, 2)
	capsule := filepath.Join(t.TempDir(), "capsule #[]&")
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatal(err)
	}
	if err := verifyTestCapsule(t, capsule); err != nil {
		t.Fatalf("verify special-character path: %v", err)
	}
}

func TestRecoveryClosureVerifyCloneNameSwapNeverTouchesReplacement(t *testing.T) {
	capsule := createTestCapsule(t)
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	originalCreated := recoveryPinnedTempCreated
	defer func() { recoveryPinnedTempCreated = originalCreated }()
	var workspace string
	recoveryPinnedTempCreated = func(created *pinnedTempDirectory) {
		if strings.HasPrefix(created.name, "flare-recovery-clone-") {
			workspace = created.path
		}
	}
	triggered := false
	var replacement string
	var parked string
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierClonePinned || triggered {
			return
		}
		triggered = true
		if workspace == "" {
			t.Fatal("current recovered clone workspace was not captured")
		}
		replacement = filepath.Join(workspace, "restored checkout #[]&")
		parked = filepath.Join(workspace, "parked-restored-checkout")
		if err := os.Rename(replacement, parked); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(replacement, 0o700); err != nil {
			t.Fatal(err)
		}
		writeFile(t, filepath.Join(replacement, "victim"), "foreign\n")
	}
	t.Cleanup(func() {
		_ = os.Remove(filepath.Join(replacement, "victim"))
		_ = os.Remove(replacement)
		_ = os.Remove(parked)
		_ = os.Remove(workspace)
	})
	err := verifyTestCapsule(t, capsule)
	assertErrorContains(t, err, "repository path changed")
	payload, readErr := os.ReadFile(filepath.Join(replacement, "victim"))
	if readErr != nil || string(payload) != "foreign\n" {
		t.Fatalf("replacement clone was touched: %q, %v", payload, readErr)
	}
}

func TestRecoveryClosureVerifyRejectsOversizedRecoveredFileBeforeCheckout(t *testing.T) {
	repository := createTestRepository(t, 2)
	large := filepath.Join(repository, "oversized.bin")
	file, err := os.OpenFile(large, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxRecoveredFileBytes + 1); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	runner := testGitRunner(t, repository)
	mustGit(t, runner, repository, "add", "oversized.bin")
	mustGit(t, runner, repository, "commit", "-m", "test: add oversized file")
	err = packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
	assertErrorContains(t, err, "exceeds size budget")
}

func createTestCapsule(t *testing.T) string {
	t.Helper()
	repository := createTestRepository(t, 3)
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatal(err)
	}
	return capsule
}

func rebindCapsule(t *testing.T, capsule string) {
	t.Helper()
	identityPath := filepath.Join(capsule, "RECOVERY.json")
	identity, err := readRecoveryIdentity(identityPath)
	if err != nil {
		t.Fatal(err)
	}
	identity.BundleSHA256, err = fileSHA256(filepath.Join(capsule, identity.BundleFile))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(identityPath); err != nil {
		t.Fatal(err)
	}
	if err := writeRecoveryIdentity(identityPath, identity); err != nil {
		t.Fatal(err)
	}
	rewriteManifest(t, capsule)
}

func rewriteManifest(t *testing.T, capsule string) {
	t.Helper()
	manifest := filepath.Join(capsule, "MANIFEST.sha256")
	if err := os.Remove(manifest); err != nil {
		t.Fatal(err)
	}
	if err := writeManifest(capsule); err != nil {
		t.Fatal(err)
	}
}
