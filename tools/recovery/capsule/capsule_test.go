package main

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestRecoveryClosurePackAndVerifyRecoveryCapsule(t *testing.T) {
	repository := createTestRepository(t, 3)
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatalf("pack clean repository: %v", err)
	}
	if err := verifyTestCapsule(t, capsule); err != nil {
		t.Fatalf("verify recovery capsule: %v", err)
	}
}

func TestRecoveryClosurePackContainsFullHeadHistory(t *testing.T) {
	repository := createTestRepository(t, 3)
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatal(err)
	}
	restored := filepath.Join(t.TempDir(), "restored")
	runner := testGitRunner(t, repository)
	mustGit(t, runner, "", "clone", "--quiet", "--no-checkout",
		filepath.Join(capsule, "repository.bundle"), restored)
	count := strings.TrimSpace(string(mustGit(t, runner, restored,
		"rev-list", "--count", "HEAD")))
	if count != "3" {
		t.Fatalf("recovery bundle history count = %q, want 3", count)
	}
}

func TestRecoveryClosureRepeatedPackIsByteStable(t *testing.T) {
	repository := createTestRepository(t, 3)
	root := t.TempDir()
	first := filepath.Join(root, "first")
	second := filepath.Join(root, "second")
	if err := packTestCapsule(t, repository, first); err != nil {
		t.Fatal(err)
	}
	if err := packTestCapsule(t, repository, second); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"MANIFEST.sha256", "RECOVERY.json", "repository.bundle"} {
		left, err := os.ReadFile(filepath.Join(first, name))
		if err != nil {
			t.Fatal(err)
		}
		right, err := os.ReadFile(filepath.Join(second, name))
		if err != nil {
			t.Fatal(err)
		}
		if string(left) != string(right) {
			t.Fatalf("repeated pack changed %s", name)
		}
	}
}

func TestRecoveryClosurePackRejectsDirtyTrackedAndUntrackedState(t *testing.T) {
	for _, scenario := range []struct {
		name string
		path string
	}{
		{"tracked", "README.md"},
		{"untracked", "untracked.txt"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			repository := createTestRepository(t, 2)
			appendFile(t, filepath.Join(repository, scenario.path), "dirty\n")
			err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
			assertErrorContains(t, err, "worktree or index is not clean")
		})
	}
}

func TestRecoveryClosurePackRejectsRepositoryConfiguredFalseCleanState(t *testing.T) {
	t.Run("file-mode", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		mustGit(t, runner, repository, "config", "--local", "core.fileMode", "false")
		path := filepath.Join(repository, "README.md")
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, info.Mode().Perm()|0o100); err != nil {
			t.Fatal(err)
		}
		assertUnsealedStatusClean(t, repository)
		assertPackRejectsWithoutOutput(t, repository, "worktree or index is not clean")
	})
	t.Run("symlink-mode", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		link := filepath.Join(repository, "tracked-link")
		if err := os.Symlink("README.md", link); err != nil {
			t.Fatal(err)
		}
		mustGit(t, runner, repository, "add", "tracked-link")
		mustGit(t, runner, repository, "commit", "-m", "test: add symlink")
		mustGit(t, runner, repository, "config", "--local", "core.symlinks", "false")
		if err := os.Remove(link); err != nil {
			t.Fatal(err)
		}
		writeFile(t, link, "README.md")
		assertUnsealedStatusClean(t, repository)
		assertPackRejectsWithoutOutput(t, repository, "worktree or index is not clean")
	})
	t.Run("autocrlf", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		path := filepath.Join(repository, "line.txt")
		mustGit(t, runner, repository, "config", "--local", "core.autocrlf", "true")
		writeFile(t, path, "first\r\nsecond\r\n")
		mustGit(t, runner, repository, "add", "line.txt")
		mustGit(t, runner, repository, "commit", "-m", "test: add line endings")
		assertUnsealedStatusClean(t, repository)
		assertPackRejectsWithoutOutput(t, repository, "worktree or index is not clean")
	})
	t.Run("minimal-stat", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		path := filepath.Join(repository, "stat.txt")
		writeFile(t, path, "stable\n")
		oldTime := time.Unix(1_700_000_000, 0)
		if err := os.Chtimes(path, oldTime, oldTime); err != nil {
			t.Fatal(err)
		}
		mustGit(t, runner, repository, "add", "stat.txt")
		mustGit(t, runner, repository, "commit", "-m", "test: add stat fixture")
		mustGit(t, runner, repository, "config", "--local", "core.trustctime", "false")
		mustGit(t, runner, repository, "config", "--local", "core.checkStat", "minimal")
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		payload, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		payload[0] ^= 1
		if err := os.WriteFile(path, payload, info.Mode().Perm()); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
			t.Fatal(err)
		}
		assertUnsealedStatusClean(t, repository)
		assertPackRejectsWithoutOutput(t, repository, "worktree or index is not clean")
	})
}

func TestRecoveryClosurePackRejectsConfiguredFilterWithoutExecutingIt(t *testing.T) {
	repository := createTestRepository(t, 2)
	runner := testGitRunner(t, repository)
	attributes := filepath.Join(repository, ".gitattributes")
	payload := filepath.Join(repository, "payload.txt")
	writeFile(t, attributes, "*.txt filter=evil\n")
	writeFile(t, payload, "clean\n")
	mustGit(t, runner, repository, "add", ".gitattributes", "payload.txt")
	mustGit(t, runner, repository, "commit", "-m", "test: add filter attributes")
	marker := filepath.Join(t.TempDir(), "filter-executed")
	filter := filepath.Join(t.TempDir(), "filter")
	writeFile(t, filter, "#!/bin/sh\nprintf executed >>'"+marker+"'\nprintf 'clean\\n'\n")
	if err := os.Chmod(filter, 0o700); err != nil {
		t.Fatal(err)
	}
	mustGit(t, runner, repository, "config", "--local", "filter.evil.clean", filter)
	writeFile(t, payload, "dirty\n")
	assertPackRejectsWithoutOutput(t, repository, "configured Git filters are unsupported")
	if _, err := os.Lstat(marker); !os.IsNotExist(err) {
		t.Fatalf("configured clean filter executed: %v", err)
	}
}

func TestRecoveryClosurePackRejectsInfoExcludeHiddenUntrackedFile(t *testing.T) {
	repository := createTestRepository(t, 2)
	runner := testGitRunner(t, repository)
	exclude := strings.TrimSpace(string(mustGit(t, runner, repository,
		"rev-parse", "--git-path", "info/exclude")))
	if !filepath.IsAbs(exclude) {
		exclude = filepath.Join(repository, exclude)
	}
	if err := os.MkdirAll(filepath.Dir(exclude), 0o700); err != nil {
		t.Fatal(err)
	}
	appendFile(t, exclude, "hidden-local.txt\n")
	writeFile(t, filepath.Join(repository, "hidden-local.txt"), "hidden\n")
	assertPackRejectsWithoutOutput(t, repository, "worktree or index is not clean")
}

func TestRecoveryClosurePackRejectsTrackedHardlinkAliasInPlatformState(t *testing.T) {
	repository := createTestRepository(t, 2)
	platform := filepath.Join(repository, ".platform")
	if err := os.Mkdir(platform, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filepath.Join(repository, "README.md"),
		filepath.Join(platform, "tracked-alias")); err != nil {
		t.Fatal(err)
	}
	assertPackRejectsWithoutOutput(t, repository, "worktree or index is not clean")
}

func TestRecoveryClosurePackCannotMaskDirtyTrackedSymlinkWithNameSwap(t *testing.T) {
	repository := createTestRepository(t, 2)
	runner := testGitRunner(t, repository)
	link := filepath.Join(repository, "tracked-link")
	if err := os.Symlink("README.md", link); err != nil {
		t.Fatal(err)
	}
	mustGit(t, runner, repository, "add", "tracked-link")
	mustGit(t, runner, repository, "commit", "-m", "test: tracked symlink")
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("dirty-target", link); err != nil {
		t.Fatal(err)
	}
	clean := filepath.Join(repository, "clean-replacement-link")
	parked := filepath.Join(repository, "dirty-parked-link")
	if err := os.Symlink("README.md", clean); err != nil {
		t.Fatal(err)
	}
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	triggered := false
	var hookErr error
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierSymlinkPinned || triggered {
			return
		}
		triggered = true
		if err := os.Rename(link, parked); err != nil {
			hookErr = err
			return
		}
		hookErr = os.Rename(clean, link)
	}
	assertPackRejectsWithoutOutput(t, repository, "tracked symlink")
	if hookErr != nil {
		t.Fatalf("symlink swap barrier: %v", hookErr)
	}
	if target, err := os.Readlink(parked); err != nil || target != "dirty-target" {
		t.Fatalf("pinned dirty symlink changed: %q, %v", target, err)
	}
}

