#!/bin/bash -p
set -euo pipefail

PROVE_ENVIRONMENT_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
[[ "${PROVE_ENVIRONMENT_SOURCE_DIR}" != "${BASH_SOURCE[0]}" ]] ||
  PROVE_ENVIRONMENT_SOURCE_DIR=.

# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
builtin source "${PROVE_ENVIRONMENT_SOURCE_DIR}/../common/env.sh"
# shellcheck source=../common/tooling.sh
# shellcheck disable=SC1091
builtin source "${PLATFORM_ROOT}/tools/common/tooling.sh"
# shellcheck source=environment-profile.sh
# shellcheck disable=SC1091
builtin source "${PLATFORM_ROOT}/tools/bootstrap/environment-profile.sh"
unset PROVE_ENVIRONMENT_SOURCE_DIR

WORK_DIR=""
WORK_TOKEN=""
WORK_RM_PATH=""
DOCKER_TEST_CONTRACT="flare-platform-docker-target-fixture-v1"
DOCKER_TEST_TOKEN="flare-platform-environment-proof-owner-v1"

cleanup_proof_workspace() {
  [[ -n "${WORK_DIR}" && -n "${WORK_TOKEN}" && -n "${WORK_RM_PATH}" ]] || return
  environment_profile_remove_owned_workspace \
    "${WORK_DIR}" "${WORK_TOKEN}" "${WORK_RM_PATH}" >/dev/null 2>&1 || true
}

expect_profile_red() {
  local label="$1"
  local reason="$2"
  local output="${WORK_DIR}/${label}.out"
  local forbidden_marker="" line failure_lines=0 reason_lines=0 status=0
  shift 2
  if [[ "${1:-}" == --forbid-marker ]]; then
    [[ -n "${2:-}" ]] || return 2
    forbidden_marker="$2"
    shift 2
    [[ "${1:-}" == -- ]] || return 2
    shift
  fi
  if "$@" >"${output}" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "${status}" -eq 0 ]]; then
    printf 'FAIL  environment-red %s unexpectedly passed\n' "${label}" >&2
    return 1
  fi
  if [[ "${status}" -ne 1 ]]; then
    printf 'FAIL  environment-red %s returned %s; expected 1\n' \
      "${label}" "${status}" >&2
    run_host_command sed -n '1,12p' "${output}" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" != FAIL\ \ * ]] || ((failure_lines += 1))
    if [[ "${line}" == FAIL\ \ *" ${reason}" ]]; then
      ((reason_lines += 1))
    fi
  done <"${output}"
  if [[ "${failure_lines}" -ne 1 || "${reason_lines}" -ne 1 ]]; then
    printf 'FAIL  environment-red %s missed exact reason: %s\n' \
      "${label}" "${reason}" >&2
    run_host_command sed -n '1,12p' "${output}" >&2
    return 1
  fi
  if [[ -n "${forbidden_marker}" &&
    (-e "${forbidden_marker}" || -L "${forbidden_marker}") ]]; then
    printf 'FAIL  environment-red %s reached forbidden mutation marker\n' \
      "${label}" >&2
    return 1
  fi
  printf 'PASS  environment-red %s rejected for exact capability\n' "${label}"
}

expect_invalid_evidence() {
  local label="$1"
  local evidence="$2"
  if environment_profile_validate_evidence "${evidence}" >/dev/null 2>&1; then
    printf 'FAIL  evidence-red %s unexpectedly passed\n' "${label}" >&2
    return 1
  fi
  printf 'PASS  evidence-red %s rejected\n' "${label}"
}

write_fake_zero() {
  local target="$1"
  run_host_command cat >"${target}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
printf '%s\n' "${0##*/}:$*" >>"${ZERO_FIXTURE_MARKER:?}"
exit 0
FAKE
  run_host_command chmod 0755 "${target}"
}

write_fake_zero_sleep() {
  local target="$1"
  run_host_command cat >"${target}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
if [[ -e "${ZERO_SLEEP_INVOCATION_MARKER:?}" ]]; then
  printf 'second invocation:%s\n' "$*" >"${ZERO_SLEEP_FORBIDDEN_MARKER:?}"
else
  printf 'first invocation:%s\n' "$*" >"${ZERO_SLEEP_INVOCATION_MARKER}"
fi
exit 0
FAKE
  run_host_command chmod 0755 "${target}"
}

prove_fake_zero_rejected() {
  local fake="${WORK_DIR}/fake-zero"
  local marker="${WORK_DIR}/fake-zero.marker"
  write_fake_zero "${fake}"
  export ZERO_FIXTURE_MARKER="${marker}"
  expect_profile_red fake-zero-bash 'GNU Bash identity is malformed' \
    environment_profile_check_bash "${fake}"
  expect_profile_red fake-zero-tar 'GNU tar identity is malformed' \
    environment_profile_check_tar \
    "${fake}" "$(builtin type -P stat)" "$(builtin type -P od)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)" \
    "$(builtin type -P chmod)" "$(builtin type -P cmp)"
  expect_profile_red fake-zero-timeout 'GNU timeout identity is malformed' \
    environment_profile_check_timeout "${fake}" "${fake}"
  expect_profile_red fake-zero-docker 'Docker identity response is malformed' \
    environment_profile_check_docker_capabilities "${fake}" "$(type -P timeout)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  expect_profile_red fake-zero-curl 'curl identity is malformed' \
    environment_profile_check_curl "${fake}"
  [[ "$(run_host_command wc -l <"${marker}")" -eq 5 ]]
  printf 'PASS  environment-red zero-returning command names prove no capability\n'
}

prove_curl_surface_red() {
  local fake="${WORK_DIR}/limited-curl"
  run_host_command cat >"${fake}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
[[ "${1:-}" == --disable ]] || exit 64
shift
if [[ "${1:-}" == --version ]]; then
  printf 'curl 9.0.0 test\nProtocols: http https\n'
  exit 0
fi
if [[ "${1:-}" == --help && "${2:-}" == all ]]; then
  printf '%s\n' --fail --location --proto --proto-redir --tlsv1.2 \
    --connect-timeout --max-time --max-filesize --retry --output --silent \
    --show-error
  exit 0
fi
exit 64
FAKE
  run_host_command chmod 0755 "${fake}"
  expect_profile_red curl-options \
    'required bounded HTTP transfer surface is unavailable' \
    environment_profile_check_curl "${fake}"
  printf 'PASS  environment-red curl protocols and consumed flags are exact\n'
}

prove_core_utility_red() {
  local fake="${WORK_DIR}/fake-core-utility"
  local marker="${WORK_DIR}/fake-core-utility.marker"
  local -a actual probe
  actual=(
    "$(builtin type -P sha256sum)" "$(builtin type -P readlink)"
    "$(builtin type -P stat)" "$(builtin type -P mktemp)"
    "$(builtin type -P cmp)" "$(builtin type -P diff)"
    "$(builtin type -P chmod)" "$(builtin type -P ln)"
    "$(builtin type -P mkfifo)" "$(builtin type -P mkdir)"
    "$(builtin type -P od)" "$(builtin type -P rm)"
  )
  write_fake_zero "${fake}"
  export ZERO_FIXTURE_MARKER="${marker}"
  probe=("${actual[@]}")
  probe[0]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-sha \
    'sha256sum grammar is unavailable' environment_profile_check_core_utilities \
    "${probe[@]}"
  probe=("${actual[@]}")
  probe[1]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-readlink \
    'readlink -n/-f semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[2]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-stat \
    'stat creation-mode semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[3]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-mktemp \
    'mktemp directory template is unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[4]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-cmp \
    'cmp inequality semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[5]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-diff \
    'diff inequality semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[6]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-chmod \
    'stat or chmod semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[7]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-ln \
    'readlink -n/-f semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[8]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-mkfifo \
    'mkfifo semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[9]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-mkdir \
    'mkdir ownership semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[10]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-od \
    'od byte semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  probe=("${actual[@]}")
  probe[11]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red core-rm \
    'rm cleanup semantics are unavailable' environment_profile_check_core_utilities \
    "${probe[@]}"
  prove_mktemp_cannot_select_cleanup_target "${actual[@]}"
  prove_mkdir_cannot_select_ownership_target "${actual[@]}"
  TMPDIR=/tmp/ environment_profile_check_core_utilities "${actual[@]}"
  printf 'PASS  environment-red core utility behavior is proved, not named\n'
}

