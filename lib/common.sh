#!/usr/bin/env bash
# Shared functions for GPG/YubiKey management tasks
# Sourced by all mise task scripts

set -euo pipefail

# --- Output helpers ---

info()    { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
success() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }

# --- Tor SOCKS proxy ---

# Configure environment so curl and other CLI tools route through Tor.
# Tor listens on 127.0.0.1:9050. Using socks5h:// ensures DNS resolution
# happens through Tor (no DNS leaks).
# Note: ALL_PROXY is the correct variable for SOCKS proxies. http_proxy/
# https_proxy expect HTTP proxy URLs — socks5h:// in those is curl-specific
# and not portable. GPG's dirmngr ignores env vars entirely (uses dirmngr.conf).
setup_tor_proxy() {
    export ALL_PROXY="socks5h://127.0.0.1:9050"
}

# --- Dependency checks ---

check_deps() {
    local missing=()
    for cmd in gpg ykman scdaemon pcscd; do
        case "$cmd" in
            scdaemon)
                if ! command -v scdaemon &>/dev/null && [[ ! -x /usr/lib/gnupg/scdaemon ]]; then
                    missing+=("$cmd")
                fi
                ;;
            pcscd)
                if ! systemctl is-active --quiet pcscd 2>/dev/null && ! pgrep -x pcscd &>/dev/null; then
                    warn "pcscd is not running; attempting to start..."
                    sudo systemctl start pcscd 2>/dev/null || sudo pcscd 2>/dev/null || missing+=("$cmd")
                fi
                ;;
            *)
                if ! command -v "$cmd" &>/dev/null; then
                    missing+=("$cmd")
                fi
                ;;
        esac
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        error "Run: mise run gpg:install-deps"
        exit 1
    fi
}

check_yubikey() {
    if ! ykman info &>/dev/null; then
        error "No YubiKey detected. Please insert a YubiKey and try again."
        exit 1
    fi
}

# --- YubiKey detection ---

# Sets: YUBIKEY_MODEL, YUBIKEY_SERIAL, YUBIKEY_FIRMWARE
detect_yubikey() {
    check_yubikey
    local yk_info
    yk_info="$(ykman info 2>/dev/null)"

    YUBIKEY_MODEL="$(echo "$yk_info" | grep -i 'Device type:' | sed 's/.*: *//')"
    YUBIKEY_SERIAL="$(echo "$yk_info" | grep -i 'Serial number:' | sed 's/.*: *//')"
    YUBIKEY_FIRMWARE="$(echo "$yk_info" | grep -i 'Firmware version:' | sed 's/.*: *//')"

    if [[ -z "$YUBIKEY_MODEL" ]]; then
        # Fallback: try device name
        YUBIKEY_MODEL="$(echo "$yk_info" | head -1)"
    fi

    export YUBIKEY_MODEL YUBIKEY_SERIAL YUBIKEY_FIRMWARE
    info "Detected: ${YUBIKEY_MODEL} (serial: ${YUBIKEY_SERIAL}, firmware: ${YUBIKEY_FIRMWARE})"
}

# Returns best key type for the connected YubiKey
# YubiKey 5 with firmware >= 5.2.3: ed25519/cv25519
# YubiKey 4 or older YubiKey 5: rsa4096
best_key_type() {
    if [[ -z "${YUBIKEY_FIRMWARE:-}" ]]; then
        detect_yubikey
    fi

    local major minor patch
    IFS='.' read -r major minor patch <<< "$YUBIKEY_FIRMWARE"

    # YubiKey 5 with fw >= 5.2.3 supports ed25519
    if [[ "$major" -ge 5 ]] && [[ "$minor" -gt 2 || ("$minor" -eq 2 && "$patch" -ge 3) ]]; then
        echo "ed25519"
    else
        echo "rsa4096"
    fi
}

# --- YubiKey version helpers ---

# Returns true if the connected YubiKey is a YubiKey 5 (firmware major >= 5)
is_yubikey5() {
    if [[ -z "${YUBIKEY_FIRMWARE:-}" ]]; then
        detect_yubikey
    fi
    local major
    IFS='.' read -r major _ _ <<< "$YUBIKEY_FIRMWARE"
    [[ "$major" -ge 5 ]]
}

# --- Passphrase generation ---