func TestRecoveryClosurePackRejectsPlatformSymlinkWithoutTouchingTarget(t *testing.T) {
	repository := createTestRepository(t, 2)
	target := t.TempDir()
	marker := filepath.Join(target, "marker")
	writeFile(t, marker, "foreign\n")
	if err := os.Symlink(target, filepath.Join(repository, ".platform")); err != nil {
		t.Fatal(err)
	}
	assertPackRejectsWithoutOutput(t, repository, ".platform must be a private non-symlink directory")
	payload, err := os.ReadFile(marker)
	if err != nil || string(payload) != "foreign\n" {
		t.Fatalf("platform symlink target was touched: %q, %v", payload, err)
	}
}

func TestRecoveryClosurePackRejectsRepositoryConfigIncludesWithoutExecutingFilter(t *testing.T) {
	for _, section := range []string{
		"[include] ; trailing comment",
		`[includeIf "gitdir:**"]`,
	} {
		t.Run(section, func(t *testing.T) {
			repository := createTestRepository(t, 2)
			external := filepath.Join(t.TempDir(), "external.config")
			marker := filepath.Join(t.TempDir(), "filter-executed")
			filter := filepath.Join(t.TempDir(), "filter")
			writeFile(t, filter, "#!/bin/sh\nprintf executed >'"+marker+"'\ncat\n")
			if err := os.Chmod(filter, 0o700); err != nil {
				t.Fatal(err)
			}
			writeFile(t, external, "[filter \"evil\"]\n\tclean = "+filter+"\n")
			config := filepath.Join(repository, ".git", "config")
			appendFile(t, config, "\n"+section+"\n\tpath = "+external+"\n")
			assertPackRejectsWithoutOutput(t, repository, "config includes are unsupported")
			if _, err := os.Lstat(marker); !os.IsNotExist(err) {
				t.Fatalf("included filter executed: %v", err)
			}
		})
	}
}

func TestRecoveryClosurePackRejectsMalformedRepositoryConfigWithoutPanic(t *testing.T) {
	repository := createTestRepository(t, 2)
	appendFile(t, filepath.Join(repository, ".git", "config"), "\n= malformed\n")
	assertPackRejectsWithoutOutput(t, repository, "repository config is malformed")
}

func TestRecoveryClosureRepositoryConfigSnapshotDetectsSameInodeRestore(t *testing.T) {
	repository := createTestRepository(t, 2)
	boundary, err := openRepositoryBoundary(repository)
	if err != nil {
		t.Fatal(err)
	}
	defer boundary.close()
	snapshot, err := inspectRepositoryConfig(boundary.git)
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(repository, ".git", "config")
	payload, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	changed := append([]byte(nil), payload...)
	changed[len(changed)-1] ^= 1
	file, err := os.OpenFile(configPath, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write(changed); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if _, err := file.Seek(0, 0); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Truncate(0); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if _, err := file.Write(payload); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	err = verifyRepositoryConfig(boundary.git, snapshot)
	assertErrorContains(t, err, "config changed during capture")
}

func TestRecoveryClosurePackRejectsDangerousRepositoryMetadataAndConfiguration(t *testing.T) {
	t.Run("object-alternates-and-command", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		alternates := filepath.Join(repository, ".git", "objects", "info", "alternates")
		if err := os.MkdirAll(filepath.Dir(alternates), 0o700); err != nil {
			t.Fatal(err)
		}
		writeFile(t, alternates, t.TempDir()+"\n")
		marker := filepath.Join(t.TempDir(), "alternate-command-executed")
		command := "printf executed >'" + marker + "'"
		mustGit(t, runner, repository, "config", "--local", "core.alternateRefsCommand", command)
		assertPackRejectsWithoutOutput(t, repository, "object alternates are unsupported")
		if _, err := os.Lstat(marker); !os.IsNotExist(err) {
			t.Fatalf("alternateRefsCommand executed: %v", err)
		}
	})
	t.Run("fsck-configuration", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		mustGit(t, runner, repository, "config", "--local", "fsck.missingEmail", "ignore")
		assertPackRejectsWithoutOutput(t, repository, "fsck configuration is unsupported")
	})
	t.Run("worktree-config", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		appendFile(t, filepath.Join(repository, ".git", "config"),
			"\n[extensions]\n\tworktreeConfig = true\n")
		assertPackRejectsWithoutOutput(t, repository, "extensions.worktreeConfig is unsupported")
	})
	t.Run("common-directory", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		writeFile(t, filepath.Join(repository, ".git", "commondir"), t.TempDir()+"\n")
		assertPackRejectsWithoutOutput(t, repository, "common-directory indirection is unsupported")
	})
}

func TestRecoveryClosurePackRejectsStagedOnlyIndexChange(t *testing.T) {
	repository := createTestRepository(t, 2)
	runner := testGitRunner(t, repository)
	appendFile(t, filepath.Join(repository, "README.md"), "staged only\n")
	mustGit(t, runner, repository, "add", "README.md")
	assertPackRejectsWithoutOutput(t, repository, "worktree or index is not clean")
}

func TestRecoveryClosurePackAndVerifySHA256Repository(t *testing.T) {
	repository := filepath.Join(t.TempDir(), "repository")
	if err := os.Mkdir(repository, 0o700); err != nil {
		t.Fatal(err)
	}
	runner := testGitRunner(t, repository)
	mustGit(t, runner, "", "init", "--quiet", "--object-format=sha256", "-b", "main", repository)
	mustGit(t, runner, repository, "config", "user.name", "Flare Recovery Test")
	mustGit(t, runner, repository, "config", "user.email", "recovery@example.invalid")
	writeFile(t, filepath.Join(repository, "README.md"), "sha256\n")
	mustGit(t, runner, repository, "add", "README.md")
	mustGit(t, runner, repository, "commit", "-m", "test: sha256")
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatalf("pack SHA-256 repository: %v", err)
	}
	if err := verifyTestCapsule(t, capsule); err != nil {
		t.Fatalf("verify SHA-256 repository: %v", err)
	}
}

func TestRecoveryClosurePackRejectsHiddenIndexFlags(t *testing.T) {
	for _, flag := range []string{"--assume-unchanged", "--skip-worktree"} {
		t.Run(strings.TrimPrefix(flag, "--"), func(t *testing.T) {
			repository := createTestRepository(t, 2)
			runner := testGitRunner(t, repository)
			mustGit(t, runner, repository, "update-index", flag, "README.md")
			appendFile(t, filepath.Join(repository, "README.md"), "hidden\n")
			err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
			assertErrorContains(t, err, "hidden index flags")
		})
	}
}

func TestRecoveryClosurePackRejectsDetachedAndShallowRepositories(t *testing.T) {
	t.Run("detached", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		mustGit(t, runner, repository, "checkout", "--detach", "HEAD")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "HEAD must name a local branch")
	})
	t.Run("shallow", func(t *testing.T) {
		origin := createTestRepository(t, 3)
		shallow := filepath.Join(t.TempDir(), "shallow")
		runner := testGitRunner(t, origin)
		mustGit(t, runner, "", "clone", "--quiet", "--depth=1", "file://"+origin, shallow)
		err := packTestCapsule(t, shallow, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "shallow repository")
	})
}

