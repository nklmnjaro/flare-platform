#!/bin/bash -p
# Hostile fixtures are intentionally consumed indirectly by managed children
# and by the exact production functions under proof.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail

PROVE_PRIVACY_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_PRIVACY_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_PRIVACY_SOURCE_DIR=.
builtin source "${PROVE_PRIVACY_SOURCE_DIR}/collect.sh"
builtin source \
  "${PLATFORM_ROOT}/tools/kubernetes/diagnostic-authorization.sh"
builtin unset PROVE_PRIVACY_SOURCE_DIR

PROOF_RELATIVE=''
PROOF_ROOT=''

cleanup() {
  [[ -n "${PROOF_ROOT}" ]] || return
  case "${PROOF_ROOT}" in
    "${PLATFORM_STATE_DIR}"/diagnostics-privacy.*)
      run_host_command rm -rf -- "${PROOF_ROOT}"
      ;;
    *)
      builtin printf \
        'FAIL  diagnostics   refusing unsafe privacy proof cleanup\n' >&2
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

assert_fixed_text_absent() {
  local value="$1" file="$2" status=0
  run_host_command grep -Fq -- "${value}" "${file}" || status=$?
  case "${status}" in
    0)
      builtin printf \
        'FAIL  diagnostics   forbidden evidence text survived: %s\n' \
        "${value}" >&2
      return 1
      ;;
    1) return 0 ;;
    *)
      builtin printf \
        'FAIL  diagnostics   unable to inspect durable evidence\n' >&2
      return 1
      ;;
  esac
}

assert_no_temporary_evidence() {
  local root="$1" unexpected
  unexpected="$(run_host_command find "${root}" \
    \( -name '.framed.*' -o -name '.text.*' -o -name '.capture.*' -o -name '.render.*' \
    -o -name '.status.*' \) -print -quit)"
  if [[ -n "${unexpected}" ]]; then
    builtin printf \
      'FAIL  diagnostics   temporary evidence survived: %s\n' \
      "${unexpected}" >&2
    return 1
  fi
}

sensitive_fixture() {
  local auth='auth-canary-411'
  local password='password-canary-422'
  local token='token-canary-433'
  local secret='secret-canary-444'
  builtin printf 'Authorization: Bearer %s\n' "${auth}"
  builtin printf 'DB_PASSWORD=%s status=ok\n' "${password}"
  builtin printf '{"api_token":"%s","visible":true}\n' "${token}"
  builtin printf 'clientSecret=%s; result=retained\n' "${secret}"
  builtin printf '\033[31mterminal-control\033[0m\n'
  builtin printf '\033]0;osc-secret-canary\007osc-retained\n'
  builtin printf 'nul-byte:\0end\n'
  builtin printf 'TO\001KEN=control-key-canary visible-control=true\n'
  builtin printf 'TO\377KEN=invalid-utf8-canary visible-utf8=true\n'
  builtin printf 'repository=%s\n' "${PLATFORM_ROOT}"
  builtin printf 'home=%s/private\n' "${HOME:-/nonexistent}"
  builtin printf 'generic=/%s\n' 'home/synthetic-user/private'
  return 7
}

assert_no_forbidden_octets() {
  local file="$1" octets
  octets="$(LC_ALL=C run_host_command od -An -t u1 -- "${file}")" || return
  if [[ "${octets}" =~ (^|[[:space:]])(0|27|255)($|[[:space:]]) ]]; then
    builtin printf \
      'FAIL  diagnostics   forbidden control or invalid octet survived\n' >&2
    return 1
  fi
}

