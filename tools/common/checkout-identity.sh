#!/bin/bash -p

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  builtin printf 'FAIL  checkout-id   this file must be sourced\n' >&2
  builtin exit 2
fi

case "$(builtin declare -p PLATFORM_CHECKOUT_IDENTITY_MODULE_LOADED \
  2>/dev/null || builtin true)" in
  'declare -r PLATFORM_CHECKOUT_IDENTITY_MODULE_LOADED="true"') builtin return 0 ;;
esac

# shellcheck disable=SC2034
builtin readonly PLATFORM_CHECKOUT_IDENTITY_MODULE_LOADED=true

checkout_identity_fail() {
  builtin printf 'FAIL  checkout-id   %s\n' "$*" >&2
  return 1
}

checkout_identity_for_root() {
  local root="${1:-}" physical_root hash_output sentinel=$'\036'
  local LC_ALL=C
  [[ $# -eq 1 && -n "${root}" && -d "${root}" ]] || {
    checkout_identity_fail 'checkout root is unavailable'
    return
  }
  physical_root="$({
    builtin cd -P -- "${root}" 2>/dev/null &&
      builtin pwd -P && builtin printf '%s' "${sentinel}"
  })" || {
    checkout_identity_fail 'checkout root is not canonical'
    return
  }
  [[ "${physical_root: -1}" == "${sentinel}" ]] || {
    checkout_identity_fail 'checkout root capture is incomplete'
    return
  }
  physical_root="${physical_root::-1}"
  [[ "${physical_root: -1}" == $'\n' ]] || {
    checkout_identity_fail 'checkout root capture is malformed'
    return
  }
  physical_root="${physical_root::-1}"
  [[ "${physical_root}" == /* ]] || {
    checkout_identity_fail 'checkout root is not canonical'
    return
  }
  hash_output="$({
    builtin printf 'flare-platform-checkout-v1\0uid=%s\0root=%s\0' \
      "${EUID}" "${physical_root}" |
      run_host_command sha256sum --
  })" || {
    checkout_identity_fail 'checkout identity hash failed'
    return
  }
  [[ "${hash_output}" =~ ^([0-9a-f]{64})\ \ -$ ]] || {
    checkout_identity_fail 'checkout identity hash is malformed'
    return
  }
  builtin printf 'sha256:%s\n' "${BASH_REMATCH[1]}"
}

platform_checkout_identity() {
  checkout_identity_for_root "${PLATFORM_ROOT}"
}
