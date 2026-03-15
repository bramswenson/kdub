#!/usr/bin/env bash
# Install latest mise task runner with checksum verification.
# Platform-aware: supports Linux (including Tails), macOS.
set -euo pipefail

info()    { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
success() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }

# --- Platform + arch detection ---
MACHINE_ARCH="$(uname -m)"
case "$MACHINE_ARCH" in
    arm64|aarch64) ARCH_SUFFIX="arm64" ;;
    x86_64)        ARCH_SUFFIX="x64" ;;
    *)             error "Unsupported architecture: $MACHINE_ARCH"; exit 1 ;;
esac

case "$(uname)" in
    Darwin)
        PLATFORM="macos"
        MISE_ARCH="macos-${ARCH_SUFFIX}"
        SHA_CMD="shasum -a 256"
        INSTALL_DIR="${HOME}/.local/bin"
        ;;
    Linux)
        PLATFORM="linux"
        MISE_ARCH="linux-${ARCH_SUFFIX}"
        SHA_CMD="sha256sum"
        if [[ -f /etc/os-release ]] && grep -q "Tails" /etc/os-release 2>/dev/null; then
            PLATFORM="tails"
            INSTALL_DIR="${HOME}/Persistent/bin"
        else
            INSTALL_DIR="${HOME}/.local/bin"
        fi
        ;;
    *)
        error "Unsupported platform: $(uname)"
        exit 1
        ;;
esac

MISE_BIN="${INSTALL_DIR}/mise"

# --- Tor proxy (Tails or explicit) ---
if [[ -n "${YK_GPG_TOR_PROXY:-}" ]]; then
    export ALL_PROXY="$YK_GPG_TOR_PROXY"
    info "Using Tor proxy: $ALL_PROXY"
elif [[ "$PLATFORM" == "tails" ]]; then
    export ALL_PROXY="socks5h://127.0.0.1:9050"
    info "Using Tails Tor proxy: $ALL_PROXY"
fi

# --- Fetch latest version ---
info "Checking latest mise release..."
MISE_VERSION="$(curl -fsSL https://api.github.com/repos/jdx/mise/releases/latest | grep '"tag_name":' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
if [[ -z "$MISE_VERSION" ]]; then
    error "Could not determine latest mise version"
    exit 1
fi
info "Latest version: ${MISE_VERSION}"

# --- Check if already up to date ---
if command -v mise &>/dev/null; then
    installed_version="$(mise --version 2>/dev/null | awk '{print $1}')"
    target_version="${MISE_VERSION#v}"
    if [[ "$installed_version" == "$target_version" ]]; then
        success "mise ${installed_version} is already installed"
        exit 0
    fi
    info "Upgrading mise from ${installed_version} to ${target_version}"
fi

# --- Download and verify ---
mkdir -p "$INSTALL_DIR"

DL_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$DL_TMPDIR"' EXIT

MISE_URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-${MISE_ARCH}"
MISE_CHECKSUM_URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/SHASUMS256.txt"

info "Downloading mise ${MISE_VERSION} (${MISE_ARCH})..."
curl -fsSL "$MISE_URL" -o "${DL_TMPDIR}/mise"
curl -fsSL "$MISE_CHECKSUM_URL" -o "${DL_TMPDIR}/SHASUMS256.txt"

info "Verifying checksum..."
expected_checksum="$(grep "mise-${MISE_VERSION}-${MISE_ARCH}\$" "${DL_TMPDIR}/SHASUMS256.txt" | awk '{print $1}')"
if [[ -z "$expected_checksum" ]]; then
    error "Could not find checksum for mise-${MISE_VERSION}-${MISE_ARCH}"
    exit 1
fi

actual_checksum="$($SHA_CMD "${DL_TMPDIR}/mise" | awk '{print $1}')"
if [[ "$expected_checksum" != "$actual_checksum" ]]; then
    error "Checksum verification failed!"
    error "Expected: ${expected_checksum}"
    error "Actual:   ${actual_checksum}"
    exit 1
fi
success "Checksum verified"

# --- Install ---
chmod +x "${DL_TMPDIR}/mise"
mv "${DL_TMPDIR}/mise" "$MISE_BIN"
success "Installed mise to ${MISE_BIN}"

# --- Shell activation ---
SHELL_RC="${HOME}/.bashrc"
[[ "$PLATFORM" == "macos" ]] && SHELL_RC="${HOME}/.zshrc"

# shellcheck disable=SC2016
ACTIVATION_LINE="eval \"\$(${MISE_BIN} activate $(basename "${SHELL:-bash}"))\""

if ! grep -qF 'mise activate' "$SHELL_RC" 2>/dev/null; then
    info "Adding mise activation to ${SHELL_RC}"
    {
        echo ""
        echo "# mise task runner"
        echo "$ACTIVATION_LINE"
    } >> "$SHELL_RC"
    warn "Run 'source ${SHELL_RC}' or start a new shell to activate mise"
else
    info "mise activation already in ${SHELL_RC}"
fi

# --- Verify ---
info "Verifying installation..."
"$MISE_BIN" --version
success "mise installation complete"
