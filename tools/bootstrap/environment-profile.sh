#!/usr/bin/env bash

# Source-only, capability-based verification environment profile.
# Callers must source env.sh and tooling.sh first.

ENVIRONMENT_PROFILE_SCHEMA="flare-platform-environment-v1"
ENVIRONMENT_PROFILE_MAX_EVIDENCE_BYTES=8192
ENVIRONMENT_PROFILE_EVIDENCE_RECORD_COUNT=28

ENVIRONMENT_PROFILE_OS=""
ENVIRONMENT_PROFILE_ARCHITECTURE=""
ENVIRONMENT_PROFILE_BASH_VERSION=""
ENVIRONMENT_PROFILE_CURL_VERSION=""
ENVIRONMENT_PROFILE_TAR_VERSION=""
ENVIRONMENT_PROFILE_TIMEOUT_VERSION=""
ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION=""
ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION=""
ENVIRONMENT_PROFILE_DOCKER_CLIENT_API=""
ENVIRONMENT_PROFILE_DOCKER_SERVER_API=""
ENVIRONMENT_PROFILE_PROJECT_STATE=""
ENVIRONMENT_PROFILE_AQUA_IDENTITY=""
ENVIRONMENT_PROFILE_KIND_IDENTITY=""
ENVIRONMENT_PROFILE_KUBECTL_IDENTITY=""
ENVIRONMENT_PROFILE_COMMAND_PATH=""
ENVIRONMENT_PROFILE_INSTALLED_TOOL_PATH=""
ENVIRONMENT_PROFILE_INSTALLED_TOOL_PROXY=""
ENVIRONMENT_PROFILE_EXPECTED_TOOL_SHA256=""
ENVIRONMENT_PROFILE_OWNED_WORKSPACE=""
ENVIRONMENT_PROFILE_OWNED_TOKEN=""
ENVIRONMENT_PROFILE_TRUSTED_MKDIR_PATH=""
ENVIRONMENT_PROFILE_TRUSTED_RM_PATH=""
declare -A ENVIRONMENT_PROFILE_HOST_PATHS=()
readonly -a ENVIRONMENT_PROFILE_HOST_COMMAND_NAMES=(
  awk basename bash cat chmod cmp cp curl cut diff dirname env find git grep gzip
  head ln make mkdir mkfifo mktemp mv od readlink rm sed sha256sum sleep
  sort stat tail tar tee timeout tr uname wc
)

environment_profile_fail() {
  local component="$1"
  shift
  printf 'FAIL  %-13s %s\n' "${component}" "$*" >&2
  return 1
}

environment_profile_is_forced_missing() {
  [[ ",${PLATFORM_TEST_FORCE_MISSING:-}," == *",$1,"* ]]
}

environment_profile_resolve_command() {
  local command_name="$1"
  local command_path="" command_type=""
  if ! environment_profile_is_forced_missing "${command_name}"; then
    command_type="$(builtin type -t -- "${command_name}" 2>/dev/null || true)"
    command_path="$(builtin type -P -- "${command_name}" 2>/dev/null || true)"
  fi
  if [[ -n "${command_type}" && "${command_type}" != file ]]; then
    environment_profile_fail host-command \
      "${command_name} is shadowed by shell ${command_type}"
    return
  fi
  if [[ -z "${command_path}" || ! -f "${command_path}" ||
    ! -x "${command_path}" ]]; then
    environment_profile_fail host-command "${command_name} missing"
    return
  fi
  ENVIRONMENT_PROFILE_COMMAND_PATH="${command_path}"
}

environment_profile_require_host_commands() {
  local command_name
  ENVIRONMENT_PROFILE_HOST_PATHS=()
  for command_name in "${ENVIRONMENT_PROFILE_HOST_COMMAND_NAMES[@]}"; do
    environment_profile_resolve_command "${command_name}" || return
    ENVIRONMENT_PROFILE_HOST_PATHS["${command_name}"]="${ENVIRONMENT_PROFILE_COMMAND_PATH}"
  done
}

environment_profile_sanitize_child_environment() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG_GLOBAL
  unset GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT
  unset MAKEFILES MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
  unset TAR_OPTIONS GZIP
}

