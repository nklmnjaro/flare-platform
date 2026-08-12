#!/bin/bash -p
# Source-module constants and exported Go environment are consumed by callers.
# shellcheck disable=SC2034
set -euo pipefail

DIAGNOSTIC_EVIDENCE_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${DIAGNOSTIC_EVIDENCE_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  DIAGNOSTIC_EVIDENCE_SOURCE_DIR=.
builtin source "${DIAGNOSTIC_EVIDENCE_SOURCE_DIR}/../common/env.sh"
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
builtin unset DIAGNOSTIC_EVIDENCE_SOURCE_DIR

DIAGNOSTICS_ARCHIVE_RELATIVE='platform-diagnostics.zip'
DIAGNOSTICS_CHECKSUM_RELATIVE='platform-diagnostics.zip.sha256'
DIAGNOSTICS_RAW_RELATIVE='diagnostics/raw'
DIAGNOSTICS_SANITIZER_MODULE="${PLATFORM_ROOT}/tools/evidence/sanitize"
DIAGNOSTICS_MAX_SUMMARY_BYTES=16384
DIAGNOSTICS_CAPTURE_HEADER_BYTES=32
DIAGNOSTICS_RUN_ID=''
DIAGNOSTICS_SOURCE_REPOSITORY="${PLATFORM_ROOT}"
DIAGNOSTICS_SOURCE_HEAD=''
DIAGNOSTICS_SOURCE_TREE=''
DIAGNOSTICS_SOURCE_BRANCH=''
DIAGNOSTICS_SOURCE_STATUS_SHA256=''
DIAGNOSTICS_SOURCE_INDEX_SHA256=''
DIAGNOSTICS_SOURCE_WORKTREE_SHA256=''
DIAGNOSTICS_SOURCE_DIRTY_ENTRIES=''
DIAGNOSTICS_SOURCE_MAX_ENTRIES=20000
DIAGNOSTICS_SOURCE_MAX_PATH_BYTES=1048576
DIAGNOSTICS_SOURCE_MAX_FILE_BYTES=67108864
DIAGNOSTICS_SOURCE_MAX_TOTAL_BYTES=268435456
DIAGNOSTICS_RAW_MAX_ENTRIES=8
DIAGNOSTICS_RAW_MAX_FILE_BYTES=131072
DIAGNOSTICS_RAW_MAX_TOTAL_BYTES=$((\
  4 * DIAGNOSTICS_RAW_MAX_FILE_BYTES + DIAGNOSTICS_MAX_SUMMARY_BYTES + 8192))
DIAGNOSTICS_EMPTY_SHA256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
DIAGNOSTICS_TRUSTED_SOURCE_PATHS=(
  aqua.yaml
  aqua-checksums.json
  tools/bootstrap/aqua-trust.sh
  tools/common/checkout-identity.sh
  tools/common/docker-target.sh
  tools/common/env.sh
  tools/common/host-commands.sh
  tools/common/process-state.sh
  tools/common/state.sh
  tools/common/tooling.sh
  tools/diagnostics/collect.sh
  tools/diagnostics/evidence.sh
  tools/evidence/sanitize
  tools/artifacts/archive
  tools/kubernetes/diagnostic-authorization.sh
  tools/kubernetes/diagnostics.sh
  tools/kubernetes/guard-context.sh
  tools/kubernetes/guard-ownership.sh
  tools/kubernetes/ownership.sh
  tools/kubernetes/runtime.sh
)

prepare_diagnostics_go_environment() {
  local variable
  ensure_state_directory diagnostics/go-cache || return
  ensure_state_directory diagnostics/go-path/pkg/mod || return
  ensure_state_directory diagnostics/go-tmp || return
  ensure_state_directory diagnostics/xdg/config || return
  ensure_state_directory diagnostics/xdg/cache || return
  ensure_state_directory diagnostics/xdg/data || return
  ensure_state_directory diagnostics/xdg/state || return
  while IFS= builtin read -r variable; do
    builtin unset -v "${variable}" || return
  done < <(builtin compgen -A export GO)
  while IFS= builtin read -r variable; do
    builtin unset -v "${variable}" || return
  done < <(builtin compgen -A export CGO_)
  builtin unset AR CC CXX FC GCCGO PKG_CONFIG
  builtin unset TMPDIR TMP TEMP TEMPDIR
  builtin export GOENV=off GOWORK=off GOTOOLCHAIN=local
  builtin export GOPROXY=off GOSUMDB=off
  builtin export CGO_ENABLED=0
  builtin export GOCACHE="${PLATFORM_STATE_DIR}/diagnostics/go-cache"
  builtin export GOPATH="${PLATFORM_STATE_DIR}/diagnostics/go-path"
  builtin export GOMODCACHE="${GOPATH}/pkg/mod"
  builtin export GOTMPDIR="${PLATFORM_STATE_DIR}/diagnostics/go-tmp"
  builtin export TMPDIR="${GOTMPDIR}" TMP="${GOTMPDIR}" TEMP="${GOTMPDIR}"
  builtin export XDG_CONFIG_HOME="${PLATFORM_STATE_DIR}/diagnostics/xdg/config"
  builtin export XDG_CACHE_HOME="${PLATFORM_STATE_DIR}/diagnostics/xdg/cache"
  builtin export XDG_DATA_HOME="${PLATFORM_STATE_DIR}/diagnostics/xdg/data"
  builtin export XDG_STATE_HOME="${PLATFORM_STATE_DIR}/diagnostics/xdg/state"
}

diagnostics_raw_directory() {
  builtin printf '%s/%s\n' "${PLATFORM_STATE_DIR}" "${DIAGNOSTICS_RAW_RELATIVE}"
}

diagnostics_archive_path() {
  builtin printf '%s/%s\n' "${PLATFORM_STATE_DIR}" \
    "${DIAGNOSTICS_ARCHIVE_RELATIVE}"
}

diagnostics_checksum_path() {
  builtin printf '%s/%s\n' "${PLATFORM_STATE_DIR}" \
    "${DIAGNOSTICS_CHECKSUM_RELATIVE}"
}

diagnostics_git_command() {
  local git_path
  git_path="$(host_command_path git)" || return
  GIT_OPTIONAL_LOCKS=0 run_host_command timeout --signal=TERM \
    --kill-after=5s 30s "${git_path}" -C \
    "${DIAGNOSTICS_SOURCE_REPOSITORY}" "$@"
}

diagnostics_stream_sha256() {
  local result digest
  result="$(run_host_command sha256sum --)" || return
  digest="${result%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  builtin printf '%s\n' "${digest}"
}

diagnostics_git_stream_sha256() {
  diagnostics_git_command "$@" | diagnostics_stream_sha256
}

diagnostics_source_dirty_count() {
  diagnostics_git_command status --porcelain=v1 -z \
    --untracked-files=all | (
    local entry count=0
    while IFS= builtin read -r -d '' entry; do
      ((count += 1))
      case "${entry:0:2}" in
        *R* | *C*) IFS= builtin read -r -d '' entry || return ;;
      esac
    done
    builtin printf '%s\n' "${count}"
  )
}

