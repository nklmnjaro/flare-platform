SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help doctor bootstrap tool-lock hooks check-fast check prove-gates verify
.PHONY: kind-up kind-smoke kind-negative kind-down clean

help:
	@printf '%s\n' \
	  'doctor         inspect host prerequisites' \
	  'bootstrap      install pinned project tools' \
	  'tool-lock      generate checksums and enforce them' \
	  'hooks          install pre-commit and commit-msg hooks' \
	  'check-fast     cheap local static checks' \
	  'check          full static and security checks' \
	  'prove-gates    prove candidate gates fail on RED fixtures' \
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

prove-gates:
	@tools/quality/prove-gates.sh

verify: check prove-gates
	@tools/kubernetes/verify.sh

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
