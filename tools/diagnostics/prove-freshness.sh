#!/bin/bash -p
# Source-module globals are intentionally rebound to the private proof fixture.
# shellcheck disable=SC2034
set -euo pipefail

PROVE_FRESHNESS_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_FRESHNESS_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_FRESHNESS_SOURCE_DIR=.
builtin source "${PROVE_FRESHNESS_SOURCE_DIR}/evidence.sh"
builtin unset PROVE_FRESHNESS_SOURCE_DIR

PROOF_RELATIVE=''
PROOF_ROOT=''

cleanup() {
  [[ -n "${PROOF_ROOT}" ]] || return
  case "${PROOF_ROOT}" in
    "${PLATFORM_STATE_DIR}"/diagnostics-freshness.*)
      run_host_command rm -rf -- "${PROOF_ROOT}"
      ;;
    *)
      builtin printf \
        'FAIL  diagnostics-red refusing unsafe proof cleanup\n' >&2
      return 1
      ;;
  esac
}

configure_proof_paths() {
  DIAGNOSTICS_RAW_RELATIVE="${PROOF_RELATIVE}/raw"
  DIAGNOSTICS_ARCHIVE_RELATIVE="${PROOF_RELATIVE}/platform-diagnostics.zip"
  # Consumed by the sourced evidence module.
  # shellcheck disable=SC2034
  DIAGNOSTICS_CHECKSUM_RELATIVE="${DIAGNOSTICS_ARCHIVE_RELATIVE}.sha256"
}

configure_proof_source_candidate() {
  local source_repo="${PROOF_ROOT}/source-candidate"
  run_host_command mkdir -p -- "${source_repo}"
  builtin printf 'trusted diagnostic source\n' >"${source_repo}/README.md"
  run_host_command git -C "${source_repo}" init -q
  run_host_command git -C "${source_repo}" add README.md
  run_host_command git -C "${source_repo}" \
    -c user.name='Diagnostics Fixture' \
    -c user.email='diagnostics@example.invalid' \
    commit -qm 'test: trusted source'
  DIAGNOSTICS_SOURCE_REPOSITORY="${source_repo}"
  DIAGNOSTICS_TRUSTED_SOURCE_PATHS=(.)
}

reset_proof_root() {
  reset_state_directory "${PROOF_RELATIVE}"
  configure_proof_source_candidate
}

render_fixture_capture_status() {
  local state="${1:-complete}" schema="${2:-flare-platform-diagnostics-capture-v2}"
  local run_id="${3:-${DIAGNOSTICS_RUN_ID}}"
  local head="${4:-${DIAGNOSTICS_SOURCE_HEAD}}"
  local tree="${5:-${DIAGNOSTICS_SOURCE_TREE}}"
  builtin printf 'schema=%s\n' "${schema}"
  builtin printf 'state=%s\n' "${state}"
  builtin printf 'run_id=%s\n' "${run_id}"
  builtin printf 'head=%s\n' "${head}"
  builtin printf 'tree=%s\n' "${tree}"
}

render_fixture_platform_summary() {
  local run_id="${1:-${DIAGNOSTICS_RUN_ID}}" tool
  local head="${2:-${DIAGNOSTICS_SOURCE_HEAD}}"
  local tree="${3:-${DIAGNOSTICS_SOURCE_TREE}}"
  local branch="${4:-${DIAGNOSTICS_SOURCE_BRANCH}}"
  builtin printf 'schema=flare-platform-diagnostics-v3\n'
  builtin printf 'run_id=%s\n' "${run_id}"
  builtin printf 'head=%s\n' "${head}"
  builtin printf 'tree=%s\n' "${tree}"
  builtin printf 'branch=%s\n' "${branch}"
  builtin printf 'dirty_entries=%s\n' "${DIAGNOSTICS_SOURCE_DIRTY_ENTRIES}"
  builtin printf 'os=synthetic\narch=synthetic\n'
  builtin printf 'privacy=supported-secrets-controls-paths-redacted\n'
  for tool in go docker kind kubectl shellcheck shfmt actionlint zizmor \
    hadolint trivy kubeconform kube-linter; do
    builtin printf 'tool.%s=missing\n' "${tool}"
  done
}

