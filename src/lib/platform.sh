#!/usr/bin/env bash
# Platform detection, XDG paths, and ephemeral GNUPGHOME management

# --- Platform detection ---

# Returns: "tails", "macos", or "linux"
detect_platform() {
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "macos"
    elif [[ -f /etc/os-release ]] && grep -q "Tails" /etc/os-release 2>/dev/null; then
        echo "tails"
    else
        echo "linux"
    fi
}

PLATFORM="$(detect_platform)"

is_tails() { [[ "$PLATFORM" == "tails" ]]; }
is_macos() { [[ "$PLATFORM" == "macos" ]]; }
is_linux() { [[ "$PLATFORM" == "linux" || "$PLATFORM" == "tails" ]]; }

# --- Batch mode ---

BATCH_MODE="${BATCH_MODE:-${CI:+true}}"
is_batch() { [[ "${BATCH_MODE:-}" == "true" ]]; }

# --- XDG path resolution ---
# These use env vars set by mise.toml [env] section.
# If sourced outside mise (e.g., tests), fall back to XDG defaults.

yk_gpg_config_dir() { echo "${YK_GPG_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/yk-gpg}"; }
yk_gpg_data_dir()   { echo "${YK_GPG_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/yk-gpg}"; }
yk_gpg_state_dir()  { echo "${YK_GPG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/yk-gpg}"; }

# --- Ephemeral GNUPGHOME ---

# Creates a RAM-backed temporary GNUPGHOME directory.
# Sets and exports: GNUPGHOME, _YK_GPG_TMPDIR_METHOD
setup_temp_gnupghome() {
    local tmpdir

    # Tier 1: XDG_RUNTIME_DIR (Linux, already tmpfs)
    if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]]; then
        tmpdir="$(mktemp -d "${XDG_RUNTIME_DIR}/yk-gpg-gnupg-XXXXXX")"
        _YK_GPG_TMPDIR_METHOD="xdg_runtime"
    # Tier 2: /dev/shm (Linux tmpfs)
    elif [[ -d /dev/shm && -w /dev/shm ]]; then
        tmpdir="$(mktemp -d /dev/shm/yk-gpg-gnupg-XXXXXX)"
        _YK_GPG_TMPDIR_METHOD="devshm"
    # Tier 3: macOS hdiutil RAM disk
    elif [[ "$(uname)" == "Darwin" ]] && command -v hdiutil &>/dev/null; then
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/yk-gpg-gnupg-XXXXXX")"
        local sectors=$((16 * 2048))  # 16MB
        _YK_GPG_RAMDISK_DEVICE="$(hdiutil attach -nomount "ram://${sectors}" 2>/dev/null)" || true
        if [[ -n "${_YK_GPG_RAMDISK_DEVICE:-}" ]]; then
            _YK_GPG_RAMDISK_DEVICE="$(echo "$_YK_GPG_RAMDISK_DEVICE" | xargs)"
            newfs_hfs -M 700 "$_YK_GPG_RAMDISK_DEVICE" &>/dev/null || true
            mount -t hfs "$_YK_GPG_RAMDISK_DEVICE" "$tmpdir" 2>/dev/null || true
            _YK_GPG_TMPDIR_METHOD="ramdisk"
        else
            _YK_GPG_TMPDIR_METHOD="tmpdir"
            warn "Could not create RAM disk; using disk-backed tmpdir"
        fi
    # Tier 4: Linux tmpfs (requires sudo)
    elif command -v mount &>/dev/null && [[ "$(uname)" != "Darwin" ]]; then
        tmpdir="$(mktemp -d /tmp/yk-gpg-gnupg-XXXXXX)"
        if sudo mount -t tmpfs -o size=16M tmpfs "$tmpdir" 2>/dev/null; then
            _YK_GPG_TMPDIR_METHOD="tmpfs"
        else
            _YK_GPG_TMPDIR_METHOD="tmpdir"
            warn "Could not mount tmpfs; using disk-backed tmpdir"
        fi
    # Tier 5: fallback
    else
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/yk-gpg-gnupg-XXXXXX")"
        _YK_GPG_TMPDIR_METHOD="tmpdir"
        # Check if /tmp is tmpfs
        if ! df -T "$tmpdir" 2>/dev/null | grep -q tmpfs; then
            warn "Temporary directory is disk-backed; keys may touch disk"
        fi
    fi

    chmod 700 "$tmpdir"

    # Copy hardened config
    local project_root="${MISE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    if [[ -f "${project_root}/config/gpg.conf" ]]; then
        cp "${project_root}/config/gpg.conf" "$tmpdir/"
    fi
    generate_gpg_agent_conf "$tmpdir"
    generate_scdaemon_conf "$tmpdir"

    export GNUPGHOME="$tmpdir"
    export _YK_GPG_TMPDIR_METHOD
    info "Temporary GNUPGHOME: $GNUPGHOME (method: $_YK_GPG_TMPDIR_METHOD)"
}

