#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright 2025 Arm Limited and/or its affiliates <open-source-office@arm.com>
# SPDX-License-Identifier: Apache-2.0


set -o errexit
set -o pipefail
set -o errtrace
set -o nounset

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

SR_EL_TEST_OPT="--test"
NO_REPO_VERIFY=""

if [ "$(uname)" = "Darwin" ]; then
  cores=$(sysctl -n hw.ncpu)
  echo "Darwin detected, skipping Emulation Layer and Scenarion Runner tests"
  SR_EL_TEST_OPT=""
elif [[ "$(uname)" == MINGW* ]]; then
  cores=$( powershell -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors")
  echo "MINGW detected, disabling repo verification"
  NO_REPO_VERIFY="--no-repo-verify"
else
  cores=$(nproc)
fi

echo "Detected uname: $(uname)"
echo "CPUs: $cores"

mkdir -p $REPO_DIR
mkdir -p $INSTALL_DIR
REPO_DIR="$(realpath "$REPO_DIR")"
INSTALL_DIR="$(realpath "$INSTALL_DIR")"
pushd $REPO_DIR

repo init $NO_REPO_VERIFY -u "$MANIFEST_URL" -g emulation-layer
repo sync $NO_REPO_VERIFY --no-clone-bundle -j "$cores"

mkdir -p .repo/local_manifests

if [ -n "$OVERRIDES" ]; then
  MANIFEST_XML=$(repo manifest -r)

  # Resolve each project's path from the active manifest and re-sync it
  for NAME in $(echo "$OVERRIDES" | jq -r 'keys[]'); do
    REVISION=$(echo "$OVERRIDES" | jq -r --arg name "$NAME" '.[$name]')

    PROJECT_PATH=$(echo "$MANIFEST_XML" | xmlstarlet sel -t -v "//project[@name='${NAME}']/@path")
    if [ -z "$PROJECT_PATH" ]; then
      echo "ERROR: project path for $NAME not found in manifest"
      exit 1
    fi

    rm -f .repo/local_manifests/override.xml
    cat > .repo/local_manifests/override.xml <<EOF
<manifest>
  <project name="${NAME}" revision="${REVISION}" remote="github"/>
</manifest>
EOF

    echo "Syncing $NAME ($PROJECT_PATH)"
    repo sync -j "$cores" --force-sync "$PROJECT_PATH"
  done

elif [ -n "$CHANGED_REPO" ]; then
  if [ -z "$CHANGED_SHA" ]; then
    echo "CHANGED_REPO is set but CHANGED_SHA is empty"
    exit 1
  fi

  # Find project path for changed repo
  PROJECT_PATH=$(repo manifest -r | xmlstarlet sel -t -v "//project[@name='${CHANGED_REPO}']/@path")
  if [ -z "$PROJECT_PATH" ]; then
    echo "Could not find project path for ${CHANGED_REPO} in manifest"
    exit 1
  fi
  echo "Changed project path: $PROJECT_PATH"

  # Create a local manifest override to pin the changed repo to the exact SHA
  cat > .repo/local_manifests/override.xml <<EOF
<manifest>
  <project name="${CHANGED_REPO}" revision="${CHANGED_SHA}" remote="github"/>
</manifest>
EOF

  # Re-sync the changed project to the specified SHA
  repo sync -j "$cores" --force-sync "$PROJECT_PATH"
fi

#echo "Build VGF-Lib"
#./sw/vgf-lib/scripts/build.py -j "$cores" --doc --test
#
#echo "Build Model Converter"
#./sw/model-converter/scripts/build.py -j "$cores" --doc --test

export VMEL_GRAPH_SEVERITY="debug"
export VMEL_TENSOR_SEVERITY="debug"
export VMEL_COMMON_SEVERITY="debug"
export VK_LOADER_DEBUG="all"
echo "Build Emulation Layer"

if [[ "$(uname)" == MINGW* ]]; then
  # Convert INSTALL_DIR to Windows style (D:\a\...)
  win_install_dir=$(cygpath -w "$INSTALL_DIR")

  bin_folder="${win_install_dir}\\bin"
  reg_key='HKEY_CURRENT_USER\SOFTWARE\Khronos\Vulkan\ExplicitLayers'
  reg_key_lm='HKEY_LOCAL_MACHINE\SOFTWARE\Khronos\Vulkan\ExplicitLayers'

  echo "Setting up Vulkan layer registry on Windows"
  echo "bin folder: $bin_folder"

  # helper: run a Windows reg.exe command via cmd.exe /c with proper quoting
  reg_add_windows() {
    local key="$1"
    local value="$2"
    # Build a single Windows-style command line and hand it to cmd.exe.
    # Use double-quotes around key and value so reg.exe sees them correctly.
    local cmdline
    cmdline="reg.exe add \"${key}\" /v \"${value}\" /t REG_DWORD /d 0 /f"
    printf 'Running: %s\n' "$cmdline"
    cmd.exe /c "$cmdline"
  }

  reg_add_windows "$reg_key" "$bin_folder"
  MSYS2_ARG_CONV_EXCL='*' cmd.exe /c reg.exe query "$reg_key" /reg:64


  reg_add_windows "$reg_key_lm" "$bin_folder"
  MSYS2_ARG_CONV_EXCL='*' cmd.exe /c reg.exe query "$reg_key_lm" /reg:64


  # Make sure the DLLs are on PATH
  export PATH="$INSTALL_DIR/bin:$PATH"
else
  export VK_LAYER_PATH="$INSTALL_DIR/share/vulkan/explicit_layer.d"
  export LD_LIBRARY_PATH="$INSTALL_DIR/lib"
fi


# Still needs to match the "name" fields in VkLayer_*.json
export VK_INSTANCE_LAYERS=VK_LAYER_ML_Graph_Emulation:VK_LAYER_ML_Tensor_Emulation

./sw/emulation-layer/scripts/build.py -j "$cores"  $SR_EL_TEST_OPT --install $INSTALL_DIR
# --doc
#echo "Build Scenario Runner"
#./sw/scenario-runner/scripts/build.py -j "$cores" --doc $SR_EL_TEST_OPT
#
#echo "Build SDK Root"
#./scripts/build.py -j "$cores" --doc

popd