write_valid_raw_contract() {
  write_sanitized_diagnostic capture-status.txt 4096 \
    render_fixture_capture_status complete
  write_sanitized_diagnostic platform.txt \
    "${DIAGNOSTICS_MAX_SUMMARY_BYTES}" render_fixture_platform_summary
  write_sanitized_diagnostic kubernetes-status.txt 4096 \
    builtin printf \
    'cluster=absent; no Kubernetes payload collected\n'
}

assert_absent() {
  local path="$1" label="$2"
  if [[ -e "${path}" || -L "${path}" ]]; then
    builtin printf 'FAIL  diagnostics-red %s unexpectedly exists\n' \
      "${label}" >&2
    return 1
  fi
}

assert_mode() {
  local path="$1" expected="$2" actual
  actual="$(run_host_command stat -c '%a' -- "${path}")" || return
  if [[ "${actual}" != "${expected}" ]]; then
    builtin printf \
      'FAIL  diagnostics-red unexpected mode for %s: %s\n' \
      "${path}" "${actual}" >&2
    return 1
  fi
}

assert_no_temporary_evidence() {
  local root="$1" unexpected
  unexpected="$(run_host_command find "${root}" \
    \( -name '.framed.*' -o -name '.text.*' -o -name '.capture.*' -o -name '.render.*' \
    -o -name '.status.*' \) -print -quit)"
  if [[ -n "${unexpected}" ]]; then
    builtin printf \
      'FAIL  diagnostics-red temporary evidence survived: %s\n' \
      "${unexpected}" >&2
    return 1
  fi
}

assert_archive_has_no_temporary_names() {
  local archive="$1" marker status
  for marker in '.framed.' '.text.' '.capture.' '.render.' '.status.'; do
    status=0
    run_host_command grep -aFq -- "${marker}" "${archive}" || status=$?
    case "${status}" in
      0)
        builtin printf \
          'FAIL  diagnostics-red archive retained temporary entry marker: %s\n' \
          "${marker}" >&2
        return 1
        ;;
      1) ;;
      *) return "${status}" ;;
    esac
  done
}

run_archive_verifier() (
  local archive="$1"
  builtin cd "${PLATFORM_ROOT}/tools/artifacts/archive" || return
  prepare_diagnostics_go_environment
  run_managed_tool_bounded 120s go run . verify --archive "${archive}"
)

prove_stale_capture_is_replaced() {
  local raw="${PROOF_ROOT}/raw"
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  reset_proof_root
  ensure_state_directory "${DIAGNOSTICS_RAW_RELATIVE}/kubernetes"
  builtin printf 'schema=old-run\nsecret=stale\n' \
    >"${raw}/kubernetes/stale.txt"
  builtin printf 'old archive\n' >"${archive}"
  builtin printf 'old checksum\n' >"${checksum}"

  prepare_diagnostics_run
  assert_absent "${raw}/kubernetes/stale.txt" 'stale raw payload'
  assert_absent "${archive}" 'stale diagnostics archive'
  assert_absent "${checksum}" 'stale diagnostics checksum'
  [[ "${DIAGNOSTICS_RUN_ID}" =~ ^sha256:[0-9a-f]{64}$ ]]
  write_sanitized_diagnostic current.txt 4096 \
    builtin printf 'schema=synthetic-fresh-v1\nstatus=current\n'
  run_host_command grep -Fqx 'status=current' "${raw}/current.txt"
  assert_mode "${raw}/current.txt" 600
  builtin printf \
    'PASS  diagnostics-red stale raw and mutable pair were invalidated\n'
}

prove_checksum_symlink_is_unlinked() {
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  local outside="${PROOF_ROOT}/outside"
  reset_proof_root
  ensure_state_directory "${PROOF_RELATIVE}/outside"
  builtin printf 'outside-checksum-safe\n' >"${outside}/sentinel.txt"
  builtin printf 'old archive\n' >"${archive}"
  run_host_command ln -s -- "${outside}/sentinel.txt" "${checksum}"

  prepare_diagnostics_run
  assert_absent "${archive}" 'archive paired with checksum symlink'
  assert_absent "${checksum}" 'checksum symlink'
  run_host_command grep -Fqx outside-checksum-safe \
    "${outside}/sentinel.txt"
  builtin printf \
    'PASS  diagnostics-red checksum symlink removed without target write\n'
}