func TestRecoveryClosurePackRejectsHistoryAndContentIndirection(t *testing.T) {
	t.Run("replace-ref", func(t *testing.T) {
		repository := createTestRepository(t, 3)
		runner := testGitRunner(t, repository)
		root := strings.TrimSpace(string(mustGit(t, runner, repository,
			"rev-list", "--max-parents=0", "HEAD")))
		mustGit(t, runner, repository, "replace", "HEAD", root)
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "replace refs")
	})
	t.Run("legacy-graft", func(t *testing.T) {
		repository := createTestRepository(t, 3)
		runner := testGitRunner(t, repository)
		root := strings.TrimSpace(string(mustGit(t, runner, repository,
			"rev-list", "--max-parents=0", "HEAD")))
		grafts := strings.TrimSpace(string(mustGit(t, runner, repository,
			"rev-parse", "--git-path", "info/grafts")))
		if !filepath.IsAbs(grafts) {
			grafts = filepath.Join(repository, grafts)
		}
		if err := os.MkdirAll(filepath.Dir(grafts), 0o700); err != nil {
			t.Fatal(err)
		}
		writeFile(t, grafts, root+"\n")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "grafts")
	})
	t.Run("submodule-gitlink", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		submodule := createTestRepository(t, 1)
		runner := testGitRunner(t, repository)
		mustGit(t, runner, repository, "-c", "protocol.file.allow=always",
			"submodule", "add", "--quiet", submodule, "vendor/submodule")
		mustGit(t, runner, repository, "commit", "-am", "test: add gitlink")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "submodule gitlinks")
	})
	t.Run("git-lfs", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		writeFile(t, filepath.Join(repository, ".gitattributes"), "*.bin filter=lfs diff=lfs -text\n")
		writeFile(t, filepath.Join(repository, "payload.bin"), "pointer placeholder\n")
		runner := testGitRunner(t, repository)
		mustGit(t, runner, repository, "add", ".gitattributes", "payload.bin")
		mustGit(t, runner, repository, "commit", "-m", "test: add lfs attributes")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "Git LFS")
	})
}

func TestRecoveryClosurePackRejectsHistoricalContentIndirection(t *testing.T) {
	t.Run("submodule-gitlink", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		submodule := createTestRepository(t, 1)
		runner := testGitRunner(t, repository)
		submoduleRunner := testGitRunner(t, submodule)
		commit := strings.TrimSpace(string(mustGit(t, submoduleRunner, submodule,
			"rev-parse", "--verify", "HEAD^{commit}")))
		mustGit(t, runner, repository, "update-index", "--add", "--cacheinfo",
			"160000,"+commit+",vendor/historical")
		mustGit(t, runner, repository, "commit", "-m", "test: add historical gitlink")
		mustGit(t, runner, repository, "rm", "--cached", "vendor/historical")
		mustGit(t, runner, repository, "commit", "-m", "test: remove historical gitlink")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "reachable recovery history")
	})
	t.Run("git-lfs-attributes", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		writeFile(t, filepath.Join(repository, ".gitattributes"), "*.bin filter=lfs diff=lfs -text\n")
		writeFile(t, filepath.Join(repository, "payload.bin"),
			"version https://git-lfs.github.com/spec/v1\n")
		mustGit(t, runner, repository, "add", ".gitattributes", "payload.bin")
		mustGit(t, runner, repository, "commit", "-m", "test: add historical LFS")
		mustGit(t, runner, repository, "rm", ".gitattributes", "payload.bin")
		mustGit(t, runner, repository, "commit", "-m", "test: remove historical LFS")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "reachable recovery history")
	})
	t.Run("git-lfs-pointer", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		pointer := "version https://git-lfs.github.com/spec/v1\n" +
			"oid sha256:" + strings.Repeat("0", 64) + "\n" +
			"size 123\n"
		writeFile(t, filepath.Join(repository, "historical-pointer.bin"), pointer)
		mustGit(t, runner, repository, "add", "historical-pointer.bin")
		mustGit(t, runner, repository, "commit", "-m", "test: add historical LFS pointer")
		mustGit(t, runner, repository, "rm", "historical-pointer.bin")
		mustGit(t, runner, repository, "commit", "-m", "test: remove historical LFS pointer")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "Git LFS pointer")
	})
}

func TestRecoveryClosurePackRejectsPartialCloneConfiguration(t *testing.T) {
	t.Run("configuration", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		mustGit(t, runner, repository, "config", "extensions.partialClone", "origin")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "partial or promisor clone")
	})
	t.Run("promisor-marker", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		runner := testGitRunner(t, repository)
		marker := strings.TrimSpace(string(mustGit(t, runner, repository,
			"rev-parse", "--git-path", "objects/pack/recovery-test.promisor")))
		if !filepath.IsAbs(marker) {
			marker = filepath.Join(repository, marker)
		}
		writeFile(t, marker, "")
		err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule"))
		assertErrorContains(t, err, "partial or promisor clone")
	})
}

func TestRecoveryClosurePackRejectsOutputInsideTrackedRepository(t *testing.T) {
	repository := createTestRepository(t, 2)
	err := packTestCapsule(t, repository, filepath.Join(repository, "recovery-capsule"))
	assertErrorContains(t, err, "output inside repository must be under .platform")
}

func TestRecoveryClosureProjectStateGitShadowIsNeverExecuted(t *testing.T) {
	repository := createTestRepository(t, 2)
	admittedGit := testGitExecutable(t)
	runner := testGitRunner(t, repository)
	exclude := strings.TrimSpace(string(mustGit(t, runner, repository,
		"rev-parse", "--git-path", "info/exclude")))
	if !filepath.IsAbs(exclude) {
		exclude = filepath.Join(repository, exclude)
	}
	if err := os.MkdirAll(filepath.Dir(exclude), 0o700); err != nil {
		t.Fatal(err)
	}
	appendFile(t, exclude, ".platform/\n")
	shadowDirectory := filepath.Join(repository, ".platform", "bootstrap")
	if err := os.MkdirAll(shadowDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(t.TempDir(), "fake-git-executed")
	fakeGit := filepath.Join(shadowDirectory, "git")
	writeFile(t, fakeGit, "#!/bin/sh\nprintf executed >'"+marker+"'\nexit 0\n")
	if err := os.Chmod(fakeGit, 0o700); err != nil {
		t.Fatal(err)
	}
	err := packCapsuleWithGit(repository, filepath.Join(t.TempDir(), "explicit"), fakeGit)
	assertErrorContains(t, err, "project-controlled state")
	originalPath := os.Getenv("PATH")
	t.Setenv("PATH", shadowDirectory+string(os.PathListSeparator)+originalPath)
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := packCapsuleWithGit(repository, capsule, admittedGit); err != nil {
		t.Fatalf("pack with shadowed Git: %v", err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("project-state Git shadow executed: %v", err)
	}
}

func TestRecoveryClosurePackRequiresExplicitAdmittedGit(t *testing.T) {
	repository := createTestRepository(t, 2)
	err := packCapsuleWithGit(repository, filepath.Join(t.TempDir(), "capsule"), "")
	assertErrorContains(t, err, "admitted absolute Git executable is required")
}

func TestRecoveryClosurePackRejectsRelativeGitExecutable(t *testing.T) {
	repository := createTestRepository(t, 2)
	err := packCapsuleWithGit(repository, filepath.Join(t.TempDir(), "capsule"), "git")
	assertErrorContains(t, err, "must be absolute")
}

func TestRecoveryClosureAmbientGitSelectorsNeverRedirectSource(t *testing.T) {
	repository := createTestRepository(t, 3)
	other := createTestRepository(t, 1)
	runner := testGitRunner(t, repository)
	expected := strings.TrimSpace(string(mustGit(t, runner, repository,
		"rev-parse", "--verify", "HEAD^{commit}")))
	t.Setenv("GIT_DIR", filepath.Join(other, ".git"))
	t.Setenv("GIT_WORK_TREE", other)
	t.Setenv("GIT_INDEX_FILE", filepath.Join(other, ".git", "index"))
	t.Setenv("GIT_OBJECT_DIRECTORY", filepath.Join(other, ".git", "objects"))
	t.Setenv("GIT_ALTERNATE_OBJECT_DIRECTORIES", filepath.Join(other, ".git", "objects"))
	t.Setenv("GIT_CONFIG_COUNT", "1")
	t.Setenv("GIT_CONFIG_KEY_0", "core.worktree")
	t.Setenv("GIT_CONFIG_VALUE_0", other)
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatalf("ambient Git selectors affected pack: %v", err)
	}
	identity, err := readRecoveryIdentity(filepath.Join(capsule, "RECOVERY.json"))
	if err != nil {
		t.Fatal(err)
	}
	if identity.Commit != expected {
		t.Fatalf("packed commit = %s, want source commit %s", identity.Commit, expected)
	}
}

func TestRecoveryClosureHostileTempEnvironmentNeverReceivesRecoveryState(t *testing.T) {
	repository := createTestRepository(t, 2)
	runner := testGitRunner(t, repository)
	exclude := strings.TrimSpace(string(mustGit(t, runner, repository,
		"rev-parse", "--git-path", "info/exclude")))
	if !filepath.IsAbs(exclude) {
		exclude = filepath.Join(repository, exclude)
	}
	if err := os.MkdirAll(filepath.Dir(exclude), 0o700); err != nil {
		t.Fatal(err)
	}
	appendFile(t, exclude, ".platform/\n")
	hostile := filepath.Join(repository, ".platform", "hostile-tmp")
	if err := os.Mkdir(filepath.Dir(hostile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(hostile, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(hostile, 0o700) })
	capsule := filepath.Join(t.TempDir(), "capsule")
	t.Setenv("TMPDIR", hostile)
	t.Setenv("TMP", hostile)
	t.Setenv("TEMP", hostile)
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatalf("pack with hostile temp environment: %v", err)
	}
	if err := verifyTestCapsule(t, capsule); err != nil {
		t.Fatalf("verify with hostile temp environment: %v", err)
	}
	entries, err := os.ReadDir(hostile)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("hostile temp directory received %d entries", len(entries))
	}
}

