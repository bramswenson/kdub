#!/usr/bin/env bash
# Install latest mise task runner with checksum verification
set -euo pipefail

INSTALL_DIR="${HOME}/Persistent/bin"
MISE_BIN="${INSTALL_DIR}/mise"

# Route traffic through Tor SOCKS proxy (127.0.0.1:9050)
# ALL_PROXY with socks5h:// tells curl to use SOCKS5 with remote DNS resolution
export ALL_PROXY="socks5h://127.0.0.1:9050"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
success() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }

# Fetch latest release version from GitHub API
info "Checking latest mise release..."
MISE_VERSION="$(curl -fsSL https://api.github.com/repos/jdx/mise/releases/latest | grep '"tag_name":' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
if [[ -z "$MISE_VERSION" ]]; then
    error "Could not determine latest mise version"
    exit 1
fi
info "Latest version: ${MISE_VERSION}"

# Check if mise is already installed and up to date
if command -v mise &>/dev/null; then
    installed_version="$(mise --version 2>/dev/null | awk '{print $1}')"
    target_version="${MISE_VERSION#v}"
    if [[ "$installed_version" == "$target_version" ]]; then
        success "mise ${installed_version} is already installed"
        exit 0
    fi
    info "Upgrading mise from ${installed_version} to ${target_version}"
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download mise binary and checksums to temp dir
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

MISE_URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-x64"
MISE_CHECKSUM_URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/SHASUMS256.txt"

info "Downloading mise ${MISE_VERSION}..."
curl -fsSL "$MISE_URL" -o "${TMPDIR}/mise"
curl -fsSL "$MISE_CHECKSUM_URL" -o "${TMPDIR}/SHASUMS256.txt"

# Verify checksum
info "Verifying checksum..."
expected_checksum="$(grep "mise-${MISE_VERSION}-linux-x64\$" "${TMPDIR}/SHASUMS256.txt" | awk '{print $1}')"
if [[ -z "$expected_checksum" ]]; then
    error "Could not find checksum for mise-${MISE_VERSION}-linux-x64"
    exit 1
fi

actual_checksum="$(sha256sum "${TMPDIR}/mise" | awk '{print $1}')"
if [[ "$expected_checksum" != "$actual_checksum" ]]; then
    error "Checksum verification failed!"
    error "Expected: ${expected_checksum}"
    error "Actual:   ${actual_checksum}"
    exit 1
fi
success "Checksum verified"

# Install
chmod +x "${TMPDIR}/mise"
mv "${TMPDIR}/mise" "$MISE_BIN"
success "Installed mise to ${MISE_BIN}"

# Add to shell rc if not present
SHELL_RC="${HOME}/.bashrc"
ACTIVATION_LINE='eval "$(~/.local/bin/mise activate bash)"'

if ! grep -qF 'mise activate' "$SHELL_RC" 2>/dev/null; then
    info "Adding mise activation to ${SHELL_RC}"
    echo "" >> "$SHELL_RC"
    echo "# mise task runner" >> "$SHELL_RC"
    echo "$ACTIVATION_LINE" >> "$SHELL_RC"
    warn "Run 'source ${SHELL_RC}' or start a new shell to activate mise"
else
    info "mise activation already in ${SHELL_RC}"
fi

# Verify
info "Verifying installation..."
"$MISE_BIN" --version
success "mise installation complete"