assert_privacy_capture() {
  local raw evidence copy synthetic_home unexpected value status=0
  raw="$(diagnostics_raw_directory)"
  evidence="${raw}/privacy-proof/capture.txt"
  copy="${raw}/privacy-proof/capture-copy.txt"
  synthetic_home="${PROOF_ROOT}/synthetic-home [x] #[]&"
  ensure_state_directory "${PROOF_RELATIVE}/synthetic-home [x] #[]&"
  builtin printf 'home-sentinel\n' >"${synthetic_home}/sentinel.txt"

  HOME="${synthetic_home}" \
    capture_diagnostic_command privacy-proof/capture.txt 8192 \
    sensitive_fixture || status=$?
  if ((status != 7)); then
    builtin printf \
      'FAIL  diagnostics   sensitive fixture status=%s expected=7\n' \
      "${status}" >&2
    return 1
  fi
  status=0
  HOME="${synthetic_home}" \
    capture_diagnostic_command privacy-proof/capture-copy.txt 8192 \
    sensitive_fixture || status=$?
  if ((status != 7)); then
    builtin printf \
      'FAIL  diagnostics   repeat fixture status=%s expected=7\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command cmp -- "${evidence}" "${copy}"
  run_host_command grep -Fqx 'exit_code=7' "${evidence}"
  run_host_command grep -Fqx 'truncated=false' "${evidence}"
  run_host_command grep -Fq '<redacted>' "${evidence}"
  run_host_command grep -Fq 'status=ok' "${evidence}"
  run_host_command grep -Fq 'result=retained' "${evidence}"
  run_host_command grep -Fq 'terminal-control' "${evidence}"
  run_host_command grep -Fq 'osc-retained' "${evidence}"
  run_host_command grep -Fq 'visible-control=true' "${evidence}"
  run_host_command grep -Fq 'visible-utf8=true' "${evidence}"
  run_host_command grep -Fq '<REPO>' "${evidence}"
  run_host_command grep -Fq '<HOME>' "${evidence}"
  run_host_command grep -Fq '<home>' "${evidence}"
  for value in auth-canary-411 password-canary-422 token-canary-433 \
    secret-canary-444 osc-secret-canary control-key-canary \
    invalid-utf8-canary synthetic-user "${PLATFORM_ROOT}" \
    "${synthetic_home}"; do
    assert_fixed_text_absent "${value}" "${evidence}"
  done
  assert_no_forbidden_octets "${evidence}"
  assert_no_temporary_evidence "${raw}"
  run_host_command grep -Fqx home-sentinel "${synthetic_home}/sentinel.txt"
  unexpected="$(run_host_command find "${synthetic_home}" -mindepth 1 \
    -maxdepth 1 ! -name sentinel.txt -print -quit)"
  if [[ -n "${unexpected}" ]]; then
    builtin printf \
      'FAIL  diagnostics   managed Go wrote through synthetic HOME: %s\n' \
      "${unexpected#"${synthetic_home}/"}" >&2
    return 1
  fi
  builtin printf \
    'PASS  diagnostics   secrets, controls, paths and invalid UTF-8 sanitized deterministically\n'
}

assert_source_snapshot_prunes_literal_state_paths() (
  local source first second third
  source="${PROOF_ROOT}/source [x] #[]&"
  ensure_state_directory "${PROOF_RELATIVE}/source [x] #[]&/.git"
  ensure_state_directory "${PROOF_RELATIVE}/source [x] #[]&/.platform"
  builtin printf 'tracked-one\n' >"${source}/tracked.txt"
  builtin printf 'git-one\n' >"${source}/.git/canary"
  builtin printf 'state-one\n' >"${source}/.platform/canary"
  DIAGNOSTICS_SOURCE_REPOSITORY="${source}"
  first="$(diagnostics_source_tree_snapshot_digest)"
  builtin printf 'git-two\n' >"${source}/.git/canary"
  builtin printf 'state-two\n' >"${source}/.platform/canary"
  second="$(diagnostics_source_tree_snapshot_digest)"
  builtin printf 'tracked-two\n' >"${source}/tracked.txt"
  third="$(diagnostics_source_tree_snapshot_digest)"
  if [[ "${first}" != "${second}" || "${first}" == "${third}" ]]; then
    builtin printf \
      'FAIL  diagnostics   source snapshot pruning is not literal and selective\n' >&2
    return 1
  fi
  builtin printf \
    'PASS  diagnostics   source snapshot prunes literal Git and state paths\n'
)

render_compound_secret_platform_summary() {
  local tool compound
  builtin printf 'schema=flare-platform-diagnostics-v3\n'
  builtin printf 'run_id=%s\n' "${DIAGNOSTICS_RUN_ID}"
  builtin printf 'head=%s\n' "${DIAGNOSTICS_SOURCE_HEAD}"
  builtin printf 'tree=%s\n' "${DIAGNOSTICS_SOURCE_TREE}"
  builtin printf 'branch=%s\n' "${DIAGNOSTICS_SOURCE_BRANCH}"
  builtin printf 'dirty_entries=%s\n' "${DIAGNOSTICS_SOURCE_DIRTY_ENTRIES}"
  compound='os=synthetic api_token: Bearer compound-token-canary visible'
  compound+=' password: Basic compound-password-canary visible'
  compound+=' --access-token Bearer compound-flag-canary visible'
  compound+=' {"client_secret":"Basic compound-json-canary"}'
  compound+=' Authorization: Bearer compound-authorization-canary visible'
  builtin printf '%s\n' "${compound}"
  builtin printf 'arch=synthetic\n'
  builtin printf 'privacy=supported-secrets-controls-paths-redacted\n'
  builtin printf 'tool.go=version-unavailable\n'
  for tool in docker kind kubectl shellcheck shfmt actionlint zizmor \
    hadolint trivy kubeconform kube-linter; do
    builtin printf 'tool.%s=missing\n' "${tool}"
  done
}

write_compound_secret_raw_contract() {
  write_sanitized_diagnostic capture-status.txt 4096 \
    render_capture_state complete
  write_sanitized_diagnostic platform.txt \
    "${DIAGNOSTICS_MAX_SUMMARY_BYTES}" \
    render_compound_secret_platform_summary
  write_sanitized_diagnostic kubernetes-status.txt 4096 \
    builtin printf 'cluster=absent; no Kubernetes payload collected\n'
}