prove_host_utility_pipeline_red() {
  local fake="${WORK_DIR}/fake-host-utility"
  local fake_sleep="${WORK_DIR}/fake-zero-sleep"
  local sleep_marker="${WORK_DIR}/fake-zero-sleep.marker"
  local sleep_forbidden="${WORK_DIR}/fake-zero-sleep.forbidden"
  local command_name reason
  local -a text_commands=(
    awk basename cat cut dirname grep head sed sort tail tee tr wc
  )
  local -a file_commands=(cp env find git gzip make mv)
  write_fake_zero "${fake}"
  export ZERO_FIXTURE_MARKER="${WORK_DIR}/fake-host-utility.marker"
  for command_name in "${text_commands[@]}"; do
    environment_profile_require_host_commands
    # Consumed by the sourced environment-profile module.
    # shellcheck disable=SC2034
    ENVIRONMENT_PROFILE_HOST_PATHS["${command_name}"]="${fake}"
    reason='bounded text utility semantics are unavailable'
    TMPDIR="${WORK_DIR}" expect_profile_red "host-zero-${command_name}" \
      "${reason}" environment_profile_check_host_utilities
  done
  for command_name in "${file_commands[@]}"; do
    environment_profile_require_host_commands
    # Consumed by the sourced environment-profile module.
    # shellcheck disable=SC2034
    ENVIRONMENT_PROFILE_HOST_PATHS["${command_name}"]="${fake}"
    reason='bounded file and command semantics are unavailable'
    TMPDIR="${WORK_DIR}" expect_profile_red "host-zero-${command_name}" \
      "${reason}" environment_profile_check_host_utilities
  done
  environment_profile_require_host_commands
  # shellcheck disable=SC2154
  ENVIRONMENT_PROFILE_HOST_PATHS[flock]="${fake}"
  TMPDIR="${WORK_DIR}" expect_profile_red host-zero-flock \
    'bounded flock descriptor semantics are unavailable' \
    environment_profile_check_host_utilities
  environment_profile_require_host_commands
  TMPDIR="${WORK_DIR}" environment_profile_check_host_utilities
  expect_profile_red host-zero-uname 'requires Linux x86_64; observed  ' \
    environment_profile_check_platform "${fake}"
  write_fake_zero_sleep "${fake_sleep}"
  ZERO_SLEEP_INVOCATION_MARKER="${sleep_marker}" \
    ZERO_SLEEP_FORBIDDEN_MARKER="${sleep_forbidden}" \
    expect_profile_red host-zero-sleep \
    'spawned job process-group visibility is unavailable' \
    --forbid-marker "${sleep_forbidden}" -- \
    environment_profile_prove_process_group \
    "${fake_sleep}" "${ENVIRONMENT_PROFILE_HOST_PATHS[timeout]}" \
    "${ENVIRONMENT_PROFILE_HOST_PATHS[bash]}"
  [[ "$(<"${sleep_marker}")" == 'first invocation:infinity' ]]
  environment_profile_prove_process_group \
    "${ENVIRONMENT_PROFILE_HOST_PATHS[sleep]}" \
    "${ENVIRONMENT_PROFILE_HOST_PATHS[timeout]}" \
    "${ENVIRONMENT_PROFILE_HOST_PATHS[bash]}"
  printf 'PASS  environment-red every declared host utility is behavioral\n'
}

prove_flock_function_shadow_rejected() {
  local marker="${WORK_DIR}/shadowed-flock.marker"
  local output="${WORK_DIR}/shadowed-flock.out" status=0
  (
    # The function is deliberately present before the host boundary is loaded.
    # shellcheck disable=SC2317,SC2329
    flock() { builtin printf 'executed\n' >"${marker}"; }
    builtin source "${PLATFORM_ROOT}/tools/common/env.sh"
    run_host_command flock --version
  ) >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]
  run_host_command grep -Fqx \
    'FAIL  host-command  flock: shadowed by shell function' "${output}"
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  printf 'PASS  host-red      caller flock function rejected with exact 69\n'
}

prove_lifecycle_state_flock_rejected() (
  local target="${WORK_DIR}/lease-host-current"
  local digest root owner_token owner_file lock_file owned=false
  local root_identity root_inode_identity owner_identity fake_identity
  local lock_identity alias_identity pinned_identity canonical entries
  local replacement_root_identity replacement_owner_identity
  local replacement_sentinel_identity saved_root_identity
  local replacement_owner replacement_sentinel saved_root replacement_saved
  local pinned_root alias_retired fake_retired owner_retired
  local root_directory_fd='' root_lock_fd='' cleanup_status=0
  local alias="/tmp/flare-platform-lease-alias-${BASHPID}"
  local scope fake lookup marker output status

  lifecycle_fixture_identity() {
    run_host_command stat -Lc '%d:%i:%u:%a:%h:%s' -- "$1"
  }
  lifecycle_fixture_inode_identity() {
    run_host_command stat -Lc '%d:%i:%u' -- "$1"
  }
  lifecycle_fixture_symlink_identity() {
    run_host_command stat -c '%d:%i:%u:%a:%h:%s' -- "$1"
  }
  close_lifecycle_fixture_descriptors() {
    if [[ "${root_lock_fd}" =~ ^[0-9]{1,4}$ ]]; then
      { exec {root_lock_fd}>&-; } 2>/dev/null || true
    fi
    if [[ "${root_directory_fd}" =~ ^[0-9]{1,4}$ ]]; then
      { exec {root_directory_fd}<&-; } 2>/dev/null || true
    fi
    root_lock_fd=''
    root_directory_fd=''
  }
  validate_persistent_lifecycle_root() {
    local candidate="$1" expected_inode="$2" expected_lock="$3"
    local candidate_entries candidate_canonical validation_status=0
    [[ "${candidate}" =~ ^/tmp/flare-platform-lifecycle-lease-[0-9a-f]{64}$ &&
      -d "${candidate}" && ! -L "${candidate}" &&
      -f "${candidate}/lock" && ! -L "${candidate}/lock" ]] || return 1
    [[ "$(lifecycle_fixture_inode_identity "${candidate}")" == "${expected_inode}" &&
    "$(run_host_command stat -Lc '%u:%a:%h' -- "${candidate}")" == "${EUID}:700:2" &&
    "$(lifecycle_fixture_identity "${candidate}/lock")" == "${expected_lock}" ]] || return 1
    candidate_canonical="$(run_host_command readlink -f -- "${candidate}")" ||
      return
    [[ "${candidate_canonical}" == "${candidate}" ]] || return 1
    candidate_entries="$(run_host_command find -H "${candidate}" -mindepth 1 \
      -maxdepth 1 -printf '%f\n' | run_host_command sort)" || return
    [[ "${candidate_entries}" == lock ]] || return 1
    exec {root_directory_fd}<"${candidate}" || return
    pinned_root="/proc/self/fd/${root_directory_fd}"
    [[ "$(lifecycle_fixture_inode_identity "${pinned_root}")" == "${expected_inode}" ]] || validation_status=1
    if ((validation_status == 0)); then
      exec {root_lock_fd}<>"${pinned_root}/lock" || validation_status=1
    fi
    if ((validation_status == 0)); then
      run_host_command flock --exclusive --nonblock "${root_lock_fd}" ||
        validation_status=1
    fi
    if ((validation_status == 0)); then
      [[ "$(lifecycle_fixture_identity "${pinned_root}/lock")" == "${expected_lock}" &&
      "$(lifecycle_fixture_inode_identity "${candidate}")" == "${expected_inode}" ]] || validation_status=1
    fi
    close_lifecycle_fixture_descriptors
    ((validation_status == 0))
  }
  cleanup_lifecycle_host_fixture() {
    [[ "${owned}" == true ]] || return 0
    [[ "${root}" =~ ^/tmp/flare-platform-lifecycle-lease-[0-9a-f]{64}$ &&
      -d "${root}" && ! -L "${root}" && -L "${alias}" &&
      -f "${owner_file}" && ! -L "${owner_file}" &&
      -f "${lock_file}" && ! -L "${lock_file}" &&
      -f "${fake}" && ! -L "${fake}" ]] || return 1
    [[ "$(lifecycle_fixture_identity "${root}")" == "${root_identity}" &&
    "$(lifecycle_fixture_inode_identity "${root}")" == "${root_inode_identity}" &&
    "$(lifecycle_fixture_identity "${owner_file}")" == "${owner_identity}" &&
    "$(lifecycle_fixture_identity "${lock_file}")" == "${lock_identity}" &&
    "$(lifecycle_fixture_identity "${fake}")" == "${fake_identity}" &&
    "$(lifecycle_fixture_symlink_identity "${alias}")" == "${alias_identity}" &&
    "$(<"${owner_file}")" == "${owner_token}" &&
    "$(run_host_command readlink -- "${alias}")" == "${root}" ]] ||
      return 1
    canonical="$(run_host_command readlink -f -- "${root}")" || return
    [[ "${canonical}" == "${root}" ]] || return 1

    exec {root_directory_fd}<"${root}" || return
    pinned_root="/proc/self/fd/${root_directory_fd}"
    pinned_identity="$(lifecycle_fixture_inode_identity "${pinned_root}")" || {
      close_lifecycle_fixture_descriptors
      return 1
    }
    [[ "${pinned_identity}" == "${root_inode_identity}" ]] || {
      close_lifecycle_fixture_descriptors
      return 1
    }
    exec {root_lock_fd}<>"${pinned_root}/lock" || {
      close_lifecycle_fixture_descriptors
      return 1
    }
    if ! run_host_command flock --exclusive --nonblock "${root_lock_fd}"; then
      close_lifecycle_fixture_descriptors
      return 1
    fi
    [[ "$(lifecycle_fixture_inode_identity "${root}")" == "${root_inode_identity}" &&
    "$(lifecycle_fixture_identity "${pinned_root}/lock")" == "${lock_identity}" &&
    "$(lifecycle_fixture_identity "${pinned_root}/.proof-owner")" == "${owner_identity}" &&
    "$(lifecycle_fixture_identity "${pinned_root}/flock")" == "${fake_identity}" ]] || {
      close_lifecycle_fixture_descriptors
      return 1
    }
    entries="$(run_host_command find -H "${pinned_root}" -mindepth 1 \
      -maxdepth 1 -printf '%f\n' | run_host_command sort)" || {
      close_lifecycle_fixture_descriptors
      return 1
    }
    [[ "${entries}" == $'.proof-owner\nflock\nlock' ]] || {
      close_lifecycle_fixture_descriptors
      return 1
    }

    cleanup_status=0
    run_host_command mv -T -- "${alias}" "${alias_retired}" || cleanup_status=$?
    ((cleanup_status != 0)) ||
      run_host_command mv -T -- "${pinned_root}/flock" "${fake_retired}" ||
      cleanup_status=$?
    ((cleanup_status != 0)) ||
      run_host_command mv -T -- "${pinned_root}/.proof-owner" \
        "${owner_retired}" || cleanup_status=$?
    if ((cleanup_status == 0)); then
      [[ "$(lifecycle_fixture_symlink_identity "${alias_retired}")" == "${alias_identity}" &&
      "$(lifecycle_fixture_identity "${fake_retired}")" == "${fake_identity}" &&
      "$(lifecycle_fixture_identity "${owner_retired}")" == "${owner_identity}" ]] || cleanup_status=1
    fi
    if ((cleanup_status == 0)); then
      entries="$(run_host_command find -H "${pinned_root}" -mindepth 1 \
        -maxdepth 1 -printf '%f\n')" || cleanup_status=1
      [[ "${entries}" == lock ]] || cleanup_status=1
    fi
    close_lifecycle_fixture_descriptors
    ((cleanup_status == 0)) || return "${cleanup_status}"
    validate_persistent_lifecycle_root \
      "${root}" "${root_inode_identity}" "${lock_identity}" || return
    owned=false
  }
  trap cleanup_lifecycle_host_fixture EXIT
  prepare_doctor_fixture "${target}"
  digest="$({
    builtin printf 'flare-platform-host-path-proof-v2\0%s\0%s\0' \
      "${PLATFORM_ROOT}" "${EUID}" | run_host_command sha256sum --
  })" || return
  [[ "${digest}" =~ ^([0-9a-f]{64})\ \ -$ ]] || return 1
  root="/tmp/flare-platform-lifecycle-lease-${BASH_REMATCH[1]}"
  owner_token="proof-${BASH_REMATCH[1]}"
  owner_file="${root}/.proof-owner"
  lock_file="${root}/lock"
  fake="${root}/flock"
  saved_root="${WORK_DIR}/lease-host-original"
  replacement_saved="${WORK_DIR}/lease-host-replacement"
  alias_retired="${WORK_DIR}/lease-host-alias.retired"
  fake_retired="${WORK_DIR}/lease-host-flock.retired"
  owner_retired="${WORK_DIR}/lease-host-owner.retired"
  [[ ! -e "${alias}" && ! -L "${alias}" && ! -e "${saved_root}" &&
    ! -L "${saved_root}" && ! -e "${replacement_saved}" &&
    ! -L "${replacement_saved}" && ! -e "${alias_retired}" &&
    ! -L "${alias_retired}" && ! -e "${fake_retired}" &&
    ! -L "${fake_retired}" && ! -e "${owner_retired}" &&
    ! -L "${owner_retired}" ]] ||
    return 1
  if [[ ! -e "${root}" && ! -L "${root}" ]]; then
    (umask 077 && run_host_command mkdir -- "${root}") || return
    (umask 077 && : >"${lock_file}")
  fi
  [[ -d "${root}" && ! -L "${root}" && -f "${lock_file}" &&
    ! -L "${lock_file}" ]] || return 1
  root_inode_identity="$(lifecycle_fixture_inode_identity "${root}")"
  lock_identity="$(lifecycle_fixture_identity "${lock_file}")"
  [[ "${lock_identity}" == *":${EUID}:600:1:0" ]]
  validate_persistent_lifecycle_root \
    "${root}" "${root_inode_identity}" "${lock_identity}"
  (umask 077 && printf '%s\n' "${owner_token}" >"${owner_file}")
  run_host_command cat >"${fake}" <<'FAKE'