prove_missing_managed_go_leaves_no_pair() {
  local raw="${PROOF_ROOT}/raw"
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  local marker="${PROOF_ROOT}/managed-go-ran"
  local output="${PROOF_ROOT}/missing-managed-go.log" status=0
  reset_proof_root
  ensure_state_directory "${DIAGNOSTICS_RAW_RELATIVE}/kubernetes"
  builtin printf 'stale-before-missing-go\n' \
    >"${raw}/kubernetes/stale.txt"
  builtin printf 'old archive\n' >"${archive}"
  builtin printf 'old checksum\n' >"${checksum}"
  (
    # Called indirectly by the evidence module.
    # shellcheck disable=SC2317,SC2329
    require_tool() {
      builtin printf 'managed-go-unavailable-fixture\n' >&2
      return 67
    }
    # Must remain unreachable after managed-Go admission fails.
    # shellcheck disable=SC2317,SC2329
    run_managed_tool_bounded() {
      builtin printf 'managed-go-ran\n' >"${marker}"
      return 99
    }
    prepare_diagnostics_run
  ) >"${output}" 2>&1 || status=$?
  if ((status != 67)) || [[ -e "${marker}" || -L "${marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics-red missing managed Go status=%s expected=67\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fqx managed-go-unavailable-fixture "${output}"
  assert_absent "${archive}" 'archive after missing managed Go'
  assert_absent "${checksum}" 'checksum after missing managed Go'
  assert_absent "${raw}/kubernetes/stale.txt" \
    'stale raw after missing managed Go'
  builtin printf \
    'PASS  diagnostics-red missing managed Go performed no lazy execution\n'
}

prove_raw_symlink_fails_after_invalidation() {
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  local outside="${PROOF_ROOT}/outside"
  local output="${PROOF_ROOT}/raw-symlink.log" status=0
  reset_proof_root
  ensure_state_directory "${PROOF_RELATIVE}/outside"
  builtin printf 'outside-raw-safe\n' >"${outside}/sentinel.txt"
  builtin printf 'old archive\n' >"${archive}"
  builtin printf 'old checksum\n' >"${checksum}"
  run_host_command ln -s -- "${outside}" "${PROOF_ROOT}/raw"

  prepare_diagnostics_run >"${output}" 2>&1 || status=$?
  if ((status != 1)); then
    builtin printf \
      'FAIL  diagnostics-red raw symlink status=%s expected=1\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'generated directory must not be a symlink' "${output}"
  assert_absent "${archive}" 'archive after raw symlink failure'
  assert_absent "${checksum}" 'checksum after raw symlink failure'
  run_host_command grep -Fqx outside-raw-safe "${outside}/sentinel.txt"
  builtin printf \
    'PASS  diagnostics-red unsafe raw target failed with no current pair\n'
}

prove_dirty_source_candidates_are_refused() {
  local kind source_repo archive checksum output status
  for kind in tracked-dirty untracked-go; do
    reset_proof_root
    source_repo="${PROOF_ROOT}/source-candidate"
    archive="${PROOF_ROOT}/platform-diagnostics.zip"
    checksum="${archive}.sha256"
    output="${PROOF_ROOT}/source-candidate-${kind}.log"
    builtin printf 'old archive\n' >"${archive}"
    builtin printf 'old checksum\n' >"${checksum}"
    case "${kind}" in
      tracked-dirty)
        builtin printf 'preexisting dirty source\n' >"${source_repo}/README.md"
        ;;
      untracked-go)
        builtin printf 'package injected\n' >"${source_repo}/extra.go"
        ;;
    esac
    status=0
    prepare_diagnostics_run >"${output}" 2>&1 || status=$?
    if ((status != 1)); then
      builtin printf \
        'FAIL  diagnostics-red %s source candidate status=%s expected=1\n' \
        "${kind}" "${status}" >&2
      return 1
    fi
    run_host_command grep -Fq \
      'executable diagnostic source differs from HEAD' "${output}"
    assert_absent "${archive}" "archive after ${kind} source admission"
    assert_absent "${checksum}" "checksum after ${kind} source admission"
    builtin printf \
      'PASS  diagnostics-red %s source candidate was refused\n' "${kind}"
  done
}