func TestRecoveryClosureGitRunnerRejectsAndReapsStubbornEarlyExitDescendant(t *testing.T) {
	proxy, pidPath := configureStubbornEarlyExitProxy(t)
	runner, cleanup, err := newGitRunner(t.TempDir(), proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := cleanup(); err != nil {
			t.Errorf("cleanup Git runner: %v", err)
		}
	}()
	runner.timeout = 2 * time.Second
	runner.termGrace = 50 * time.Millisecond
	runner.pollEvery = 5 * time.Millisecond
	runner.waitAfterKill = 2 * time.Second
	_, _, err = runner.runStatus("", nil, "version")
	assertErrorContains(t, err, "left a descendant process group")
	assertRecordedProcessAbsent(t, pidPath)
}

func TestRecoveryClosureFailureCleanupReapsStubbornEarlyExitGroup(t *testing.T) {
	proxy, pidPath := configureStubbornEarlyExitProxy(t)
	command := exec.Command(proxy)
	command.Env = os.Environ()
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	command.Stdout = writer
	command.Stderr = writer
	if err := command.Start(); err != nil {
		_ = reader.Close()
		_ = writer.Close()
		t.Fatal(err)
	}
	copied := make(chan error, 1)
	go func() {
		_, copyErr := io.Copy(io.Discard, reader)
		copied <- copyErr
	}()
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	group, err := captureOwnedProcessGroup(command.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	timedOut, err := waitForLeaderTerminal(group, 2*time.Second, 5*time.Millisecond)
	if err != nil || timedOut {
		t.Fatalf("proxy leader did not become terminal: timeout=%v err=%v", timedOut, err)
	}
	if err := abortStartedCommand(command, reader, copied, 2*time.Second); err != nil {
		t.Fatalf("failure cleanup: %v", err)
	}
	assertRecordedProcessAbsent(t, pidPath)
}

func TestRecoveryFastProcessStatESRCHIsTransientAbsence(t *testing.T) {
	err := &os.PathError{
		Op:   "read",
		Path: "/proc/4242/stat",
		Err:  syscall.ESRCH,
	}
	if !processStatEntryVanished(err) {
		t.Fatal("ESRCH process-stat race was not classified as absence")
	}
}

func TestRecoveryFastProcessStatAllowsUnrelatedNegativeNamespaceGroup(t *testing.T) {
	payload := []byte("4242 (nested process) R 1 -1" + strings.Repeat(" 0", 16) + " 100\n")
	snapshot, err := parseProcessSnapshot(4242, payload)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Group != -1 || snapshot.Starttime != 100 {
		t.Fatalf("parsed snapshot = %+v", snapshot)
	}
}

func TestRecoveryFastInitialProcessGroupCaptureRetriesTransientAbsence(t *testing.T) {
	calls := 0
	group, err := captureOwnedProcessGroupWithInspector(4242,
		func(pid int) (processSnapshot, bool, error) {
			calls++
			if calls == 1 {
				return processSnapshot{}, false, nil
			}
			return processSnapshot{
				PID: pid, Group: pid, Starttime: 100, State: 'R',
			}, true, nil
		})
	if err != nil {
		t.Fatal(err)
	}
	if calls != 2 || group.leader.PID != 4242 || group.leader.Starttime != 100 {
		t.Fatalf("capture calls=%d leader=%+v", calls, group.leader)
	}
}

func TestRecoveryFastLiveMemberScanKeepsAlreadyValidatedLeader(t *testing.T) {
	listedExcludedPID := 0
	group := ownedProcessGroup{
		leader: processIdentity{PID: 4242, Group: 4242, Starttime: 100},
		inspect: func(pid int) (processSnapshot, bool, error) {
			return processSnapshot{
				PID: pid, Group: 4242, Starttime: 100, State: 'R',
			}, true, nil
		},
		list: func(_ int, excludedPID int) ([]processSnapshot, error) {
			listedExcludedPID = excludedPID
			return nil, nil
		},
	}
	members, err := group.liveMembers(false)
	if err != nil {
		t.Fatal(err)
	}
	if listedExcludedPID != 4242 || len(members) != 1 || members[0].PID != 4242 {
		t.Fatalf("excluded PID=%d members=%+v", listedExcludedPID, members)
	}
}

func TestRecoveryFastTerminalLeaderRecoversFromTransientAbsence(t *testing.T) {
	calls := 0
	signals := 0
	same := processSnapshot{PID: 4242, Group: 4242, Starttime: 100, State: 'Z'}
	group := ownedProcessGroup{
		leader: processIdentity{PID: 4242, Group: 4242, Starttime: 100},
		inspect: func(int) (processSnapshot, bool, error) {
			calls++
			if calls == 2 {
				return processSnapshot{}, false, nil
			}
			return same, true, nil
		},
		signal: func(_ int, _ syscall.Signal) error {
			signals++
			return nil
		},
	}
	if _, err := group.leaderSnapshot(); err != nil {
		t.Fatal(err)
	}
	if err := group.signalIfOwned(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if calls != 3 || signals != 1 {
		t.Fatalf("leader reads=%d signals=%d, want reads=3 signals=1", calls, signals)
	}
}

func TestRecoveryFastAbsentLeaderIsNeverSignaled(t *testing.T) {
	signals := 0
	group := ownedProcessGroup{
		leader: processIdentity{PID: 4242, Group: 4242, Starttime: 100},
		inspect: func(int) (processSnapshot, bool, error) {
			return processSnapshot{}, false, nil
		},
		signal: func(_ int, _ syscall.Signal) error {
			signals++
			return nil
		},
	}
	err := group.signalIfOwned(syscall.SIGTERM)
	assertErrorContains(t, err, "remained absent")
	if signals != 0 {
		t.Fatalf("uncertain process group received %d signals", signals)
	}
}

func configureStubbornEarlyExitProxy(t *testing.T) (string, string) {
	t.Helper()
	proxy := filepath.Join(t.TempDir(), "git-proxy")
	ready := filepath.Join(t.TempDir(), "ready")
	pidPath := filepath.Join(t.TempDir(), "pid")
	helper, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nset -eu\n" +
		"\"$RECOVERY_HELPER_EXECUTABLE\" " +
		"-test.run='^TestRecoveryClosureStubbornProcessHelper$' " +
		"</dev/null >/dev/null 2>&1 &\n" +
		"child=$!\n" +
		"while [ ! -f \"$RECOVERY_HELPER_READY\" ]; do\n" +
		"  kill -0 \"$child\" 2>/dev/null || exit 81\n" +
		"done\n" +
		"exit 0\n"
	writeFile(t, proxy, script)
	if err := os.Chmod(proxy, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RECOVERY_PROCESS_HELPER", "stubborn")
	t.Setenv("RECOVERY_HELPER_EXECUTABLE", helper)
	t.Setenv("RECOVERY_HELPER_READY", ready)
	t.Setenv("RECOVERY_HELPER_PID", pidPath)
	return proxy, pidPath
}

func configureOversizedBundleProxy(t *testing.T) string {
	t.Helper()
	proxy := filepath.Join(t.TempDir(), "git-proxy")
	helper, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nset -eu\n" +
		"case \" $* \" in\n" +
		"  *' bundle create - '*)\n" +
		"    exec \"$RECOVERY_HELPER_EXECUTABLE\" " +
		"-test.run='^TestRecoveryClosureOversizedBundleHelper$'\n" +
		"    ;;\n" +
		"  *) exec \"$RECOVERY_REAL_GIT\" \"$@\" ;;\n" +
		"esac\n"
	writeFile(t, proxy, script)
	if err := os.Chmod(proxy, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RECOVERY_PROCESS_HELPER", "bundle-overflow")
	t.Setenv("RECOVERY_HELPER_EXECUTABLE", helper)
	t.Setenv("RECOVERY_REAL_GIT", testGitExecutable(t))
	return proxy
}

func assertRecordedProcessAbsent(t *testing.T, pidPath string) {
	t.Helper()
	payload, err := os.ReadFile(pidPath)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(payload)))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		err = syscall.Kill(pid, 0)
		if errors.Is(err, syscall.ESRCH) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stubborn descendant %d remained after runner cleanup: %v", pid, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestRecoveryFastReplacedProcessGroupIdentityIsNeverSignaled(t *testing.T) {
	signals := 0
	group := ownedProcessGroup{
		leader: processIdentity{PID: 4242, Group: 4242, Starttime: 100},
		inspect: func(pid int) (processSnapshot, bool, error) {
			return processSnapshot{
				PID:       pid,
				Group:     4242,
				Starttime: 101,
				State:     'S',
			}, true, nil
		},
		signal: func(_ int, _ syscall.Signal) error {
			signals++
			return nil
		},
	}
	err := group.signalIfOwned(syscall.SIGTERM)
	assertErrorContains(t, err, "leader identity changed")
	if signals != 0 {
		t.Fatalf("replacement process group received %d signals", signals)
	}
}

func TestRecoveryFastFinishIdentityReplacementUsesOnlyBoundedAbandonment(t *testing.T) {
	groupSignals := 0
	abandonments := 0
	runner := &gitRunner{
		timeout:       time.Second,
		pollEvery:     time.Millisecond,
		waitAfterKill: time.Second,
		monitorLeader: func(
			ownedProcessGroup,
			time.Duration,
			time.Duration,
		) (bool, error) {
			return false, errors.New("owned process-group leader identity changed")
		},
		abandon: func(*startedGitCommand, time.Duration) error {
			abandonments++
			return nil
		},
	}
	started := &startedGitCommand{
		group: ownedProcessGroup{
			signal: func(_ int, _ syscall.Signal) error {
				groupSignals++
				return nil
			},
		},
		output: &boundedBuffer{limit: 1024},
	}
	_, status, err := runner.finishGitCommand(started, 1024, "status")
	assertErrorContains(t, err, "leader identity changed")
	if status != 70 || abandonments != 1 || groupSignals != 0 {
		t.Fatalf("status=%d abandonments=%d group-signals=%d",
			status, abandonments, groupSignals)
	}
}

func TestRecoveryClosureStubbornProcessHelper(t *testing.T) {
	if os.Getenv("RECOVERY_PROCESS_HELPER") != "stubborn" {
		return
	}
	signal.Ignore(syscall.SIGTERM)
	pidPath := os.Getenv("RECOVERY_HELPER_PID")
	ready := os.Getenv("RECOVERY_HELPER_READY")
	if err := os.WriteFile(pidPath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		os.Exit(82)
	}
	if err := os.WriteFile(ready, []byte("ready\n"), 0o600); err != nil {
		os.Exit(83)
	}
	// Stay TERM-resistant long enough to require the KILL escalation while
	// guaranteeing self-cleanup if the outer test runner is interrupted.
	time.Sleep(5 * time.Second)
	os.Exit(84)
}

func TestRecoveryClosureOversizedBundleHelper(t *testing.T) {
	if os.Getenv("RECOVERY_PROCESS_HELPER") != "bundle-overflow" {
		return
	}
	chunk := make([]byte, 32<<10)
	remaining := int64(maxRecoveryBundleBytes) + 1
	for remaining > 0 {
		count := int64(len(chunk))
		if count > remaining {
			count = remaining
		}
		written, err := os.Stdout.Write(chunk[:int(count)])
		if err != nil || written != int(count) {
			os.Exit(85)
		}
		remaining -= count
	}
	os.Exit(0)
}

func TestRecoveryClosureRepositoryConfiguredFSMonitorIsNeverExecuted(t *testing.T) {
	repository := createTestRepository(t, 2)
	marker := filepath.Join(t.TempDir(), "fsmonitor-executed")
	hook := filepath.Join(t.TempDir(), "fsmonitor")
	writeFile(t, hook, "#!/bin/sh\nprintf executed >'"+marker+"'\nexit 0\n")
	if err := os.Chmod(hook, 0o700); err != nil {
		t.Fatal(err)
	}
	runner := testGitRunner(t, repository)
	mustGit(t, runner, repository, "config", "core.fsmonitor", hook)
	if err := packTestCapsule(t, repository, filepath.Join(t.TempDir(), "capsule")); err != nil {
		t.Fatalf("pack repository with inert fsmonitor config: %v", err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("repository-configured fsmonitor executed: %v", err)
	}
}

func TestRecoveryClosurePackRejectsSourceChangeDuringCapture(t *testing.T) {
	repository := createTestRepository(t, 3)
	marker := filepath.Join(t.TempDir(), "source-mutated")
	proxy := filepath.Join(t.TempDir(), "git")
	realGit := testGitExecutable(t)
	script := "#!/bin/sh\nset -eu\n" +
		"real_git='" + realGit + "'\n" +
		"marker='" + marker + "'\n" +
		"repository='" + repository + "'\n" +
		"\"$real_git\" \"$@\"\nstatus=$?\n" +
		"case \" $* \" in\n" +
		"  *' bundle create '*)\n" +
		"    if [ ! -e \"$marker\" ]; then\n" +
		"      : >\"$marker\"\n" +
		"      printf 'changed during capture\\n' >>\"$repository/README.md\"\n" +
		"    fi\n" +
		"    ;;\n" +
		"esac\nexit \"$status\"\n"
	writeFile(t, proxy, script)
	if err := os.Chmod(proxy, 0o700); err != nil {
		t.Fatal(err)
	}
	err := packCapsuleWithGit(repository, filepath.Join(t.TempDir(), "capsule"), proxy)
	assertErrorContains(t, err, "source repository changed during capture")
}

func TestRecoveryClosurePackRefusesExistingOutput(t *testing.T) {
	repository := createTestRepository(t, 2)
	capsule := filepath.Join(t.TempDir(), "capsule")
	if err := os.Mkdir(capsule, 0o700); err != nil {
		t.Fatal(err)
	}
	err := packTestCapsule(t, repository, capsule)
	assertErrorContains(t, err, "output path already exists")
}

func TestRecoveryClosurePackNeverReplacesDestinationCreatedAtPublish(t *testing.T) {
	repository := createTestRepository(t, 2)
	for _, scenario := range []struct {
		name   string
		create func(*testing.T, string)
	}{
		{
			name: "empty-directory",
			create: func(t *testing.T, path string) {
				t.Helper()
				if err := os.Mkdir(path, 0o700); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "symlink",
			create: func(t *testing.T, path string) {
				t.Helper()
				target := filepath.Join(filepath.Dir(path), "attacker-target")
				if err := os.Mkdir(target, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, path); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			parent := t.TempDir()
			capsule := filepath.Join(parent, "capsule")
			originalBarrier := recoveryFilesystemBarrier
			defer func() { recoveryFilesystemBarrier = originalBarrier }()
			var created os.FileInfo
			recoveryFilesystemBarrier = func(point string) {
				if point != recoveryBarrierBeforePublish || created != nil {
					return
				}
				scenario.create(t, capsule)
				var err error
				created, err = os.Lstat(capsule)
				if err != nil {
					t.Fatal(err)
				}
			}
			err := packTestCapsule(t, repository, capsule)
			assertErrorContains(t, err, "output path already exists")
			observed, statErr := os.Lstat(capsule)
			if statErr != nil {
				t.Fatal(statErr)
			}
			if created == nil || !os.SameFile(created, observed) || created.Mode() != observed.Mode() {
				t.Fatal("concurrently created destination was replaced")
			}
			entries, readErr := os.ReadDir(parent)
			if readErr != nil {
				t.Fatal(readErr)
			}
			expectedEntries := 1
			if scenario.name == "symlink" {
				expectedEntries = 2
			}
			if len(entries) != expectedEntries {
				t.Fatalf("staging residue count = %d", len(entries)-expectedEntries)
			}
		})
	}
}

func TestRecoveryClosurePackRevalidatesSourceAndStageAfterPublishBarrier(t *testing.T) {
	t.Run("source", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		parent := t.TempDir()
		output := filepath.Join(parent, "capsule")
		original := recoveryFilesystemBarrier
		defer func() { recoveryFilesystemBarrier = original }()
		triggered := false
		recoveryFilesystemBarrier = func(point string) {
			if point == recoveryBarrierBeforePublish && !triggered {
				triggered = true
				appendFile(t, filepath.Join(repository, "README.md"), "late mutation\n")
			}
		}
		err := packTestCapsule(t, repository, output)
		assertErrorContains(t, err, "source repository changed during capture")
		assertDestinationParentEmpty(t, parent, output)
	})
	t.Run("capsule-member", func(t *testing.T) {
		repository := createTestRepository(t, 2)
		parent := t.TempDir()
		output := filepath.Join(parent, "capsule")
		original := recoveryFilesystemBarrier
		defer func() { recoveryFilesystemBarrier = original }()
		triggered := false
		recoveryFilesystemBarrier = func(point string) {
			if point != recoveryBarrierBeforePublish || triggered {
				return
			}
			triggered = true
			stage := recoveryStagePath(t, parent)
			appendFile(t, filepath.Join(stage, "repository.bundle"), "late tamper\n")
		}
		err := packTestCapsule(t, repository, output)
		assertErrorContains(t, err, "staged recovery capsule failed final verification")
		assertDestinationParentEmpty(t, parent, output)
	})
}

func TestRecoveryClosurePackNeverPublishesStageNameReplacement(t *testing.T) {
	repository := createTestRepository(t, 2)
	parent := t.TempDir()
	output := filepath.Join(parent, "capsule")
	parked := filepath.Join(parent, "parked-stage")
	var replacement string
	original := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = original }()
	triggered := false
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierBeforePublish || triggered {
			return
		}
		triggered = true
		replacement = recoveryStagePath(t, parent)
		if err := os.Rename(replacement, parked); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(replacement, 0o700); err != nil {
			t.Fatal(err)
		}
		writeFile(t, filepath.Join(replacement, "victim"), "foreign\n")
	}
	err := packTestCapsule(t, repository, output)
	assertErrorContains(t, err, "staging directory identity changed")
	payload, readErr := os.ReadFile(filepath.Join(replacement, "victim"))
	if readErr != nil || string(payload) != "foreign\n" {
		t.Fatalf("replacement stage changed: %q, %v", payload, readErr)
	}
	entries, readErr := os.ReadDir(parked)
	if readErr != nil || len(entries) != 0 {
		t.Fatalf("parked stage retained capsule bytes: %+v, %v", entries, readErr)
	}
	if _, statErr := os.Lstat(output); !os.IsNotExist(statErr) {
		t.Fatalf("replacement stage published: %v", statErr)
	}
}

func TestRecoveryClosurePackRejectsOutputParentPathSwap(t *testing.T) {
	repository := createTestRepository(t, 2)
	root := t.TempDir()
	parent := filepath.Join(root, "output-parent")
	parked := filepath.Join(root, "parked-parent")
	if err := os.Mkdir(parent, 0o700); err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(parent, "capsule")
	original := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = original }()
	triggered := false
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierBeforePublish || triggered {
			return
		}
		triggered = true
		if err := os.Rename(parent, parked); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(parent, 0o700); err != nil {
			t.Fatal(err)
		}
		writeFile(t, filepath.Join(parent, "victim"), "foreign\n")
	}
	err := packTestCapsule(t, repository, output)
	assertErrorContains(t, err, "output parent path changed")
	payload, readErr := os.ReadFile(filepath.Join(parent, "victim"))
	if readErr != nil || string(payload) != "foreign\n" {
		t.Fatalf("replacement parent changed: %q, %v", payload, readErr)
	}
	entries, readErr := os.ReadDir(parked)
	if readErr != nil || len(entries) != 0 {
		t.Fatalf("parked parent retained capsule state: %+v, %v", entries, readErr)
	}
	if _, statErr := os.Lstat(output); !os.IsNotExist(statErr) {
		t.Fatalf("parent swap published output: %v", statErr)
	}
}