#!/bin/bash -p
builtin printf 'executed\n' >"${LEASE_FLOCK_MARKER:?}"
exit 0
FAKE
  run_host_command chmod 0755 "${fake}"
  run_host_command ln -s -- "${root}" "${alias}"
  root_identity="$(lifecycle_fixture_identity "${root}")"
  owner_identity="$(lifecycle_fixture_identity "${owner_file}")"
  fake_identity="$(lifecycle_fixture_identity "${fake}")"
  alias_identity="$(lifecycle_fixture_symlink_identity "${alias}")"
  [[ "${root_identity}" == *":${EUID}:700:2:"* &&
    "${owner_identity}" == *":${EUID}:600:1:"* &&
    "${fake_identity}" == *":${EUID}:755:1:"* &&
    "${alias_identity}" == *":${EUID}:777:1:"* ]] || return 1
  owned=true
  for scope in direct symlink-alias; do
    if [[ "${scope}" == direct ]]; then
      lookup="${root}"
    else
      lookup="${alias}"
    fi
    marker="${WORK_DIR}/lease-host-${scope}.marker"
    output="${WORK_DIR}/lease-host-${scope}.out"
    status=0
    run_host_command env PATH="${lookup}:${PLATFORM_CALLER_HOST_PATH}" \
      PLATFORM_DOCKER_TEST_CONTRACT="${DOCKER_TEST_CONTRACT}" \
      PLATFORM_DOCKER_TEST_ROOT="${target}/.platform-test/docker-target" \
      PLATFORM_DOCKER_TEST_TOKEN="${DOCKER_TEST_TOKEN}" \
      LEASE_FLOCK_MARKER="${marker}" \
      "${target}/tools/bootstrap/doctor.sh" --base-only \
      >"${output}" 2>&1 || status=$?
    [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]
    if [[ "${scope}" == direct ]]; then
      run_host_command grep -Fqx \
        'FAIL  host-command  flock: lookup location is inside repository or generated command state' \
        "${output}"
    else
      run_host_command grep -Fqx \
        'FAIL  host-command  flock: physical lookup location is inside repository or generated command state' \
        "${output}"
    fi
    [[ ! -e "${marker}" && ! -L "${marker}" ]]
  done

  run_host_command mv -- "${root}" "${saved_root}"
  saved_root_identity="$(lifecycle_fixture_identity "${saved_root}")"
  [[ "${saved_root_identity}" == "${root_identity}" ]]
  (umask 077 && run_host_command mkdir -- "${root}")
  replacement_owner="${root}/.proof-owner"
  replacement_sentinel="${root}/replacement-sentinel"
  (umask 077 && printf '%s\n' "${owner_token}" >"${replacement_owner}")
  (umask 077 && printf 'preserve\n' >"${replacement_sentinel}")
  replacement_root_identity="$(lifecycle_fixture_identity "${root}")"
  replacement_owner_identity="$(lifecycle_fixture_identity \
    "${replacement_owner}")"
  replacement_sentinel_identity="$(lifecycle_fixture_identity \
    "${replacement_sentinel}")"
  status=0
  cleanup_lifecycle_host_fixture || status=$?
  [[ "${status}" -ne 0 && "$({ lifecycle_fixture_identity "${root}"; })" == "${replacement_root_identity}" &&
  "$({ lifecycle_fixture_identity "${replacement_owner}"; })" == "${replacement_owner_identity}" &&
  "$({ lifecycle_fixture_identity "${replacement_sentinel}"; })" == "${replacement_sentinel_identity}" &&
  "$(<"${replacement_owner}")" == "${owner_token}" &&
  "$(<"${replacement_sentinel}")" == preserve ]]
  entries="$(run_host_command find -H "${root}" -mindepth 1 -maxdepth 1 \
    -printf '%f\n' | run_host_command sort)"
  [[ "${entries}" == $'.proof-owner\nreplacement-sentinel' ]]
  run_host_command mv -T -- "${root}" "${replacement_saved}"
  [[ "$(lifecycle_fixture_identity "${replacement_saved}")" == "${replacement_root_identity}" &&
  "$(lifecycle_fixture_identity "${replacement_saved}/.proof-owner")" == "${replacement_owner_identity}" &&
  "$(lifecycle_fixture_identity \
    "${replacement_saved}/replacement-sentinel")" == "${replacement_sentinel_identity}" ]]
  run_host_command mv -- "${saved_root}" "${root}"
  [[ "$(lifecycle_fixture_identity "${root}")" == "${root_identity}" ]]
  trap - EXIT
  cleanup_lifecycle_host_fixture
  validate_persistent_lifecycle_root \
    "${root}" "${root_inode_identity}" "${lock_identity}"
  printf 'PASS  host-red      shared-lease flock fakes rejected; replacement preserved; root lock-only\n'
)

prove_mktemp_cannot_select_cleanup_target() {
  local -a actual=("$@") probe
  local fake="${WORK_DIR}/untrusted-mktemp"
  local victim="${WORK_DIR}/unrelated-victim"
  run_host_command mkdir -p "${victim}"
  printf 'preserve\n' >"${victim}/sentinel"
  run_host_command cat >"${fake}" <<'FAKE'
#!/bin/bash -p
printf '%s\n' "${UNTRUSTED_MKTEMP_RESULT:?}"
FAKE
  run_host_command chmod 0755 "${fake}"
  probe=("${actual[@]}")
  probe[3]="${fake}"
  UNTRUSTED_MKTEMP_RESULT="${victim}" TMPDIR="${WORK_DIR}" \
    expect_profile_red core-mktemp-target \
    'mktemp directory template is unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  [[ "$(<"${victim}/sentinel")" == preserve ]]
  printf 'PASS  environment-red untrusted mktemp cannot select cleanup target\n'
}

prove_mkdir_cannot_select_ownership_target() {
  local -a actual=("$@") probe
  local fake="${WORK_DIR}/untrusted-mkdir"
  local victim="${WORK_DIR}/ownership-victim"
  printf 'must-survive\n' >"${victim}"
  run_host_command cat >"${fake}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
target="${!#}"
"${REAL_MKDIR:?}" "$@"
"${REAL_LN:?}" -s -- "${OWNERSHIP_VICTIM:?}" "${target}/.ownership"
FAKE
  run_host_command chmod 0755 "${fake}"
  probe=("${actual[@]}")
  probe[9]="${fake}"
  REAL_MKDIR="${actual[9]}" REAL_LN="${actual[7]}" \
    OWNERSHIP_VICTIM="${victim}" TMPDIR="${WORK_DIR}" \
    expect_profile_red core-ownership-target \
    'mkdir ownership semantics are unavailable' \
    environment_profile_check_core_utilities "${probe[@]}"
  [[ "$(<"${victim}")" == must-survive ]]
  printf 'PASS  environment-red ownership marker cannot overwrite a symlink\n'
}

