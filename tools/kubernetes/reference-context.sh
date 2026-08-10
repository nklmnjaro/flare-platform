#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../common/env.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../common/env.sh" || {
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
}

export LC_ALL=C

REFERENCE_CONTEXT="${PLATFORM_STATE_DIR}/reference/context"
REFERENCE_MANIFEST="${PLATFORM_STATE_DIR}/reference/context.manifest.tsv"
REFERENCE_DOCKERFILE="${PLATFORM_ROOT}/kubernetes/reference/Dockerfile"
MANIFEST_HEADER=$'path\tmode\tsize\tsha256'

context_failure() {
  printf 'FAIL  reference-context %s\n' "$1" >&2 || return
  return 1
}

resolve_context_directory() {
  local context="$1"
  if [[ -L "${context}" ]]; then
    context_failure 'context directory must not be a symlink' || return
  fi
  if [[ ! -d "${context}" ]]; then
    context_failure 'context directory is missing or not a directory' || return
  fi
  (cd -- "${context}" && pwd -P) || {
    context_failure 'unable to resolve context directory' || return
  }
}

resolve_manifest_file() {
  local manifest="$1"
  local basename parent resolved_parent
  if [[ -L "${manifest}" ]]; then
    context_failure 'manifest must not be a symlink' || return
  fi
  if [[ ! -f "${manifest}" ]]; then
    context_failure 'manifest is missing or not a regular file' || return
  fi
  parent="$(dirname -- "${manifest}")" || return
  resolved_parent="$(cd -- "${parent}" && pwd -P)" || {
    context_failure 'unable to resolve manifest parent' || return
  }
  basename="$(basename -- "${manifest}")" || return
  printf '%s/%s\n' "${resolved_parent}" "${basename}" || return
}