func recoveryStagePath(t *testing.T, parent string) string {
	t.Helper()
	entries, err := os.ReadDir(parent)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".flare-recovery-stage-") {
			return filepath.Join(parent, entry.Name())
		}
	}
	t.Fatal("recovery stage was absent at barrier")
	return ""
}

func assertDestinationParentEmpty(t *testing.T, parent, output string) {
	t.Helper()
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		t.Fatalf("failed capture published output: %v", err)
	}
	entries, err := os.ReadDir(parent)
	if err != nil || len(entries) != 0 {
		t.Fatalf("failed capture left destination state: %+v, %v", entries, err)
	}
}

func TestRecoveryClosurePackStageNameSwapNeverWritesReplacementDirectory(t *testing.T) {
	repository := createTestRepository(t, 2)
	parent := t.TempDir()
	capsule := filepath.Join(parent, "capsule")
	parked := filepath.Join(parent, "parked-stage")
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	var replacement string
	var hookErr error
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierBeforePopulate || replacement != "" || hookErr != nil {
			return
		}
		entries, err := os.ReadDir(parent)
		if err != nil {
			hookErr = err
			return
		}
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), ".flare-recovery-stage-") {
				replacement = filepath.Join(parent, entry.Name())
				break
			}
		}
		if replacement == "" {
			hookErr = errors.New("recovery stage was not found at barrier")
			return
		}
		if err := os.Rename(replacement, parked); err != nil {
			hookErr = err
			return
		}
		if err := os.Mkdir(replacement, 0o700); err != nil {
			hookErr = err
			return
		}
		hookErr = os.WriteFile(filepath.Join(replacement, "victim-marker"), []byte("owned\n"), 0o600)
	}
	err := packTestCapsule(t, repository, capsule)
	if hookErr != nil {
		t.Fatalf("stage swap barrier: %v", hookErr)
	}
	assertErrorContains(t, err, "staging directory identity changed")
	entries, err := os.ReadDir(replacement)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "victim-marker" {
		t.Fatalf("replacement directory received recovery state: %+v", entries)
	}
	parkedEntries, err := os.ReadDir(parked)
	if err != nil {
		t.Fatal(err)
	}
	if len(parkedEntries) != 0 {
		t.Fatalf("moved pinned stage retained recovery state: %+v", parkedEntries)
	}
	if _, err := os.Lstat(capsule); !os.IsNotExist(err) {
		t.Fatalf("failed capture published output: %v", err)
	}
}