write_limited_tar() {
  local target="$1"
  run_host_command cat >"${target}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'tar (GNU tar) 1.35\n'
  exit 0
fi
printf '%s\n' "$*" >>"${TAR_FIXTURE_MARKER:?}"
exit 64
FAKE
  run_host_command chmod 0755 "${target}"
}

write_limited_timeout() {
  local target="$1"
  run_host_command cat >"${target}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'timeout (GNU coreutils) 9.4\n'
  exit 0
fi
printf '%s\n' "$*" >>"${TIMEOUT_FIXTURE_MARKER:?}"
exit 0
FAKE
  run_host_command chmod 0755 "${target}"
}

prove_tar_and_timeout_red() {
  local fake_tar="${WORK_DIR}/limited-tar"
  local wrapper="${WORK_DIR}/tar-wrapper"
  local fake_timeout="${WORK_DIR}/limited-timeout"
  local tar_marker="${WORK_DIR}/tar.marker"
  local timeout_marker="${WORK_DIR}/timeout.marker"
  write_limited_tar "${fake_tar}"
  write_limited_timeout "${fake_timeout}"
  TAR_FIXTURE_MARKER="${tar_marker}" expect_profile_red tar-stream \
    'deterministic ustar flags or stream semantics are unavailable' \
    environment_profile_check_tar \
    "${fake_tar}" "$(builtin type -P stat)" "$(builtin type -P od)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)" \
    "$(builtin type -P chmod)" "$(builtin type -P cmp)"
  write_semantic_tar_wrapper "${wrapper}"
  REAL_TAR="$(builtin type -P tar)" TAR_WRAPPER_MODE=mode-loss \
    expect_profile_red tar-mode \
    'deterministic ustar flags or stream semantics are unavailable' \
    environment_profile_check_tar \
    "${wrapper}" "$(builtin type -P stat)" "$(builtin type -P od)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)" \
    "$(builtin type -P chmod)" "$(builtin type -P cmp)"
  REAL_TAR="$(builtin type -P tar)" TAR_WRAPPER_MODE=gnu-format \
    expect_profile_red tar-format \
    'deterministic ustar flags or stream semantics are unavailable' \
    environment_profile_check_tar \
    "${wrapper}" "$(builtin type -P stat)" "$(builtin type -P od)" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)" \
    "$(builtin type -P chmod)" "$(builtin type -P cmp)"
  TIMEOUT_FIXTURE_MARKER="${timeout_marker}" expect_profile_red timeout-bound \
    '--foreground and --kill-after behavior returned 0, expected 137' \
    environment_profile_check_timeout "${fake_timeout}" "$(type -P bash)"
  run_host_command grep -Fq -- \
    '--sort=name --format=ustar --mtime=UTC 1970-01-01' "${tar_marker}"
  run_host_command grep -Fq -- \
    '--foreground --signal=TERM --kill-after=0.1s 0.1s' \
    "${timeout_marker}"
  printf 'PASS  environment-red tar and timeout behavior is exercised, not named\n'
}

write_semantic_tar_wrapper() {
  local target="$1"
  run_host_command cat >"${target}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
create=false
args=()
for argument in "$@"; do
  case "${argument}" in
    --create | -*c*) create=true ;;
  esac
  if [[ "${TAR_WRAPPER_MODE:?}" == gnu-format &&
    "${argument}" == --format=ustar ]]; then
    args+=(--format=gnu)
  else
    args+=("${argument}")
  fi
done
if [[ "${TAR_WRAPPER_MODE}" == mode-loss && "${create}" == true ]]; then
  exec "${REAL_TAR:?}" --mode=0644 "${args[@]}"
fi
exec "${REAL_TAR:?}" "${args[@]}"
FAKE
  run_host_command chmod 0755 "${target}"
}

prove_proc_red() {
  local absent="${WORK_DIR}/proc-absent"
  local malformed="${WORK_DIR}/proc-malformed"
  run_host_command mkdir -p "${absent}" "${malformed}/self"
  printf '123 (broken) R parent 42\n' >"${malformed}/self/stat"
  expect_profile_red proc-absent "${absent}/self/stat is unavailable" \
    environment_profile_read_proc_stat "${absent}"
  expect_profile_red proc-malformed 'Linux /proc stat fields are malformed' \
    environment_profile_read_proc_stat "${malformed}"
  printf 'PASS  environment-red alternate proc roots fail closed\n'
}

write_fake_docker() {
  local target="$1"
  run_host_command cat >"${target}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
printf '%s\n' "$*" >>"${DOCKER_FIXTURE_LOG:?}"
case "${DOCKER_FIXTURE_MODE:-valid}:${1:-}" in
  unreachable:version) exit 69 ;;
  malformed:version) printf 'not-a-docker-identity\n' ;;
  extra-line:version)
    printf '29.7.2|29.7.2|1.55|1.55|linux|amd64\nJUNK_SECOND_LINE\n'
    ;;
  trailing-field:version)
    printf '29.7.2|29.7.2|1.55|1.55|linux|amd64||\n'
    ;;
  *:version)
    printf '29.7.2|29.7.2|1.55|1.55|linux|amd64\n'
    ;;
  zero-help:build | zero-help:image) ;;
  missing-help:build)
    printf '%s\n' 'docker buildx build [OPTIONS] PATH | URL | -' \
      '  --builder string' '  --network string' '  --pull' '  --no-cache' \
      '  --progress string auto'
    ;;
  *:build)
    [[ " $* " == *' --help '* ]] || exit 90
    printf '%s\n' 'docker buildx build [OPTIONS] PATH | URL | -' \
      '  --builder string' '  --network string' '  --pull' '  --no-cache' \
      '  --progress string' '      ("auto", "plain", "tty", "rawjson")'
    ;;
  inspect-fail:image)
    [[ "${2:-}" != inspect ]] || exit 67
    printf '%s\n' 'docker image rm [OPTIONS] IMAGE'
    ;;
  remove-fail:image)
    [[ "${2:-}" != rm ]] || exit 68
    printf '%s\n' 'docker image inspect [OPTIONS] IMAGE' '  --format string'
    ;;
  *:image)
    [[ " $* " == *' --help '* ]] || exit 91
    case "${2:-}" in
      inspect) printf '%s\n' 'docker image inspect [OPTIONS] IMAGE' '  --format string' ;;
      rm) printf '%s\n' 'docker image rm [OPTIONS] IMAGE' ;;
      *) exit 92 ;;
    esac
    ;;
  *) exit 93 ;;
esac
FAKE
  run_host_command chmod 0755 "${target}"
}

prove_docker_identity_red() {
  local docker="${WORK_DIR}/docker"
  local log="${WORK_DIR}/docker-red.log"
  local timeout_path
  timeout_path="$(type -P timeout)"
  write_fake_docker "${docker}"
  PLATFORM_TEST_FORCE_MISSING=docker expect_profile_red docker-missing \
    'docker missing' environment_profile_resolve_command docker
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=unreachable \
    expect_profile_red docker-unreachable 'Docker daemon is unreachable within 15s' \
    environment_profile_check_docker_capabilities "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=malformed \
    expect_profile_red docker-malformed 'Docker identity response is malformed' \
    environment_profile_check_docker_capabilities "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=extra-line \
    expect_profile_red docker-extra-line 'Docker identity response is malformed' \
    environment_profile_check_docker_capabilities "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=trailing-field \
    expect_profile_red docker-trailing-field \
    'Docker identity response is malformed' \
    environment_profile_check_docker_capabilities "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=missing-help \
    expect_profile_red docker-build-response \
    'BuildKit response lacks --progress=plain' \
    environment_profile_check_docker_capabilities "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=inspect-fail \
    expect_profile_red docker-inspect-query \
    'unable to query local image inspect surface' \
    environment_profile_check_docker_capabilities "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  DOCKER_FIXTURE_LOG="${log}" DOCKER_FIXTURE_MODE=remove-fail \
    expect_profile_red docker-remove-query \
    'unable to query local image removal surface' \
    environment_profile_check_docker_capabilities "${docker}" "${timeout_path}" \
    "$(builtin type -P mkdir)" "$(builtin type -P rm)"
  printf 'PASS  environment-red Docker availability and identity are semantic\n'
}

prove_docker_help_red() {
  local valid missing
  valid=$'docker buildx build [OPTIONS] PATH | URL | -\n'
  valid+=$'--builder string\n--network string\n--pull\n--no-cache\n'
  valid+=$'--progress string plain'
  missing="${valid/docker buildx build/docker legacy build}"
  expect_profile_red docker-buildx 'BuildKit buildx response is absent' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--builder string/--executor string}"
  expect_profile_red docker-builder '--builder=default is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/PATH | URL | -/PATH}"
  expect_profile_red docker-stdin 'stdin tar context is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--network string/--net string}"
  expect_profile_red docker-network '--network=none is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--pull/--download}"
  expect_profile_red docker-pull '--pull=false is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--no-cache/--cache}"
  expect_profile_red docker-no-cache '--no-cache is unavailable' \
    environment_profile_check_docker_build_help "${missing}"
  missing="${valid/--progress string/--output string}"
  expect_profile_red docker-progress 'BuildKit response lacks --progress=plain' \
    environment_profile_check_docker_build_help "${missing}"
  expect_profile_red docker-inspect 'image inspect --format is unavailable' \
    environment_profile_check_docker_local_help \
    'docker image inspect [OPTIONS]' 'docker image rm [OPTIONS] --force'
  expect_profile_red docker-remove 'local image removal is unavailable' \
    environment_profile_check_docker_local_help \
    'docker image inspect [OPTIONS] --format' 'docker image remove [OPTIONS]'
  printf 'PASS  environment-red every consumed Docker help token is required\n'
}