maximum_kubernetes_capture_fixture() {
  local index
  for ((index = 0; index < 4096; index++)); do
    builtin printf \
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
  done
}

prove_raw_total_boundary_is_inclusive() (
  local raw total=0 size relative digest
  local original_total="${DIAGNOSTICS_RAW_MAX_TOTAL_BYTES}"
  local -a files=(
    capture-status.txt platform.txt kubernetes-status.txt
    kubernetes/nodes.txt kubernetes/resources.txt kubernetes/events.txt
    kubernetes/logs.txt
  )
  reset_proof_root
  prepare_diagnostics_run
  write_valid_raw_contract
  write_sanitized_diagnostic kubernetes-status.txt 4096 \
    builtin printf 'cluster=present; owned bounded inspection collected\n'
  for relative in nodes resources events logs; do
    capture_diagnostic_command "kubernetes/${relative}.txt" 131072 \
      maximum_kubernetes_capture_fixture
    size="$(run_host_command stat -c '%s' -- \
      "${PROOF_ROOT}/raw/kubernetes/${relative}.txt")" || return
    ((10#${size} >= 131000)) || return 1
  done
  raw="$(diagnostics_raw_directory)"
  validate_diagnostics_raw_evidence "${raw}"
  for relative in "${files[@]}"; do
    size="$(run_host_command stat -c '%s' -- "${raw}/${relative}")" || return
    ((total += 10#${size}))
  done
  ((original_total == 548864 && total <= original_total)) || return 1
  DIAGNOSTICS_RAW_MAX_TOTAL_BYTES="${total}"
  digest="$(diagnostics_raw_snapshot_digest "${raw}")" || return
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  DIAGNOSTICS_RAW_MAX_TOTAL_BYTES=$((total - 1))
  if diagnostics_raw_snapshot_digest "${raw}" >/dev/null 2>&1; then
    builtin printf \
      'FAIL  diagnostics-red raw total sum-1 boundary unexpectedly passed\n' >&2
    return 1
  fi
  builtin printf \
    'PASS  diagnostics-red raw total boundary is inclusive and bounded\n'
)

prove_verified_private_publication() {
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  reset_proof_root
  prepare_diagnostics_run
  write_valid_raw_contract
  assert_no_temporary_evidence "$(diagnostics_raw_directory)"
  publish_diagnostics_archive "$(diagnostics_raw_directory)"
  run_archive_verifier "${archive}" >/dev/null
  assert_no_temporary_evidence "$(diagnostics_raw_directory)"
  assert_archive_has_no_temporary_names "${archive}"
  assert_mode "${archive}" 600
  assert_mode "${checksum}" 600
  builtin printf \
    'PASS  diagnostics-red verified ZIP published before private checksum\n'
}

prove_failure_after_archive_removes_pair() {
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  local output="${PROOF_ROOT}/after-archive-failure.log" status=0
  prepare_diagnostics_run
  write_valid_raw_contract
  (
    # Called indirectly by publish_diagnostics_archive.
    # shellcheck disable=SC2317,SC2329
    publish_diagnostics_checksum_file() {
      return 86
    }
    publish_diagnostics_archive "$(diagnostics_raw_directory)"
  ) >"${output}" 2>&1 || status=$?
  if ((status != 86)); then
    builtin printf \
      'FAIL  diagnostics-red post-ZIP failure status=%s expected=86\n' \
      "${status}" >&2
    return 1
  fi
  assert_absent "${archive}" 'ZIP after checksum publication failure'
  assert_absent "${checksum}" 'checksum after checksum publication failure'
  builtin printf \
    'PASS  diagnostics-red post-ZIP checksum failure removed both files\n'
}

prove_source_race_invalidates_publication() {
  local kind="$1" label="$2"
  local source_repo="${PROOF_ROOT}/source-candidate"
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  local output="${PROOF_ROOT}/source-${kind}-race.log" status=0
  reset_proof_root
  prepare_diagnostics_run
  write_valid_raw_contract
  (
    # Called indirectly after ZIP and checksum reach their final names.
    # shellcheck disable=SC2317,SC2329
    diagnostics_after_pair_publication_hook() {
      case "${kind}" in
        tracked)
          builtin printf 'uncommitted tracked mutation\n' \
            >"${source_repo}/README.md"
          ;;
        untracked)
          builtin printf 'package injected\n' >"${source_repo}/extra.go"
          ;;
        *) return 99 ;;
      esac
    }
    publish_diagnostics_archive "$(diagnostics_raw_directory)"
  ) >"${output}" 2>&1 || status=$?
  if ((status != 1)); then
    builtin printf \
      'FAIL  diagnostics-red %s source race status=%s expected=1\n' \
      "${label}" "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'executable diagnostic source differs from HEAD' "${output}"
  assert_absent "${archive}" "archive after ${label} source race"
  assert_absent "${checksum}" "checksum after ${label} source race"
  assert_no_temporary_evidence "$(diagnostics_raw_directory)"
  builtin printf \
    'PASS  diagnostics-red %s source race left no current pair\n' "${label}"
}

write_mismatched_capture_contract() {
  local field="$1"
  local run_id="${DIAGNOSTICS_RUN_ID}"
  local head="${DIAGNOSTICS_SOURCE_HEAD}"
  local tree="${DIAGNOSTICS_SOURCE_TREE}"
  case "${field}" in
    run) run_id='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    head) head='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    tree) tree='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
    *) return 1 ;;
  esac
  write_sanitized_diagnostic capture-status.txt 4096 \
    render_fixture_capture_status complete \
    flare-platform-diagnostics-capture-v2 "${run_id}" "${head}" "${tree}"
}