assert_compound_canaries_absent() {
  local file="$1" canary
  for canary in compound-token-canary compound-password-canary \
    compound-flag-canary compound-json-canary \
    compound-authorization-canary; do
    assert_fixed_text_absent "${canary}" "${file}"
  done
}

assert_no_publish_residue() {
  local unexpected
  unexpected="$(run_host_command find "${PLATFORM_STATE_DIR}/diagnostics" \
    -maxdepth 1 -name '.publish.*' -print -quit)"
  if [[ -n "${unexpected}" ]]; then
    builtin printf \
      'FAIL  diagnostics   private publication residue survived\n' >&2
    return 1
  fi
}

assert_compound_secrets_absent_from_publication() {
  local raw archive checksum output success_output status=0
  raw="$(diagnostics_raw_directory)"
  archive="$(diagnostics_archive_path)"
  checksum="$(diagnostics_checksum_path)"
  output="${PROOF_ROOT}/compound-publication-failure.log"
  success_output="${PROOF_ROOT}/compound-publication-success.log"

  prepare_diagnostics_run
  write_compound_secret_raw_contract
  validate_diagnostics_raw_evidence "${raw}"
  assert_compound_canaries_absent "${raw}/platform.txt"
  publish_diagnostics_archive "${raw}" >"${success_output}" 2>&1
  [[ -f "${archive}" && ! -L "${archive}" &&
    -f "${checksum}" && ! -L "${checksum}" ]] || return 1
  assert_compound_canaries_absent "${archive}"
  assert_compound_canaries_absent "${checksum}"
  assert_compound_canaries_absent "${success_output}"
  assert_no_temporary_evidence "${raw}"
  assert_no_publish_residue

  prepare_diagnostics_run
  write_compound_secret_raw_contract
  (
    # Called indirectly after the private archive has been verified.
    # shellcheck disable=SC2317,SC2329
    publish_diagnostics_checksum_file() { return 86; }
    publish_diagnostics_archive "${raw}"
  ) >"${output}" 2>&1 || status=$?
  if ((status != 86)) || [[ -e "${archive}" || -L "${archive}" ||
    -e "${checksum}" || -L "${checksum}" ]]; then
    builtin printf \
      'FAIL  diagnostics   compound failure cleanup status=%s\n' \
      "${status}" >&2
    return 1
  fi
  assert_compound_canaries_absent "${raw}/platform.txt"
  assert_compound_canaries_absent "${output}"
  assert_no_temporary_evidence "${raw}"
  assert_no_publish_residue
  builtin printf \
    'PASS  diagnostics   compound secret canaries absent from raw ZIP checksum and failure residue\n'
}

