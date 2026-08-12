package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
)

const (
	recoveryFastTestPrefix    = "TestRecoveryFast"
	recoveryClosureTestPrefix = "TestRecoveryClosure"
	recoveryFastTestPattern   = "^TestRecoveryFast"
)

var recoveryFastTestAllowlist = map[string]struct{}{
	"TestRecoveryFastAbsentLeaderIsNeverSignaled":                         {},
	"TestRecoveryFastClassContract":                                       {},
	"TestRecoveryFastDrainingCappedWriterReportsAndDiscardsOverflow":      {},
	"TestRecoveryFastFinishIdentityReplacementUsesOnlyBoundedAbandonment": {},
	"TestRecoveryFastInitialProcessGroupCaptureRetriesTransientAbsence":   {},
	"TestRecoveryFastLiveMemberScanKeepsAlreadyValidatedLeader":           {},
	"TestRecoveryFastProcessStatAllowsUnrelatedNegativeNamespaceGroup":    {},
	"TestRecoveryFastProcessStatESRCHIsTransientAbsence":                  {},
	"TestRecoveryFastReplacedProcessGroupIdentityIsNeverSignaled":         {},
	"TestRecoveryFastTerminalLeaderRecoversFromTransientAbsence":          {},
}

var recoveryClosureTestAllowlist = map[string]struct{}{
	"TestRecoveryClosureAmbientGitSelectorsNeverRedirectSource":                             {},
	"TestRecoveryClosureClassSentinel":                                                      {},
	"TestRecoveryClosureFailureCleanupReapsStubbornEarlyExitGroup":                          {},
	"TestRecoveryClosureGitRunnerRejectsAndReapsStubbornEarlyExitDescendant":                {},
	"TestRecoveryClosureHostileTempEnvironmentNeverReceivesRecoveryState":                   {},
	"TestRecoveryClosureOversizedBundleHelper":                                              {},
	"TestRecoveryClosurePackAndVerifyRecoveryCapsule":                                       {},
	"TestRecoveryClosurePackAndVerifySHA256Repository":                                      {},
	"TestRecoveryClosurePackCannotMaskDirtyTrackedSymlinkWithNameSwap":                      {},
	"TestRecoveryClosurePackCapsBundleStreamBeforeWritingPastLimit":                         {},
	"TestRecoveryClosurePackContainsFullHeadHistory":                                        {},
	"TestRecoveryClosurePackFailsWhenGitHomeCleanupNameIsReplaced":                          {},
	"TestRecoveryClosurePackNeverPublishesStageNameReplacement":                             {},
	"TestRecoveryClosurePackNeverReplacesDestinationCreatedAtPublish":                       {},
	"TestRecoveryClosurePackRefusesExistingOutput":                                          {},
	"TestRecoveryClosurePackRejectsConfiguredFilterWithoutExecutingIt":                      {},
	"TestRecoveryClosurePackRejectsDangerousRepositoryMetadataAndConfiguration":             {},
	"TestRecoveryClosurePackRejectsDetachedAndShallowRepositories":                          {},
	"TestRecoveryClosurePackRejectsDirtyTrackedAndUntrackedState":                           {},
	"TestRecoveryClosurePackRejectsHiddenIndexFlags":                                        {},
	"TestRecoveryClosurePackRejectsHistoricalContentIndirection":                            {},
	"TestRecoveryClosurePackRejectsHistoryAndContentIndirection":                            {},
	"TestRecoveryClosurePackRejectsInfoExcludeHiddenUntrackedFile":                          {},
	"TestRecoveryClosurePackRejectsMalformedRepositoryConfigWithoutPanic":                   {},
	"TestRecoveryClosurePackRejectsOutputInsideTrackedRepository":                           {},
	"TestRecoveryClosurePackRejectsOutputParentPathSwap":                                    {},
	"TestRecoveryClosurePackRejectsPartialCloneConfiguration":                               {},
	"TestRecoveryClosurePackRejectsPlatformSymlinkWithoutTouchingTarget":                    {},
	"TestRecoveryClosurePackRejectsRelativeGitExecutable":                                   {},
	"TestRecoveryClosurePackRejectsRepositoryConfigIncludesWithoutExecutingFilter":          {},
	"TestRecoveryClosurePackRejectsRepositoryConfiguredFalseCleanState":                     {},
	"TestRecoveryClosurePackRejectsSourceChangeDuringCapture":                               {},
	"TestRecoveryClosurePackRejectsStagedOnlyIndexChange":                                   {},
	"TestRecoveryClosurePackRejectsTrackedHardlinkAliasInPlatformState":                     {},
	"TestRecoveryClosurePackRejectsWholeRepositoryPathSwap":                                 {},
	"TestRecoveryClosurePackRequiresExplicitAdmittedGit":                                    {},
	"TestRecoveryClosurePackRevalidatesSourceAndStageAfterPublishBarrier":                   {},
	"TestRecoveryClosurePackStageNameSwapNeverWritesReplacementDirectory":                   {},
	"TestRecoveryClosurePackWorksWithDestinationSiblingOfRepository":                        {},
	"TestRecoveryClosurePinnedTempCleanupNeverDeletesReplacementEntries":                    {},
	"TestRecoveryClosurePinnedTempCleanupNeverDeletesReplacementPath":                       {},
	"TestRecoveryClosurePinnedTempRegisteredNamePreservesReplacementAndScrubsMovedOriginal": {},
	"TestRecoveryClosureProjectStateGitShadowIsNeverExecuted":                               {},
	"TestRecoveryClosureRepeatedPackIsByteStable":                                           {},
	"TestRecoveryClosureRepositoryConfiguredFSMonitorIsNeverExecuted":                       {},
	"TestRecoveryClosureRepositoryConfigSnapshotDetectsSameInodeRestore":                    {},
	"TestRecoveryClosureStubbornProcessHelper":                                              {},
	"TestRecoveryClosureVerifyCloneNameSwapNeverTouchesReplacement":                         {},
	"TestRecoveryClosureVerifyRejectsBundleWithoutExplicitHEAD":                             {},
	"TestRecoveryClosureVerifyRejectsCapsuleRootSymlink":                                    {},
	"TestRecoveryClosureVerifyRejectsIdentityMismatch":                                      {},
	"TestRecoveryClosureVerifyRejectsInvalidRecordedBranch":                                 {},
	"TestRecoveryClosureVerifyRejectsMemberNameSwapDuringSnapshot":                          {},
	"TestRecoveryClosureVerifyRejectsOversizedRecoveredFileBeforeCheckout":                  {},
	"TestRecoveryClosureVerifyRejectsShallowBundleThatGitBundleVerifyAccepts":               {},
	"TestRecoveryClosureVerifyRejectsTamperAndUnexpectedFiles":                              {},
	"TestRecoveryClosureVerifyWorksFromSpecialCharacterPath":                                {},
}

