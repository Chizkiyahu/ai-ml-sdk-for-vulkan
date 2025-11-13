#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright 2025 Arm Limited and/or its affiliates <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0


set -o errexit
set -o pipefail
set -o errtrace
set -o nounset
set -o xtrace

usage() {
  echo "Usage: $(basename "$0")"
  echo
  echo "Environment:"
  echo "  MANIFEST_URL   (optional)  default: https://github.com/arm/ai-ml-sdk-manifest.git"
  echo "  REPO_DIR       (optional)  default: ./sdk"
  echo "  INSTALL_DIR    (optional)  default: ./install"
  echo "  CHANGED_REPO   (optional)  manifest project name to pin and resync"
  echo "  CHANGED_SHA    (optional)  commit SHA to pin CHANGED_REPO to (required if CHANGED_REPO is set)"
  echo "  OVERRIDES      (optional)  JSON object: { \"org/repo\": \"40-char-sha\", ... }"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MANIFEST_URL="${MANIFEST_URL:-https://github.com/arm/ai-ml-sdk-manifest.git}"
REPO_DIR="${REPO_DIR:-$PWD/sdk}"
INSTALL_DIR="${INSTALL_DIR:-$PWD/install}"
CHANGED_REPO="${CHANGED_REPO:-}"
CHANGED_SHA="${CHANGED_SHA:-}"
OVERRIDES="${OVERRIDES:-}"

echo "Using manifest URL: $MANIFEST_URL"
echo "Using repo directory: $REPO_DIR"
echo "Using install directory: $INSTALL_DIR"
echo "find CHANGED_REPO: $CHANGED_REPO"
echo "find CHANGED_SHA: $CHANGED_SHA"
echo "find OVERRIDES: $OVERRIDES"

# for Darwin compatibility
if ! command -v nproc >/dev/null 2>&1; then
  nproc() { sysctl -n hw.ncpu; }
fi

mkdir -p $REPO_DIR
mkdir -p $INSTALL_DIR
REPO_DIR="$(realpath "$REPO_DIR")"
INSTALL_DIR="$(realpath "$INSTALL_DIR")"
pushd $REPO_DIR

repo init -u $MANIFEST_URL -g emulation-layer --depth=1
repo sync --no-clone-bundle -j $(nproc) --force-sync

export VK_LAYER_PATH=$INSTALL_DIR/share/vulkan/explicit_layer.d
export VK_INSTANCE_LAYERS=VK_LAYER_ML_Graph_Emulation:VK_LAYER_ML_Tensor_Emulation
export VMEL_GRAPH_SEVERITY="debug"
export VMEL_TENSOR_SEVERITY="debug"
export VMEL_COMMON_SEVERITY="debug"
export VK_LOADER_DEBUG="all"

echo "Build Emulation Layer"
#run_checks ./sw/emulation-layer
./sw/emulation-layer/scripts/build.py -j $(nproc)  --test --install $INSTALL_DIR

popd