# Cleans up the ephemeral GNUPGHOME created by setup_temp_gnupghome().
cleanup_temp_gnupghome() {
    if [[ -z "${GNUPGHOME:-}" ]]; then
        return
    fi

    # Kill gpg-agent
    gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true

    case "${_YK_GPG_TMPDIR_METHOD:-}" in
        ramdisk)
            if [[ -n "${_YK_GPG_RAMDISK_DEVICE:-}" ]]; then
                umount "$GNUPGHOME" 2>/dev/null || true
                hdiutil detach "$_YK_GPG_RAMDISK_DEVICE" 2>/dev/null || true
            fi
            ;;
        tmpfs)
            sudo umount "$GNUPGHOME" 2>/dev/null || true
            ;;
    esac

    rm -rf "$GNUPGHOME"
    unset GNUPGHOME
    unset _YK_GPG_TMPDIR_METHOD
    unset _YK_GPG_RAMDISK_DEVICE
    info "Cleaned up temporary GNUPGHOME"
}

# --- Networking ---

# Configures Tor proxy if YK_GPG_TOR_PROXY is set.
setup_networking() {
    if [[ -n "${YK_GPG_TOR_PROXY:-}" ]]; then
        export ALL_PROXY="$YK_GPG_TOR_PROXY"
        local gnupghome="${GNUPGHOME:-$(yk_gpg_config_dir)}"
        local project_root="${MISE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
        if [[ -f "${project_root}/config/dirmngr.conf" ]]; then
            cp "${project_root}/config/dirmngr.conf" "${gnupghome}/dirmngr.conf"
        fi
    fi
}

# --- Dependency checking ---

# Checks that gpg and jq are available (needed for all GPG operations).
check_gpg_deps() {
    local missing=()
    command -v gpg &>/dev/null || missing+=("gpg")
    command -v jq &>/dev/null || missing+=("jq")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        error "Run: mise run setup:install-deps"
        return 1
    fi
}

# Checks card-related deps (gpg-card, scdaemon, pcscd). Called by card/yubikey tasks.
check_card_deps() {
    check_gpg_deps || return 1
    local missing=()
    command -v gpg-card &>/dev/null || missing+=("gpg-card")
    # scdaemon: check both PATH and GnuPG libexec
    if ! command -v scdaemon &>/dev/null && \
       [[ ! -x /usr/lib/gnupg/scdaemon ]] && \
       [[ ! -x /usr/local/lib/gnupg/scdaemon ]] && \
       [[ ! -x /opt/homebrew/lib/gnupg/scdaemon ]]; then
        missing+=("scdaemon")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        error "Run: mise run setup:install-deps"
        return 1
    fi
    # pcscd: Linux only (macOS uses CryptoTokenKit)
    if is_linux && ! pgrep -x pcscd &>/dev/null; then
        if command -v systemctl &>/dev/null; then
            sudo systemctl start pcscd 2>/dev/null || { error "pcscd is not running"; return 1; }
        elif command -v pcscd &>/dev/null; then
            sudo pcscd 2>/dev/null || { error "pcscd is not running"; return 1; }
        else
            error "pcscd is not installed"
            return 1
        fi
    fi
}