assert_compound_secrets_absent_after_interruption() {
  local raw archive checksum output ready publisher_pid target_pid
  local status=0 attempt
  raw="$(diagnostics_raw_directory)"
  archive="$(diagnostics_archive_path)"
  checksum="$(diagnostics_checksum_path)"
  output="${PROOF_ROOT}/compound-publication-interrupted.log"
  ready="${PROOF_ROOT}/compound-publication-interrupted.ready"

  prepare_diagnostics_run
  write_compound_secret_raw_contract
  (
    # Called after the final pair exists, before publication is complete.
    # shellcheck disable=SC2317,SC2329
    diagnostics_after_pair_publication_hook() {
      builtin printf '%s\n' "${BASHPID}" >"${ready}"
      while :; do :; done
    }
    publish_diagnostics_archive "${raw}"
  ) >"${output}" 2>&1 &
  publisher_pid=$!
  for ((attempt = 1; attempt <= 500; attempt++)); do
    [[ ! -s "${ready}" ]] || break
    builtin kill -0 "${publisher_pid}" 2>/dev/null || break
    run_host_command sleep 0.01
  done
  if [[ ! -s "${ready}" ]]; then
    builtin kill -KILL "${publisher_pid}" 2>/dev/null || true
    builtin wait "${publisher_pid}" 2>/dev/null || true
    builtin printf \
      'FAIL  diagnostics   compound interruption hook was not reached\n' >&2
    return 1
  fi
  IFS= builtin read -r target_pid <"${ready}" || return
  [[ "${target_pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  builtin kill -TERM "${target_pid}"
  builtin wait "${publisher_pid}" 2>/dev/null || status=$?
  if ((status != 143)) || [[ -e "${archive}" || -L "${archive}" ||
    -e "${checksum}" || -L "${checksum}" ]]; then
    builtin printf \
      'FAIL  diagnostics   compound interruption cleanup status=%s\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command sleep 0.05
  if builtin kill -0 "${target_pid}" 2>/dev/null; then
    builtin printf \
      'FAIL  diagnostics   interrupted publisher remained live\n' >&2
    return 1
  fi
  assert_compound_canaries_absent "${raw}/platform.txt"
  assert_compound_canaries_absent "${output}"
  assert_no_temporary_evidence "${raw}"
  assert_no_publish_residue
  builtin printf \
    'PASS  diagnostics   interrupted compound publication retained no pair or secret residue\n'
}

assert_hostile_go_environment_is_sealed() {
  local raw evidence hostile_home hostile_tmp hostile_goroot hostile_tools
  local helper marker goenv directory unexpected
  raw="$(diagnostics_raw_directory)"
  evidence="${raw}/privacy-proof/hostile-go-environment.txt"
  hostile_home="${PROOF_ROOT}/hostile-home"
  hostile_tmp="${PROOF_ROOT}/hostile-tmp"
  hostile_goroot="${PROOF_ROOT}/hostile-goroot"
  hostile_tools="${PROOF_ROOT}/hostile-tools"
  helper="${hostile_tools}/hostile-helper"
  marker="${PROOF_ROOT}/hostile-helper-ran"
  goenv="${PROOF_ROOT}/hostile-go.env"
  for directory in hostile-home hostile-tmp hostile-goroot hostile-tools; do
    ensure_state_directory "${PROOF_RELATIVE}/${directory}"
  done
  builtin printf 'home-sentinel\n' >"${hostile_home}/sentinel.txt"
  builtin printf 'tmp-sentinel\n' >"${hostile_tmp}/sentinel.txt"
  builtin printf 'goroot-sentinel\n' >"${hostile_goroot}/sentinel.txt"
  builtin printf \
    '#!/bin/bash -p\nprintf "ran\\n" >"%s"\nexit 91\n' "${marker}" \
    >"${helper}"
  run_host_command chmod 0700 -- "${helper}"
  builtin printf 'GOFLAGS=-toolexec=%s\n' "${helper}" >"${goenv}"
  (
    builtin export HOME="${hostile_home}"
    builtin export TMPDIR="${hostile_tmp}" TMP="${hostile_tmp}"
    builtin export TEMP="${hostile_tmp}" GOTMPDIR="${hostile_tmp}"
    builtin export GOROOT="${hostile_goroot}" GOTOOLDIR="${hostile_tools}"
    builtin export GOCACHE="${hostile_tmp}" GOMODCACHE="${hostile_tmp}"
    builtin export GOPATH="${hostile_tmp}" GOCACHEPROG="${helper}"
    builtin export GOENV="${goenv}" GOWORK="${goenv}"
    builtin export GOFLAGS="-toolexec=${helper}" GOTOOLCHAIN="${helper}"
    builtin export GOPROXY='http://127.0.0.1:1' GOSUMDB='sum.invalid'
    builtin export CGO_ENABLED=1 CC="${helper}" CXX="${helper}"
    builtin export AR="${helper}" PKG_CONFIG="${helper}"
    capture_diagnostic_command privacy-proof/hostile-go-environment.txt \
      4096 builtin printf 'sealed-go-environment=true\n'
  )
  run_host_command grep -Fqx 'exit_code=0' "${evidence}"
  run_host_command grep -Fqx 'sealed-go-environment=true' "${evidence}"
  if [[ -e "${marker}" || -L "${marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics   hostile Go helper executed\n' >&2
    return 1
  fi
  for directory in "${hostile_home}" "${hostile_tmp}" "${hostile_goroot}"; do
    unexpected="$(run_host_command find "${directory}" -mindepth 1 \
      -maxdepth 1 ! -name sentinel.txt -print -quit)"
    if [[ -n "${unexpected}" ]]; then
      builtin printf \
        'FAIL  diagnostics   hostile Go path received a write: %s\n' \
        "${unexpected}" >&2
      return 1
    fi
  done
  assert_no_temporary_evidence "${raw}"
  builtin printf \
    'PASS  diagnostics   hostile Go helpers and HOME/TMP paths were sealed\n'
}

truncating_fixture() {
  local index
  for ((index = 0; index < 256; index++)); do
    builtin printf 'bounded-visible-payload-'
  done
  builtin printf '\n'
}

assert_truncation_metadata() {
  local evidence bytes
  evidence="$(diagnostics_raw_directory)/privacy-proof/truncated.txt"
  capture_diagnostic_command privacy-proof/truncated.txt 256 \
    truncating_fixture
  run_host_command grep -Fqx 'exit_code=0' "${evidence}"
  run_host_command grep -Fqx 'truncated=true' "${evidence}"
  bytes="$(run_host_command wc -c <"${evidence}")" || return
  bytes="${bytes//[[:space:]]/}"
  if [[ ! "${bytes}" =~ ^[0-9]+$ ]] || ((10#${bytes} > 256)); then
    builtin printf \
      'FAIL  diagnostics   full durable capture exceeded byte limit\n' >&2
    return 1
  fi
  assert_no_temporary_evidence "$(diagnostics_raw_directory)"
  builtin printf \
    'PASS  diagnostics   explicit truncation bounds metadata plus payload\n'
}

assert_stale_capture_removed() {
  local stale
  stale="$(diagnostics_raw_directory)/stale-private.txt"
  builtin printf 'stale-private-canary\n' >"${stale}"
  prepare_diagnostics_run
  if [[ -e "${stale}" || -L "${stale}" ]]; then
    builtin printf \
      'FAIL  diagnostics   stale raw evidence survived a new run\n' >&2
    return 1
  fi
  builtin printf \
    'PASS  diagnostics   each run starts from empty raw evidence\n'
}

assert_failed_collection_discards_partial_payload() {
  local partial status=0
  partial="$(diagnostics_raw_directory)/kubernetes/partial.txt"
  failing_collection() {
    builtin printf 'partial-safe-evidence\n' >"${partial}"
    return 23
  }
  run_fresh_diagnostic_collection \
    "${DIAGNOSTICS_RAW_RELATIVE}/kubernetes" \
    failing_collection || status=$?
  if ((status != 23)) || [[ -e "${partial}" || -L "${partial}" ]]; then
    builtin printf \
      'FAIL  diagnostics   failed collection retained partial payload; status=%s\n' \
      "${status}" >&2
    return 1
  fi
  builtin printf \
    'PASS  diagnostics   failed collection status=23 discarded Kubernetes staging\n'
}

assert_failed_query_resets_entire_kubernetes_staging() {
  local kubernetes unexpected status=0
  kubernetes="$(diagnostics_raw_directory)/kubernetes"
  successful_query() {
    builtin printf 'safe-query-output\n'
  }
  failing_query() {
    builtin printf 'bounded-query-failure\n'
    return 37
  }
  synthetic_kubernetes_collection() {
    capture_diagnostic_command kubernetes/first.txt 4096 \
      successful_query || return
    capture_diagnostic_command kubernetes/failed.txt 4096 \
      failing_query || return
  }
  run_fresh_diagnostic_collection \
    "${DIAGNOSTICS_RAW_RELATIVE}/kubernetes" \
    synthetic_kubernetes_collection || status=$?
  unexpected="$(run_host_command find "${kubernetes}" -mindepth 1 \
    -print -quit)"
  if ((status != 37)) || [[ -n "${unexpected}" ]]; then
    builtin printf \
      'FAIL  diagnostics   failed query staging reset status=%s residual=%q\n' \
      "${status}" "${unexpected}" >&2
    return 1
  fi
  assert_no_temporary_evidence "$(diagnostics_raw_directory)"
  builtin printf \
    'PASS  diagnostics   query status=37 reset whole Kubernetes staging\n'
}

assert_kubernetes_staging_symlink_has_no_side_effect() {
  local raw outside marker output status=0
  raw="$(diagnostics_raw_directory)"
  outside="${PROOF_ROOT}/kubernetes-outside"
  marker="${PROOF_ROOT}/kubernetes-symlink-collector-ran"
  output="${PROOF_ROOT}/kubernetes-symlink.log"
  run_host_command rm -rf -- "${raw}/kubernetes"
  ensure_state_directory "${PROOF_RELATIVE}/kubernetes-outside"
  builtin printf 'kubernetes-outside-safe\n' >"${outside}/sentinel.txt"
  run_host_command ln -s -- "${outside}" "${raw}/kubernetes"
  forbidden_kubernetes_collector() {
    builtin printf 'collector-ran\n' >"${marker}"
  }
  run_fresh_diagnostic_collection \
    "${DIAGNOSTICS_RAW_RELATIVE}/kubernetes" \
    forbidden_kubernetes_collector >"${output}" 2>&1 || status=$?
  if ((status != 1)) || [[ -e "${marker}" || -L "${marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics   Kubernetes staging symlink status=%s expected=1\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'generated directory must not be a symlink' "${output}"
  run_host_command grep -Fqx kubernetes-outside-safe \
    "${outside}/sentinel.txt"
  run_host_command rm -f -- "${raw}/kubernetes"
  reset_state_directory "${DIAGNOSTICS_RAW_RELATIVE}/kubernetes"
  builtin printf \
    'PASS  diagnostics   Kubernetes staging symlink target remained untouched\n'
}

assert_ownership_precedes_collection() {
  local proof_dir="${PROOF_ROOT}/authorization"
  local context_guard="${proof_dir}/context-ok"
  local ownership_refused="${proof_dir}/ownership-refused"
  local ownership_ok="${proof_dir}/ownership-ok"
  local collector_marker="${proof_dir}/collector-ran"
  local output="${proof_dir}/refused.log" status=0
  ensure_state_directory "${PROOF_RELATIVE}/authorization"
  builtin printf '#!/bin/bash -p\nexit 0\n' >"${context_guard}"
  builtin printf \
    '#!/bin/bash -p\nprintf "foreign-checkout-refused\\n" >&2\nexit 9\n' \
    >"${ownership_refused}"
  builtin printf '#!/bin/bash -p\nexit 0\n' >"${ownership_ok}"
  run_host_command chmod 0700 -- \
    "${context_guard}" "${ownership_refused}" "${ownership_ok}"
  privacy_collector() {
    builtin printf 'collector-ran\n' >"${collector_marker}"
  }

  run_authorized_diagnostic_collection \
    "${context_guard}" "${ownership_refused}" privacy_collector \
    >"${output}" 2>&1 || status=$?
  if ((status != 9)) ||
    [[ -e "${collector_marker}" || -L "${collector_marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics   foreign ownership did not stop callback; status=%s\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fqx foreign-checkout-refused "${output}"
  run_authorized_diagnostic_collection \
    "${context_guard}" "${ownership_ok}" privacy_collector
  run_host_command grep -Fqx collector-ran "${collector_marker}"
  builtin printf \
    'PASS  diagnostics   foreign ownership status=9 preceded payload callback\n'
}

assert_raw_file_symlink_has_no_side_effect() {
  local raw outside target output marker status=0
  raw="$(diagnostics_raw_directory)"
  outside="${PROOF_ROOT}/raw-file-outside.txt"
  target="${raw}/privacy-proof/symlink.txt"
  output="${PROOF_ROOT}/raw-file-symlink.log"
  marker="${PROOF_ROOT}/raw-file-collector-ran"
  ensure_state_directory "${DIAGNOSTICS_RAW_RELATIVE}/privacy-proof"
  builtin printf 'outside-file-safe\n' >"${outside}"
  run_host_command ln -s -- "${outside}" "${target}"
  symlink_collector() {
    builtin printf 'collector-ran\n' >"${marker}"
    sensitive_fixture
  }
  capture_diagnostic_command privacy-proof/symlink.txt 4096 \
    symlink_collector >"${output}" 2>&1 || status=$?
  if ((status != 1)); then
    builtin printf \
      'FAIL  diagnostics   raw file symlink status=%s expected=1\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'refusing generated-state file symlink' "${output}"
  run_host_command grep -Fqx outside-file-safe "${outside}"
  if [[ -e "${marker}" || -L "${marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics   raw file symlink executed collector callback\n' >&2
    return 1
  fi
  builtin printf \
    'PASS  diagnostics   raw file symlink refused before collector execution\n'
}

assert_sanitized_writer_symlink_has_no_side_effect() {
  local raw outside target output marker status=0
  raw="$(diagnostics_raw_directory)"
  outside="${PROOF_ROOT}/writer-outside.txt"
  target="${raw}/privacy-proof/writer-symlink.txt"
  output="${PROOF_ROOT}/writer-symlink.log"
  marker="${PROOF_ROOT}/writer-renderer-ran"
  ensure_state_directory "${DIAGNOSTICS_RAW_RELATIVE}/privacy-proof"
  builtin printf 'outside-writer-safe\n' >"${outside}"
  run_host_command ln -s -- "${outside}" "${target}"
  forbidden_writer_renderer() {
    builtin printf 'renderer-ran\n' >"${marker}"
    builtin printf 'unsafe-render\n'
  }
  write_sanitized_diagnostic privacy-proof/writer-symlink.txt 4096 \
    forbidden_writer_renderer >"${output}" 2>&1 || status=$?
  if ((status != 1)) || [[ -e "${marker}" || -L "${marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics   sanitized writer symlink status=%s expected=1\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'refusing generated-state file symlink' "${output}"
  run_host_command grep -Fqx outside-writer-safe "${outside}"
  builtin printf \
    'PASS  diagnostics   sanitized writer symlink refused before renderer execution\n'
}

assert_fake_state_host_tool_is_rejected() {
  local fake_dir="${PROOF_ROOT}/fake-bin"
  local marker="${PROOF_ROOT}/fake-host-ran"
  local output="${PROOF_ROOT}/fake-host.log" status=0
  ensure_state_directory "${PROOF_RELATIVE}/fake-bin"
  builtin printf \
    '#!/bin/bash -p\nprintf "ran\\n" >"%s"\nexit 0\n' "${marker}" \
    >"${fake_dir}/git"
  run_host_command chmod 0700 -- "${fake_dir}/git"
  (
    # Consumed by the sourced host-command module.
    # shellcheck disable=SC2034
    HOST_COMMAND_PATH_CACHE=()
    PLATFORM_CALLER_HOST_PATH="${fake_dir}:${PLATFORM_CALLER_HOST_PATH}"
    run_host_command git --version
  ) >"${output}" 2>&1 || status=$?
  if ((status != HOST_COMMAND_UNTRUSTED_STATUS)) ||
    [[ -e "${marker}" || -L "${marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics   fake state host tool status=%s expected=%s\n' \
      "${status}" "${HOST_COMMAND_UNTRUSTED_STATUS}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'lookup location is inside repository or generated command state' \
    "${output}"
  builtin printf \
    'PASS  diagnostics   project-state host tool rejected without execution\n'
}

assert_missing_sanitizer_does_not_run_go() {
  local output="${PROOF_ROOT}/missing-sanitizer.log" status=0
  local original_module="${DIAGNOSTICS_SANITIZER_MODULE}"
  DIAGNOSTICS_SANITIZER_MODULE="${PROOF_ROOT}/missing-sanitizer"
  set +e
  sanitize_diagnostics_stream 4096 \
    <<<'TOKEN=must-not-run' >"${output}" 2>&1
  status=$?
  set -e
  DIAGNOSTICS_SANITIZER_MODULE="${original_module}"
  if ((status != 1)) ||
    [[ -e "${PROOF_ROOT}/missing-sanitizer" ||
      -L "${PROOF_ROOT}/missing-sanitizer" ]]; then
    builtin printf \
      'FAIL  diagnostics   missing sanitizer source was materialized; status=%s\n' \
      "${status}" >&2
    return 1
  fi
  run_host_command grep -Fq \
    'evidence sanitizer source is unavailable or unsafe' "${output}"
  builtin printf \
    'PASS  diagnostics   missing sanitizer source failed before managed Go\n'
}

assert_kubernetes_scope_is_narrow() {
  local script="${PLATFORM_ROOT}/tools/kubernetes/diagnostics.sh"
  local count forbidden
  count="$(run_host_command grep -Ec \
    '^[[:space:]]*capture (nodes|resources|events|logs) ' "${script}")" || return
  if [[ "${count}" != 4 ]]; then
    builtin printf \
      'FAIL  diagnostics   Kubernetes capture set count=%s expected=4\n' \
      "${count}" >&2
    return 1
  fi
  for forbidden in describe-pods ' describe ' ' get secrets' \
    ' get configmaps' --all-namespaces ' -A '; do
    assert_fixed_text_absent "${forbidden}" "${script}"
  done
  builtin printf \
    'PASS  diagnostics   Kubernetes scope is nodes/resources/events/logs only\n'
}

assert_tool_identity_failed_producers() {
  local output
  output="$({
    # Called by the exact production inventory implementation.
    # shellcheck disable=SC2317,SC2329
    require_tool() { return 0; }
    diagnostics_tool_identity_command() {
      builtin printf 'forged-producer42-identity\n'
      return 42
    }
    write_tool_inventory_entry synthetic
  })"
  [[ "${output}" == 'tool.synthetic=version-unavailable' ]] || {
    builtin printf \
      'FAIL  diagnostics   failed producer published identity: %q\n' \
      "${output}" >&2
    return 1
  }
  output="$({
    # shellcheck disable=SC2317,SC2329
    require_tool() { return 0; }
    diagnostics_tool_identity_command() {
      builtin printf 'forged-timeout-identity\n'
      return 124
    }
    write_tool_inventory_entry synthetic
  })"
  [[ "${output}" == 'tool.synthetic=version-unavailable' ]] || {
    builtin printf \
      'FAIL  diagnostics   timed-out producer published identity: %q\n' \
      "${output}" >&2
    return 1
  }
}

assert_tool_identity_sanitizer_failures() {
  local output
  output="$({
    # shellcheck disable=SC2317,SC2329
    require_tool() { return 0; }
    diagnostics_tool_identity_command() {
      builtin printf 'forged-sanitizer-failure-identity\n'
    }
    sanitize_diagnostics_stream() {
      run_host_command cat >/dev/null
      return 19
    }
    write_tool_inventory_entry synthetic
  })"
  [[ "${output}" == 'tool.synthetic=version-unavailable' ]] || {
    builtin printf \
      'FAIL  diagnostics   failed sanitizer published identity: %q\n' \
      "${output}" >&2
    return 1
  }
  output="$({
    # shellcheck disable=SC2317,SC2329
    require_tool() { return 0; }
    diagnostics_tool_identity_command() { return 0; }
    write_tool_inventory_entry synthetic
  })"
  [[ "${output}" == 'tool.synthetic=version-unavailable' ]] || {
    builtin printf \
      'FAIL  diagnostics   empty producer published identity: %q\n' \
      "${output}" >&2
    return 1
  }
  output="$({
    # shellcheck disable=SC2317,SC2329
    require_tool() { return 0; }
    diagnostics_tool_identity_command() {
      builtin printf 'forged-malformed-frame-identity\n'
    }
    sanitize_diagnostics_stream() {
      run_host_command cat >/dev/null
      builtin printf 'sanitizer_status=forged\nforged-malformed-frame-identity\n'
    }
    write_tool_inventory_entry synthetic
  })"
  [[ "${output}" == 'tool.synthetic=version-unavailable' ]] || {
    builtin printf \
      'FAIL  diagnostics   malformed sanitizer frame published identity: %q\n' \
      "${output}" >&2
    return 1
  }

  output="$({
    # shellcheck disable=SC2317,SC2329
    require_tool() { return 0; }
    diagnostics_tool_identity_command() {
      builtin printf 'forged-extra-frame-identity\n'
    }
    sanitize_diagnostics_stream() {
      run_host_command cat >/dev/null
      builtin printf \
        'sanitizer_truncated=false\nforged-first-frame\nforged-second-frame\n'
    }
    write_tool_inventory_entry synthetic
  })"
  [[ "${output}" == 'tool.synthetic=version-unavailable' ]] || {
    builtin printf \
      'FAIL  diagnostics   extra sanitizer frame published identity: %q\n' \
      "${output}" >&2
    return 1
  }
}

assert_tool_identity_bounded_drain() {
  local output marker="${PROOF_ROOT}/multiline-version-drained"
  local large_marker="${PROOF_ROOT}/large-version-drained"
  output="$({
    # shellcheck disable=SC2317,SC2329
    require_tool() { return 0; }
    diagnostics_tool_identity_command() {
      local index
      builtin printf 'synthetic tool 1.2.3\n'
      for ((index = 0; index < 4096; index++)); do
        builtin printf 'forged-second-line-%s\n' "${index}" || return
      done
      builtin printf 'drained\n' >"${marker}"
    }
    write_tool_inventory_entry synthetic
  })"
  if [[ "${output}" != 'tool.synthetic=present | synthetic tool 1.2.3' ]] ||
    [[ ! -f "${marker}" || -L "${marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics   multiline producer was not bounded and drained: %q\n' \
      "${output}" >&2
    return 1
  fi
  run_host_command grep -Fqx drained "${marker}"

  output="$({
    # shellcheck disable=SC2317,SC2329
    require_tool() { return 0; }
    diagnostics_tool_identity_command() {
      local index
      builtin printf 'TOKEN=large-version-canary-733'
      for ((index = 0; index < 32768; index++)); do
        builtin printf '0123456789abcdef' || return
      done
      builtin printf 'drained\n' >"${large_marker}"
    }
    write_tool_inventory_entry synthetic
  })"
  if [[ "${output}" != 'tool.synthetic=version-unavailable' ]] ||
    [[ ! -f "${large_marker}" || -L "${large_marker}" ]]; then
    builtin printf \
      'FAIL  diagnostics   oversized producer was not rejected and drained: %q\n' \
      "${output}" >&2
    return 1
  fi
  run_host_command grep -Fqx drained "${large_marker}"
  [[ "${output}" != *large-version-canary-733* ]] || {
    builtin printf \
      'FAIL  diagnostics   oversized producer retained unsanitized identity\n' >&2
    return 1
  }
}

assert_tool_identity_contract() {
  assert_tool_identity_failed_producers
  assert_tool_identity_sanitizer_failures
  assert_tool_identity_bounded_drain
  assert_no_temporary_evidence "$(diagnostics_raw_directory)"
  builtin printf \
    'PASS  diagnostics   tool identity requires successful producer and exact bounded frame\n'
}

run_sanitizer_unit_tests() (
  builtin cd "${DIAGNOSTICS_SANITIZER_MODULE}" || return
  prepare_diagnostics_go_environment
  run_managed_tool_bounded 120s go test ./...
)

main() {
  umask 077
  ensure_state_directory '' || return
  PROOF_ROOT="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/diagnostics-privacy.XXXXXXXX")" || return
  PROOF_RELATIVE="${PROOF_ROOT#"${PLATFORM_STATE_DIR}/"}"
  configure_proof_paths
  configure_proof_source_candidate
  trap cleanup EXIT
  prepare_diagnostics_run
  run_sanitizer_unit_tests >/dev/null
  assert_privacy_capture
  assert_source_snapshot_prunes_literal_state_paths
  assert_hostile_go_environment_is_sealed
  assert_truncation_metadata
  assert_stale_capture_removed
  assert_failed_collection_discards_partial_payload
  assert_failed_query_resets_entire_kubernetes_staging
  assert_kubernetes_staging_symlink_has_no_side_effect
  assert_ownership_precedes_collection
  assert_raw_file_symlink_has_no_side_effect
  assert_sanitized_writer_symlink_has_no_side_effect
  assert_fake_state_host_tool_is_rejected
  assert_missing_sanitizer_does_not_run_go
  assert_kubernetes_scope_is_narrow
  assert_tool_identity_contract
  assert_compound_secrets_absent_from_publication
  assert_compound_secrets_absent_after_interruption
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