prove_buildkit_parser_helper_red() {
  local directory="${WORK_DIR}/buildkit-helper"
  local log="${directory}/missing.log" marker="${directory}/sed.marker"
  run_host_command mkdir -p "${directory}/bin"
  run_host_command cat >"${directory}/bin/sed" <<'FAKE'
#!/bin/bash -p
printf 'sha256:%064d\n' 0
printf 'executed\n' >"${FAKE_SED_MARKER:?}"
FAKE
  run_host_command chmod 0755 "${directory}/bin/sed"
  printf '# no BuildKit result\n' >"${log}"
  # shellcheck source=../kubernetes/buildkit-result.sh
  # shellcheck disable=SC1091
  builtin source "${PLATFORM_ROOT}/tools/kubernetes/buildkit-result.sh"
  if PATH="${directory}/bin:${PATH}" FAKE_SED_MARKER="${marker}" \
    buildkit_result_config_id "${log}" >/dev/null 2>&1; then
    printf 'FAIL  buildkit-red  helper forged a missing result\n' >&2
    return 1
  fi
  [[ ! -e "${marker}" ]]
  printf 'PASS  buildkit-red  exact parser is independent of PATH helpers\n'
}

prove_project_identity_red() {
  expect_profile_red kind-absent \
    'kind identity differs from trusted Aqua identity' \
    environment_profile_check_kind_output '' v2.0.0
  expect_profile_red kind-wrong \
    'kind identity differs from trusted Aqua identity' \
    environment_profile_check_kind_output \
    'kind v1.0.0 go1.25.5 linux/amd64' v2.0.0
  expect_profile_red kubectl-absent \
    'kubectl client identity/platform differs from trusted Aqua identity' \
    environment_profile_check_kubectl_output '{}' v2.0.0
  expect_profile_red kubectl-wrong \
    'kubectl client identity/platform differs from trusted Aqua identity' \
    environment_profile_check_kubectl_output \
    $'  "gitVersion": "v1.0.0",\n  "platform": "linux/amd64"' v2.0.0
  expect_profile_red kubectl-platform \
    'kubectl client identity/platform differs from trusted Aqua identity' \
    environment_profile_check_kubectl_output \
    $'  "gitVersion": "v2.0.0",\n  "platform": "darwin/amd64"' v2.0.0
  printf 'PASS  environment-red managed kind and kubectl identities are exact\n'
}

prove_project_package_checksum_red() {
  local root="${WORK_DIR}/package-lock" lock asset binary expected
  asset='github_release/github.com/example/kind/v1.2.3/kind-linux-amd64'
  binary="${root}/pkgs/${asset}/kind-linux-amd64"
  lock="${root}/aqua-checksums.json"
  run_host_command mkdir -p "${binary%/*}"
  printf '#!/bin/bash -p\nprintf "kind v1.2.3 go1 linux/amd64\\n"\n' \
    >"${binary}"
  run_host_command chmod 0755 "${binary}"
  expected="$(run_host_command sha256sum -- "${binary}")"
  expected="${expected%%[[:space:]]*}"
  {
    printf '{\n  "checksums": [\n    {\n'
    printf '      "id": "%s",\n' "${asset}"
    printf '      "checksum": "%s",\n' "${expected^^}"
    printf '      "algorithm": "sha256"\n'
    printf '    }\n  ]\n}\n'
  } >"${lock}"
  environment_profile_verify_installed_tool_checksum \
    "${binary}" "${root}" "${lock}" "$(builtin type -P sha256sum)" kind
  printf '#!/bin/bash -p\nprintf "kind v1.2.3 go2 linux/amd64\\n"\n' \
    >"${binary}"
  expect_profile_red project-package-tamper \
    'installed kind bytes differ from checksum lock' \
    environment_profile_verify_installed_tool_checksum \
    "${binary}" "${root}" "${lock}" "$(builtin type -P sha256sum)" kind
  printf 'PASS  project-red   installed package bytes bind to Aqua checksum lock\n'
}

prepare_doctor_fixture() {
  local target="$1"
  local docker_root path
  run_host_command mkdir -p "${target}/tools/bootstrap" "${target}/tools/common" \
    "${target}/tools/kubernetes" "${target}/fake-bin"
  run_host_command cp "${PLATFORM_ROOT}/aqua.yaml" "${target}/aqua.yaml"
  for path in aqua-trust.sh doctor.sh environment-profile.sh; do
    run_host_command cp "${PLATFORM_ROOT}/tools/bootstrap/${path}" \
      "${target}/tools/bootstrap/"
  done
  for path in env.sh host-commands.sh process-state.sh state.sh tooling.sh; do
    run_host_command cp "${PLATFORM_ROOT}/tools/common/${path}" \
      "${target}/tools/common/"
  done
  run_host_command cp "${PLATFORM_ROOT}/tools/common/docker-target.sh" \
    "${target}/tools/common/docker-target-production.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/docker-target-fixture.sh" \
    "${target}/tools/common/docker-target.sh"
  run_host_command cp "${PLATFORM_ROOT}/tools/kubernetes/buildkit-result.sh" \
    "${target}/tools/kubernetes/buildkit-result.sh"
  docker_root="${target}/.platform-test/docker-target"
  run_host_command mkdir -p "${docker_root}"
  printf '%s\n' "${DOCKER_TEST_TOKEN}" >"${docker_root}/.docker-target-owner"
  write_fake_docker "${docker_root}/docker"
  run_host_command cat >"${target}/fake-bin/external-managed" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
printf '%s\n' "${0##*/}:$*" >>"${EXTERNAL_MANAGED_MARKER:?}"
exit 0
FAKE
  run_host_command chmod 0755 "${target}/fake-bin/external-managed"
  run_host_command ln -s external-managed "${target}/fake-bin/aqua"
  run_host_command ln -s external-managed "${target}/fake-bin/kind"
  run_host_command ln -s external-managed "${target}/fake-bin/kubectl"
}

run_doctor_fixture() {
  local target="$1"
  shift
  run_host_command env PATH="${target}/fake-bin:${PLATFORM_CALLER_HOST_PATH}" \
    PLATFORM_DOCKER_TEST_CONTRACT="${DOCKER_TEST_CONTRACT}" \
    PLATFORM_DOCKER_TEST_ROOT="${target}/.platform-test/docker-target" \
    PLATFORM_DOCKER_TEST_TOKEN="${DOCKER_TEST_TOKEN}" \
    "$@"
}

pin_doctor_fixture_digest() {
  local target="$1" variable="$2" source="$3" module temporary digest
  module="${target}/tools/bootstrap/aqua-trust.sh"
  temporary="${module}.new"
  digest="$(run_host_command sha256sum -- "${source}")"
  digest="${digest%% *}"
  run_host_command sed -E \
    "s/^(builtin readonly ${variable}=\")[0-9a-f]{64}(\")$/\\1${digest}\\2/" \
    "${module}" >"${temporary}"
  run_host_command grep -Fqx \
    "builtin readonly ${variable}=\"${digest}\"" "${temporary}"
  run_host_command mv "${temporary}" "${module}"
}

write_ready_project_fixture_lock() {
  local target="$1" kind_asset="$2" kind_path="$3"
  local kubectl_asset="$4" kubectl_path="$5" kind_hash kubectl_hash
  kind_hash="$(run_host_command sha256sum -- "${kind_path}")"
  kind_hash="${kind_hash%%[[:space:]]*}"
  kubectl_hash="$(run_host_command sha256sum -- "${kubectl_path}")"
  kubectl_hash="${kubectl_hash%%[[:space:]]*}"
  {
    printf '{\n  "checksums": [\n    {\n'
    printf '      "id": "%s",\n' "${kind_asset}"
    printf '      "checksum": "%s",\n' "${kind_hash^^}"
    printf '      "algorithm": "sha256"\n    },\n    {\n'
    printf '      "id": "%s",\n' "${kubectl_asset}"
    printf '      "checksum": "%s",\n' "${kubectl_hash^^}"
    printf '      "algorithm": "sha256"\n    }\n  ]\n}\n'
  } >"${target}/aqua-checksums.json"
}

prepare_ready_project_fixture() {
  local target="$1" kind_asset kubectl_asset kind_path kubectl_path proxy
  kind_asset='github_release/github.com/example/kind/v1.2.3/kind-linux-amd64'
  kubectl_asset='http/example.invalid/v4.5.6/linux/amd64/kubectl'
  kind_path="${target}/.platform/aqua/pkgs/${kind_asset}/kind-linux-amd64"
  kubectl_path="${target}/.platform/aqua/pkgs/${kubectl_asset}/kubectl"
  proxy="${target}/.platform/aqua/internal/pkgs/review/aqua-proxy"
  prepare_doctor_fixture "${target}"
  run_host_command mkdir -p "${target}/.platform/bootstrap" \
    "${target}/.platform/aqua/bin" \
    "${target}/.platform/aqua/registries" "${proxy%/*}" \
    "${kind_path%/*}" "${kubectl_path%/*}"
  run_host_command cat >"${target}/.platform/bootstrap/aqua" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
aqua_export_count=0
while IFS= read -r aqua_variable; do
  case "${aqua_variable}" in
    AQUA_CONFIG | AQUA_DISABLE_LAZY_INSTALL | AQUA_ROOT_DIR) ;;
    *) exit 63 ;;
  esac
  ((aqua_export_count += 1))