environment_profile_temp_root() {
  local temp_root="${TMPDIR:-/tmp}"
  while [[ "${temp_root}" != / && "${temp_root}" == */ ]]; do
    temp_root="${temp_root%/}"
  done
  [[ "${temp_root}" == /* && "${temp_root}" != *$'\n'* &&
    "${temp_root}" != *$'\r'* && "${temp_root}" != *$'\t'* ]] || return
  printf '%s\n' "${temp_root}"
}

environment_profile_create_owned_workspace() {
  local prefix="$1" mkdir_path="$2" temp_root candidate token _
  ENVIRONMENT_PROFILE_OWNED_WORKSPACE=""
  ENVIRONMENT_PROFILE_OWNED_TOKEN=""
  [[ "${prefix}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 2
  temp_root="$(environment_profile_temp_root)" || return
  [[ -d "${temp_root}" && ! -L "${temp_root}" ]] || return
  for _ in {1..8}; do
    candidate="${temp_root}/flare-${prefix}-owner.$$.${RANDOM}${RANDOM}"
    [[ ! -e "${candidate}" && ! -L "${candidate}" ]] || continue
    "${mkdir_path}" -- "${candidate}" >/dev/null 2>&1 || continue
    [[ -d "${candidate}" && ! -L "${candidate}" ]] || continue
    token="flare-owned-v1:${BASHPID}:${RANDOM}${RANDOM}"
    [[ ! -e "${candidate}/.ownership" && ! -L "${candidate}/.ownership" ]] || return
    (
      umask 077
      set -o noclobber
      printf '%s\n' "${token}" >"${candidate}/.ownership"
    ) 2>/dev/null || return
    [[ -f "${candidate}/.ownership" && ! -L "${candidate}/.ownership" ]] || return
    ENVIRONMENT_PROFILE_OWNED_WORKSPACE="${candidate}"
    ENVIRONMENT_PROFILE_OWNED_TOKEN="${token}"
    return 0
  done
  return 1
}

environment_profile_remove_owned_workspace() {
  local work="$1" token="$2" rm_path="$3" temp_root observed
  temp_root="$(environment_profile_temp_root)" || return
  case "${work}" in
    "${temp_root}"/flare-*-owner.*) ;;
    *) return 2 ;;
  esac
  [[ -d "${work}" && ! -L "${work}" &&
    -f "${work}/.ownership" && ! -L "${work}/.ownership" ]] || return
  IFS= read -r observed <"${work}/.ownership" || return
  [[ -n "${token}" && "${observed}" == "${token}" ]] || return
  "${rm_path}" -rf -- "${work}" || return
  [[ ! -e "${work}" && ! -L "${work}" ]]
}

environment_profile_check_core_file_semantics() {
  local work="$1" sha256sum_path="$2" readlink_path="$3" stat_path="$4"
  local chmod_path="$5" ln_path="$6" od_path="$7"
  local payload output link
  payload="${work}/known-value"
  (umask 077 && printf 'flare-platform-environment-v1\n' >"${payload}") || return
  output="$("${stat_path}" -c '%F|%s|%a' -- "${payload}")" || true
  if [[ "${output}" != 'regular file|30|600' ]]; then
    environment_profile_fail core-utilities "stat creation-mode semantics are unavailable"
    return
  fi
  "${chmod_path}" 0640 "${payload}" || return
  output="$("${stat_path}" -c '%F|%s|%a' -- "${payload}")" || true
  if [[ "${output}" != 'regular file|30|640' ]]; then
    environment_profile_fail core-utilities "stat or chmod semantics are unavailable"
    return
  fi
  output="$("${sha256sum_path}" -- <"${payload}")" || true
  if [[ "${output}" != 'fc327befd01c4bb56e0639176d62253bdaa3e6cb635b40c70d898a9fbcf0e7a2  -' ]]; then
    environment_profile_fail core-utilities "sha256sum grammar is unavailable"
    return
  fi
  output="$("${od_path}" -An -v -tx1 -N 2 -- "${payload}")" || true
  if [[ ! "${output}" =~ ^[[:space:]]*66[[:space:]]6c[[:space:]]*$ ]]; then
    environment_profile_fail core-utilities "od byte semantics are unavailable"
    return
  fi
  link="${work}/known-link"
  "${ln_path}" -s known-value "${link}" || return
  output="$(
    "${readlink_path}" -n -- "${link}"
    printf '|sentinel'
  )" || true
  if [[ "${output}" != 'known-value|sentinel' ||
    "$("${readlink_path}" -f -- "${link}" 2>/dev/null || true)" != "${payload}" ]]; then
    environment_profile_fail core-utilities "readlink -n/-f semantics are unavailable"
    return
  fi
}

environment_profile_check_core_collection_semantics() {
  local work="$1" mktemp_path="$2" cmp_path="$3" diff_path="$4"
  local mkfifo_path="$5" temporary different fifo status=0
  temporary="$("${mktemp_path}" -d "${work}/directory.XXXXXXXX")" || true
  if [[ -z "${temporary}" || ! -d "${temporary}" || -L "${temporary}" ||
    "${temporary}" != "${work}"/directory.* ]]; then
    environment_profile_fail core-utilities "mktemp directory template is unavailable"
    return
  fi
  temporary="$("${mktemp_path}" "${work}/payload.XXXXXXXX")" || true
  if [[ -z "${temporary}" || ! -f "${temporary}" || -L "${temporary}" ||
    "${temporary}" != "${work}"/payload.* ]]; then
    environment_profile_fail core-utilities "mktemp file template is unavailable"
    return
  fi
  different="${work}/different"
  printf 'different\n' >"${different}" || return
  "${cmp_path}" --silent -- "${work}/known-value" "${work}/known-value" || status=$?
  [[ "${status}" -eq 0 ]] || {
    environment_profile_fail core-utilities "cmp equality semantics are unavailable"
    return
  }
  status=0
  "${cmp_path}" --silent -- "${work}/known-value" "${different}" || status=$?
  [[ "${status}" -eq 1 ]] || {
    environment_profile_fail core-utilities "cmp inequality semantics are unavailable"
    return
  }
  status=0
  "${diff_path}" -u -- "${work}/known-value" "${work}/known-value" \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 0 ]] || {
    environment_profile_fail core-utilities "diff equality semantics are unavailable"
    return
  }
  status=0
  "${diff_path}" -u -- "${work}/known-value" "${different}" \
    >/dev/null 2>&1 || status=$?
  [[ "${status}" -eq 1 ]] || {
    environment_profile_fail core-utilities "diff inequality semantics are unavailable"
    return
  }
  fifo="${work}/fixture.fifo"
  "${mkfifo_path}" -- "${fifo}" || true
  if [[ ! -p "${fifo}" || -L "${fifo}" ]]; then
    environment_profile_fail core-utilities "mkfifo semantics are unavailable"
    return
  fi
}

environment_profile_check_core_utilities() (
  local sha256sum_path="$1" readlink_path="$2" stat_path="$3"
  local mktemp_path="$4" cmp_path="$5" diff_path="$6" chmod_path="$7"
  local ln_path="$8" mkfifo_path="$9" mkdir_path="${10}"
  local od_path="${11}" rm_path="${12}"
  local work="" token="" removable rm_trusted=false
  # Invoked indirectly by the EXIT trap below.
  # shellcheck disable=SC2329
  cleanup_core_utility_fixture() {
    if [[ -n "${work}" && "${rm_trusted}" == true ]]; then
      environment_profile_remove_owned_workspace \
        "${work}" "${token}" "${rm_path}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_core_utility_fixture EXIT
  if ! environment_profile_create_owned_workspace core "${mkdir_path}"; then
    environment_profile_fail core-utilities "mkdir ownership semantics are unavailable"
    return
  fi
  work="${ENVIRONMENT_PROFILE_OWNED_WORKSPACE}"
  token="${ENVIRONMENT_PROFILE_OWNED_TOKEN}"
  removable="${work}/remove-me"
  "${mkdir_path}" -- "${removable}" || return
  printf 'owned\n' >"${removable}/sentinel" || return
  "${rm_path}" -rf -- "${removable}" || true
  if [[ -e "${removable}" || -L "${removable}" ]]; then
    environment_profile_fail core-utilities "rm cleanup semantics are unavailable"
    return
  fi
  rm_trusted=true
  environment_profile_check_core_file_semantics \
    "${work}" "${sha256sum_path}" "${readlink_path}" "${stat_path}" \
    "${chmod_path}" "${ln_path}" "${od_path}" || return
  environment_profile_check_core_collection_semantics \
    "${work}" "${mktemp_path}" "${cmp_path}" "${diff_path}" \
    "${mkfifo_path}" || return
  if ! environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${rm_path}"; then
    environment_profile_fail core-utilities "rm cleanup semantics are unavailable"
    return
  fi
  work=""
)

environment_profile_check_text_utilities() {
  local work="$1" source output observed
  source="${work}/records.txt"
  printf 'gamma:3\nalpha:1\nbeta:2\n' >"${source}" || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[cat]}" -- "${source}")" || return
  [[ "${output}" == $'gamma:3\nalpha:1\nbeta:2' ]] || return
  # The field expression expands only inside the isolated awk process.
  # shellcheck disable=SC2016
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[awk]}" -F: '{print $1}' "${source}")" || return
  [[ "${output}" == $'gamma\nalpha\nbeta' ]] || return
  [[ "$("${ENVIRONMENT_PROFILE_HOST_PATHS[basename]}" -- /one/two.txt)" == two.txt ]] || return
  [[ "$("${ENVIRONMENT_PROFILE_HOST_PATHS[dirname]}" -- /one/two.txt)" == /one ]] || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[cut]}" -d: -f2 "${source}")" || return
  [[ "${output}" == $'3\n1\n2' ]] || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[grep]}" -Fx -- alpha:1 "${source}")" || return
  [[ "${output}" == alpha:1 ]] || return
  [[ "$("${ENVIRONMENT_PROFILE_HOST_PATHS[head]}" -n 1 -- "${source}")" == gamma:3 ]] || return
  [[ "$("${ENVIRONMENT_PROFILE_HOST_PATHS[sed]}" -n '2p' "${source}")" == alpha:1 ]] || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[sort]}" -- "${source}")" || return
  [[ "${output}" == $'alpha:1\nbeta:2\ngamma:3' ]] || return
  [[ "$("${ENVIRONMENT_PROFILE_HOST_PATHS[tail]}" -n 1 -- "${source}")" == beta:2 ]] || return
  output="$(printf 'lower\n' | "${ENVIRONMENT_PROFILE_HOST_PATHS[tr]}" '[:lower:]' '[:upper:]')" || return
  [[ "${output}" == LOWER ]] || return
  output="$(printf 'tee-value\n' | "${ENVIRONMENT_PROFILE_HOST_PATHS[tee]}" "${work}/tee.txt")" || return
  IFS= read -r observed <"${work}/tee.txt" || return
  [[ "${output}" == tee-value && "${observed}" == tee-value ]] || return
  read -r observed <<<"$("${ENVIRONMENT_PROFILE_HOST_PATHS[wc]}" -l <"${source}")" || return
  [[ "${observed}" == 3 ]] || return
}

environment_profile_check_file_utilities() {
  local work="$1" source copied moved output repo makefile compressed
  source="${work}/records.txt"
  copied="${work}/copied.txt"
  moved="${work}/moved.txt"
  "${ENVIRONMENT_PROFILE_HOST_PATHS[cp]}" -- "${source}" "${copied}" || return
  "${ENVIRONMENT_PROFILE_HOST_PATHS[cmp]}" --silent -- "${source}" "${copied}" || return
  "${ENVIRONMENT_PROFILE_HOST_PATHS[mv]}" -fT -- "${copied}" "${moved}" || return
  [[ ! -e "${copied}" && -f "${moved}" ]] || return
  "${ENVIRONMENT_PROFILE_HOST_PATHS[cmp]}" --silent -- "${source}" "${moved}" || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[find]}" "${work}" -maxdepth 1 -type f -name moved.txt -print)" || return
  [[ "${output}" == "${moved}" ]] || return
  compressed="${work}/records.txt.gz"
  "${ENVIRONMENT_PROFILE_HOST_PATHS[gzip]}" -n -c -- "${source}" >"${compressed}" || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[gzip]}" -dc -- "${compressed}")" || return
  [[ "${output}" == $'gamma:3\nalpha:1\nbeta:2' ]] || return
  # The variable expands only inside the isolated Bash process.
  # shellcheck disable=SC2016
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[env]}" FLARE_HOST_PROBE=ready \
    "${ENVIRONMENT_PROFILE_HOST_PATHS[bash]}" -c 'printf "%s\n" "$FLARE_HOST_PROBE"')" || return
  [[ "${output}" == ready ]] || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[env]}" -S \
    "${ENVIRONMENT_PROFILE_HOST_PATHS[bash]} -c 'printf \"env-s-ready\\n\"'")" || return
  [[ "${output}" == env-s-ready ]] || return
  repo="${work}/repo"
  "${ENVIRONMENT_PROFILE_HOST_PATHS[mkdir]}" -- "${repo}" || return
  "${ENVIRONMENT_PROFILE_HOST_PATHS[git]}" -C "${repo}" init -q || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[git]}" -C "${repo}" rev-parse --is-inside-work-tree)" || return
  [[ "${output}" == true ]] || return
  makefile="${work}/Makefile"
  printf 'probe:\n\t@printf "make-ready\\n"\n' >"${makefile}" || return
  output="$("${ENVIRONMENT_PROFILE_HOST_PATHS[make]}" -s -f "${makefile}" probe)" || return
  [[ "${output}" == make-ready ]] || return
}

environment_profile_check_host_utilities() (
  local work token
  environment_profile_create_owned_workspace \
    host "${ENVIRONMENT_PROFILE_HOST_PATHS[mkdir]}" || {
    environment_profile_fail host-capability "owned probe workspace is unavailable"
    return
  }
  work="${ENVIRONMENT_PROFILE_OWNED_WORKSPACE}"
  token="${ENVIRONMENT_PROFILE_OWNED_TOKEN}"
  trap 'environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${ENVIRONMENT_PROFILE_HOST_PATHS[rm]}" \
    >/dev/null 2>&1 || true' EXIT
  environment_profile_check_text_utilities "${work}" || {
    environment_profile_fail host-capability "bounded text utility semantics are unavailable"
    return
  }
  environment_profile_check_file_utilities "${work}" || {
    environment_profile_fail host-capability "bounded file and command semantics are unavailable"
    return
  }
  environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${ENVIRONMENT_PROFILE_HOST_PATHS[rm]}" || return
  work=""
)

environment_profile_check_curl() {
  local curl_path="$1"
  local output first_line line protocols="" help
  local fail=false location=false proto=false proto_redir=false tls=false
  local connect=false max_time=false max_filesize=false retry=false
  local retry_connrefused=false output_file=false silent=false show_error=false
  output="$("${curl_path}" --version 2>&1)" || {
    environment_profile_fail curl-capability "unable to query curl identity"
    return
  }
  if ((${#output} > 8192)); then
    environment_profile_fail curl-capability "identity response exceeded 8192 bytes"
    return
  fi
  first_line="${output%%$'\n'*}"
  if [[ ! "${first_line}" =~ ^curl[[:space:]]([0-9]+\.[0-9]+\.[0-9]+)[[:space:]] ]]; then
    environment_profile_fail curl-capability "curl identity is malformed"
    return
  fi
  ENVIRONMENT_PROFILE_CURL_VERSION="${BASH_REMATCH[1]}"
  while IFS= read -r line; do
    [[ "${line}" == Protocols:* ]] && protocols=" ${line#Protocols:} "
  done <<<"${output}"
  if [[ "${protocols}" != *' http '* || "${protocols}" != *' https '* ]]; then
    environment_profile_fail curl-capability "HTTP/HTTPS protocols are unavailable"
    return
  fi
  help="$("${curl_path}" --help all 2>&1)" || {
    environment_profile_fail curl-capability "unable to query curl option surface"
    return
  }
  if ((${#help} > 65536)); then
    environment_profile_fail curl-capability "option response exceeded 65536 bytes"
    return
  fi
  while IFS= read -r line; do
    [[ "${line}" =~ (^|[[:space:],])--fail([[:space:]]|$) ]] && fail=true
    [[ "${line}" =~ (^|[[:space:],])--location([[:space:]]|$) ]] && location=true
    [[ "${line}" =~ (^|[[:space:],])--proto([[:space:]]|$) ]] && proto=true
    [[ "${line}" =~ (^|[[:space:],])--proto-redir([[:space:]]|$) ]] && proto_redir=true
    [[ "${line}" =~ (^|[[:space:],])--tlsv1\.2([[:space:]]|$) ]] && tls=true
    [[ "${line}" =~ (^|[[:space:],])--connect-timeout([[:space:]]|$) ]] && connect=true
    [[ "${line}" =~ (^|[[:space:],])--max-time([[:space:]]|$) ]] && max_time=true
    [[ "${line}" =~ (^|[[:space:],])--max-filesize([[:space:]]|$) ]] && max_filesize=true
    [[ "${line}" =~ (^|[[:space:],])--retry([[:space:]]|$) ]] && retry=true
    [[ "${line}" =~ (^|[[:space:],])--retry-connrefused([[:space:]]|$) ]] &&
      retry_connrefused=true
    [[ "${line}" =~ (^|[[:space:],])--output([[:space:]]|$) ]] && output_file=true
    [[ "${line}" =~ (^|[[:space:],])--silent([[:space:]]|$) ]] && silent=true
    [[ "${line}" =~ (^|[[:space:],])--show-error([[:space:]]|$) ]] && show_error=true
  done <<<"${help}"
  if [[ "${fail}" != true || "${location}" != true || "${proto}" != true ||
    "${proto_redir}" != true || "${tls}" != true || "${connect}" != true ||
    "${max_time}" != true || "${max_filesize}" != true || "${retry}" != true ||
    "${retry_connrefused}" != true || "${output_file}" != true ||
    "${silent}" != true || "${show_error}" != true ]]; then
    environment_profile_fail curl-capability \
      "required bounded HTTP transfer surface is unavailable"
    return
  fi
}

environment_profile_check_platform() {
  local uname_path="$1" system architecture
  system="$("${uname_path}" -s)" || return
  architecture="$("${uname_path}" -m)" || return
  if [[ "${system}" != Linux || "${architecture}" != x86_64 ]]; then
    environment_profile_fail platform \
      "requires Linux x86_64; observed ${system} ${architecture}"
    return
  fi
  ENVIRONMENT_PROFILE_OS="linux"
  ENVIRONMENT_PROFILE_ARCHITECTURE="amd64"
}

environment_profile_check_bash() {
  local bash_path="$1"
  local output first_line capability
  output="$("${bash_path}" --version 2>&1)" || {
    environment_profile_fail bash-capability "unable to query GNU Bash"
    return
  }
  if ((${#output} > 4096)); then
    environment_profile_fail bash-capability "version response exceeded 4096 bytes"
    return
  fi
  first_line="${output%%$'\n'*}"
  if [[ ! "${first_line}" =~ GNU[[:space:]]bash,[[:space:]]version[[:space:]]([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    environment_profile_fail bash-capability "GNU Bash identity is malformed"
    return
  fi
  # The capability program expands only in the isolated Bash under test.
  # shellcheck disable=SC2016
  capability="$("${bash_path}" -c '
set -euo pipefail
set -m
coproc ENV_PROFILE_COPROC { printf "coproc-ready\n"; }
coproc_pid=${ENV_PROFILE_COPROC_PID}
IFS= read -r value <&"${ENV_PROFILE_COPROC[0]}"
wait "${coproc_pid}"
[[ "${value}" == coproc-ready ]]
printf "bash-job-control-v1\n"
' 2>/dev/null)" || {
    environment_profile_fail bash-capability \
      "job control, coproc, or wait behavior is unavailable"
    return
  }
  if [[ "${capability}" != bash-job-control-v1 ]]; then
    environment_profile_fail bash-capability \
      "job control capability response is malformed"
    return
  fi
  ENVIRONMENT_PROFILE_BASH_VERSION="${BASH_REMATCH[1]}"
}

environment_profile_has_ustar_header() {
  local od_path="$1" archive="$2" offset="$3" bytes pattern
  bytes="$("${od_path}" -An -v -tx1 -j "$((offset + 257))" -N 8 \
    -- "${archive}")" || return
  pattern='^[[:space:]]*75[[:space:]]73[[:space:]]74[[:space:]]61'
  pattern+='[[:space:]]72[[:space:]]00[[:space:]]30[[:space:]]30[[:space:]]*$'
  [[ "${bytes}" =~ ${pattern} ]]
}

environment_profile_prove_tar_stream() (
  local tar_path="$1" stat_path="$2" od_path="$3" mkdir_path="$4"
  local rm_path="$5" chmod_path="$6" cmp_path="$7" token
  local work context first second selected extracted compressed expanded modes
  local entries listing line owner_count=0 time_count=0 mode_count=0
  environment_profile_create_owned_workspace tar "${mkdir_path}" || return
  work="${ENVIRONMENT_PROFILE_OWNED_WORKSPACE}"
  token="${ENVIRONMENT_PROFILE_OWNED_TOKEN}"
  trap 'environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${rm_path}" >/dev/null 2>&1 || true' EXIT
  context="${work}/context"
  "${mkdir_path}" -- "${context}" || return
  printf 'FROM scratch\n' >"${context}/Dockerfile" || return
  printf 'server\n' >"${context}/server" || return
  "${chmod_path}" 0644 "${context}/Dockerfile" || return
  "${chmod_path}" 0755 "${context}/server" || return
  first="${work}/first.tar"
  second="${work}/second.tar"
  "${tar_path}" --sort=name --format=ustar --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner -cf "${first}" \
    -C "${context}" Dockerfile server || return
  "${tar_path}" --sort=name --format=ustar --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner -cf "${second}" \
    -C "${context}" Dockerfile server || return
  [[ -f "${first}" && -f "${second}" ]] || return 1
  "${cmp_path}" --silent -- "${first}" "${second}" || return
  entries="$("${tar_path}" -tf "${first}")" || return
  [[ "${entries}" == $'Dockerfile\nserver' ]] || return 1
  environment_profile_has_ustar_header "${od_path}" "${first}" 0 || return
  environment_profile_has_ustar_header "${od_path}" "${first}" 1024 || return
  listing="$(TZ=UTC0 "${tar_path}" --numeric-owner --full-time -tvf "${first}")" || return
  while IFS= read -r line; do
    [[ "${line}" == *' 0/0 '* ]] && ((owner_count += 1))
    [[ "${line}" == *'1970-01-01 00:00:00'* ]] && ((time_count += 1))
    [[ "${line}" == -rw-r--r--*' Dockerfile' ]] && ((mode_count += 1))
    [[ "${line}" == -rwxr-xr-x*' server' ]] && ((mode_count += 1))
  done <<<"${listing}"
  [[ "${owner_count}" -eq 2 && "${time_count}" -eq 2 &&
    "${mode_count}" -eq 2 ]] || return 1
  modes="${work}/modes"
  "${mkdir_path}" -- "${modes}" || return
  (umask 000 && "${tar_path}" -xf "${first}" -C "${modes}" --no-same-owner) || return
  [[ "$("${stat_path}" -c %a -- "${modes}/Dockerfile")" == 644 &&
  "$("${stat_path}" -c %a -- "${modes}/server")" == 755 ]] || return 1
  selected="${work}/selected"
  extracted="${work}/extracted"
  "${mkdir_path}" -- "${extracted}" || return
  printf 'Dockerfile\0server\0' >"${selected}" || return
  (
    cd -- "${context}" || exit
    "${tar_path}" --null --verbatim-files-from --files-from="${selected}" \
      --create --file=-
  ) | "${tar_path}" --extract --file=- --directory="${extracted}" \
    --no-same-owner --no-same-permissions || return
  "${cmp_path}" --silent -- \
    "${context}/Dockerfile" "${extracted}/Dockerfile" || return
  "${cmp_path}" --silent -- "${context}/server" "${extracted}/server" || return
  compressed="${work}/payload.tar.gz"
  expanded="${work}/expanded"
  "${mkdir_path}" -- "${expanded}" || return
  "${tar_path}" -czf "${compressed}" -C "${context}" Dockerfile server || return
  "${tar_path}" -xzf "${compressed}" -C "${expanded}" \
    --no-same-owner --no-same-permissions || return
  "${cmp_path}" --silent -- "${context}/server" "${expanded}/server" || return
  environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${rm_path}" || return
  work=""
)

environment_profile_check_tar() {
  local tar_path="$1" stat_path="$2" od_path="$3" mkdir_path="$4"
  local rm_path="$5" chmod_path="$6" cmp_path="$7"
  local output first_line
  output="$("${tar_path}" --version 2>&1)" || {
    environment_profile_fail tar-capability "unable to query GNU tar"
    return
  }
  first_line="${output%%$'\n'*}"
  if [[ ! "${first_line}" =~ ^tar[[:space:]]\(GNU[[:space:]]tar\)[[:space:]]([0-9]+\.[0-9]+) ]]; then
    environment_profile_fail tar-capability "GNU tar identity is malformed"
    return
  fi
  if ! environment_profile_prove_tar_stream \
    "${tar_path}" "${stat_path}" "${od_path}" "${mkdir_path}" "${rm_path}" \
    "${chmod_path}" "${cmp_path}"; then
    environment_profile_fail tar-capability \
      "deterministic ustar flags or stream semantics are unavailable"
    return
  fi
  ENVIRONMENT_PROFILE_TAR_VERSION="${BASH_REMATCH[1]}"
}

environment_profile_check_timeout() {
  local timeout_path="$1"
  local bash_path="$2"
  local output first_line status=0
  output="$("${timeout_path}" --version 2>&1)" || {
    environment_profile_fail timeout-capability "unable to query GNU timeout"
    return
  }
  first_line="${output%%$'\n'*}"
  if [[ ! "${first_line}" =~ ^timeout[[:space:]]\(GNU[[:space:]]coreutils\)[[:space:]]([0-9]+\.[0-9]+) ]]; then
    environment_profile_fail timeout-capability "GNU timeout identity is malformed"
    return
  fi
  "${timeout_path}" --foreground --signal=TERM --kill-after=0.1s 0.1s \
    "${bash_path}" -c 'trap "" TERM; while :; do :; done' \
    >/dev/null 2>&1 || status=$?
  if [[ "${status}" -ne 137 ]]; then
    environment_profile_fail timeout-capability \
      "--foreground and --kill-after behavior returned ${status}, expected 137"
    return
  fi
  status=0
  "${timeout_path}" --foreground --signal=TERM --kill-after=0.1s 0.1s \
    "${bash_path}" -c 'trap "exit 0" TERM; while :; do :; done' \
    >/dev/null 2>&1 || status=$?
  if [[ "${status}" -ne 124 ]]; then
    environment_profile_fail timeout-capability \
      "foreground timeout behavior returned ${status}, expected 124"
    return
  fi
  ENVIRONMENT_PROFILE_TIMEOUT_VERSION="${BASH_REMATCH[1]}"
}

environment_profile_read_proc_stat() {
  local proc_root="$1"
  local record fields state parent process_group _
  if [[ ! -r "${proc_root}/self/stat" ]]; then
    environment_profile_fail process-state "${proc_root}/self/stat is unavailable"
    return
  fi
  IFS= read -r record <"${proc_root}/self/stat" || {
    environment_profile_fail process-state "unable to read process state"
    return
  }
  fields="${record##*) }"
  read -r state parent process_group _ <<<"${fields}" || true
  if [[ "${fields}" == "${record}" || ! "${state}" =~ ^[A-Za-z]$ ||
    ! "${parent}" =~ ^[0-9]+$ || ! "${process_group}" =~ ^[0-9]+$ ]]; then
    environment_profile_fail process-state "Linux /proc stat fields are malformed"
    return
  fi
}

environment_profile_prove_process_group() (
  local sleep_path="$1" child="" fields group status=0
  # Invoked by the EXIT trap below.
  # shellcheck disable=SC2329
  cleanup_environment_process() {
    trap - EXIT
    [[ -z "${child}" ]] || kill -KILL -- "-${child}" 2>/dev/null || true
    [[ -z "${child}" ]] || wait "${child}" 2>/dev/null || true
  }
  trap cleanup_environment_process EXIT
  set -m
  "${sleep_path}" infinity &
  child=$!
  fields="$(linux_process_read_stat "${child}")" || status=$?
  group="${fields#* }"
  if [[ "${status}" -ne 0 || "${group}" != "${child}" ]] ||
    ! linux_process_group_has_live_member "${child}"; then
    environment_profile_fail process-state \
      "spawned job process-group visibility is unavailable"
    return 1
  fi
  kill -KILL -- "-${child}" 2>/dev/null || return
  wait "${child}" 2>/dev/null || true
  if linux_process_or_group_is_live "${child}"; then
    environment_profile_fail process-state \
      "spawned job process group remained live after reap"
    return 1
  fi
  child=""
)

environment_profile_check_proc() {
  local proc_root="${1:-/proc}" sleep_path="${2:-}"
  environment_profile_read_proc_stat "${proc_root}" || return
  if [[ "${proc_root}" == /proc ]]; then
    if ! linux_process_state "$$" >/dev/null; then
      environment_profile_fail process-state \
        "shared Linux process-state parser cannot inspect the current shell"
      return
    fi
    [[ -n "${sleep_path}" ]] || return 2
    environment_profile_prove_process_group "${sleep_path}" || return
  fi
}

environment_profile_validate_simple_identity() {
  [[ "$1" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]]
}

environment_profile_validate_docker_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

environment_profile_validate_docker_api() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+$ ]]
}

environment_profile_check_docker_build_help() {
  local response="$1"
  local line
  local buildx=false stdin_context=false network=false pull=false
  local no_cache=false progress=false progress_next=false
  if ((${#response} > 16384)); then
    environment_profile_fail docker-build "help response exceeded 16384 bytes"
    return
  fi
  while IFS= read -r line; do
    [[ "${line}" == *'docker buildx build'* ]] && buildx=true
    [[ "${line}" == *'PATH | URL | -'* ]] && stdin_context=true
    [[ "${line}" =~ (^|[[:space:]])--network([[:space:]]|$) ]] && network=true
    [[ "${line}" =~ (^|[[:space:]])--pull([[:space:]]|$) ]] && pull=true
    [[ "${line}" =~ (^|[[:space:]])--no-cache([[:space:]]|$) ]] && no_cache=true
    if [[ "${line}" =~ (^|[[:space:]])--progress([[:space:]]|$) ]]; then
      progress_next=true
      [[ "${line}" =~ (^|[^[:alnum:]_])plain([^[:alnum:]_]|$) ]] && progress=true
      continue
    fi
    if [[ "${progress_next}" == true ]]; then
      if [[ "${line}" =~ ^[[:space:]]+\(.*\"plain\" ]]; then
        progress=true
      fi
      progress_next=false
    fi
  done <<<"${response}"
  [[ "${buildx}" == true ]] || {
    environment_profile_fail docker-build "BuildKit buildx response is absent"
    return
  }
  [[ "${stdin_context}" == true ]] || {
    environment_profile_fail docker-build "stdin tar context is unavailable"
    return
  }
  [[ "${network}" == true ]] || {
    environment_profile_fail docker-build "--network=none is unavailable"
    return
  }
  [[ "${pull}" == true ]] || {
    environment_profile_fail docker-build "--pull=false is unavailable"
    return
  }
  [[ "${no_cache}" == true ]] || {
    environment_profile_fail docker-build "--no-cache is unavailable"
    return
  }
  if [[ "${progress}" != true ]]; then
    environment_profile_fail docker-build \
      "BuildKit response lacks --progress=plain"
    return
  fi
}

environment_profile_check_docker_local_help() {
  local inspect_help="$1"
  local remove_help="$2"
  local line inspect=false format=false remove=false
  if ((${#inspect_help} > 16384 || ${#remove_help} > 16384)); then
    environment_profile_fail docker-local "help response exceeded 16384 bytes"
    return
  fi
  while IFS= read -r line; do
    [[ "${line}" == *'docker image inspect'* ]] && inspect=true
    [[ "${line}" =~ (^|[[:space:]])--format([[:space:]]|$) ]] && format=true
  done <<<"${inspect_help}"
  while IFS= read -r line; do
    [[ "${line}" == *'docker image rm'* ]] && remove=true
  done <<<"${remove_help}"
  if [[ "${inspect}" != true || "${format}" != true ]]; then
    environment_profile_fail docker-local "image inspect --format is unavailable"
    return
  fi
  if [[ "${remove}" != true ]]; then
    environment_profile_fail docker-local "local image removal is unavailable"
    return
  fi
}

environment_profile_check_buildkit_parser() (
  local mkdir_path="$1" rm_path="$2" work token log expected observed module
  module="$(dirname -- "${BASH_SOURCE[0]}")/../kubernetes/buildkit-result.sh"
  # shellcheck source=../kubernetes/buildkit-result.sh
  source "${module}" || {
    environment_profile_fail buildkit-result \
      "shared BuildKit result parser module is unavailable"
    return
  }
  environment_profile_create_owned_workspace buildkit "${mkdir_path}" || return
  work="${ENVIRONMENT_PROFILE_OWNED_WORKSPACE}"
  token="${ENVIRONMENT_PROFILE_OWNED_TOKEN}"
  trap 'environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${rm_path}" >/dev/null 2>&1 || true' EXIT
  log="${work}/build.log"
  expected="sha256:$(printf 'a%.0s' {1..64})"
  printf '#1 writing image %s done\n' "${expected}" >"${log}" || return
  observed="$(buildkit_result_config_id "${log}")" || {
    environment_profile_fail buildkit-result \
      "shared exact BuildKit result parser is unavailable"
    return
  }
  if [[ "${observed}" != "${expected}" ]]; then
    environment_profile_fail buildkit-result \
      "shared BuildKit result parser changed identity"
    return
  fi
  environment_profile_remove_owned_workspace \
    "${work}" "${token}" "${rm_path}" || return
  work=""
)

environment_profile_check_docker() {
  local docker_path="$1"
  local timeout_path="$2"
  local mkdir_path="$3" rm_path="$4"
  local identity extra build_help inspect_help remove_help
  local identity_format
  identity_format='{{.Client.Version}}|{{.Server.Version}}|'
  identity_format+='{{.Client.APIVersion}}|{{.Server.APIVersion}}|'
  identity_format+='{{.Server.Os}}|{{.Server.Arch}}'
  identity="$("${timeout_path}" --foreground --kill-after=2s 15s \
    "${docker_path}" version --format "${identity_format}" \
    2>/dev/null)" || {
    environment_profile_fail docker-daemon "Docker daemon is unreachable within 15s"
    return
  }
  if [[ "${identity}" == *$'\n'* || "${identity}" == *$'\r'* ||
    "${identity}" == *$'\t'* ]]; then
    environment_profile_fail docker-daemon "Docker identity response is malformed"
    return
  fi
  IFS='|' read -r ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION \
    ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION \
    ENVIRONMENT_PROFILE_DOCKER_CLIENT_API \
    ENVIRONMENT_PROFILE_DOCKER_SERVER_API docker_os docker_arch extra \
    <<<"${identity}" || true
  if [[ -n "${extra}" ]] ||
    ! environment_profile_validate_docker_version \
      "${ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION}" ||
    ! environment_profile_validate_docker_version \
      "${ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION}" ||
    ! environment_profile_validate_docker_api \
      "${ENVIRONMENT_PROFILE_DOCKER_CLIENT_API}" ||
    ! environment_profile_validate_docker_api \
      "${ENVIRONMENT_PROFILE_DOCKER_SERVER_API}"; then
    environment_profile_fail docker-daemon "Docker identity response is malformed"
    return
  fi
  if [[ "${docker_os}" != linux || "${docker_arch}" != amd64 ]]; then
    environment_profile_fail docker-daemon \
      "daemon requires linux/amd64; observed ${docker_os}/${docker_arch}"
    return
  fi
  build_help="$(DOCKER_BUILDKIT=1 "${timeout_path}" --foreground \
    --kill-after=2s 10s "${docker_path}" build --help 2>&1)" || {
    environment_profile_fail docker-build "unable to query BuildKit build surface"
    return
  }
  environment_profile_check_docker_build_help "${build_help}" || return
  environment_profile_check_buildkit_parser "${mkdir_path}" "${rm_path}" || return
  inspect_help="$("${timeout_path}" --foreground --kill-after=2s 10s \
    "${docker_path}" image inspect --help 2>&1)" || {
    environment_profile_fail docker-local \
      "unable to query local image inspect surface"
    return
  }
  remove_help="$("${timeout_path}" --foreground --kill-after=2s 10s \
    "${docker_path}" image rm --help 2>&1)" || {
    environment_profile_fail docker-local \
      "unable to query local image removal surface"
    return
  }
  environment_profile_check_docker_local_help "${inspect_help}" "${remove_help}"
}

environment_profile_verify_aqua_state() {
  if [[ "${PROJECT_AQUA_VERIFIED}" != true ]]; then
    verify_existing_aqua environment >/dev/null 2>&1 || {
      environment_profile_fail project-state \
        "Aqua state is partial or untrusted; run make bootstrap"
      return
    }
    PROJECT_AQUA_VERIFIED=true
  fi
}

environment_profile_read_aqua_identities() {
  local timeout_path="$1"
  local observation_root="$2"
  local output package version registry extra
  local kind_count=0 kubectl_count=0
  environment_profile_verify_aqua_state || return
  output="$(AQUA_ROOT_DIR="${observation_root}" AQUA_DISABLE_LAZY_INSTALL=true \
    "${timeout_path}" --foreground \
    --kill-after=2s 10s "${AQUA_BIN}" --config "${AQUA_CONFIG}" list -i \
    2>/dev/null)" || {
    environment_profile_fail project-state "unable to read trusted Aqua package identities"
    return
  }
  if ((${#output} > 8192)); then
    environment_profile_fail project-state "Aqua package identity response exceeded 8192 bytes"
    return
  fi
  while IFS=$'\t' read -r package version registry extra; do
    [[ -z "${extra}" && "${registry}" == standard ]] || continue
    case "${package}" in
      kubernetes-sigs/kind)
        ENVIRONMENT_PROFILE_KIND_IDENTITY="${version}"
        ((kind_count += 1))
        ;;
      kubernetes/kubectl)
        ENVIRONMENT_PROFILE_KUBECTL_IDENTITY="${version}"
        ((kubectl_count += 1))
        ;;
    esac
  done <<<"${output}"
  if [[ "${kind_count}" -ne 1 || "${kubectl_count}" -ne 1 ||
    ! "${ENVIRONMENT_PROFILE_KIND_IDENTITY}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ||
    ! "${ENVIRONMENT_PROFILE_KUBECTL_IDENTITY}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    environment_profile_fail project-state \
      "trusted Aqua kind/kubectl package identities are absent or ambiguous"
    return
  fi
  ENVIRONMENT_PROFILE_AQUA_IDENTITY="${AQUA_VERSION}"
}

environment_profile_check_kind_output() {
  local output="$1"
  local expected="$2"
  if [[ ! "${output}" =~ ^kind[[:space:]](v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]go[^[:space:]]+[[:space:]]linux/amd64$ ||
    "${BASH_REMATCH[1]:-}" != "${expected}" ]]; then
    environment_profile_fail project-tool "kind identity differs from trusted Aqua identity"
    return
  fi
}

environment_profile_check_kubectl_output() {
  local output="$1"
  local expected="$2"
  local line version="" platform="" version_count=0 platform_count=0
  while IFS= read -r line; do
    if [[ "${line}" =~ ^[[:space:]]*\"gitVersion\":[[:space:]]\"(v[0-9]+\.[0-9]+\.[0-9]+)\",?$ ]]; then
      version="${BASH_REMATCH[1]}"
      ((version_count += 1))
    elif [[ "${line}" =~ ^[[:space:]]*\"platform\":[[:space:]]\"([^\"]+)\",?$ ]]; then
      platform="${BASH_REMATCH[1]}"
      ((platform_count += 1))
    fi
  done <<<"${output}"
  if [[ "${version_count}" -ne 1 || "${version}" != "${expected}" ||
    "${platform_count}" -ne 1 || "${platform}" != linux/amd64 ]]; then
    environment_profile_fail project-tool \
      "kubectl client identity/platform differs from trusted Aqua identity"
    return
  fi
}

environment_profile_validate_asset_id() {
  local asset_id="$1" component
  local -a components
  [[ "${asset_id}" =~ ^[0-9A-Za-z][0-9A-Za-z._+/-]{0,511}$ &&
    "${asset_id}" != /* && "${asset_id}" != *//* ]] || return
  IFS=/ read -r -a components <<<"${asset_id}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != . && "${component}" != .. ]] || return
  done
}

environment_profile_checksum_for_asset() {
  local checksum_lock="$1" asset_id="$2" line checksum_line algorithm_line
  local expected="" count=0 lines=0 target checksum_pattern
  ENVIRONMENT_PROFILE_EXPECTED_TOOL_SHA256=""
  [[ -f "${checksum_lock}" && ! -L "${checksum_lock}" ]] || return
  environment_profile_validate_asset_id "${asset_id}" || return
  target="      \"id\": \"${asset_id}\","
  checksum_pattern='^      "checksum": "([0-9A-F]{64})",$'
  while IFS= read -r line || [[ -n "${line}" ]]; do
    ((lines += 1))
    ((lines <= 10000)) || return
    [[ "${line}" == "${target}" ]] || continue
    ((count += 1))
    IFS= read -r checksum_line || return
    IFS= read -r algorithm_line || return
    [[ "${checksum_line}" =~ ${checksum_pattern} ]] || return
    expected="${BASH_REMATCH[1]}"
    [[ "${algorithm_line}" == '      "algorithm": "sha256"' ]] || return
  done <"${checksum_lock}"
  [[ "${count}" -eq 1 && -n "${expected}" ]] || return
  ENVIRONMENT_PROFILE_EXPECTED_TOOL_SHA256="${expected,,}"
}

environment_profile_verify_installed_tool_checksum() {
  local resolved="$1" production_root="$2" checksum_lock="$3"
  local sha256sum_path="$4" command_name="$5"
  local relative asset_id output observed
  relative="${resolved#"${production_root}"/pkgs/}"
  if [[ "${relative}" == "${resolved}" || "${relative}" != */* ]]; then
    environment_profile_fail project-tool \
      "installed ${command_name} asset identity is unsafe"
    return
  fi
  asset_id="${relative%/*}"
  if ! environment_profile_checksum_for_asset "${checksum_lock}" "${asset_id}"; then
    environment_profile_fail project-tool \
      "installed ${command_name} checksum lock is absent or ambiguous"
    return
  fi
  output="$("${sha256sum_path}" -- "${resolved}")" || return
  observed="${output%%[[:space:]]*}"
  if [[ "${output}" == *$'\n'* || ! "${observed}" =~ ^[0-9a-f]{64}$ ||
    "${observed}" != "${ENVIRONMENT_PROFILE_EXPECTED_TOOL_SHA256}" ]]; then
    environment_profile_fail project-tool \
      "installed ${command_name} bytes differ from checksum lock"
    return
  fi
}