manifest_line() {
  local context="$1"
  local name="$2"
  local mode sha size
  mode="$(stat -c '%a' "${context}/${name}")" || return
  size="$(stat -c '%s' "${context}/${name}")" || return
  sha="$(sha256sum -- "${context}/${name}" | awk '{print $1}')" || return
  [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\t0%s\t%s\t%s\n' "${name}" "${mode}" "${size}" "${sha}" || return
}

verify_context_entries() {
  local context="$1"
  local entry name
  local -A seen=()
  local -a entries=()
  shopt -s dotglob nullglob || return
  entries=("${context}"/*)
  shopt -u dotglob nullglob || return
  for entry in "${entries[@]}"; do
    name="${entry#"${context}"/}"
    if [[ -L "${entry}" ]]; then
      printf 'FAIL  reference-context symlink path: %q\n' "${name}" >&2 || return
      return 1
    fi
    if [[ ! -f "${entry}" ]]; then
      printf 'FAIL  reference-context special path: %q\n' "${name}" >&2 || return
      return 1
    fi
    if [[ "${name}" != Dockerfile && "${name}" != server ]]; then
      printf 'FAIL  reference-context unexpected path: %q\n' "${name}" >&2 || return
      return 1
    fi
    seen["${name}"]=true
  done
  for name in Dockerfile server; do
    if [[ "${seen[${name}]:-false}" != true ]]; then
      printf 'FAIL  reference-context missing path: %s\n' "${name}" >&2 || return
      return 1
    fi
  done
}

verify_context_manifest() {
  local context="$1"
  local manifest="$2"
  local dockerfile_line manifest_bytes manifest_lines server_line
  local -a lines=()
  manifest_bytes="$(wc -c <"${manifest}")" || return
  if [[ "${manifest_bytes}" -gt 1024 ]]; then
    context_failure 'manifest exceeds 1024-byte boundary' || return
  fi
  mapfile -t lines <"${manifest}" || return
  manifest_lines="$(wc -l <"${manifest}")" || return
  if [[ "${manifest_lines}" -ne 3 || "${#lines[@]}" -ne 3 ]]; then
    context_failure 'manifest must contain three newline-terminated records' || return
  fi
  dockerfile_line="$(manifest_line "${context}" Dockerfile)" || return
  server_line="$(manifest_line "${context}" server)" || return
  if [[ "${lines[0]}" != "${MANIFEST_HEADER}" ||
    "${lines[1]}" != "${dockerfile_line}" || "${lines[2]}" != "${server_line}" ]]; then
    context_failure 'manifest content does not match sorted context metadata' || return
  fi
}

verify_context_modes() {
  local context="$1"
  local dockerfile_mode server_mode
  dockerfile_mode="$(stat -c '%a' "${context}/Dockerfile")" || return
  server_mode="$(stat -c '%a' "${context}/server")" || return
  if [[ "${dockerfile_mode}" != 644 ]]; then
    context_failure 'mode mismatch: Dockerfile must be 0644' || return
  fi
  if [[ "${server_mode}" != 755 ]]; then
    context_failure 'mode mismatch: server must be 0755' || return
  fi
}

verify_context() {
  local requested_context="${1:-${REFERENCE_CONTEXT}}"
  local requested_manifest="${2:-${REFERENCE_MANIFEST}}"
  local context manifest
  context="$(resolve_context_directory "${requested_context}")" || return
  manifest="$(resolve_manifest_file "${requested_manifest}")" || return
  if [[ "${manifest}" == "${context}"/* ]]; then
    context_failure 'manifest must remain outside the Docker build context' || return
  fi
  verify_context_entries "${context}" || return
  verify_context_modes "${context}" || return
  verify_context_manifest "${context}" "${manifest}" || return
}

context_identity_sha256() {
  local context="$1" manifest="$2" digest
  verify_context "${context}" "${manifest}" || return
  digest="$(sha256sum -- "${manifest}" | awk '{print $1}')" || return
  if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
    context_failure 'manifest SHA-256 is malformed' || return
  fi
  printf '%s\n' "${digest}" || return
}

assert_context_identity() {
  local context="$1" manifest="$2" expected="$3" actual
  if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
    context_failure 'expected context identity is malformed' || return
  fi
  actual="$(context_identity_sha256 "${context}" "${manifest}")" || return
  if [[ "${actual}" != "${expected}" ]]; then
    context_failure 'context identity changed across guarded operation' || return
  fi
}

write_manifest() {
  local context="$1"
  local target="$2"
  {
    printf '%s\n' "${MANIFEST_HEADER}" || return
    manifest_line "${context}" Dockerfile || return
    manifest_line "${context}" server || return
  } >"${target}" || return
}

stage_context() {
  local server_source="$1"
  local dockerfile_target manifest_target manifest_temporary server_target
  if [[ -L "${server_source}" || ! -f "${server_source}" ]]; then
    context_failure 'server source must be a non-symlink regular file' || return
  fi
  reset_state_directory "reference/context" || return
  dockerfile_target="$(prepare_state_file "reference/context/Dockerfile")" || return
  server_target="$(prepare_state_file "reference/context/server")" || return
  manifest_target="$(prepare_state_file "reference/context.manifest.tsv")" || return
  cp -- "${REFERENCE_DOCKERFILE}" "${dockerfile_target}" || return
  cp -- "${server_source}" "${server_target}" || return
  chmod 0644 "${dockerfile_target}" || return
  chmod 0755 "${server_target}" || return
  manifest_temporary="$(mktemp "${PLATFORM_STATE_DIR}/reference/.context-manifest.XXXXXXXX")" || return
  if ! write_manifest "${REFERENCE_CONTEXT}" "${manifest_temporary}"; then
    rm -f -- "${manifest_temporary}" || return
    return 1
  fi
  manifest_target="$(prepare_state_file "reference/context.manifest.tsv")" || {
    rm -f -- "${manifest_temporary}" || return
    return 1
  }
  if ! mv -fT -- "${manifest_temporary}" "${manifest_target}"; then
    rm -f -- "${manifest_temporary}" || return
    return 1
  fi
  verify_context "${REFERENCE_CONTEXT}" "${REFERENCE_MANIFEST}" || return
}

stage_context_snapshot() {
  local source="$1" source_manifest="$2" snapshot="$3" manifest="$4" expected="$5"
  local dockerfile_target server_target
  local -a entries=()
  if [[ -L "${snapshot}" || ! -d "${snapshot}" || -L "${manifest}" || ! -f "${manifest}" ]]; then
    context_failure 'snapshot paths are missing or unsafe' || return
  fi
  shopt -s dotglob nullglob || return
  entries=("${snapshot}"/*)
  shopt -u dotglob nullglob || return
  if ((${#entries[@]})); then
    context_failure 'snapshot directory must begin empty' || return
  fi
  assert_context_identity "${source}" "${source_manifest}" "${expected}" || return
  dockerfile_target="${snapshot}/Dockerfile"
  server_target="${snapshot}/server"
  cp -- "${source}/Dockerfile" "${dockerfile_target}" || return
  cp -- "${source}/server" "${server_target}" || return
  chmod 0644 "${dockerfile_target}" || return
  chmod 0755 "${server_target}" || return
  write_manifest "${snapshot}" "${manifest}" || return
  assert_context_identity "${snapshot}" "${manifest}" "${expected}" || return
  assert_context_identity "${source}" "${source_manifest}" "${expected}" || return
}

expect_context_failure() {
  local label="$1"
  local expected="$2"
  local context="$3"
  local manifest="$4"
  local output status
  if output="$(verify_context "${context}" "${manifest}" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [[ "${status}" -ne 1 || "${output}" != "${expected}" ]]; then
    printf 'FAIL  reference-context %s failed with status=%s output=%q\n' \
      "${label}" "${status}" "${output}" >&2 || return
    return 1
  fi
  printf 'PASS  reference-red %s\n' "${label}" || return
}

expect_context_identity_failure() {
  local label="$1" context="$2" manifest="$3" expected="$4"
  local output status
  if output="$(assert_context_identity "${context}" "${manifest}" "${expected}" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [[ "${status}" -ne 1 ||
    "${output}" != 'FAIL  reference-context context identity changed across guarded operation' ]]; then
    printf 'FAIL  reference-context %s failed with status=%s output=%q\n' \
      "${label}" "${status}" "${output}" >&2 || return
    return 1
  fi
  printf 'PASS  reference-red %s\n' "${label}" || return
}

prove_context_contract() (
  local context="${PLATFORM_STATE_DIR}/reference/context-proof"
  local manifest="${PLATFORM_STATE_DIR}/reference/context-proof.manifest.tsv"
  local snapshot="${PLATFORM_STATE_DIR}/reference/context-snapshot-proof"
  local snapshot_manifest="${PLATFORM_STATE_DIR}/reference/context-snapshot-proof.manifest.tsv"
  local baseline_identity dockerfile server unexpected
  trap 'rm -rf -- "${context}" "${snapshot}"; rm -f -- "${manifest}" "${snapshot_manifest}"' EXIT || return
  reset_state_directory "reference/context-proof" || return
  reset_state_directory "reference/context-snapshot-proof" || return
  manifest="$(prepare_state_file "reference/context-proof.manifest.tsv")" || return
  snapshot_manifest="$(prepare_state_file \
    "reference/context-snapshot-proof.manifest.tsv")" || return
  : >"${snapshot_manifest}" || return
  dockerfile="$(prepare_state_file "reference/context-proof/Dockerfile")" || return
  server="$(prepare_state_file "reference/context-proof/server")" || return
  unexpected="$(prepare_state_file "reference/context-proof/unexpected.txt")" || return
  printf 'FROM scratch\nCOPY server /server\n' >"${dockerfile}" || return
  printf 'fixture-server\n' >"${server}" || return
  chmod 0644 "${dockerfile}" || return
  chmod 0755 "${server}" || return
  write_manifest "${context}" "${manifest}" || return
  verify_context "${context}" "${manifest}" || return
  baseline_identity="$(context_identity_sha256 "${context}" "${manifest}")" || return
  stage_context_snapshot "${context}" "${manifest}" "${snapshot}" \
    "${snapshot_manifest}" "${baseline_identity}" || return
  printf 'SERVER\n' >"${snapshot}/server" || return
  expect_context_failure changed-snapshot-file \
    'FAIL  reference-context manifest content does not match sorted context metadata' \
    "${snapshot}" "${snapshot_manifest}" || return
  printf 'FROM busybox\nCOPY server /server\n' >"${dockerfile}" || return
  write_manifest "${context}" "${manifest}" || return
  verify_context "${context}" "${manifest}" || return
  expect_context_identity_failure coherent-context-change \
    "${context}" "${manifest}" "${baseline_identity}" || return
  printf 'FROM scratch\nCOPY server /server\n' >"${dockerfile}" || return
  write_manifest "${context}" "${manifest}" || return
  assert_context_identity "${context}" "${manifest}" "${baseline_identity}" || return
  printf 'canary\n' >"${unexpected}" || return
  expect_context_failure unexpected-file \
    'FAIL  reference-context unexpected path: unexpected.txt' "${context}" "${manifest}" || return
  rm -f -- "${unexpected}" "${server}" || return
  ln -s Dockerfile "${server}" || return
  expect_context_failure symlink \
    'FAIL  reference-context symlink path: server' "${context}" "${manifest}" || return
  rm -f -- "${server}" || return
  mkfifo "${server}" || return
  expect_context_failure special-file \
    'FAIL  reference-context special path: server' "${context}" "${manifest}" || return
  printf 'PASS  reference-context exact two-file context contract proved\n' || return
)

main() {
  case "${1:-}" in
    stage)
      [[ $# -eq 2 ]] || {
        context_failure 'usage: reference-context.sh stage SERVER_BINARY' || return
      }
      stage_context "$2" || return
      ;;
    verify)
      if [[ $# -eq 1 ]]; then
        verify_context || return
      elif [[ $# -eq 3 ]]; then
        verify_context "$2" "$3" || return
      else
        context_failure 'usage: reference-context.sh verify [CONTEXT MANIFEST]' || return
      fi
      ;;
    prove)
      [[ $# -eq 1 ]] || {
        context_failure 'usage: reference-context.sh prove' || return
      }
      prove_context_contract || return
      ;;
    *)
      context_failure 'usage: reference-context.sh <stage|verify|prove>' || return
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit $?
fi