done < <(builtin compgen -A export AQUA_)
[[ "${aqua_export_count}" -eq 3 ]]
[[ "${AQUA_CONFIG:?}" == */aqua.yaml ]]
[[ "${AQUA_DISABLE_LAZY_INSTALL:?}" == true ]]
[[ "${AQUA_ROOT_DIR:?}" == /* && -d "${AQUA_ROOT_DIR}" ]]
[[ "${PATH:?}" == "${PLATFORM_HOST_PATH:?}" ]]
if [[ "${1:-}" == exec ]]; then
  shift
  [[ "${1:-}" == -- ]] || exit 2
  shift
  command_name="${1:-}"
  [[ "${command_name}" == kind || "${command_name}" == kubectl ]] || exit 2
  shift
  exec "${AQUA_ROOT_DIR:?}/bin/${command_name}" "$@"
fi
case " $* " in
  ' version ') printf '%s\n' "${FIXTURE_AQUA_VERSION:?}" ;;
  *' list -i '*)
    printf 'kubernetes-sigs/kind\tv1.2.3\tstandard\n'
    printf 'kubernetes/kubectl\tv4.5.6\tstandard\n'
    ;;
  *' which kind '*)
    printf '%s%s\n' \
      "${AQUA_ROOT_DIR:?}/pkgs/github_release/github.com/example/kind/v1.2.3/" \
      'kind-linux-amd64/kind-linux-amd64'
    ;;
  *' which kubectl '*)
    printf '%s%s\n' "${AQUA_ROOT_DIR:?}/pkgs/http/example.invalid/v4.5.6/" \
      'linux/amd64/kubectl/kubectl'
    ;;
  *) exit 2 ;;
esac
FAKE
  run_host_command cat >"${proxy}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
printf '%s\n' "${0##*/}" >>"${PROJECT_FIXTURE_PROXY_MARKER:?}"
case "${0##*/}" in
  kind) printf 'kind v1.2.3 go1.25.5 linux/amd64\n' ;;
  kubectl) printf '{\n  "gitVersion": "v4.5.6",\n  "platform": "linux/amd64"\n}\n' ;;
  *) exit 2 ;;
esac
FAKE
  printf '#!/bin/bash -p\nprintf "kind package\\n"\n' >"${kind_path}"
  printf '#!/bin/bash -p\nprintf "kubectl package\\n"\n' >"${kubectl_path}"
  run_host_command chmod 0755 "${target}/.platform/bootstrap/aqua" "${proxy}" \
    "${kind_path}" "${kubectl_path}"
  run_host_command ln -s internal/pkgs/review/aqua-proxy \
    "${target}/.platform/aqua/aqua-proxy"
  run_host_command ln -s ../aqua-proxy "${target}/.platform/aqua/bin/kind"
  run_host_command ln -s ../aqua-proxy "${target}/.platform/aqua/bin/kubectl"
  pin_doctor_fixture_digest "${target}" AQUA_BIN_SHA256 \
    "${target}/.platform/bootstrap/aqua"
  pin_doctor_fixture_digest "${target}" AQUA_PROXY_BIN_SHA256 "${proxy}"
  write_ready_project_fixture_lock \
    "${target}" "${kind_asset}" "${kind_path}" \
    "${kubectl_asset}" "${kubectl_path}"
}

run_ready_project_fixture_doctor() {
  local target="$1" output="$2" proxy_marker="$3"
  FIXTURE_AQUA_VERSION="${AQUA_VERSION}" \
    DOCKER_FIXTURE_LOG="${target}/docker.log" \
    PROJECT_FIXTURE_PROXY_MARKER="${proxy_marker}" \
    EXTERNAL_MANAGED_MARKER="${target}/external.marker" \
    run_doctor_fixture "${target}" \
    "${target}/tools/bootstrap/doctor.sh" --machine >"${output}" 2>&1
}

prove_ready_project_tamper_red() {
  local valid="${WORK_DIR}/project-valid" package="${WORK_DIR}/project-package"
  local proxy="${WORK_DIR}/project-proxy" output marker target
  prepare_ready_project_fixture "${valid}"
  marker="${valid}/proxy.marker"
  if ! run_ready_project_fixture_doctor \
    "${valid}" "${valid}/doctor.out" "${marker}"; then
    run_host_command sed -n '1,16p' "${valid}/doctor.out" >&2
    return 1
  fi
  [[ "$(<"${marker}")" == $'kind\nkubectl' ]]
  printf 'PASS  project       sealed managed identity executes admitted proxies\n'
  prepare_ready_project_fixture "${package}"
  target="${package}/.platform/aqua/pkgs/github_release/github.com/"
  target+='example/kind/v1.2.3/kind-linux-amd64/kind-linux-amd64'
  printf '# tampered\n' >>"${target}"
  marker="${package}/proxy.marker"
  output="${package}/doctor.out"
  if run_ready_project_fixture_doctor "${package}" "${output}" "${marker}"; then
    printf 'FAIL  project-red   tampered package reached READY\n' >&2
    return 1
  fi
  run_host_command grep -Fq \
    'installed kind bytes differ from checksum lock' "${output}"
  [[ ! -e "${marker}" ]]
  prepare_ready_project_fixture "${proxy}"
  target="${proxy}/.platform/aqua/internal/pkgs/review/aqua-proxy"
  printf '# tampered\n' >>"${target}"
  marker="${proxy}/proxy.marker"
  output="${proxy}/doctor.out"
  if run_ready_project_fixture_doctor "${proxy}" "${output}" "${marker}"; then
    printf 'FAIL  project-red   tampered proxy reached READY\n' >&2
    return 1
  fi
  run_host_command grep -Fq \
    'managed kind proxy is absent or untrusted' "${output}"
  [[ ! -e "${marker}" ]]
  printf 'PASS  project-red   end-to-end package and proxy tampering rejected\n'
}

prove_doctor_non_destructive() {
  local target="${WORK_DIR}/doctor-repo"
  local output="${WORK_DIR}/doctor.out"
  local docker_log="${WORK_DIR}/doctor-docker.log"
  local managed_marker="${WORK_DIR}/external-managed.marker"
  prepare_doctor_fixture "${target}"
  if ! DOCKER_FIXTURE_LOG="${docker_log}" \
    EXTERNAL_MANAGED_MARKER="${managed_marker}" \
    run_doctor_fixture "${target}" \
    "${target}/tools/bootstrap/doctor.sh" >"${output}" 2>&1; then
    run_host_command sed -n '1,20p' "${output}" >&2
    return 1
  fi
  run_host_command grep -Fq 'READY_FOR_BOOTSTRAP' "${output}"
  [[ ! -e "${target}/.platform" && ! -L "${target}/.platform" ]]
  [[ ! -e "${managed_marker}" ]]
  [[ "$(run_host_command grep -Ec '^version --format ' "${docker_log}")" -eq 1 ]]
  [[ "$(run_host_command grep -Ec '^build --help$' "${docker_log}")" -eq 1 ]]
  [[ "$(run_host_command grep -Ec \
    '^image (inspect|rm) --help$' "${docker_log}")" -eq 2 ]]
  if run_host_command grep -Evq \
    '^(version --format |build --help$|image (inspect|rm) --help$)' \
    "${docker_log}"; then
    printf 'FAIL  doctor-red    doctor attempted a mutating Docker command\n' >&2
    return 1
  fi
  printf 'PASS  doctor        no state, Docker, or cluster mutation attempted\n'
}

prove_inherited_tool_environment_isolated() {
  local directory="${WORK_DIR}/inherited-tool-environment"
  local git_target="${directory}/outside.git"
  local make_marker="${directory}/make.marker"
  local tar_marker="${directory}/tar.marker"
  local bash_marker="${directory}/bash.marker"
  local bash_environment="${directory}/inherited.bash"
  local makefile="${directory}/inherited.mk"
  local output="${directory}/doctor.out"
  run_host_command mkdir -p "${directory}"
  # The make file-function expands only in the isolated Make process.
  # shellcheck disable=SC2016
  printf '$(file >%s,mutated)\n' "${make_marker}" >"${makefile}"
  printf 'printf "inherited\\n" >>%q\n' "${bash_marker}" >"${bash_environment}"
  run_host_command env GIT_DIR="${git_target}" MAKEFILES="${makefile}" \
    TAR_OPTIONS="--index-file=${tar_marker}" \
    BASH_ENV="${bash_environment}" ENV="${bash_environment}" \
    "${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" --base-only \
    >"${output}" 2>&1 || {
    run_host_command sed -n '1,12p' "${output}" >&2
    return 1
  }
  if [[ -e "${git_target}" || -L "${git_target}" ||
    -e "${make_marker}" || -L "${make_marker}" ||
    -e "${tar_marker}" || -L "${tar_marker}" ||
    -e "${bash_marker}" || -L "${bash_marker}" ]]; then
    printf 'FAIL  doctor-red    inherited tool environment escaped probe root\n' >&2
    return 1
  fi
  printf 'PASS  doctor-red    inherited Bash, Git, Make, and tar state is isolated\n'
}