func TestRecoveryClosurePackWorksWithDestinationSiblingOfRepository(t *testing.T) {
	original := createTestRepository(t, 2)
	parent := t.TempDir()
	repository := filepath.Join(parent, "repository")
	if err := os.Rename(original, repository); err != nil {
		t.Fatal(err)
	}
	capsule := filepath.Join(parent, "capsule")
	if err := packTestCapsule(t, repository, capsule); err != nil {
		t.Fatalf("pack sibling destination: %v", err)
	}
	if err := verifyTestCapsule(t, capsule); err != nil {
		t.Fatalf("verify sibling destination: %v", err)
	}
}

func TestRecoveryClosurePackRejectsWholeRepositoryPathSwap(t *testing.T) {
	repository := createTestRepository(t, 2)
	parked := repository + "-parked"
	marker := filepath.Join(repository, "victim-marker")
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	triggered := false
	var hookErr error
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierRepositoryPath || triggered {
			return
		}
		triggered = true
		if err := os.Rename(repository, parked); err != nil {
			hookErr = err
			return
		}
		if err := os.Mkdir(repository, 0o700); err != nil {
			hookErr = err
			return
		}
		hookErr = os.WriteFile(marker, []byte("owned\n"), 0o600)
	}
	output := filepath.Join(t.TempDir(), "capsule")
	err := packTestCapsule(t, repository, output)
	if hookErr != nil {
		t.Fatalf("repository swap barrier: %v", hookErr)
	}
	assertErrorContains(t, err, "repository")
	entries, err := os.ReadDir(repository)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "victim-marker" {
		t.Fatalf("replacement repository was touched: %+v", entries)
	}
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		t.Fatalf("repository path swap published output: %v", err)
	}
}

