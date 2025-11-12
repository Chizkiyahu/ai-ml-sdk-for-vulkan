#!/usr/bin/env zsh
set -euo pipefail

echo "=== Lavapipe (CPU Vulkan) build for macOS (Mesa 25.2.5) ==="

MESA_SRC_DIR="${MESA_SRC_DIR:-${HOME}/src/mesa}"
MESA_BUILD_DIR="${MESA_BUILD_DIR:-${MESA_SRC_DIR}/build-lavapipe}"
MESA_INSTALL_PREFIX="${MESA_INSTALL_PREFIX:-${HOME}/.local/mesa-lavapipe}"

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

brew_install_if_needed() {
    local pkg="$1"
    if brew list "$pkg" >/dev/null 2>&1; then
        echo "brew: $pkg already installed"
    else
        echo "brew: installing $pkg"
        brew install "$pkg"
    fi
}

echo "==> Checking for Homebrew..."
if ! have_cmd brew; then
    echo "ERROR: Homebrew not installed"
    exit 1
fi

echo "==> Checking that cc works..."
TMP_C="/tmp/mesa-cc-test-$$.c"
TMP_EXE="/tmp/mesa-cc-test-$$"

cat > "${TMP_C}" << 'EOF'
#include <stdio.h>
int main(void){ printf("cc test ok\n"); return 0; }
EOF

if ! cc "${TMP_C}" -o "${TMP_EXE}" >/dev/null 2>&1; then
    echo "ERROR: cc cannot compile. Run:"
    echo "  xcode-select --install"
    exit 1
fi

if ! "${TMP_EXE}" >/dev/null 2>&1; then
    echo "ERROR: cc output program failed"
    exit 1
fi

rm -f "${TMP_C}" "${TMP_EXE}"
echo "cc test ok"

echo "==> Forcing Apple clang toolchain..."
export CC=/usr/bin/cc
export CXX=/usr/bin/c++
export OBJC=/usr/bin/clang
export OBJCXX=/usr/bin/clang++

if have_cmd xcrun; then
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [ -n "${SDK_PATH}" ]; then
        export SDKROOT="${SDK_PATH}"
        echo "Using SDKROOT=${SDKROOT}"
    fi
fi

echo "==> Installing Mesa dependencies..."
brew_install_if_needed meson
brew_install_if_needed ninja
brew_install_if_needed pkgconf
brew_install_if_needed python
brew_install_if_needed llvm
brew_install_if_needed libclc
brew_install_if_needed libpng
brew_install_if_needed zstd
brew_install_if_needed git
brew_install_if_needed vulkan-loader
brew_install_if_needed vulkan-tools
brew_install_if_needed vulkan-validationlayers

echo "==> Installing Python Mako..."
if ! pip3 show mako >/dev/null 2>&1; then
    pip3 install mako
else
    echo "pip: mako already installed"
fi

echo "==> Install python PyYAML "
if ! pip3 show PyYAML >/dev/null 2>&1; then
    pip3 install PyYAML
else
    echo "pip: PyYAML already installed"
fi

echo "==> Fetching Mesa source: ${MESA_SRC_DIR}"
if [ ! -d "${MESA_SRC_DIR}" ]; then
    mkdir -p "$(dirname "${MESA_SRC_DIR}")"
    git clone https://gitlab.freedesktop.org/mesa/mesa.git "${MESA_SRC_DIR}"
fi

echo "==> Checking out Mesa tag mesa-25.2.5"
git -C "${MESA_SRC_DIR}" fetch --all --tags
git -C "${MESA_SRC_DIR}" checkout mesa-25.2.5

echo "==> Preparing build dir: ${MESA_BUILD_DIR}"
mkdir -p "${MESA_BUILD_DIR}"

MESON_ARGS=(
    "${MESA_BUILD_DIR}"
    "${MESA_SRC_DIR}"
    "--prefix=${MESA_INSTALL_PREFIX}"
    "--buildtype=release"

    -Dvulkan-drivers=swrast
    -Dgallium-drivers=llvmpipe

    -Dplatforms=macos
    -Dglx=disabled
    -Degl=disabled
)

echo "==> Running Meson setup..."
if [ -f "${MESA_BUILD_DIR}/build.ninja" ]; then
    meson setup "${MESON_ARGS[@]}" --reconfigure
else
    meson setup "${MESON_ARGS[@]}"
fi

echo "==> Building Mesa..."
meson compile -C "${MESA_BUILD_DIR}"

echo "==> Installing Mesa..."
meson install -C "${MESA_BUILD_DIR}"

ICD_DIR="${MESA_INSTALL_PREFIX}/share/vulkan/icd.d"
if [ ! -d "${ICD_DIR}" ]; then
    echo "ERROR: ICD directory not found: ${ICD_DIR}"
    exit 1
fi

LVP_ICD_FILE="$(ls "${ICD_DIR}"/lvp_icd*.json 2>/dev/null | head -n 1 || true)"

if [ -z "${LVP_ICD_FILE}" ]; then
    echo "ERROR: Lavapipe ICD JSON missing"
    exit 1
fi

echo "Found Lavapipe ICD: ${LVP_ICD_FILE}"

cat <<EOF

============================================================
Mesa 25.2.5 Lavapipe build completed successfully.

Installation prefix:
  ${MESA_INSTALL_PREFIX}

Lavapipe ICD JSON:
  ${LVP_ICD_FILE}

To use Lavapipe Vulkan:

  export MESA_LAVAPIPE_PREFIX="${MESA_INSTALL_PREFIX}"
  export VK_DRIVER_FILES="${LVP_ICD_FILE}"
  export VK_ICD_FILENAMES="${LVP_ICD_FILE}"

Test:

  vulkaninfo | grep -E 'driverName|deviceName|apiVersion'

============================================================
EOF
