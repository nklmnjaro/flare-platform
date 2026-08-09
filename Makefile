SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help doctor bootstrap tool-lock hooks check-fast check prove-local prove-gates verify
.PHONY: prove-integrity artifact-pack artifact-verify diagnose verify-runtime
.PHONY: kind-up kind-smoke kind-negative kind-down clean

help:
	@printf '%s\n' \
	  'doctor         inspect host prerequisites' \
	  'bootstrap      install pinned project tools' \
	  'tool-lock      generate checksums and enforce them' \
	  'hooks          install pre-commit and commit-msg hooks' \
	  'check-fast     cheap local static checks' \
	  'check          full static and security checks' \
	  'prove-local    prove offline-capable RED fixtures' \
	  'prove-gates    prove all candidate gates fail on RED fixtures' \
	  'prove-integrity prove handoff integrity fails closed' \
	  'artifact-pack  create deterministic review artifact' \
	  'artifact-verify verify review artifact and manifest' \
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

prove-gates:
	@tools/quality/prove-gates.sh

prove-integrity:
	@tools/artifacts/prove-integrity.sh

artifact-pack:
	@test -n "$(SOURCE)" || { echo 'SOURCE is required' >&2; exit 2; }
	@test -n "$(OUTPUT)" || { echo 'OUTPUT is required' >&2; exit 2; }
	@cd tools/artifacts/archive && go run . pack \
	  --source "$(abspath $(SOURCE))" --output "$(abspath $(OUTPUT))"

artifact-verify:
	@test -n "$(ARCHIVE)" || { echo 'ARCHIVE is required' >&2; exit 2; }
	@cd tools/artifacts/archive && go run . verify \
	  --archive "$(abspath $(ARCHIVE))"

verify: check prove-gates verify-runtime

verify-runtime:
	@tools/kubernetes/verify.sh

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
	@tools/kubernetes/kind-down.sh --if-present
	@rm -rf .platform