func TestRecoveryFastClassContract(t *testing.T) {
	assertRecoveryTestClassification(t)
	t.Run("literal glob characters in source path", func(t *testing.T) {
		directory := filepath.Join(t.TempDir(), "source #[]&")
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatalf("create special source directory: %v", err)
		}
		source := []byte("package main\n\nfunc TestSynthetic() {}\n")
		path := filepath.Join(directory, "sample_test.go")
		if err := os.WriteFile(path, source, 0o600); err != nil {
			t.Fatalf("write synthetic recovery test: %v", err)
		}
		names := recoveryTestNamesInDirectory(t, directory)
		if len(names) != 1 || names[0] != "TestSynthetic" {
			t.Fatalf("special source directory names = %v", names)
		}
	})
}

func assertRecoveryTestClassification(t *testing.T) {
	t.Helper()
	testNames := recoveryTestNames(t)
	fastSelector := regexp.MustCompile(recoveryFastTestPattern)
	seenFast := make(map[string]struct{})
	seenClosure := make(map[string]struct{})
	for _, name := range testNames {
		switch {
		case strings.HasPrefix(name, recoveryFastTestPrefix):
			if !fastSelector.MatchString(name) {
				t.Errorf("fast recovery test escaped selector: %s", name)
			}
			if _, admitted := recoveryFastTestAllowlist[name]; !admitted {
				t.Errorf("unreviewed test entered fast recovery class: %s", name)
			}
			seenFast[name] = struct{}{}
		case strings.HasPrefix(name, recoveryClosureTestPrefix):
			if fastSelector.MatchString(name) {
				t.Errorf("closure recovery test entered fast selector: %s", name)
			}
			if _, admitted := recoveryClosureTestAllowlist[name]; !admitted {
				t.Errorf("unreviewed test entered closure recovery class: %s", name)
			}
			seenClosure[name] = struct{}{}
		default:
			t.Errorf("recovery test has no explicit class: %s", name)
		}
	}
	for name := range recoveryFastTestAllowlist {
		if _, present := seenFast[name]; !present {
			t.Errorf("admitted fast recovery test disappeared: %s", name)
		}
	}
	for name := range recoveryClosureTestAllowlist {
		if _, present := seenClosure[name]; !present {
			t.Errorf("admitted closure recovery test disappeared: %s", name)
		}
	}
}

func TestRecoveryClosureClassSentinel(t *testing.T) {
	assertRecoveryTestClassification(t)
	if os.Getenv("RECOVERY_TEST_CLASS_SENTINEL") == "reject" {
		t.Fatal("intentional RED: closure test entered fast recovery class")
	}
	tracePath := os.Getenv("RECOVERY_TEST_CLOSURE_TRACE")
	if tracePath == "" {
		return
	}
	file, err := os.OpenFile(tracePath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		t.Fatalf("record unique full recovery selection: %v", err)
	}
	if _, err := file.WriteString("closure-suite-selected\n"); err != nil {
		_ = file.Close()
		t.Fatalf("write full recovery selection: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("close full recovery selection: %v", err)
	}
}

func recoveryTestNames(t *testing.T) []string {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate recovery test package")
	}
	return recoveryTestNamesInDirectory(t, filepath.Dir(currentFile))
}

func recoveryTestNamesInDirectory(t *testing.T, directory string) []string {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), "_test.go") {
			continue
		}
		path := filepath.Join(directory, entry.Name())
		parsed, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", filepath.Base(path), err)
		}
		for _, declaration := range parsed.Decls {
			function, ok := declaration.(*ast.FuncDecl)
			if !ok || function.Recv != nil || !strings.HasPrefix(function.Name.Name, "Test") {
				continue
			}
			names = append(names, function.Name.Name)
		}
	}
	sort.Strings(names)
	return names
}