# Generate a strong passphrase: uppercase + digits, excluding ambiguous chars (I, O, U, S, 5)
generate_passphrase() {
    local length="${1:-20}"
    tr -dc 'ABCDEFGHJKLMNPQRTVWXYZ234679' < /dev/urandom | head -c "$length"
    echo
}

# --- Temporary GNUPGHOME ---

# Create a tmpfs-backed temporary GNUPG home with hardened config
# Sets: GNUPGHOME (exported)
setup_temp_gnupghome() {
    local tmpdir
    tmpdir="$(mktemp -d /tmp/gnupg-XXXXXX)"
    chmod 700 "$tmpdir"

    # Mount tmpfs for security (keys never touch disk)
    if ! mountpoint -q "$tmpdir" 2>/dev/null; then
        sudo mount -t tmpfs -o size=16M tmpfs "$tmpdir"
        chmod 700 "$tmpdir"
    fi

    # Copy hardened config
    local project_root="${MISE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    cp "${project_root}/config/gpg.conf" "$tmpdir/"
    cp "${project_root}/config/gpg-agent.conf" "$tmpdir/"
    if [[ -f "${project_root}/config/scdaemon.conf" ]]; then
        cp "${project_root}/config/scdaemon.conf" "$tmpdir/"
    fi
    if [[ -f "${project_root}/config/dirmngr.conf" ]]; then
        cp "${project_root}/config/dirmngr.conf" "$tmpdir/"
    fi

    export GNUPGHOME="$tmpdir"
    info "Temporary GNUPGHOME: $GNUPGHOME"
}

cleanup_temp_gnupghome() {
    if [[ -n "${GNUPGHOME:-}" && "$GNUPGHOME" == /tmp/gnupg-* ]]; then
        if mountpoint -q "$GNUPGHOME" 2>/dev/null; then
            sudo umount "$GNUPGHOME"
        fi
        rm -rf "$GNUPGHOME"
        info "Cleaned up temporary GNUPGHOME"
    fi
}

# --- Identity management ---

PERSISTENT_GNUPGHOME="/home/bram/TailsData/gnupg"
IDENTITIES_DIR="${MISE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/identities"

validate_identity() {
    local identity="$1"
    local keyid

    # Try as key ID first
    if keyid="$(gpg --with-colons --list-secret-keys "$identity" 2>/dev/null | grep '^sec:' | head -1 | cut -d: -f5)"; then
        if [[ -n "$keyid" ]]; then
            echo "$keyid"
            return 0
        fi
    fi

    error "Identity not found: $identity"
    return 1
}

save_metadata() {
    local fingerprint="$1"
    shift
    local metadata_file="${IDENTITIES_DIR}/${fingerprint}.json"

    # Build or update JSON metadata
    if [[ -f "$metadata_file" ]]; then
        # Update existing - merge with provided key=value pairs
        local tmp
        tmp="$(mktemp)"
        cp "$metadata_file" "$tmp"
        while [[ $# -ge 2 ]]; do
            local key="$1" value="$2"
            shift 2
            # Simple JSON update using python3 (available on Tails)
            python3 -c "
import json, sys
with open('$tmp') as f:
    data = json.load(f)
data['$key'] = '$value'
with open('$tmp', 'w') as f:
    json.dump(data, f, indent=2)
"
        done
        mv "$tmp" "$metadata_file"
    else
        # Create new
        local json="{"
        local first=true
        while [[ $# -ge 2 ]]; do
            local key="$1" value="$2"
            shift 2
            if $first; then first=false; else json+=","; fi
            json+=$'\n'"  \"${key}\": \"${value}\""
        done
        json+=$'\n'"}"
        echo "$json" > "$metadata_file"
    fi

    info "Saved metadata: $metadata_file"
}

load_metadata() {
    local fingerprint="$1"
    local metadata_file="${IDENTITIES_DIR}/${fingerprint}.json"

    if [[ ! -f "$metadata_file" ]]; then
        return 1
    fi

    cat "$metadata_file"
}

# --- User interaction ---

confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-n}"

    if [[ "$default" == "y" ]]; then
        prompt+=" [Y/n] "
    else
        prompt+=" [y/N] "
    fi

    printf '\033[1;33m%s\033[0m' "$prompt"
    read -r reply
    reply="${reply:-$default}"

    [[ "$reply" =~ ^[Yy] ]]
}