environment_profile_resolve_installed_tool() {
  local timeout_path="$1" command_name="$2"
  local observation_root="$3" production_root="$4"
  local checksum_lock="$5" sha256sum_path="$6"
  local output root resolved
  case "${command_name}" in
    kind | kubectl) ;;
    *) return 2 ;;
  esac
  managed_tool_path "${command_name}" >/dev/null || {
    environment_profile_fail project-tool \
      "managed ${command_name} proxy is absent or untrusted"
    return
  }
  ENVIRONMENT_PROFILE_INSTALLED_TOOL_PROXY="${MANAGED_TOOL_PATH}"
  output="$(AQUA_ROOT_DIR="${observation_root}" AQUA_DISABLE_LAZY_INSTALL=true \
    "${timeout_path}" --foreground --kill-after=2s 10s "${AQUA_BIN}" \
    --config "${AQUA_CONFIG}" which "${command_name}" 2>/dev/null)" || {
    environment_profile_fail project-tool \
      "installed ${command_name} identity is absent"
    return
  }
  if [[ -z "${output}" || "${output}" != /* || "${output}" == *$'\n'* ||
    "${output}" == *$'\r'* ||
    "${output}" == *$'\t'* || -L "${output}" || ! -f "${output}" ||
    ! -x "${output}" ]]; then
    environment_profile_fail project-tool \
      "installed ${command_name} path is unsafe"
    return
  fi
  case "${output}" in
    "${observation_root}"/pkgs/*) ;;
    *)
      environment_profile_fail project-tool \
        "installed ${command_name} path escaped the observation root"
      return
      ;;
  esac
  root="$("${AQUA_TRUST_READLINK}" -f -- "${production_root}")" || return
  resolved="$("${AQUA_TRUST_READLINK}" -f -- "${output}")" || return
  case "${resolved}" in
    "${root}"/pkgs/*) ;;
    *)
      environment_profile_fail project-tool \
        "installed ${command_name} escaped project Aqua state"
      return
      ;;
  esac
  environment_profile_verify_installed_tool_checksum \
    "${resolved}" "${root}" "${checksum_lock}" \
    "${sha256sum_path}" "${command_name}" || return
  ENVIRONMENT_PROFILE_INSTALLED_TOOL_PATH="${resolved}"
}

environment_profile_prepare_aqua_observation() {
  local observation_root="$1"
  if [[ -L "${AQUA_ROOT_DIR}/registries" ||
    ! -d "${AQUA_ROOT_DIR}/registries" ||
    -L "${AQUA_ROOT_DIR}/pkgs" || ! -d "${AQUA_ROOT_DIR}/pkgs" ]]; then
    environment_profile_fail project-state \
      "project Aqua registry or package state is unsafe"
    return
  fi
  mkdir -- "${observation_root}/registry-cache" "${observation_root}/metadata" \
    "${observation_root}/temp" || return
  ln -s -- "${AQUA_ROOT_DIR}/registries" \
    "${observation_root}/registries" || return
  ln -s -- "${AQUA_ROOT_DIR}/pkgs" "${observation_root}/pkgs" || return
}

environment_profile_query_project_tool() {
  local timeout_path="$1" proxy_path="$2" observation_root="$3"
  local command_name="$4"
  case "${command_name}" in
    kind)
      AQUA_ROOT_DIR="${observation_root}" AQUA_DISABLE_LAZY_INSTALL=true \
        "${timeout_path}" --foreground --kill-after=2s 10s \
        env AQUA_ROOT_DIR="${observation_root}" AQUA_DISABLE_LAZY_INSTALL=true \
        "${proxy_path}" version
      ;;
    kubectl)
      AQUA_ROOT_DIR="${observation_root}" AQUA_DISABLE_LAZY_INSTALL=true \
        "${timeout_path}" --foreground --kill-after=2s 10s \
        env AQUA_ROOT_DIR="${observation_root}" AQUA_DISABLE_LAZY_INSTALL=true \
        "${proxy_path}" version --client=true -o json
      ;;
    *) return 2 ;;
  esac
}

environment_profile_observe_project_tools() (
  local timeout_path="$1" sha256sum_path="$2" checksum_lock="$3"
  local observation_root token kind_path kubectl_path kind_proxy kubectl_proxy
  local kind_output kubectl_output production_root="${AQUA_ROOT_DIR}"
  environment_profile_create_owned_workspace \
    aqua "${ENVIRONMENT_PROFILE_TRUSTED_MKDIR_PATH}" || return
  observation_root="${ENVIRONMENT_PROFILE_OWNED_WORKSPACE}"
  token="${ENVIRONMENT_PROFILE_OWNED_TOKEN}"
  trap 'environment_profile_remove_owned_workspace \
    "${observation_root}" "${token}" "${ENVIRONMENT_PROFILE_TRUSTED_RM_PATH}" \
    >/dev/null 2>&1 || true' EXIT
  environment_profile_verify_aqua_state || return
  environment_profile_prepare_aqua_observation "${observation_root}" || return
  environment_profile_read_aqua_identities \
    "${timeout_path}" "${observation_root}" || return
  environment_profile_resolve_installed_tool \
    "${timeout_path}" kind "${observation_root}" "${production_root}" \
    "${checksum_lock}" "${sha256sum_path}" || return
  kind_path="${ENVIRONMENT_PROFILE_INSTALLED_TOOL_PATH}"
  kind_proxy="${ENVIRONMENT_PROFILE_INSTALLED_TOOL_PROXY}"
  environment_profile_resolve_installed_tool \
    "${timeout_path}" kubectl "${observation_root}" "${production_root}" \
    "${checksum_lock}" "${sha256sum_path}" || return
  kubectl_path="${ENVIRONMENT_PROFILE_INSTALLED_TOOL_PATH}"
  kubectl_proxy="${ENVIRONMENT_PROFILE_INSTALLED_TOOL_PROXY}"
  [[ -n "${kind_path}" && -n "${kubectl_path}" ]] || return
  kind_output="$(environment_profile_query_project_tool \
    "${timeout_path}" "${kind_proxy}" "${observation_root}" kind \
    2>/dev/null)" || {
    environment_profile_fail project-tool "managed kind identity command failed"
    return
  }
  kubectl_output="$(environment_profile_query_project_tool \
    "${timeout_path}" "${kubectl_proxy}" "${observation_root}" kubectl \
    2>/dev/null)" || {
    environment_profile_fail project-tool "managed kubectl identity command failed"
    return
  }
  environment_profile_check_kind_output \
    "${kind_output}" "${ENVIRONMENT_PROFILE_KIND_IDENTITY}" || return
  environment_profile_check_kubectl_output \
    "${kubectl_output}" "${ENVIRONMENT_PROFILE_KUBECTL_IDENTITY}" || return
  environment_profile_remove_owned_workspace \
    "${observation_root}" "${token}" \
    "${ENVIRONMENT_PROFILE_TRUSTED_RM_PATH}" || return
  observation_root=""
  printf '%s\t%s\t%s\n' "${ENVIRONMENT_PROFILE_AQUA_IDENTITY}" \
    "${ENVIRONMENT_PROFILE_KIND_IDENTITY}" \
    "${ENVIRONMENT_PROFILE_KUBECTL_IDENTITY}"
)

environment_profile_check_project_tools() {
  local timeout_path="$1" sha256sum_path="$2" checksum_lock="$3"
  local record aqua_identity kind_identity kubectl_identity extra
  record="$(environment_profile_observe_project_tools \
    "${timeout_path}" "${sha256sum_path}" "${checksum_lock}")" || return
  IFS=$'\t' read -r aqua_identity kind_identity kubectl_identity extra \
    <<<"${record}" || true
  if [[ -n "${extra}" || "${aqua_identity}" != "${AQUA_VERSION}" ||
    ! "${kind_identity}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ||
    ! "${kubectl_identity}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    environment_profile_fail project-tool \
      "bounded project tool observation is malformed"
    return
  fi
  ENVIRONMENT_PROFILE_AQUA_IDENTITY="${aqua_identity}"
  ENVIRONMENT_PROFILE_KIND_IDENTITY="${kind_identity}"
  ENVIRONMENT_PROFILE_KUBECTL_IDENTITY="${kubectl_identity}"
  ENVIRONMENT_PROFILE_PROJECT_STATE="ready"
}

environment_profile_classify_project() {
  local timeout_path="$1"
  local require_toolchain="$2"
  local sha256sum_path="$3" checksum_lock="$4"
  if [[ ! -e "${AQUA_ROOT_DIR}" && ! -L "${AQUA_ROOT_DIR}" &&
    ! -e "${AQUA_BIN}" && ! -L "${AQUA_BIN}" ]]; then
    ENVIRONMENT_PROFILE_PROJECT_STATE="ready_for_bootstrap"
    ENVIRONMENT_PROFILE_AQUA_IDENTITY="not_installed"
    ENVIRONMENT_PROFILE_KIND_IDENTITY="not_installed"
    ENVIRONMENT_PROFILE_KUBECTL_IDENTITY="not_installed"
    if [[ "${require_toolchain}" == true ]]; then
      environment_profile_fail project-state \
        "machine evidence requires make bootstrap first"
      return
    fi
    return 0
  fi
  environment_profile_check_project_tools \
    "${timeout_path}" "${sha256sum_path}" "${checksum_lock}"
}

environment_profile_run() {
  local base_only="$1"
  local require_toolchain="$2"
  local bash_path curl_path tar_path timeout_path docker_path
  local sha256sum_path readlink_path stat_path mktemp_path cmp_path
  local diff_path chmod_path ln_path mkfifo_path mkdir_path od_path rm_path
  local sleep_path uname_path
  local LC_ALL=C
  export LC_ALL
  environment_profile_sanitize_child_environment
  environment_profile_require_host_commands || return
  bash_path="${ENVIRONMENT_PROFILE_HOST_PATHS[bash]}"
  chmod_path="${ENVIRONMENT_PROFILE_HOST_PATHS[chmod]}"
  cmp_path="${ENVIRONMENT_PROFILE_HOST_PATHS[cmp]}"
  curl_path="${ENVIRONMENT_PROFILE_HOST_PATHS[curl]}"
  diff_path="${ENVIRONMENT_PROFILE_HOST_PATHS[diff]}"
  ln_path="${ENVIRONMENT_PROFILE_HOST_PATHS[ln]}"
  mkdir_path="${ENVIRONMENT_PROFILE_HOST_PATHS[mkdir]}"
  mkfifo_path="${ENVIRONMENT_PROFILE_HOST_PATHS[mkfifo]}"
  mktemp_path="${ENVIRONMENT_PROFILE_HOST_PATHS[mktemp]}"
  od_path="${ENVIRONMENT_PROFILE_HOST_PATHS[od]}"
  readlink_path="${ENVIRONMENT_PROFILE_HOST_PATHS[readlink]}"
  rm_path="${ENVIRONMENT_PROFILE_HOST_PATHS[rm]}"
  sha256sum_path="${ENVIRONMENT_PROFILE_HOST_PATHS[sha256sum]}"
  sleep_path="${ENVIRONMENT_PROFILE_HOST_PATHS[sleep]}"
  stat_path="${ENVIRONMENT_PROFILE_HOST_PATHS[stat]}"
  tar_path="${ENVIRONMENT_PROFILE_HOST_PATHS[tar]}"
  timeout_path="${ENVIRONMENT_PROFILE_HOST_PATHS[timeout]}"
  uname_path="${ENVIRONMENT_PROFILE_HOST_PATHS[uname]}"
  environment_profile_check_platform "${uname_path}" || return
  environment_profile_check_core_utilities \
    "${sha256sum_path}" "${readlink_path}" "${stat_path}" "${mktemp_path}" \
    "${cmp_path}" "${diff_path}" "${chmod_path}" "${ln_path}" \
    "${mkfifo_path}" "${mkdir_path}" "${od_path}" "${rm_path}" || return
  ENVIRONMENT_PROFILE_TRUSTED_MKDIR_PATH="${mkdir_path}"
  ENVIRONMENT_PROFILE_TRUSTED_RM_PATH="${rm_path}"
  environment_profile_check_host_utilities || return
  environment_profile_check_curl "${curl_path}" || return
  environment_profile_check_bash "${bash_path}" || return
  environment_profile_check_tar \
    "${tar_path}" "${stat_path}" "${od_path}" \
    "${mkdir_path}" "${rm_path}" "${chmod_path}" "${cmp_path}" || return
  environment_profile_check_timeout "${timeout_path}" "${bash_path}" || return
  environment_profile_check_proc /proc "${sleep_path}" || return
  [[ "${base_only}" != true ]] || return 0
  environment_profile_resolve_command docker || return
  docker_path="${ENVIRONMENT_PROFILE_COMMAND_PATH}"
  environment_profile_check_docker \
    "${docker_path}" "${timeout_path}" "${mkdir_path}" "${rm_path}" || return
  environment_profile_classify_project \
    "${timeout_path}" "${require_toolchain}" "${AQUA_TRUST_SHA256SUM}" \
    "${PLATFORM_ROOT}/aqua-checksums.json"
}

environment_profile_render_evidence() {
  printf '%s\n' \
    "SCHEMA=${ENVIRONMENT_PROFILE_SCHEMA}" \
    'EVIDENCE_SEMANTICS=invocation_scoped_non_destructive' \
    'OBSERVATION_TIME_SEMANTICS=invocation_only_not_persisted' \
    "OS=${ENVIRONMENT_PROFILE_OS}" \
    "ARCHITECTURE=${ENVIRONMENT_PROFILE_ARCHITECTURE}" \
    "BASH_VERSION=${ENVIRONMENT_PROFILE_BASH_VERSION}" \
    'BASH_CAPABILITY=job_control_coproc_wait' \
    "CURL_VERSION=${ENVIRONMENT_PROFILE_CURL_VERSION}" \
    'CURL_CAPABILITY=http_https_bounded_transfer' \
    'COREUTILS_CAPABILITY=sha256_link_stat_temp_cmp_diff_fifo_cleanup' \
    'HOST_COMMAND_CAPABILITY=behavioral_exact_surface' \
    "TAR_VERSION=${ENVIRONMENT_PROFILE_TAR_VERSION}" \
    'TAR_CAPABILITY=deterministic_ustar_null_stream_extract_gzip' \
    "TIMEOUT_VERSION=${ENVIRONMENT_PROFILE_TIMEOUT_VERSION}" \
    'TIMEOUT_CAPABILITY=foreground_term_kill_after_statuses' \
    'PROCESS_STATE_CAPABILITY=linux_proc_stat_job_group_reap' \
    "DOCKER_CLIENT_VERSION=${ENVIRONMENT_PROFILE_DOCKER_CLIENT_VERSION}" \
    "DOCKER_SERVER_VERSION=${ENVIRONMENT_PROFILE_DOCKER_SERVER_VERSION}" \
    "DOCKER_CLIENT_API=${ENVIRONMENT_PROFILE_DOCKER_CLIENT_API}" \
    "DOCKER_SERVER_API=${ENVIRONMENT_PROFILE_DOCKER_SERVER_API}" \
    'DOCKER_DAEMON_PLATFORM=linux_amd64' \
    'DOCKER_BUILD_SURFACE=stdin_network_none_pull_false_no_cache_plain' \
    'BUILDKIT_RESULT_PROOF=parser_ready_runtime_execution_not_run' \
    'DOCKER_LOCAL_OPERATIONS=inspect_format_local_remove' \
    "PROJECT_BOOTSTRAP_STATE=${ENVIRONMENT_PROFILE_PROJECT_STATE}" \
    "AQUA_IDENTITY=${ENVIRONMENT_PROFILE_AQUA_IDENTITY}" \
    "KIND_IDENTITY=${ENVIRONMENT_PROFILE_KIND_IDENTITY}" \
    "KUBECTL_IDENTITY=${ENVIRONMENT_PROFILE_KUBECTL_IDENTITY}"
}

environment_profile_validate_evidence_value() {
  local key="$1" value="$2"
  case "${key}" in
    SCHEMA) [[ "${value}" == "${ENVIRONMENT_PROFILE_SCHEMA}" ]] ;;
    EVIDENCE_SEMANTICS) [[ "${value}" == invocation_scoped_non_destructive ]] ;;
    OBSERVATION_TIME_SEMANTICS) [[ "${value}" == invocation_only_not_persisted ]] ;;
    OS) [[ "${value}" == linux ]] ;;
    ARCHITECTURE) [[ "${value}" == amd64 ]] ;;
    BASH_VERSION) [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
    BASH_CAPABILITY) [[ "${value}" == job_control_coproc_wait ]] ;;
    CURL_VERSION) [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
    CURL_CAPABILITY) [[ "${value}" == http_https_bounded_transfer ]] ;;
    COREUTILS_CAPABILITY)
      [[ "${value}" == sha256_link_stat_temp_cmp_diff_fifo_cleanup ]]
      ;;
    HOST_COMMAND_CAPABILITY) [[ "${value}" == behavioral_exact_surface ]] ;;
    TAR_VERSION | TIMEOUT_VERSION)
      [[ "${value}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
      ;;
    TAR_CAPABILITY) [[ "${value}" == deterministic_ustar_null_stream_extract_gzip ]] ;;
    TIMEOUT_CAPABILITY) [[ "${value}" == foreground_term_kill_after_statuses ]] ;;
    PROCESS_STATE_CAPABILITY) [[ "${value}" == linux_proc_stat_job_group_reap ]] ;;
    DOCKER_CLIENT_VERSION | DOCKER_SERVER_VERSION)
      environment_profile_validate_docker_version "${value}"
      ;;
    DOCKER_CLIENT_API | DOCKER_SERVER_API)
      environment_profile_validate_docker_api "${value}"
      ;;
    DOCKER_DAEMON_PLATFORM) [[ "${value}" == linux_amd64 ]] ;;
    DOCKER_BUILD_SURFACE) [[ "${value}" == stdin_network_none_pull_false_no_cache_plain ]] ;;
    BUILDKIT_RESULT_PROOF) [[ "${value}" == parser_ready_runtime_execution_not_run ]] ;;
    DOCKER_LOCAL_OPERATIONS) [[ "${value}" == inspect_format_local_remove ]] ;;
    PROJECT_BOOTSTRAP_STATE) [[ "${value}" == ready ]] ;;
    AQUA_IDENTITY) [[ "${value}" == "${AQUA_VERSION}" ]] ;;
    KIND_IDENTITY)
      [[ "${value}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ &&
        "${value}" == "${ENVIRONMENT_PROFILE_KIND_IDENTITY}" ]]
      ;;
    KUBECTL_IDENTITY)
      [[ "${value}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ &&
        "${value}" == "${ENVIRONMENT_PROFILE_KUBECTL_IDENTITY}" ]]
      ;;
    *) return 1 ;;
  esac
}

environment_profile_validate_evidence() {
  local evidence="$1"
  local line key value prefix="" index=0
  local -a expected=(
    SCHEMA EVIDENCE_SEMANTICS OBSERVATION_TIME_SEMANTICS OS ARCHITECTURE
    BASH_VERSION BASH_CAPABILITY CURL_VERSION CURL_CAPABILITY
    COREUTILS_CAPABILITY HOST_COMMAND_CAPABILITY TAR_VERSION TAR_CAPABILITY TIMEOUT_VERSION
    TIMEOUT_CAPABILITY
    PROCESS_STATE_CAPABILITY DOCKER_CLIENT_VERSION DOCKER_SERVER_VERSION
    DOCKER_CLIENT_API DOCKER_SERVER_API DOCKER_DAEMON_PLATFORM
    DOCKER_BUILD_SURFACE BUILDKIT_RESULT_PROOF DOCKER_LOCAL_OPERATIONS
    PROJECT_BOOTSTRAP_STATE AQUA_IDENTITY KIND_IDENTITY KUBECTL_IDENTITY
  )
  [[ -f "${evidence}" && ! -L "${evidence}" ]] || return 1
  if IFS= read -r -N "$((ENVIRONMENT_PROFILE_MAX_EVIDENCE_BYTES + 1))" \
    prefix <"${evidence}"; then
    return 1
  fi
  ((${#prefix} > 0 && ${#prefix} <= ENVIRONMENT_PROFILE_MAX_EVIDENCE_BYTES)) ||
    return 1
  [[ "${prefix: -1}" == $'\n' ]] || return 1
  prefix=""
  if IFS= read -r -d '' prefix <"${evidence}"; then
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    ((index < ${#expected[@]})) || return 1
    [[ "${line}" == *=* ]] || return 1
    key="${line%%=*}"
    value="${line#*=}"
    [[ "${key}" == "${expected[index]}" ]] || return 1
    [[ "${value}" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,127}$ ]] || return 1
    [[ "${value}" != *'/'* ]] || return 1
    [[ "${value}" != *\\* ]] || return 1
    environment_profile_validate_evidence_value "${key}" "${value}" || return
    ((index += 1))
  done <"${evidence}"
  [[ "${index}" -eq "${#expected[@]}" &&
    "${index}" -eq "${ENVIRONMENT_PROFILE_EVIDENCE_RECORD_COUNT}" ]]
}
