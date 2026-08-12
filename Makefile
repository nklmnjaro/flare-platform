override SHELL := /bin/bash
override .SHELLFLAGS := -p -c
unexport BASH_ENV ENV MAKEFILES MFLAGS GNUMAKEFLAGS
.DEFAULT_GOAL := help

.PHONY: help doctor environment-evidence bootstrap tool-lock hooks check-fast check
.PHONY: prove-local prove-environment prove-gates verify
.PHONY: prove-integrity prove-diagnostics artifact-pack artifact-verify diagnose verify-runtime
.PHONY: recovery-pack recovery-verify prove-recovery
.PHONY: kind-up kind-smoke kind-negative kind-down clean

help:
	@printf '%s\n' \
	  'doctor         inspect host prerequisites' \
	  'environment-evidence print bounded environment evidence' \
	  'bootstrap      install pinned project tools' \
	  'tool-lock      generate checksums and enforce them' \
	  'hooks          install pre-commit and commit-msg hooks' \
	  'check-fast     cheap local static checks' \
	  'check          full static and security checks' \
	  'prove-local    prove offline-capable RED fixtures' \
	  'prove-environment prove environment capability RED fixtures' \
	  'prove-gates    prove all candidate gates fail on RED fixtures' \
	  'prove-integrity prove handoff integrity fails closed' \
	  'prove-diagnostics prove fresh and private diagnostic evidence' \
	  'artifact-pack  create deterministic review artifact' \
	  'artifact-verify verify review artifact and manifest' \
	  'recovery-pack  capture clean committed repository state' \
	  'recovery-verify restore and verify a recovery capsule' \
	  'prove-recovery prove repository recovery failures closed' \
	  'diagnose       collect bounded local diagnostics' \
	  'verify-runtime verify disposable Kubernetes runtime' \
	  'verify         full static + disposable kind verification' \
	  'kind-up        create isolated disposable kind cluster' \
	  'kind-smoke     build/load/probe reference workload' \
	  'kind-negative  prove runtime diagnostics on bad workload' \
	  'kind-down      delete only the project kind cluster' \
	  'clean          remove project-local generated state'

doctor:
	@tools/bootstrap/doctor.sh

environment-evidence:
	@tools/bootstrap/doctor.sh --machine

bootstrap:
	@tools/bootstrap/bootstrap.sh

tool-lock:
	@tools/bootstrap/lock-tools.sh

hooks:
	@tools/bootstrap/install-hooks.sh

check-fast:
	@tools/quality/check-fast.sh

check:
	@tools/quality/check.sh

prove-local:
	@tools/quality/prove-gates.sh --local-only

prove-environment:
	@tools/bootstrap/prove-environment.sh

prove-gates:
	@tools/quality/prove-gates.sh

prove-integrity:
	@tools/artifacts/prove-integrity.sh

prove-diagnostics:
	@tools/diagnostics/prove-freshness.sh
	@tools/diagnostics/prove-privacy.sh

artifact-pack: export ARTIFACT_SOURCE = $(SOURCE)
artifact-pack: export ARTIFACT_OUTPUT = $(OUTPUT)
artifact-pack:
	@test -n "$${ARTIFACT_SOURCE}" || { echo 'SOURCE is required' >&2; exit 2; }
	@test -n "$${ARTIFACT_OUTPUT}" || { echo 'OUTPUT is required' >&2; exit 2; }
	@set -euo pipefail; \
	  invocation_root="$$(pwd -P)"; \
	  source_path="$${ARTIFACT_SOURCE}"; \
	  output_path="$${ARTIFACT_OUTPUT}"; \
	  [[ "$${source_path}" == /* ]] || source_path="$${invocation_root}/$${source_path}"; \
	  [[ "$${output_path}" == /* ]] || output_path="$${invocation_root}/$${output_path}"; \
	  cd -- tools/artifacts/archive; \
	  "$(CURDIR)/tools/common/run-managed-tool.sh" go run . pack \
	    --source "$${source_path}" --output "$${output_path}"

artifact-verify: export ARTIFACT_ARCHIVE = $(ARCHIVE)
artifact-verify:
	@test -n "$${ARTIFACT_ARCHIVE}" || { echo 'ARCHIVE is required' >&2; exit 2; }
	@set -euo pipefail; \
	  invocation_root="$$(pwd -P)"; \
	  archive_path="$${ARTIFACT_ARCHIVE}"; \
	  [[ "$${archive_path}" == /* ]] || archive_path="$${invocation_root}/$${archive_path}"; \
	  cd -- tools/artifacts/archive; \
	  "$(CURDIR)/tools/common/run-managed-tool.sh" go run . verify \
	    --archive "$${archive_path}"

recovery-pack:
	@set -euo pipefail; \
	  output_path="$${OUTPUT:-}"; \
	  [[ -n "$${output_path}" ]] || { \
	    printf 'OUTPUT is required\n' >&2; \
	    exit 2; \
	  }; \
	  invocation_root="$$(pwd -P)"; \
	  builtin source "$(CURDIR)/tools/common/env.sh"; \
	  [[ "$${output_path}" == /* ]] || \
	    output_path="$${invocation_root}/$${output_path}"; \
	  if [[ "$${output_path}" == "$${PLATFORM_STATE_DIR}/recovery/"* ]]; then \
	    ensure_state_directory recovery; \
	  fi; \
	  git_path="$$(host_command_path git)"; \
	  builtin cd -- "$(CURDIR)/tools/recovery/capsule"; \
	  "$(CURDIR)/tools/common/run-managed-tool.sh" go run . pack \
	    --repository "$(CURDIR)" --output "$${output_path}" --git "$${git_path}"

recovery-verify:
	@set -euo pipefail; \
	  capsule_path="$${CAPSULE:-}"; \
	  [[ -n "$${capsule_path}" ]] || { \
	    printf 'CAPSULE is required\n' >&2; \
	    exit 2; \
	  }; \
	  invocation_root="$$(pwd -P)"; \
	  builtin source "$(CURDIR)/tools/common/env.sh"; \
	  [[ "$${capsule_path}" == /* ]] || \
	    capsule_path="$${invocation_root}/$${capsule_path}"; \
	  git_path="$$(host_command_path git)"; \
	  builtin cd -- "$(CURDIR)/tools/recovery/capsule"; \
	  "$(CURDIR)/tools/common/run-managed-tool.sh" go run . verify \
	    --capsule "$${capsule_path}" --git "$${git_path}"

prove-recovery:
	@set -euo pipefail; \
	  builtin source "$(CURDIR)/tools/common/env.sh"; \
	  git_path="$$(host_command_path git)"; \
	  builtin cd -- "$(CURDIR)/tools/recovery/capsule"; \
	  RECOVERY_TEST_GIT="$${git_path}" \
	    "$(CURDIR)/tools/common/run-managed-tool.sh" go test -count=1 ./...

verify:
	@tools/quality/check.sh
	@tools/quality/prove-gates.sh
	@tools/kubernetes/verify.sh --action verify

verify-runtime:
	@tools/kubernetes/verify.sh --action verify-runtime

diagnose:
	@tools/diagnostics/collect.sh

kind-up:
	@tools/kubernetes/kind-up.sh

kind-smoke:
	@tools/kubernetes/smoke.sh

kind-negative:
	@tools/kubernetes/negative-smoke.sh

kind-down:
	@tools/kubernetes/kind-down.sh

clean:
	@tools/common/clean.sh