write_mismatched_platform_contract() {
  local field="$1"
  local run_id="${DIAGNOSTICS_RUN_ID}"
  local head="${DIAGNOSTICS_SOURCE_HEAD}"
  local tree="${DIAGNOSTICS_SOURCE_TREE}"
  local branch="${DIAGNOSTICS_SOURCE_BRANCH}"
  case "${field}" in
    run) run_id='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    head) head='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    tree) tree='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
    branch) branch='mismatched-branch' ;;
    *) return 1 ;;
  esac
  write_sanitized_diagnostic platform.txt \
    "${DIAGNOSTICS_MAX_SUMMARY_BYTES}" render_fixture_platform_summary \
    "${run_id}" "${head}" "${tree}" "${branch}"
}

mutate_raw_contract_fixture() {
  local case_name="$1" raw="$2"
  case "${case_name}" in
    missing)
      run_host_command rm -f -- "${raw}/capture-status.txt"
      builtin printf 'required file is missing or unsafe\n'
      ;;
    malformed)
      write_sanitized_diagnostic capture-status.txt 4096 \
        render_fixture_capture_status complete malformed-schema
      builtin printf 'capture status is missing, incomplete, malformed, or mismatched\n'
      ;;
    collecting)
      write_sanitized_diagnostic capture-status.txt 4096 \
        render_fixture_capture_status collecting
      builtin printf 'capture status is missing, incomplete, malformed, or mismatched\n'
      ;;
    capture-*)
      write_mismatched_capture_contract "${case_name#capture-}"
      builtin printf 'capture status is missing, incomplete, malformed, or mismatched\n'
      ;;
    platform-*)
      write_mismatched_platform_contract "${case_name#platform-}"
      builtin printf 'platform identity is malformed or mismatched\n'
      ;;
    extra)
      write_sanitized_diagnostic secrets.txt 4096 \
        builtin printf 'forbidden-extra=true\n'
      builtin printf 'unexpected raw entry is forbidden\n'
      ;;
    *) return 1 ;;
  esac
}