func TestRecoveryClosurePackCapsBundleStreamBeforeWritingPastLimit(t *testing.T) {
	repository := createTestRepository(t, 2)
	proxy := configureOversizedBundleProxy(t)
	parent := t.TempDir()
	output := filepath.Join(parent, "capsule")
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	observedSize := int64(-1)
	var hookErr error
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierBundleOverflow || observedSize >= 0 || hookErr != nil {
			return
		}
		entries, err := os.ReadDir(parent)
		if err != nil {
			hookErr = err
			return
		}
		for _, entry := range entries {
			if !strings.HasPrefix(entry.Name(), ".flare-recovery-stage-") {
				continue
			}
			info, err := os.Stat(filepath.Join(parent, entry.Name(), "repository.bundle"))
			if err != nil {
				hookErr = err
				return
			}
			observedSize = info.Size()
			return
		}
		hookErr = errors.New("recovery stage was absent at bundle overflow barrier")
	}
	err := packCapsuleWithGit(repository, output, proxy)
	if hookErr != nil {
		t.Fatal(hookErr)
	}
	assertErrorContains(t, err, "recovery bundle exceeds 64 MiB")
	if observedSize != maxRecoveryBundleBytes {
		t.Fatalf("capped bundle size = %d, want %d", observedSize, maxRecoveryBundleBytes)
	}
	entries, err := os.ReadDir(parent)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("oversized bundle left destination or stage: %+v", entries)
	}
}

func TestRecoveryFastDrainingCappedWriterReportsAndDiscardsOverflow(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bundle")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	writer := newDrainingCappedWriter(file, 8)
	for _, payload := range [][]byte{[]byte("12345"), []byte("67890")} {
		written, err := writer.Write(payload)
		if err != nil || written != len(payload) {
			t.Fatalf("capped write = %d, %v", written, err)
		}
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !writer.overflowedLimit() || writer.bytesWritten() != 8 || info.Size() != 8 {
		t.Fatalf("overflow=%v writer=%d file=%d",
			writer.overflowedLimit(), writer.bytesWritten(), info.Size())
	}
}

func TestRecoveryClosurePinnedTempCleanupNeverDeletesReplacementPath(t *testing.T) {
	temporary, err := newPinnedTempDirectory("flare-recovery-cleanup-test-")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(temporary.pinnedPath, "nested"), 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(temporary.pinnedPath, "nested", "owned"), "recovery\n")
	parked := temporary.path + "-parked"
	victim := filepath.Join(temporary.path, "victim")
	t.Cleanup(func() {
		_ = os.Remove(victim)
		_ = os.Remove(temporary.path)
		_ = os.Remove(parked)
	})
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	triggered := false
	var hookErr error
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierTempCleanup || triggered {
			return
		}
		triggered = true
		if err := os.Rename(temporary.path, parked); err != nil {
			hookErr = err
			return
		}
		if err := os.Mkdir(temporary.path, 0o700); err != nil {
			hookErr = err
			return
		}
		hookErr = os.WriteFile(victim, []byte("foreign\n"), 0o600)
	}
	err = temporary.cleanup()
	if hookErr != nil {
		t.Fatal(hookErr)
	}
	assertErrorContains(t, err, "temp directory identity changed")
	payload, err := os.ReadFile(victim)
	if err != nil || string(payload) != "foreign\n" {
		t.Fatalf("replacement temp path was touched: %q, %v", payload, err)
	}
	entries, err := os.ReadDir(parked)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("moved pinned temp retained recovery state: %+v", entries)
	}
}

type pinnedTempEntrySwapScenario struct {
	name    string
	barrier string
	create  func(*testing.T, string)
	swap    func(*testing.T, string, string)
	assert  func(*testing.T, string, string)
	clean   func(string, string)
}

func pinnedTempEntrySwapScenarios() []pinnedTempEntrySwapScenario {
	return []pinnedTempEntrySwapScenario{
		pinnedTempRegularSwapScenario(),
		{
			name: "directory", barrier: recoveryBarrierTempUnlinkDir,
			create: func(t *testing.T, path string) {
				if err := os.Mkdir(path, 0o700); err != nil {
					t.Fatal(err)
				}
				writeFile(t, filepath.Join(path, "secret"), "secret\n")
			},
			swap: func(t *testing.T, path, parked string) {
				if err := os.Rename(path, parked); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(path, 0o700); err != nil {
					t.Fatal(err)
				}
				writeFile(t, filepath.Join(path, "victim"), "foreign\n")
			},
			assert: func(t *testing.T, path, parked string) {
				payload, err := os.ReadFile(filepath.Join(path, "victim"))
				if err != nil || string(payload) != "foreign\n" {
					t.Fatalf("replacement directory changed: %q, %v", payload, err)
				}
				entries, err := os.ReadDir(parked)
				if err != nil || len(entries) != 0 {
					t.Fatalf("parked owned directory retained entries: %+v, %v", entries, err)
				}
			},
			clean: func(path, parked string) {
				_ = os.Remove(filepath.Join(path, "victim"))
				_ = os.Remove(path)
				_ = os.Remove(parked)
			},
		},
		{
			name: "symlink", barrier: recoveryBarrierTempUnlinkLink,
			create: func(t *testing.T, path string) {
				if err := os.Symlink("owned-target", path); err != nil {
					t.Fatal(err)
				}
			},
			swap: func(t *testing.T, path, parked string) {
				if err := os.Rename(path, parked); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("foreign-target", path); err != nil {
					t.Fatal(err)
				}
			},
			assert: func(t *testing.T, path, parked string) {
				target, err := os.Readlink(path)
				if err != nil || target != "foreign-target" {
					t.Fatalf("replacement symlink changed: %q, %v", target, err)
				}
				owned, err := os.Readlink(parked)
				if err != nil || owned != "owned-target" {
					t.Fatalf("parked symlink changed: %q, %v", owned, err)
				}
			},
			clean: func(path, parked string) { _ = os.Remove(path); _ = os.Remove(parked) },
		},
	}
}

func pinnedTempRegularSwapScenario() pinnedTempEntrySwapScenario {
	return pinnedTempEntrySwapScenario{
		name: "regular-file", barrier: recoveryBarrierTempUnlinkFile,
		create: func(t *testing.T, path string) { writeFile(t, path, "secret\n") },
		swap: func(t *testing.T, path, parked string) {
			if err := os.Rename(path, parked); err != nil {
				t.Fatal(err)
			}
			writeFile(t, path, "foreign\n")
		},
		assert: func(t *testing.T, path, parked string) {
			payload, err := os.ReadFile(path)
			if err != nil || string(payload) != "foreign\n" {
				t.Fatalf("replacement file changed: %q, %v", payload, err)
			}
			info, err := os.Stat(parked)
			if err != nil || info.Size() != 0 {
				t.Fatalf("parked owned file retained bytes: %+v, %v", info, err)
			}
		},
		clean: func(path, parked string) { _ = os.Remove(path); _ = os.Remove(parked) },
	}
}

func TestRecoveryClosurePinnedTempCleanupNeverDeletesReplacementEntries(t *testing.T) {
	for _, scenario := range pinnedTempEntrySwapScenarios() {
		t.Run(scenario.name, func(t *testing.T) {
			runPinnedTempEntrySwapScenario(t, scenario)
		})
	}
}