prove_helper_false_green_red() {
  local target="${WORK_DIR}/doctor-repo"
  local output="${WORK_DIR}/doctor-helper.out"
  local docker_log="${WORK_DIR}/doctor-helper-docker.log"
  local helper_marker="${WORK_DIR}/doctor-helper.marker"
  local status=0
  run_host_command cat >"${target}/fake-bin/grep" <<'FAKE'
#!/bin/bash -p
printf 'executed\n' >"${PROJECT_HELPER_MARKER:?}"
exit 0
FAKE
  run_host_command chmod 0755 "${target}/fake-bin/grep"
  PROJECT_HELPER_MARKER="${helper_marker}" DOCKER_FIXTURE_LOG="${docker_log}" \
    run_doctor_fixture "${target}" \
    "${target}/tools/bootstrap/doctor.sh" >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]
  [[ "$(run_host_command grep -Fxc \
    'FAIL  host-command  grep: lookup location is inside repository or generated command state' \
    "${output}")" -eq 1 ]]
  [[ ! -e "${helper_marker}" ]]
  run_host_command rm -- "${target}/fake-bin/grep"
  printf 'PASS  doctor-red    project helper fails closed at host command boundary\n'
}

prove_shadowed_host_command_red() {
  local marker="${WORK_DIR}/shadowed-tar.marker"
  local output="${WORK_DIR}/shadowed-tar.out"
  local bash_path
  bash_path="$(host_command_path bash)" || return
  # The child expands only the two explicitly passed fixture variables.
  # shellcheck disable=SC2016
  if ! run_host_command env SHADOWED_COMMAND_MARKER="${marker}" \
    DOCTOR_PATH="${PLATFORM_ROOT}/tools/bootstrap/doctor.sh" \
    "${bash_path}" -p -c '
tar() { printf "executed\n" >"${SHADOWED_COMMAND_MARKER}"; }
type() { printf "file\n"; }
export -f tar
export -f type
exec "${DOCTOR_PATH}" --base-only
' >"${output}" 2>&1; then
    printf 'FAIL  doctor-red    privileged entry did not ignore inherited functions\n' >&2
    return 1
  fi
  run_host_command grep -Fq 'PASS  platform' "${output}"
  [[ ! -e "${marker}" ]]
  printf 'PASS  doctor-red    privileged entry ignores inherited host functions\n'
}

