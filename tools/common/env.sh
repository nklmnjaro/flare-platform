#!/usr/bin/env bash
set -euo pipefail

PLATFORM_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export PLATFORM_ROOT
export PLATFORM_STATE_DIR="${PLATFORM_ROOT}/.platform"
export AQUA_ROOT_DIR="${PLATFORM_STATE_DIR}/aqua"
export AQUA_CONFIG="${PLATFORM_ROOT}/aqua.yaml"
export KUBECONFIG="${PLATFORM_STATE_DIR}/kubeconfig"
export PLATFORM_DIAGNOSTICS_DIR="${PLATFORM_STATE_DIR}/diagnostics/raw"
export TRIVY_CACHE_DIR="${PLATFORM_STATE_DIR}/trivy"
export TRIVY_NO_PROGRESS=true
export PATH="${AQUA_ROOT_DIR}/bin:${PATH}"

PLATFORM_CLUSTER_NAME="flare-platform-dev"
PLATFORM_CONTEXT="kind-${PLATFORM_CLUSTER_NAME}"
PLATFORM_NAMESPACE="flare-platform-reference"
PLATFORM_IMAGE="flare-platform-reference:dev"
export PLATFORM_CLUSTER_NAME PLATFORM_CONTEXT PLATFORM_NAMESPACE PLATFORM_IMAGE