prove_raw_contract_reds() {
  local case_name expected raw archive checksum output status
  for case_name in missing malformed collecting capture-run capture-head \
    capture-tree platform-run platform-head platform-tree platform-branch \
    extra; do
    reset_proof_root
    raw="${PROOF_ROOT}/raw"
    archive="${PROOF_ROOT}/platform-diagnostics.zip"
    checksum="${archive}.sha256"
    output="${PROOF_ROOT}/raw-contract-${case_name}.log"
    prepare_diagnostics_run
    write_valid_raw_contract
    expected="$(mutate_raw_contract_fixture "${case_name}" "${raw}")" || return
    status=0
    publish_diagnostics_archive "${raw}" >"${output}" 2>&1 || status=$?
    if ((status != 1)); then
      builtin printf \
        'FAIL  diagnostics-red raw contract %s status=%s expected=1\n' \
        "${case_name}" "${status}" >&2
      return 1
    fi
    run_host_command grep -Fq -- "${expected}" "${output}"
    assert_absent "${archive}" "archive after ${case_name} raw contract"
    assert_absent "${checksum}" "checksum after ${case_name} raw contract"
    builtin printf \
      'PASS  diagnostics-red raw contract %s left no current pair\n' \
      "${case_name}"
  done
}

prove_detached_checksum_reds() {
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  local output="${PROOF_ROOT}/checksum-red.log" status=0
  local zeros='0000000000000000000000000000000000000000000000000000000000000000'

  builtin printf '%s  %s\n' "${zeros}" "${archive##*/}" >"${checksum}"
  run_archive_verifier "${archive}" >"${output}" 2>&1 || status=$?
  if ((status != 1)); then
    builtin printf \
      'FAIL  diagnostics-red checksum mismatch status=%s expected=1\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq 'detached archive checksum mismatch' "${output}"

  run_host_command rm -f -- "${checksum}"
  status=0
  run_archive_verifier "${archive}" >"${output}" 2>&1 || status=$?
  if ((status != 1)); then
    builtin printf \
      'FAIL  diagnostics-red missing checksum status=%s expected=1\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq 'detached checksum:' "${output}"
  invalidate_published_diagnostics
  builtin printf \
    'PASS  diagnostics-red mismatched and missing checksum fail closed\n'
}

prove_failed_replacement_leaves_no_pair() {
  local raw="${PROOF_ROOT}/raw"
  local archive="${PROOF_ROOT}/platform-diagnostics.zip"
  local checksum="${archive}.sha256"
  local output="${PROOF_ROOT}/publish-failure.log" status=0
  reset_proof_root
  prepare_diagnostics_run
  write_valid_raw_contract
  write_sanitized_diagnostic unexpected.txt 4096 \
    builtin printf 'unexpected=true\n'
  publish_diagnostics_archive "${raw}" >"${output}" 2>&1 || status=$?
  if ((status != 1)); then
    builtin printf \
      'FAIL  diagnostics-red unsafe publish status=%s expected=1\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'unexpected raw entry is forbidden' "${output}"
  assert_absent "${archive}" 'archive after failed current run'
  assert_absent "${checksum}" 'checksum after failed current run'
  builtin printf \
    'PASS  diagnostics-red failed current run left no mutable pair\n'
}

main() {
  umask 077
  ensure_state_directory '' || return
  PROOF_ROOT="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/diagnostics-freshness.XXXXXXXX")" || return
  PROOF_RELATIVE="${PROOF_ROOT#"${PLATFORM_STATE_DIR}/"}"
  configure_proof_paths
  trap cleanup EXIT
  prove_stale_capture_is_replaced
  prove_checksum_symlink_is_unlinked
  prove_missing_managed_go_leaves_no_pair
  prove_raw_symlink_fails_after_invalidation
  prove_dirty_source_candidates_are_refused
  prove_raw_total_boundary_is_inclusive
  prove_verified_private_publication
  prove_detached_checksum_reds
  prove_failure_after_archive_removes_pair
  prove_raw_contract_reds
  prove_source_race_invalidates_publication tracked tracked-dirty
  prove_source_race_invalidates_publication untracked untracked-go
  prove_failed_replacement_leaves_no_pair
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