# Checks that ykman is available. Only called by yubikey:* tasks.
check_ykman() {
    if ! command -v ykman &>/dev/null; then
        error "ykman (yubikey-manager) is not installed."
        error "Run: mise run setup:install-deps"
        return 1
    fi
}

# --- YubiKey detection ---

# Sets: YUBIKEY_MODEL, YUBIKEY_SERIAL, YUBIKEY_FIRMWARE
detect_yubikey() {
    check_yubikey || return 1
    local yk_info
    yk_info="$(ykman info 2>/dev/null)"

    YUBIKEY_MODEL="$(echo "$yk_info" | grep -i 'Device type:' | sed 's/.*: *//')"
    YUBIKEY_SERIAL="$(echo "$yk_info" | grep -i 'Serial number:' | sed 's/.*: *//')"
    YUBIKEY_FIRMWARE="$(echo "$yk_info" | grep -i 'Firmware version:' | sed 's/.*: *//')"

    if [[ -z "$YUBIKEY_MODEL" ]]; then
        YUBIKEY_MODEL="$(echo "$yk_info" | head -1)"
    fi

    export YUBIKEY_MODEL YUBIKEY_SERIAL YUBIKEY_FIRMWARE
    info "Detected: ${YUBIKEY_MODEL} (serial: ${YUBIKEY_SERIAL}, firmware: ${YUBIKEY_FIRMWARE})"
}

check_yubikey() {
    if ! ykman info &>/dev/null; then
        error "No YubiKey detected. Please insert a YubiKey and try again."
        return 1
    fi
}

# Returns best key type for the connected YubiKey
best_key_type() {
    if [[ -z "${YUBIKEY_FIRMWARE:-}" ]]; then
        detect_yubikey
    fi

    local major minor patch
    IFS='.' read -r major minor patch <<< "$YUBIKEY_FIRMWARE"

    if [[ "$major" -ge 5 ]] && [[ "$minor" -gt 2 || ("$minor" -eq 2 && "$patch" -ge 3) ]]; then
        echo "ed25519"
    else
        echo "rsa4096"
    fi
}

# Returns true if the connected YubiKey is a YubiKey 5 (firmware major >= 5)
is_yubikey5() {
    if [[ -z "${YUBIKEY_FIRMWARE:-}" ]]; then
        detect_yubikey
    fi
    local major
    IFS='.' read -r major _ _ <<< "$YUBIKEY_FIRMWARE"
    [[ "$major" -ge 5 ]]
}

# --- Config file generation ---

# Generates platform-specific gpg-agent.conf into the given directory.
generate_gpg_agent_conf() {
    local target_dir="$1"
    local pinentry_program
    case "$PLATFORM" in
        tails)  pinentry_program="/usr/bin/pinentry-gnome3" ;;
        macos)
            if [[ -x /opt/homebrew/bin/pinentry-mac ]]; then
                pinentry_program="/opt/homebrew/bin/pinentry-mac"
            elif [[ -x /usr/local/bin/pinentry-mac ]]; then
                pinentry_program="/usr/local/bin/pinentry-mac"
            else
                pinentry_program="/usr/bin/pinentry-curses"
            fi
            ;;
        *)      pinentry_program="/usr/bin/pinentry-curses" ;;
    esac
    cat > "${target_dir}/gpg-agent.conf" <<EOF
enable-ssh-support
pinentry-program ${pinentry_program}
default-cache-ttl 60
max-cache-ttl 120
allow-loopback-pinentry
EOF
}

# Generates platform-specific scdaemon.conf into the given directory.
generate_scdaemon_conf() {
    local target_dir="$1"
    if is_macos; then
        cat > "${target_dir}/scdaemon.conf" <<EOF
disable-ccid
pcsc-driver /System/Library/Frameworks/PCSC.framework/PCSC
EOF
    else
        cat > "${target_dir}/scdaemon.conf" <<EOF
disable-ccid
EOF
    fi
}
