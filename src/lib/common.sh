#!/usr/bin/env bash
# Shared functions for GPG/YubiKey management tasks
# Sourced by all mise task scripts

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"

# --- Output helpers ---

info()    { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
success() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }

# --- Passphrase generation ---

# Generate a strong passphrase: uppercase + digits, excluding ambiguous chars (I, O, U, S, 5)
generate_passphrase() {
    local length="${1:-20}"
    # Use openssl to produce clean ASCII, then filter to charset.
    # Avoids BSD tr "Illegal byte sequence" on raw /dev/urandom and
    # macOS SIGPIPE hang with infinite tr | head pipelines.
    local result
    result=$(openssl rand -base64 256 | tr -dc 'ABCDEFGHJKLMNPQRTVWXYZ234679') || true
    if [[ ${#result} -lt $length ]]; then
        echo "ERROR: passphrase generation failed" >&2
        return 1
    fi
    printf '%s\n' "${result:0:$length}"
}

# --- Identity management ---

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
    local identities_dir
    identities_dir="$(yk_gpg_data_dir)/identities"
    mkdir -p "$identities_dir"
    local metadata_file="${identities_dir}/${fingerprint}.json"

    if [[ -f "$metadata_file" ]]; then
        # Update existing — merge with provided key=value pairs using jq
        local tmp
        tmp="$(mktemp)"
        cp "$metadata_file" "$tmp"
        while [[ $# -ge 2 ]]; do
            local key="$1" value="$2"
            shift 2
            jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
        done
        mv "$tmp" "$metadata_file"
    else
        # Create new — use jq for safe JSON encoding
        local tmp
        tmp="$(mktemp)"
        echo '{}' > "$tmp"
        while [[ $# -ge 2 ]]; do
            local key="$1" value="$2"
            shift 2
            jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
        done
        mv "$tmp" "$metadata_file"
    fi

    info "Saved metadata: $metadata_file"
}

load_metadata() {
    local fingerprint="$1"
    local identities_dir
    identities_dir="$(yk_gpg_data_dir)/identities"
    local metadata_file="${identities_dir}/${fingerprint}.json"

    if [[ ! -f "$metadata_file" ]]; then
        return 1
    fi

    cat "$metadata_file"
}

# --- User interaction ---

confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-n}"

    # In batch mode, return the default value without prompting
    if is_batch; then
        [[ "$default" =~ ^[Yy] ]]
        return
    fi

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