func runPinnedTempEntrySwapScenario(t *testing.T, scenario pinnedTempEntrySwapScenario) {
	t.Helper()
	temporary, err := newPinnedTempDirectory("flare-recovery-cleanup-entry-test-")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(temporary.path, "entry")
	parked := filepath.Join(temporary.path, "parked-entry")
	scenario.create(t, filepath.Join(temporary.pinnedPath, "entry"))
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	triggered := false
	recoveryFilesystemBarrier = func(point string) {
		if point == scenario.barrier && !triggered {
			triggered = true
			scenario.swap(t, path, parked)
		}
	}
	err = temporary.cleanup()
	assertErrorContains(t, err, "temp entry identity changed")
	scenario.assert(t, path, parked)
	scenario.clean(path, parked)
	if err := os.Remove(temporary.path); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryClosurePinnedTempRegisteredNamePreservesReplacementAndScrubsMovedOriginal(t *testing.T) {
	temporary, err := newPinnedTempDirectory("flare-recovery-registered-name-test-")
	if err != nil {
		t.Fatal(err)
	}
	owned := filepath.Join(temporary.pinnedPath, "owned")
	if err := os.Mkdir(owned, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(owned, "secret"), "secret\n")
	if err := temporary.registerCurrentOwnedName("owned"); err != nil {
		t.Fatal(err)
	}
	parked := filepath.Join(temporary.path, "parked")
	if err := os.Rename(filepath.Join(temporary.path, "owned"), parked); err != nil {
		t.Fatal(err)
	}
	replacement := filepath.Join(temporary.path, "owned")
	if err := os.Mkdir(replacement, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(replacement, "victim"), "foreign\n")
	err = temporary.cleanup()
	assertErrorContains(t, err, "temp entry identity changed")
	payload, err := os.ReadFile(filepath.Join(replacement, "victim"))
	if err != nil || string(payload) != "foreign\n" {
		t.Fatalf("replacement changed: %q, %v", payload, err)
	}
	entries, err := os.ReadDir(parked)
	if err != nil && !os.IsNotExist(err) {
		t.Fatalf("inspect moved original: %v", err)
	}
	if err == nil && len(entries) != 0 {
		t.Fatalf("moved original retained state: %+v, %v", entries, err)
	}
	_ = os.Remove(filepath.Join(replacement, "victim"))
	_ = os.Remove(replacement)
	_ = os.Remove(parked)
	if err := os.Remove(temporary.path); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryClosurePackFailsWhenGitHomeCleanupNameIsReplaced(t *testing.T) {
	repository := createTestRepository(t, 2)
	parent := t.TempDir()
	output := filepath.Join(parent, "capsule")
	originalBarrier := recoveryFilesystemBarrier
	defer func() { recoveryFilesystemBarrier = originalBarrier }()
	originalCreated := recoveryPinnedTempCreated
	defer func() { recoveryPinnedTempCreated = originalCreated }()
	triggered := false
	var temporary string
	var victim string
	var parked string
	var hookErr error
	recoveryPinnedTempCreated = func(created *pinnedTempDirectory) {
		if strings.HasPrefix(created.name, "flare-recovery-git-home-") {
			temporary = created.path
		}
	}
	recoveryFilesystemBarrier = func(point string) {
		if point != recoveryBarrierTempCleanup || triggered {
			return
		}
		triggered = true
		if temporary == "" {
			hookErr = errors.New("current recovery Git HOME was not captured")
			return
		}
		parked = temporary + "-parked"
		if err := os.Rename(temporary, parked); err != nil {
			hookErr = err
			return
		}
		if err := os.Mkdir(temporary, 0o700); err != nil {
			hookErr = err
			return
		}
		victim = filepath.Join(temporary, "victim")
		hookErr = os.WriteFile(victim, []byte("foreign\n"), 0o600)
	}
	t.Cleanup(func() {
		_ = os.Remove(victim)
		_ = os.Remove(temporary)
		_ = os.Remove(parked)
	})
	err := packTestCapsule(t, repository, output)
	if hookErr != nil {
		t.Fatal(hookErr)
	}
	assertErrorContains(t, err, "temp directory identity changed")
	payload, err := os.ReadFile(victim)
	if err != nil || string(payload) != "foreign\n" {
		t.Fatalf("replacement Git HOME was touched: %q, %v", payload, err)
	}
	entries, err := os.ReadDir(parked)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("moved Git HOME retained recovery state: %+v", entries)
	}
}

func createTestRepository(t *testing.T, commitCount int) string {
	t.Helper()
	repository := filepath.Join(t.TempDir(), "repository")
	if err := os.Mkdir(repository, 0o700); err != nil {
		t.Fatal(err)
	}
	runner := testGitRunner(t, repository)
	mustGit(t, runner, "", "init", "--quiet", "-b", "main", repository)
	mustGit(t, runner, repository, "config", "user.name", "Flare Recovery Test")
	mustGit(t, runner, repository, "config", "user.email", "recovery@example.invalid")
	for index := 1; index <= commitCount; index++ {
		writeFile(t, filepath.Join(repository, "README.md"), strings.Repeat("state\n", index))
		mustGit(t, runner, repository, "add", "README.md")
		mustGit(t, runner, repository, "commit", "-m", "test: state")
	}
	return repository
}

func testGitRunner(t *testing.T, repository string) *gitRunner {
	t.Helper()
	runner, cleanup, err := newGitRunner(repository, testGitExecutable(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := cleanup(); err != nil {
			t.Errorf("cleanup Git runner: %v", err)
		}
	})
	return runner
}

func packTestCapsule(t *testing.T, repository, destination string) error {
	t.Helper()
	return packCapsuleWithGit(repository, destination, testGitExecutable(t))
}

func verifyTestCapsule(t *testing.T, capsule string) error {
	t.Helper()
	return verifyCapsuleWithGit(capsule, testGitExecutable(t))
}

func testGitExecutable(t *testing.T) string {
	t.Helper()
	path := os.Getenv("RECOVERY_TEST_GIT")
	if path == "" {
		t.Fatal("RECOVERY_TEST_GIT must name the admitted absolute Git executable")
	}
	if !filepath.IsAbs(path) {
		t.Fatal("RECOVERY_TEST_GIT must be absolute")
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}

func mustGit(t *testing.T, runner *gitRunner, directory string, arguments ...string) []byte {
	t.Helper()
	output, err := runner.run(directory, nil, arguments...)
	if err != nil {
		t.Fatalf("git %s: %v", arguments[0], err)
	}
	return output
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func appendFile(t *testing.T, path, content string) {
	t.Helper()
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(content); err != nil {
		t.Fatal(err)
	}
}

func assertErrorContains(t *testing.T, err error, marker string) {
	t.Helper()
	if err == nil || !strings.Contains(err.Error(), marker) {
		t.Fatalf("expected error containing %q, got %v", marker, err)
	}
}

func assertUnsealedStatusClean(t *testing.T, repository string) {
	t.Helper()
	executable := testGitExecutable(t)
	home := t.TempDir()
	command := exec.Command(executable,
		"--no-pager", "--no-optional-locks",
		"-c", "core.hooksPath=/dev/null",
		"-c", "core.fsmonitor=false",
		"-c", "core.attributesFile=/dev/null",
		"-c", "core.excludesFile=/dev/null",
		"status", "--porcelain=v1", "-z", "--untracked-files=all")
	command.Dir = repository
	command.Env = []string{
		"HOME=" + home,
		"XDG_CONFIG_HOME=" + filepath.Join(home, "xdg"),
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_TERMINAL_PROMPT=0",
		"LC_ALL=C",
		"PATH=" + filepath.Dir(executable),
		"TMPDIR=" + recoveryHostTempRoot,
	}
	output, err := command.Output()
	if err != nil {
		t.Fatalf("unsealed git status: %v", err)
	}
	if len(output) != 0 {
		t.Fatalf("false-clean setup is visible to unsealed Git: %q", output)
	}
}

func assertPackRejectsWithoutOutput(t *testing.T, repository, marker string) {
	t.Helper()
	parent := t.TempDir()
	output := filepath.Join(parent, "capsule")
	err := packTestCapsule(t, repository, output)
	assertErrorContains(t, err, marker)
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		t.Fatalf("failed capture published output: %v", err)
	}
	entries, err := os.ReadDir(parent)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("failed capture left destination state: %+v", entries)
	}
}