prove_external_symlink_cannot_admit_project_command() {
  local target="${WORK_DIR}/doctor-host-symlink"
  local outside="${WORK_DIR}/outside-host-bin"
  local fake marker output status=0
  marker="${WORK_DIR}/project-tar.marker"
  output="${WORK_DIR}/project-tar.out"
  fake="${target}/.platform/host-fake/tar"
  prepare_doctor_fixture "${target}"
  run_host_command mkdir -p -- "${outside}" "${fake%/*}"
  run_host_command cat >"${fake}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
printf 'executed\n' >"${PROJECT_TAR_MARKER:?}"
exit 0
FAKE
  run_host_command chmod 0755 "${fake}"
  run_host_command ln -s -- "${fake}" "${outside}/tar"
  run_host_command env PATH="${outside}:${PLATFORM_CALLER_HOST_PATH}" \
    PROJECT_TAR_MARKER="${marker}" \
    "${target}/tools/bootstrap/doctor.sh" --base-only \
    >"${output}" 2>&1 || status=$?
  if [[ "${status}" -ne "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]; then
    printf 'FAIL  doctor-red    project tar symlink returned %s, expected %s\n' \
      "${status}" "${HOST_COMMAND_UNTRUSTED_STATUS}" >&2
    run_host_command sed -n '1,12p' "${output}" >&2
    return 1
  fi
  if [[ "$(run_host_command grep -Fxc \
    'FAIL  host-command  tar: resolved inside repository or generated command state' \
    "${output}")" -ne 1 ]]; then
    printf 'FAIL  doctor-red    project tar symlink missed exact host reason\n' >&2
    run_host_command sed -n '1,12p' "${output}" >&2
    return 1
  fi
  [[ ! -e "${marker}" && ! -L "${marker}" ]]
  printf 'PASS  doctor-red    external symlink cannot admit project command bytes\n'
}

prove_stateful_mktemp_cannot_select_cleanup_target() {
  local target="${WORK_DIR}/doctor-stateful" victim="${WORK_DIR}/later-victim"
  local counter="${WORK_DIR}/mktemp.counter" output="${WORK_DIR}/mktemp.out"
  local fake="${target}/fake-bin/mktemp"
  local status=0
  prepare_doctor_fixture "${target}"
  run_host_command mkdir -p "${victim}"
  printf 'preserve\n' >"${victim}/sentinel"
  run_host_command cat >"${fake}" <<'FAKE'
#!/bin/bash -p
set -euo pipefail
count=0
[[ ! -f "${STATEFUL_MKTEMP_COUNTER:?}" ]] || count="$(<"${STATEFUL_MKTEMP_COUNTER}")"
((count += 1))
printf '%s\n' "${count}" >"${STATEFUL_MKTEMP_COUNTER}"
if ((count >= 3)); then
  printf '%s\n' "${STATEFUL_MKTEMP_VICTIM:?}"
  exit 0
fi
exec "${REAL_MKTEMP:?}" "$@"
FAKE
  run_host_command chmod 0755 "${fake}"
  STATEFUL_MKTEMP_COUNTER="${counter}" STATEFUL_MKTEMP_VICTIM="${victim}" \
    REAL_MKTEMP="$(builtin type -P mktemp)" \
    run_doctor_fixture "${target}" \
    "${target}/tools/bootstrap/doctor.sh" --base-only \
    >"${output}" 2>&1 || status=$?
  [[ "${status}" -eq "${HOST_COMMAND_UNTRUSTED_STATUS}" ]]
  [[ "$(run_host_command grep -Fxc \
    'FAIL  host-command  mktemp: lookup location is inside repository or generated command state' \
    "${output}")" -eq 1 ]]
  [[ ! -e "${counter}" && "$(<"${victim}/sentinel")" == preserve ]]
  printf 'PASS  doctor-red    project mktemp cannot enter host command surface\n'
}

prove_project_state_red() {
  local target="${WORK_DIR}/doctor-repo"
  local output="${WORK_DIR}/doctor-partial.out"
  local docker_log="${WORK_DIR}/doctor-partial-docker.log"
  local managed_marker="${WORK_DIR}/external-managed.marker"
  if DOCKER_FIXTURE_LOG="${docker_log}" \
    EXTERNAL_MANAGED_MARKER="${managed_marker}" \
    run_doctor_fixture "${target}" \
    "${target}/tools/bootstrap/doctor.sh" --machine >"${output}" 2>&1; then
    printf 'FAIL  project-red   absent toolchain produced machine evidence\n' >&2
    return 1
  fi
  run_host_command grep -Fq \
    'machine evidence requires make bootstrap first' "${output}"
  run_host_command mkdir -p "${target}/.platform/aqua"
  if DOCKER_FIXTURE_LOG="${docker_log}" \
    EXTERNAL_MANAGED_MARKER="${managed_marker}" \
    run_doctor_fixture "${target}" \
    "${target}/tools/bootstrap/doctor.sh" >"${output}" 2>&1; then
    printf 'FAIL  project-red   partial toolchain unexpectedly passed\n' >&2
    return 1
  fi
  run_host_command grep -Fq 'Aqua state is partial or untrusted' "${output}"
  [[ ! -e "${managed_marker}" ]]
  printf 'PASS  project-red   absent/partial state rejects external PATH tools\n'
}

project_tool_state_snapshot() {
  local root="$1" relative
  local find_path sort_path sha256sum_path
  find_path="$(host_command_path find)" || return
  sort_path="$(host_command_path sort)" || return
  sha256sum_path="$(host_command_path sha256sum)" || return
  [[ "${root}" == /* && -d "${root}" && ! -L "${root}" ]] || return 1
  (
    builtin cd "${root}" || exit
    for relative in .platform/aqua .platform/bootstrap/aqua; do
      if [[ -e "${relative}" || -L "${relative}" ]]; then
        "${find_path}" "${relative}" -xdev \
          -printf '%p|%y|%m|%s|%T@|%C@|%l\n' || exit
      else
        printf '%s|absent\n' "${relative}"
      fi
    done
  ) | "${sort_path}" | "${sha256sum_path}" --
}

prove_ready_toolchain_non_destructive() {
  local directory="${WORK_DIR}/ready-toolchain" marker evidence before after
  local docker_log
  local line first="" last="" count=0
  marker="${directory}/project-proxy.marker"
  evidence="${directory}/machine.env"
  docker_log="${directory}/docker.log"
  prepare_ready_project_fixture "${directory}"
  before="$(project_tool_state_snapshot "${directory}")"
  if ! run_ready_project_fixture_doctor \
    "${directory}" "${evidence}" "${marker}"; then
    printf 'FAIL  project-red   ready toolchain observation failed\n' >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${first}" ]] || first="${line}"
    last="${line}"
    ((count += 1))
  done <"${evidence}"
  after="$(project_tool_state_snapshot "${directory}")"
  [[ "${first}" == "SCHEMA=${ENVIRONMENT_PROFILE_SCHEMA}" ]]
  [[ "${last}" =~ ^KUBECTL_IDENTITY=v[0-9]+\.[0-9]+\.[0-9]+$ &&
    "${count}" -eq "${ENVIRONMENT_PROFILE_EVIDENCE_RECORD_COUNT}" ]]
  [[ "$(<"${marker}")" == $'kind\nkubectl' && "${before}" == "${after}" ]]
  [[ ! -e "${directory}/external.marker" ]]
  [[ "$(run_host_command grep -Ec '^version --format ' "${docker_log}")" -eq 1 ]]
  [[ "$(run_host_command grep -Ec '^build --help$' "${docker_log}")" -eq 1 ]]
  [[ "$(run_host_command grep -Ec \
    '^image (inspect|rm) --help$' "${docker_log}")" -eq 2 ]]
  printf 'PASS  project       ready toolchain is explicit-path and non-mutating\n'
}

prove_pristine_toolchain_snapshot() {
  local directory="${WORK_DIR}/pristine-toolchain" before after
  local docker_log="${WORK_DIR}/pristine-toolchain-docker.log"
  local managed_marker="${WORK_DIR}/pristine-toolchain-managed.marker"
  local output="${WORK_DIR}/pristine-toolchain.out"
  prepare_doctor_fixture "${directory}"
  [[ ! -e "${directory}/.platform" && ! -L "${directory}/.platform" ]]
  before="$(project_tool_state_snapshot "${directory}")"
  if ! DOCKER_FIXTURE_LOG="${docker_log}" \
    EXTERNAL_MANAGED_MARKER="${managed_marker}" \
    run_doctor_fixture "${directory}" \
    "${directory}/tools/bootstrap/doctor.sh" >"${output}" 2>&1; then
    run_host_command sed -n '1,20p' "${output}" >&2
    return 1
  fi
  after="$(project_tool_state_snapshot "${directory}")"
  [[ "${before}" =~ ^[0-9a-f]{64}[[:space:]] && "${before}" == "${after}" ]]
  [[ ! -e "${directory}/.platform" && ! -L "${directory}/.platform" ]]
  [[ ! -e "${managed_marker}" && ! -L "${managed_marker}" ]]
  [[ "$(run_host_command grep -Fxc \
    'INFO  project       READY_FOR_BOOTSTRAP; run make bootstrap' \
    "${output}")" -eq 1 ]]
  printf 'PASS  project       pristine doctor preserves absent toolchain bytes\n'
}

render_valid_evidence() {
  local target="$1"
  ENVIRONMENT_PROFILE_OS=linux
  ENVIRONMENT_PROFILE_ARCHITECTURE=amd64
  ENVIRONMENT_PROFILE_BASH_VERSION=5.2.21
  ENVIRONMENT_PROFILE_CURL_VERSION=8.5.0
  ENVIRONMENT_PROFILE_TAR_VERSION=1.35
  ENVIRONMENT_PROFILE_TIMEOUT_VERSION=9.4
  ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION=29.7.2
  ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION=29.7.2
  ENVIRONMENT_PROFILE_DOCKER_CLIENT_API=1.55
  ENVIRONMENT_PROFILE_DOCKER_SERVER_API=1.55
  DOCKER_TARGET_FINGERPRINT=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  DOCKER_TARGET_DISCOVERY=host_override
  ENVIRONMENT_PROFILE_PROJECT_STATE=ready
  ENVIRONMENT_PROFILE_AQUA_IDENTITY="${AQUA_VERSION}"
  ENVIRONMENT_PROFILE_KIND_IDENTITY=v1.2.3
  ENVIRONMENT_PROFILE_KUBECTL_IDENTITY=v4.5.6
  export ENVIRONMENT_PROFILE_OS ENVIRONMENT_PROFILE_ARCHITECTURE
  export ENVIRONMENT_PROFILE_BASH_VERSION ENVIRONMENT_PROFILE_TAR_VERSION
  export ENVIRONMENT_PROFILE_CURL_VERSION
  export ENVIRONMENT_PROFILE_TIMEOUT_VERSION
  export ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION
  export ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION
  export ENVIRONMENT_PROFILE_DOCKER_CLIENT_API
  export ENVIRONMENT_PROFILE_DOCKER_SERVER_API
  export DOCKER_TARGET_DISCOVERY DOCKER_TARGET_FINGERPRINT
  export ENVIRONMENT_PROFILE_PROJECT_STATE ENVIRONMENT_PROFILE_AQUA_IDENTITY
  export ENVIRONMENT_PROFILE_KIND_IDENTITY ENVIRONMENT_PROFILE_KUBECTL_IDENTITY
  environment_profile_render_evidence >"${target}"
  environment_profile_validate_evidence "${target}"
}

prove_evidence_red() {
  local directory="${WORK_DIR}/evidence"
  local valid="${directory}/valid.env"
  local supported_home='/ho''me/review-user'
  run_host_command mkdir -p "${directory}"
  render_valid_evidence "${valid}"
  run_host_command head -n -1 "${valid}" >"${directory}/missing.env"
  expect_invalid_evidence missing "${directory}/missing.env"
  {
    run_host_command cat "${valid}"
    printf 'EXTRA=value\n'
  } >"${directory}/extra.env"
  expect_invalid_evidence extra "${directory}/extra.env"
  run_host_command awk 'NR == 2 { print } { print }' \
    "${valid}" >"${directory}/duplicate.env"
  expect_invalid_evidence duplicate "${directory}/duplicate.env"
  run_host_command sed $'s/^AQUA_IDENTITY=.*/AQUA_IDENTITY=bad\tvalue/' \
    "${valid}" \
    >"${directory}/control.env"
  expect_invalid_evidence control "${directory}/control.env"
  run_host_command cp "${valid}" "${directory}/nul.env"
  printf '\0' >>"${directory}/nul.env"
  expect_invalid_evidence nul "${directory}/nul.env"
  run_host_command head -c \
    "$((ENVIRONMENT_PROFILE_MAX_EVIDENCE_BYTES + 1))" /dev/zero |
    run_host_command tr '\0' x >"${directory}/oversize.env"
  expect_invalid_evidence oversize "${directory}/oversize.env"
  run_host_command sed \
    "s#^AQUA_IDENTITY=.*#AQUA_IDENTITY=${supported_home}#" "${valid}" \
    >"${directory}/path.env"
  expect_invalid_evidence path "${directory}/path.env"
  run_host_command sed \
    's/^AQUA_IDENTITY=.*/AQUA_IDENTITY=review-user/' "${valid}" \
    >"${directory}/identity.env"
  expect_invalid_evidence identity "${directory}/identity.env"
  run_host_command sed \
    's/^DOCKER_CLIENT_VERSION=.*/DOCKER_CLIENT_VERSION=review-user/' \
    "${valid}" >"${directory}/docker-version.env"
  expect_invalid_evidence docker-version "${directory}/docker-version.env"
  run_host_command sed \
    's/^DOCKER_CLIENT_VERSION=.*/DOCKER_CLIENT_VERSION=29.7.2-review-user/' \
    "${valid}" >"${directory}/docker-version-suffix.env"
  expect_invalid_evidence docker-version-suffix \
    "${directory}/docker-version-suffix.env"
  run_host_command sed \
    's/^DOCKER_SERVER_API=.*/DOCKER_SERVER_API=credentialToken123/' \
    "${valid}" >"${directory}/docker-api.env"
  expect_invalid_evidence docker-api "${directory}/docker-api.env"
  run_host_command sed \
    's/^DOCKER_TARGET_FINGERPRINT=.*/DOCKER_TARGET_FINGERPRINT=review-user/' \
    "${valid}" >"${directory}/docker-target-fingerprint.env"
  expect_invalid_evidence docker-target-fingerprint \
    "${directory}/docker-target-fingerprint.env"
  run_host_command sed \
    's/^DOCKER_TARGET_DISCOVERY=.*/DOCKER_TARGET_DISCOVERY=forged/' \
    "${valid}" >"${directory}/docker-target-discovery.env"
  expect_invalid_evidence docker-target-discovery \
    "${directory}/docker-target-discovery.env"
  run_host_command sed \
    's/^BASH_CAPABILITY=.*/BASH_CAPABILITY=version_only/' "${valid}" \
    >"${directory}/weakened.env"
  expect_invalid_evidence weakened "${directory}/weakened.env"
  run_host_command sed \
    's/^KIND_IDENTITY=.*/KIND_IDENTITY=v9.9.9/' "${valid}" \
    >"${directory}/wrong-kind.env"
  expect_invalid_evidence wrong-kind "${directory}/wrong-kind.env"
  run_host_command ln -s valid.env "${directory}/symlink.env"
  expect_invalid_evidence symlink "${directory}/symlink.env"
  printf 'PASS  evidence      schema, order, bounds, and path safety proved\n'
}

main() {
  local mkdir_path rm_path
  mkdir_path="$(builtin type -P mkdir)"
  rm_path="$(builtin type -P rm)"
  environment_profile_create_owned_workspace proof "${mkdir_path}"
  WORK_DIR="${ENVIRONMENT_PROFILE_OWNED_WORKSPACE}"
  WORK_TOKEN="${ENVIRONMENT_PROFILE_OWNED_TOKEN}"
  WORK_RM_PATH="${rm_path}"
  trap cleanup_proof_workspace EXIT
  prove_fake_zero_rejected
  prove_curl_surface_red
  prove_core_utility_red
  prove_host_utility_pipeline_red
  prove_flock_function_shadow_rejected
  prove_lifecycle_state_flock_rejected
  prove_tar_and_timeout_red
  prove_proc_red
  prove_docker_identity_red
  prove_docker_help_red
  prove_buildkit_parser_helper_red
  prove_project_identity_red
  prove_project_package_checksum_red
  prove_ready_project_tamper_red
  prove_doctor_non_destructive
  prove_inherited_tool_environment_isolated
  prove_helper_false_green_red
  prove_shadowed_host_command_red
  prove_external_symlink_cannot_admit_project_command
  prove_stateful_mktemp_cannot_select_cleanup_target
  prove_project_state_red
  prove_pristine_toolchain_snapshot
  prove_ready_toolchain_non_destructive
  prove_evidence_red
  printf 'PASS  environment   capability profile adversarial proof complete\n'
  environment_profile_remove_owned_workspace \
    "${WORK_DIR}" "${WORK_TOKEN}" "${WORK_RM_PATH}"
  trap - EXIT
  WORK_DIR=""
  WORK_TOKEN=""
  WORK_RM_PATH=""
}

main "$@"