diagnostics_source_tree_snapshot_digest() (
  local root="${DIAGNOSTICS_SOURCE_REPOSITORY}" entry relative kind mode
  local before after size digest count=0 path_bytes=0 total_bytes=0
  local maximum_read=$((DIAGNOSTICS_SOURCE_MAX_FILE_BYTES + 1))
  builtin export LC_ALL=C
  [[ -d "${root}" && ! -L "${root}" ]] || {
    builtin printf \
      'FAIL  diagnostics   source repository is unavailable or unsafe\n' >&2
    return 1
  }
  {
    run_host_command find -P "${root}" -mindepth 1 \
      \( -path "${root}/.git" -o -path "${root}/.platform" \) \
      -prune -o -print0 |
      run_host_command sort -z | (
      while IFS= builtin read -r -d '' entry; do
        relative="${entry#"${root}/"}"
        [[ -n "${relative}" && "${relative}" != "${entry}" ]] || return 1
        ((count += 1))
        ((path_bytes += ${#relative}))
        if ((count > DIAGNOSTICS_SOURCE_MAX_ENTRIES || \
          path_bytes > DIAGNOSTICS_SOURCE_MAX_PATH_BYTES)); then
          builtin printf \
            'FAIL  diagnostics   source snapshot exceeds its entry bound\n' >&2
          return 1
        fi
        if [[ -L "${entry}" ]]; then
          kind='symlink'
          before="$(run_host_command stat -c '%a:%s' -- "${entry}")" || return
          size="${before#*:}"
          [[ "${size}" =~ ^[0-9]+$ ]] || return 1
          ((10#${size} <= DIAGNOSTICS_SOURCE_MAX_PATH_BYTES)) || return 1
          digest="$(run_host_command readlink -- "${entry}" |
            diagnostics_stream_sha256)" || return
          after="$(run_host_command stat -c '%a:%s' -- "${entry}")" || return
        elif [[ -f "${entry}" ]]; then
          kind='file'
          before="$(run_host_command stat -c '%a:%s' -- "${entry}")" || return
          size="${before#*:}"
          [[ "${size}" =~ ^[0-9]+$ ]] || return 1
          if ((10#${size} > DIAGNOSTICS_SOURCE_MAX_FILE_BYTES || \
            total_bytes + 10#${size} > DIAGNOSTICS_SOURCE_MAX_TOTAL_BYTES)); then
            builtin printf \
              'FAIL  diagnostics   source snapshot exceeds its byte bound\n' >&2
            return 1
          fi
          digest="$(run_host_command head -c "${maximum_read}" -- "${entry}" |
            diagnostics_stream_sha256)" || return
          after="$(run_host_command stat -c '%a:%s' -- "${entry}")" || return
          ((total_bytes += 10#${size}))
        elif [[ -d "${entry}" ]]; then
          kind='directory'
          before="$(run_host_command stat -c '%a:0' -- "${entry}")" || return
          size=0
          digest="${DIAGNOSTICS_EMPTY_SHA256}"
          after="$(run_host_command stat -c '%a:0' -- "${entry}")" || return
        else
          builtin printf \
            'FAIL  diagnostics   special source entry is not allowed\n' >&2
          return 1
        fi
        [[ "${before}" == "${after}" ]] || {
          builtin printf \
            'FAIL  diagnostics   source changed while it was inspected\n' >&2
          return 1
        }
        mode="${before%%:*}"
        builtin printf '%s\0%s\0%s\0%s\0%s\0' \
          "${relative}" "${kind}" "${mode}" "${size}" "${digest}"
      done
      builtin printf 'entries\0%s\0bytes\0%s\0' "${count}" "${total_bytes}"
    )
  } | diagnostics_stream_sha256
)

diagnostics_trusted_source_status_sha256() {
  ((${#DIAGNOSTICS_TRUSTED_SOURCE_PATHS[@]} > 0)) || return 1
  diagnostics_git_stream_sha256 status --porcelain=v1 -z \
    --untracked-files=all --ignored=matching -- \
    "${DIAGNOSTICS_TRUSTED_SOURCE_PATHS[@]}"
}

read_diagnostics_source_identity_once() {
  local head tree branch status_digest index_digest worktree_digest
  local dirty_count trusted_digest
  head="$(diagnostics_git_command rev-parse --verify HEAD)" || return
  tree="$(diagnostics_git_command rev-parse --verify 'HEAD^{tree}')" || return
  branch="$(diagnostics_git_command branch --show-current)" || return
  trusted_digest="$(diagnostics_trusted_source_status_sha256)" || return
  if [[ "${trusted_digest}" != "${DIAGNOSTICS_EMPTY_SHA256}" ]]; then
    builtin printf \
      'FAIL  diagnostics   executable diagnostic source differs from HEAD\n' >&2
    return 1
  fi
  status_digest="$(diagnostics_git_stream_sha256 status --porcelain=v1 -z \
    --untracked-files=all)" || return
  index_digest="$(diagnostics_git_stream_sha256 ls-files -s -z)" || return
  worktree_digest="$(diagnostics_source_tree_snapshot_digest)" || return
  dirty_count="$(diagnostics_source_dirty_count)" || return
  if [[ ! "${head}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${tree}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    "${branch}" == *$'\n'* || "${branch}" == *$'\r'* ||
    "${branch}" == *$'\t'* ||
    ! "${status_digest}" =~ ^[0-9a-f]{64}$ ||
    ! "${index_digest}" =~ ^[0-9a-f]{64}$ ||
    ! "${worktree_digest}" =~ ^[0-9a-f]{64}$ ||
    ! "${dirty_count}" =~ ^[0-9]+$ ]]; then
    builtin printf \
      'FAIL  diagnostics   source identity is malformed\n' >&2
    return 1
  fi
  builtin printf \
    'head=%s\ntree=%s\nbranch=%s\nstatus_sha256=%s\nindex_sha256=%s\nworktree_sha256=%s\ndirty_entries=%s\n' \
    "${head}" "${tree}" "${branch}" "${status_digest}" \
    "${index_digest}" "${worktree_digest}" "${dirty_count}"
}

read_diagnostics_source_identity() {
  local first second
  first="$(read_diagnostics_source_identity_once)" || return
  second="$(read_diagnostics_source_identity_once)" || return
  if [[ "${first}" != "${second}" ]]; then
    builtin printf \
      'FAIL  diagnostics   source changed while identity was frozen\n' >&2
    return 1
  fi
  builtin printf '%s\n' "${first}"
}

freeze_diagnostics_source_identity() {
  local identity
  local -a lines=()
  identity="$(read_diagnostics_source_identity)" || return
  mapfile -t lines <<<"${identity}"
  if ((${#lines[@]} != 7)) ||
    [[ "${lines[0]}" != head=* || "${lines[1]}" != tree=* ||
      "${lines[2]}" != branch=* || "${lines[3]}" != status_sha256=* ||
      "${lines[4]}" != index_sha256=* ||
      "${lines[5]}" != worktree_sha256=* ||
      "${lines[6]}" != dirty_entries=* ]]; then
    builtin printf \
      'FAIL  diagnostics   source identity is malformed\n' >&2
    return 1
  fi
  DIAGNOSTICS_SOURCE_HEAD="${lines[0]#head=}"
  DIAGNOSTICS_SOURCE_TREE="${lines[1]#tree=}"
  DIAGNOSTICS_SOURCE_BRANCH="${lines[2]#branch=}"
  DIAGNOSTICS_SOURCE_STATUS_SHA256="${lines[3]#status_sha256=}"
  DIAGNOSTICS_SOURCE_INDEX_SHA256="${lines[4]#index_sha256=}"
  DIAGNOSTICS_SOURCE_WORKTREE_SHA256="${lines[5]#worktree_sha256=}"
  DIAGNOSTICS_SOURCE_DIRTY_ENTRIES="${lines[6]#dirty_entries=}"
}

verify_diagnostics_source_identity() {
  local current expected
  if [[ -z "${DIAGNOSTICS_SOURCE_HEAD}" ||
    -z "${DIAGNOSTICS_SOURCE_TREE}" ||
    -z "${DIAGNOSTICS_SOURCE_STATUS_SHA256}" ||
    -z "${DIAGNOSTICS_SOURCE_INDEX_SHA256}" ||
    -z "${DIAGNOSTICS_SOURCE_WORKTREE_SHA256}" ||
    -z "${DIAGNOSTICS_SOURCE_DIRTY_ENTRIES}" ]]; then
    builtin printf \
      'FAIL  diagnostics   frozen source identity is unavailable\n' >&2
    return 1
  fi
  expected="$(builtin printf \
    'head=%s\ntree=%s\nbranch=%s\nstatus_sha256=%s\nindex_sha256=%s\nworktree_sha256=%s\ndirty_entries=%s\n' \
    "${DIAGNOSTICS_SOURCE_HEAD}" "${DIAGNOSTICS_SOURCE_TREE}" \
    "${DIAGNOSTICS_SOURCE_BRANCH}" "${DIAGNOSTICS_SOURCE_STATUS_SHA256}" \
    "${DIAGNOSTICS_SOURCE_INDEX_SHA256}" \
    "${DIAGNOSTICS_SOURCE_WORKTREE_SHA256}" \
    "${DIAGNOSTICS_SOURCE_DIRTY_ENTRIES}")"
  current="$(read_diagnostics_source_identity)" || return
  if [[ "${current}" != "${expected}" ]]; then
    builtin printf \
      'FAIL  diagnostics   source identity changed during capture\n' >&2
    return 1
  fi
}

remove_published_diagnostic() {
  local relative="$1"
  local target="${PLATFORM_STATE_DIR}/${relative}"
  validate_state_relative_path "${relative}" || return
  assert_existing_state_directory '' || return
  if [[ -d "${target}" && ! -L "${target}" ]]; then
    builtin printf \
      'FAIL  diagnostics   publication target is a directory: %s\n' \
      "${target}" >&2
    return 1
  fi
  run_host_command rm -f -- "${target}"
}

invalidate_published_diagnostics() {
  local failed=0
  remove_published_diagnostic "${DIAGNOSTICS_CHECKSUM_RELATIVE}" || failed=1
  remove_published_diagnostic "${DIAGNOSTICS_ARCHIVE_RELATIVE}" || failed=1
  [[ "${failed}" -eq 0 ]]
}

prepare_diagnostics_sanitizer() {
  require_diagnostics_sanitizer
}

require_diagnostics_sanitizer() {
  local source
  require_tool go || return
  for source in go.mod main.go sanitize.go; do
    if [[ -L "${DIAGNOSTICS_SANITIZER_MODULE}/${source}" ||
      ! -f "${DIAGNOSTICS_SANITIZER_MODULE}/${source}" ]]; then
      builtin printf \
        'FAIL  diagnostics   evidence sanitizer source is unavailable or unsafe\n' >&2
      return 1
    fi
  done
}

sanitize_diagnostics_stream() {
  local maximum_bytes="$1"
  shift
  local -a arguments=(
    --max-bytes "${maximum_bytes}"
    --repository "${PLATFORM_ROOT}"
  )
  [[ -z "${HOME:-}" ]] || arguments+=(--home "${HOME}")
  arguments+=("$@")
  require_diagnostics_sanitizer || return
  (
    builtin cd "${DIAGNOSTICS_SANITIZER_MODULE}" || return
    prepare_diagnostics_go_environment
    run_managed_tool_bounded 30s go run . "${arguments[@]}"
  )
}

read_sanitizer_report() {
  local framed="$1" report=''
  IFS= builtin read -r report <"${framed}" || return
  case "${report}" in
    sanitizer_truncated=true) builtin printf 'true\n' ;;
    sanitizer_truncated=false) builtin printf 'false\n' ;;
    *)
      builtin printf \
        'FAIL  diagnostics   sanitizer returned a malformed status report\n' >&2
      return 1
      ;;
  esac
}

extract_sanitized_payload() {
  local framed="$1" payload="$2"
  run_host_command tail -n +2 -- "${framed}" >"${payload}"
}

generate_diagnostics_run_identity() (
  local nonce_file nonce digest
  ensure_state_directory diagnostics || return
  nonce_file="$(run_host_command mktemp \
    "${PLATFORM_STATE_DIR}/diagnostics/.run-id.XXXXXXXX")" || return
  trap 'run_host_command rm -f -- "${nonce_file}" >/dev/null 2>&1 || :' EXIT
  nonce="${nonce_file##*.run-id.}"
  digest="$({
    builtin printf 'flare-platform-diagnostics-run-v1\0%s\0%s\0%s\0' \
      "${PLATFORM_ROOT}" "${BASHPID}" "${nonce}"
  } | run_host_command sha256sum --)" || return
  digest="${digest%%[[:space:]]*}"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  builtin printf 'sha256:%s\n' "${digest}"
)

prepare_diagnostics_run() {
  invalidate_published_diagnostics || return
  reset_state_directory "${DIAGNOSTICS_RAW_RELATIVE}" || return
  prepare_diagnostics_sanitizer || return
  require_diagnostics_sanitizer || return
  freeze_diagnostics_source_identity || return
  DIAGNOSTICS_RUN_ID="$(generate_diagnostics_run_identity)" || return
  [[ "${DIAGNOSTICS_RUN_ID}" =~ ^sha256:[0-9a-f]{64}$ ]]
}

write_sanitized_diagnostic() (
  local relative="$1" maximum_bytes="$2"
  shift 2
  local target directory framed temporary sanitizer_status truncated
  local -a pipeline_status=()
  target="$(prepare_state_file \
    "${DIAGNOSTICS_RAW_RELATIVE}/${relative}")" || return
  directory="${target%/*}"
  framed="$(run_host_command mktemp \
    "${directory}/.framed.XXXXXXXX")" || return
  temporary="$(run_host_command mktemp \
    "${directory}/.text.XXXXXXXX")" || {
    run_host_command rm -f -- "${framed}" >/dev/null 2>&1 || :
    return 1
  }
  # ShellCheck does not associate nested cleanup functions with EXIT traps.
  # shellcheck disable=SC2317,SC2329
  cleanup() {
    run_host_command rm -f -- "${framed}" "${temporary}" \
      >/dev/null 2>&1 || :
  }
  trap cleanup EXIT
  set +e
  "$@" 2>&1 |
    sanitize_diagnostics_stream "${maximum_bytes}" \
      >"${framed}" 2>/dev/null
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  sanitizer_status="${pipeline_status[1]}"
  if ((pipeline_status[0] != 0 || sanitizer_status != 0)); then
    builtin printf 'FAIL  diagnostics   unable to sanitize %s\n' \
      "${relative}" >&2
    return 1
  fi
  truncated="$(read_sanitizer_report "${framed}")" || return
  if [[ "${truncated}" != false ]]; then
    builtin printf 'FAIL  diagnostics   generated %s exceeded its byte limit\n' \
      "${relative}" >&2
    return 1
  fi
  extract_sanitized_payload "${framed}" "${temporary}" || return
  [[ -f "${temporary}" && ! -L "${temporary}" ]] || return 1
  run_host_command chmod 0600 -- "${temporary}" || return
  run_host_command rm -f -- "${framed}" || return
  prepare_state_file "${DIAGNOSTICS_RAW_RELATIVE}/${relative}" \
    >/dev/null || return
  run_host_command mv -f -- "${temporary}" "${target}" || return
  trap - EXIT
)

capture_diagnostic_command() (
  local relative="$1" maximum_bytes="$2"
  shift 2
  local target directory framed payload rendered payload_limit status sanitizer_status
  local truncated=false
  local -a pipeline_status=()
  if [[ ! "${maximum_bytes}" =~ ^[0-9]+$ ]] ||
    ((maximum_bytes <= DIAGNOSTICS_CAPTURE_HEADER_BYTES)); then
    builtin printf 'FAIL  diagnostics   invalid capture byte limit: %q\n' \
      "${maximum_bytes}" >&2
    return 1
  fi
  payload_limit=$((maximum_bytes - DIAGNOSTICS_CAPTURE_HEADER_BYTES))
  target="$(prepare_state_file \
    "${DIAGNOSTICS_RAW_RELATIVE}/${relative}")" || return
  directory="${target%/*}"
  framed="$(run_host_command mktemp \
    "${directory}/.framed.XXXXXXXX")" || return
  payload="$(run_host_command mktemp \
    "${directory}/.capture.XXXXXXXX")" || {
    run_host_command rm -f -- "${framed}" >/dev/null 2>&1 || :
    return 1
  }
  rendered="$(run_host_command mktemp \
    "${directory}/.render.XXXXXXXX")" || {
    run_host_command rm -f -- "${framed}" "${payload}" \
      >/dev/null 2>&1 || :
    return 1
  }
  # ShellCheck does not associate nested cleanup functions with EXIT traps.
  # shellcheck disable=SC2317,SC2329
  cleanup() {
    run_host_command rm -f -- "${framed}" "${payload}" "${rendered}" \
      >/dev/null 2>&1 || :
  }
  trap cleanup EXIT
  set +e
  "$@" 2>&1 |
    sanitize_diagnostics_stream "${payload_limit}" \
      >"${framed}" 2>/dev/null
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  status="${pipeline_status[0]}"
  sanitizer_status="${pipeline_status[1]}"
  if ((sanitizer_status != 0)); then
    builtin printf 'FAIL  diagnostics   sanitizer failed for %s\n' \
      "${relative}" >&2
    return 1
  fi
  truncated="$(read_sanitizer_report "${framed}")" || return
  extract_sanitized_payload "${framed}" "${payload}" || return
  {
    builtin printf 'exit_code=%s\ntruncated=%s\n' \
      "${status}" "${truncated}"
    run_host_command cat -- "${payload}"
  } >"${rendered}"
  [[ -f "${rendered}" && ! -L "${rendered}" ]] || return 1
  run_host_command chmod 0600 -- "${rendered}" || return
  run_host_command rm -f -- "${framed}" "${payload}" || return
  prepare_state_file "${DIAGNOSTICS_RAW_RELATIVE}/${relative}" \
    >/dev/null || return
  run_host_command mv -f -- "${rendered}" "${target}" || return
  trap - EXIT
  return "${status}"
)

run_fresh_diagnostic_collection() {
  local relative="$1"
  shift
  local status=0
  reset_state_directory "${relative}" || return
  "$@" || status=$?
  if ((status != 0)); then
    reset_state_directory "${relative}" || return
    return "${status}"
  fi
}

diagnostics_raw_contract_failure() {
  builtin printf 'FAIL  diagnostics   raw evidence contract: %s\n' "$1" >&2
  return 1
}

validate_diagnostics_private_file() {
  local path="$1" maximum_bytes="$2" identity owner mode links size
  [[ ! -L "${path}" && -f "${path}" ]] ||
    diagnostics_raw_contract_failure 'required file is missing or unsafe' || return
  identity="$(run_host_command stat -c '%u:%a:%h:%s' -- "${path}")" || return
  IFS=: builtin read -r owner mode links size <<<"${identity}"
  if [[ "${owner}" != "${EUID}" || "${mode}" != 600 ||
    "${links}" != 1 || ! "${size}" =~ ^[0-9]+$ ]] ||
    ((10#${size} > maximum_bytes)); then
    diagnostics_raw_contract_failure 'file mode, link count, or size is invalid'
    return
  fi
}

validate_diagnostics_exact_line_count() {
  local path="$1" expected="$2" lines
  lines="$(run_host_command wc -l <"${path}")" || return
  lines="${lines//[[:space:]]/}"
  if [[ ! "${lines}" =~ ^[0-9]+$ ]] || ((10#${lines} != expected)); then
    diagnostics_raw_contract_failure 'line count or final newline is invalid'
    return
  fi
}

validate_diagnostics_capture_status() {
  local path="$1"
  local -a lines=()
  validate_diagnostics_private_file "${path}" 4096 || return
  validate_diagnostics_exact_line_count "${path}" 5 || return
  mapfile -t lines <"${path}"
  if ((${#lines[@]} != 5)) ||
    [[ "${lines[0]}" != 'schema=flare-platform-diagnostics-capture-v2' ||
      "${lines[1]}" != 'state=complete' ||
      "${lines[2]}" != "run_id=${DIAGNOSTICS_RUN_ID}" ||
      "${lines[3]}" != "head=${DIAGNOSTICS_SOURCE_HEAD}" ||
      "${lines[4]}" != "tree=${DIAGNOSTICS_SOURCE_TREE}" ]]; then
    diagnostics_raw_contract_failure \
      'capture status is missing, incomplete, malformed, or mismatched'
    return
  fi
}

validate_diagnostics_platform_summary() {
  local path="$1" index tool value
  local -a lines=() tools=(
    go docker kind kubectl shellcheck shfmt actionlint zizmor hadolint trivy
    kubeconform kube-linter
  )
  validate_diagnostics_private_file \
    "${path}" "${DIAGNOSTICS_MAX_SUMMARY_BYTES}" || return
  validate_diagnostics_exact_line_count "${path}" 21 || return
  mapfile -t lines <"${path}"
  if ((${#lines[@]} != 21)) ||
    [[ "${lines[0]}" != 'schema=flare-platform-diagnostics-v3' ||
      "${lines[1]}" != "run_id=${DIAGNOSTICS_RUN_ID}" ||
      "${lines[2]}" != "head=${DIAGNOSTICS_SOURCE_HEAD}" ||
      "${lines[3]}" != "tree=${DIAGNOSTICS_SOURCE_TREE}" ||
      "${lines[4]}" != "branch=${DIAGNOSTICS_SOURCE_BRANCH}" ||
      "${lines[5]}" != "dirty_entries=${DIAGNOSTICS_SOURCE_DIRTY_ENTRIES}" ||
      "${lines[6]}" != os=?* || "${lines[7]}" != arch=?* ||
      "${lines[8]}" != 'privacy=supported-secrets-controls-paths-redacted' ]]; then
    diagnostics_raw_contract_failure \
      'platform identity is malformed or mismatched'
    return
  fi
  for index in "${!tools[@]}"; do
    tool="${tools[${index}]}"
    value="${lines[$((index + 9))]}"
    case "${value}" in
      "tool.${tool}=missing") ;;
      "tool.${tool}=present | "?*)
        ((${#value} <= ${#tool} + 316)) || {
          diagnostics_raw_contract_failure \
            'platform tool version exceeds its byte bound'
          return
        }
        ;;
      *)
        diagnostics_raw_contract_failure \
          'platform tool inventory is malformed'
        return
        ;;
    esac
  done
}

diagnostics_kubernetes_status_kind() {
  local path="$1" value
  validate_diagnostics_private_file "${path}" 4096 || return
  validate_diagnostics_exact_line_count "${path}" 1 || return
  IFS= builtin read -r value <"${path}" || return
  case "${value}" in
    'cluster=present; owned bounded inspection collected')
      builtin printf 'collected\n'
      ;;
    'cluster=not-inspected; kind or kubectl missing' | \
      'cluster=not-inspected; kind query failed' | \
      'cluster=absent; no Kubernetes payload collected' | \
      'cluster=present; kubeconfig=absent-or-unsafe' | \
      'cluster=present; inspection refused or failed; no raw command output retained')
      builtin printf 'empty\n'
      ;;
    *)
      diagnostics_raw_contract_failure 'Kubernetes status is malformed'
      return
      ;;
  esac
}

validate_diagnostics_kubernetes_capture() {
  local path="$1"
  local -a lines=()
  validate_diagnostics_private_file \
    "${path}" "${DIAGNOSTICS_RAW_MAX_FILE_BYTES}" || return
  mapfile -t lines <"${path}"
  if ((${#lines[@]} < 2)) || [[ "${lines[0]}" != 'exit_code=0' ]] ||
    [[ "${lines[1]}" != 'truncated=true' &&
      "${lines[1]}" != 'truncated=false' ]]; then
    diagnostics_raw_contract_failure 'Kubernetes capture header is malformed'
    return
  fi
}

validate_diagnostics_raw_allowlist() (
  local source="$1" entry relative count=0 identity
  run_host_command find -P "${source}" -mindepth 1 -print0 | (
    while IFS= builtin read -r -d '' entry; do
      ((count += 1))
      ((count <= DIAGNOSTICS_RAW_MAX_ENTRIES)) ||
        diagnostics_raw_contract_failure 'too many raw entries' || return
      relative="${entry#"${source}/"}"
      case "${relative}" in
        capture-status.txt | platform.txt | kubernetes-status.txt | \
          kubernetes/nodes.txt | kubernetes/resources.txt | \
          kubernetes/events.txt | kubernetes/logs.txt)
          [[ ! -L "${entry}" && -f "${entry}" ]] ||
            diagnostics_raw_contract_failure \
              'allowlisted raw file is nonregular or a symlink' || return
          ;;
        kubernetes)
          [[ ! -L "${entry}" && -d "${entry}" ]] ||
            diagnostics_raw_contract_failure \
              'Kubernetes staging is unavailable or unsafe' || return
          identity="$(run_host_command stat -c '%u:%a' -- "${entry}")" || return
          [[ "${identity}" == "${EUID}:700" ]] ||
            diagnostics_raw_contract_failure \
              'Kubernetes staging mode is not private' || return
          ;;
        *)
          diagnostics_raw_contract_failure \
            'unexpected raw entry is forbidden'
          return
          ;;
      esac
    done
  )
)

validate_diagnostics_raw_evidence() {
  local source="$1" canonical status_kind kube_dir unexpected root_identity
  [[ -d "${source}" && ! -L "${source}" ]] ||
    diagnostics_raw_contract_failure 'source directory is unavailable or unsafe' || return
  canonical="$(run_host_command readlink -f -- "${source}")" || return
  if [[ "${canonical}" != "${source}" ]]; then
    diagnostics_raw_contract_failure 'source directory is not canonical'
    return
  fi
  case "${canonical}" in
    "${PLATFORM_STATE_DIR}"/*) ;;
    *)
      diagnostics_raw_contract_failure 'source directory is outside private state'
      return
      ;;
  esac
  root_identity="$(run_host_command stat -c '%u:%a' -- "${source}")" || return
  if [[ "${root_identity}" != "${EUID}:700" ]]; then
    diagnostics_raw_contract_failure 'source directory is not private'
    return
  fi
  validate_diagnostics_raw_allowlist "${source}" || return
  validate_diagnostics_capture_status "${source}/capture-status.txt" || return
  validate_diagnostics_platform_summary "${source}/platform.txt" || return
  status_kind="$(diagnostics_kubernetes_status_kind \
    "${source}/kubernetes-status.txt")" || return
  kube_dir="${source}/kubernetes"
  if [[ "${status_kind}" == collected ]]; then
    [[ -d "${kube_dir}" && ! -L "${kube_dir}" ]] ||
      diagnostics_raw_contract_failure \
        'successful Kubernetes status has no payload directory' || return
    validate_diagnostics_kubernetes_capture "${kube_dir}/nodes.txt" || return
    validate_diagnostics_kubernetes_capture "${kube_dir}/resources.txt" || return
    validate_diagnostics_kubernetes_capture "${kube_dir}/events.txt" || return
    validate_diagnostics_kubernetes_capture "${kube_dir}/logs.txt" || return
  elif [[ -e "${kube_dir}" || -L "${kube_dir}" ]]; then
    [[ -d "${kube_dir}" && ! -L "${kube_dir}" ]] ||
      diagnostics_raw_contract_failure \
        'empty Kubernetes staging is unavailable or unsafe' || return
    unexpected="$(run_host_command find -P "${kube_dir}" -mindepth 1 \
      -print -quit)" || return
    if [[ -n "${unexpected}" ]]; then
      diagnostics_raw_contract_failure \
        'refused Kubernetes inspection retained payload'
      return
    fi
  fi
}

diagnostics_raw_snapshot_digest() (
  local source="$1" relative path before after mode links size digest
  local count=0 total_bytes=0
  local -a entries=(
    capture-status.txt platform.txt kubernetes-status.txt kubernetes
    kubernetes/nodes.txt kubernetes/resources.txt kubernetes/events.txt
    kubernetes/logs.txt
  )
  {
    for relative in "${entries[@]}"; do
      path="${source}/${relative}"
      if [[ -L "${path}" ]]; then
        return 1
      elif [[ -f "${path}" ]]; then
        before="$(run_host_command stat -c '%a:%h:%s' -- "${path}")" || return
        IFS=: builtin read -r mode links size <<<"${before}"
        [[ "${size}" =~ ^[0-9]+$ ]] || return 1
        if ((10#${size} > DIAGNOSTICS_RAW_MAX_FILE_BYTES || \
          total_bytes + 10#${size} > DIAGNOSTICS_RAW_MAX_TOTAL_BYTES)); then
          return 1
        fi
        digest="$(run_host_command head -c \
          "$((DIAGNOSTICS_RAW_MAX_FILE_BYTES + 1))" -- "${path}" |
          diagnostics_stream_sha256)" || return
        after="$(run_host_command stat -c '%a:%h:%s' -- "${path}")" || return
        [[ "${before}" == "${after}" ]] || return 1
        ((count += 1, total_bytes += 10#${size}))
        builtin printf '%s\0file\0%s\0%s\0%s\0' \
          "${relative}" "${mode}" "${size}" "${digest}"
      elif [[ -d "${path}" ]]; then
        mode="$(run_host_command stat -c '%a' -- "${path}")" || return
        builtin printf '%s\0directory\0%s\0' "${relative}" "${mode}"
      fi
    done
    builtin printf 'files\0%s\0bytes\0%s\0' "${count}" "${total_bytes}"
  } | diagnostics_stream_sha256
)

publish_diagnostics_checksum_file() {
  local checksum="$1" final_checksum="$2"
  run_host_command mv -f -- "${checksum}" "${final_checksum}"
}

diagnostics_after_pair_publication_hook() {
  :
}

publish_diagnostics_archive() (
  local source="${1:-$(diagnostics_raw_directory)}"
  local final_archive final_checksum staging snapshot archive checksum status=0
  local raw_digest snapshot_digest current_digest cp_path
  local publication_complete=false
  invalidate_published_diagnostics || return
  verify_diagnostics_source_identity || return
  validate_diagnostics_raw_evidence "${source}" || return
  raw_digest="$(diagnostics_raw_snapshot_digest "${source}")" || return
  final_archive="$(prepare_state_file \
    "${DIAGNOSTICS_ARCHIVE_RELATIVE}")" || return
  final_checksum="$(prepare_state_file \
    "${DIAGNOSTICS_CHECKSUM_RELATIVE}")" || return
  ensure_state_directory diagnostics || return
  staging="$(run_host_command mktemp -d \
    "${PLATFORM_STATE_DIR}/diagnostics/.publish.XXXXXXXX")" || return
  # ShellCheck does not associate nested cleanup functions with EXIT traps.
  # shellcheck disable=SC2317,SC2329
  cleanup() {
    status=$?
    trap - EXIT
    run_host_command rm -rf -- "${staging}" >/dev/null 2>&1 || status=1
    if [[ "${publication_complete}" != true ]]; then
      invalidate_published_diagnostics >/dev/null 2>&1 || status=1
    fi
    builtin exit "${status}"
  }
  trap cleanup EXIT
  run_host_command chmod 0700 -- "${staging}" || return
  snapshot="${staging}/raw"
  run_host_command mkdir -- "${snapshot}" || return
  run_host_command chmod 0700 -- "${snapshot}" || return
  cp_path="$(host_command_path cp)" || return
  run_host_command timeout --signal=TERM --kill-after=5s 30s \
    "${cp_path}" -a -- "${source}/." "${snapshot}/" || return
  validate_diagnostics_raw_evidence "${snapshot}" || return
  snapshot_digest="$(diagnostics_raw_snapshot_digest "${snapshot}")" || return
  [[ "${snapshot_digest}" == "${raw_digest}" ]] || {
    diagnostics_raw_contract_failure 'raw evidence changed during snapshot'
    return
  }
  validate_diagnostics_raw_evidence "${source}" || return
  current_digest="$(diagnostics_raw_snapshot_digest "${source}")" || return
  [[ "${current_digest}" == "${raw_digest}" ]] || {
    diagnostics_raw_contract_failure 'raw evidence changed during snapshot'
    return
  }
  archive="${staging}/platform-diagnostics.zip"
  checksum="${archive}.sha256"
  (
    builtin cd "${PLATFORM_ROOT}/tools/artifacts/archive" || return
    prepare_diagnostics_go_environment
    run_managed_tool_bounded 120s go run . pack \
      --source "${snapshot}" --output "${archive}"
    run_managed_tool_bounded 120s go run . verify --archive "${archive}"
  ) >/dev/null
  validate_diagnostics_raw_evidence "${snapshot}" || return
  current_digest="$(diagnostics_raw_snapshot_digest "${snapshot}")" || return
  [[ "${current_digest}" == "${snapshot_digest}" ]] || {
    diagnostics_raw_contract_failure 'private raw snapshot changed during pack'
    return
  }
  validate_diagnostics_raw_evidence "${source}" || return
  current_digest="$(diagnostics_raw_snapshot_digest "${source}")" || return
  [[ "${current_digest}" == "${raw_digest}" ]] || {
    diagnostics_raw_contract_failure 'raw evidence changed during pack'
    return
  }
  verify_diagnostics_source_identity || return
  [[ -f "${archive}" && ! -L "${archive}" &&
    -f "${checksum}" && ! -L "${checksum}" ]] || return 1
  run_host_command chmod 0600 -- "${archive}" "${checksum}" || return
  prepare_state_file "${DIAGNOSTICS_ARCHIVE_RELATIVE}" >/dev/null || return
  prepare_state_file "${DIAGNOSTICS_CHECKSUM_RELATIVE}" >/dev/null || return
  verify_diagnostics_source_identity || return
  run_host_command mv -f -- "${archive}" "${final_archive}" || return
  publish_diagnostics_checksum_file "${checksum}" "${final_checksum}" || return
  diagnostics_after_pair_publication_hook || return
  verify_diagnostics_source_identity || return
  validate_diagnostics_raw_evidence "${source}" || return
  current_digest="$(diagnostics_raw_snapshot_digest "${source}")" || return
  [[ "${current_digest}" == "${raw_digest}" ]] || {
    diagnostics_raw_contract_failure 'raw evidence changed during publication'
    return
  }
  run_host_command rm -rf -- "${staging}" || return
  publication_complete=true
  trap - EXIT
)
