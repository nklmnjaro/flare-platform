#!/bin/bash -p
set -euo pipefail

DOCTOR_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${DOCTOR_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] || DOCTOR_SOURCE_DIR=.

# shellcheck source=../common/env.sh
builtin source "${DOCTOR_SOURCE_DIR}/../common/env.sh"
# shellcheck source=../common/tooling.sh
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
# shellcheck source=environment-profile.sh
builtin source "${PLATFORM_ROOT}/tools/bootstrap/environment-profile.sh"
unset DOCTOR_SOURCE_DIR

base_only=false
machine=false

parse_arguments() {
  case "${1:-}" in
    "") ;;
    --base-only) base_only=true ;;
    --machine) machine=true ;;
    *)
      printf 'FAIL  doctor        usage: doctor.sh [--base-only|--machine]\n' >&2
      return 2
      ;;
  esac
  if [[ -n "${2:-}" ]]; then
    printf 'FAIL  doctor        usage: doctor.sh [--base-only|--machine]\n' >&2
    return 2
  fi
}

render_machine_evidence() (
  local work token temporary line
  environment_profile_create_owned_workspace evidence \
    "${ENVIRONMENT_PROFILE_TRUSTED_MKDIR_PATH}" || return
  work="${ENVIRONMENT_PROFILE_OWNED_WORKSPACE}"
  token="${ENVIRONMENT_PROFILE_OWNED_TOKEN}"
  trap 'environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${ENVIRONMENT_PROFILE_TRUSTED_RM_PATH}" \
    >/dev/null 2>&1 || true' EXIT
  temporary="${work}/environment.env"
  environment_profile_render_evidence >"${temporary}" || return
  if ! environment_profile_validate_evidence "${temporary}"; then
    environment_profile_fail evidence "generated environment evidence is invalid"
    return
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}"
  done <"${temporary}"
  environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${ENVIRONMENT_PROFILE_TRUSTED_RM_PATH}" || return
  work=""
)

render_human_result() {
  printf 'PASS  platform      Linux amd64 capability profile\n'
  printf 'PASS  bash          GNU Bash %s job control, coproc, and wait\n' \
    "${ENVIRONMENT_PROFILE_BASH_VERSION}"
  printf 'PASS  curl          curl %s bounded HTTP/HTTPS transfer surface\n' \
    "${ENVIRONMENT_PROFILE_CURL_VERSION}"
  printf 'PASS  core-utils    hash/link/stat/temp/compare/FIFO/cleanup behavior\n'
  printf 'PASS  tar           GNU tar %s deterministic ustar stream\n' \
    "${ENVIRONMENT_PROFILE_TAR_VERSION}"
  printf 'PASS  timeout       GNU coreutils %s foreground TERM/KILL bound\n' \
    "${ENVIRONMENT_PROFILE_TIMEOUT_VERSION}"
  printf 'PASS  process-state Linux /proc stat visibility\n'
  [[ "${base_only}" != true ]] || return 0
  printf 'PASS  docker        client=%s server=%s api=%s/%s linux/amd64\n' \
    "${ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION}" \
    "${ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION}" \
    "${ENVIRONMENT_PROFILE_DOCKER_CLIENT_API}" \
    "${ENVIRONMENT_PROFILE_DOCKER_SERVER_API}"
  printf 'PASS  docker-surface advertised stdin/network/pull/cache/plain flags\n'
  printf 'PASS  docker-target local-unix frozen fingerprint=%s builder-contract=daemon-default-required\n' \
    "${DOCKER_TARGET_FINGERPRINT}"
  printf 'INFO  buildkit      result execution is proved by make verify-runtime\n'
  if [[ "${ENVIRONMENT_PROFILE_PROJECT_STATE}" == ready_for_bootstrap ]]; then
    printf 'INFO  project       READY_FOR_BOOTSTRAP; run make bootstrap\n'
    return 0
  fi
  printf 'PASS  project       READY Aqua=%s kind=%s kubectl=%s\n' \
    "${ENVIRONMENT_PROFILE_AQUA_IDENTITY}" \
    "${ENVIRONMENT_PROFILE_KIND_IDENTITY}" \
    "${ENVIRONMENT_PROFILE_KUBECTL_IDENTITY}"
}

main() {
  parse_arguments "$@" || return
  if [[ "${machine}" == true ]]; then
    environment_profile_run false true || return
    render_machine_evidence
    return
  fi
  environment_profile_run "${base_only}" false || return
  render_human_result
}

main "$@"
