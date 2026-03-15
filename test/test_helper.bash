_common_setup() {
    # Load bats helper libraries from submodules
    load "${BATS_TEST_DIRNAME}/../bats-support/load"
    load "${BATS_TEST_DIRNAME}/../bats-assert/load"
    load "${BATS_TEST_DIRNAME}/../bats-file/load"

    # PROJECT_ROOT = repo root, SRC_ROOT = src/ (distribution code)
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}" && while [[ ! -f mise.toml && "$PWD" != "/" ]]; do cd ..; done && pwd)"
    SRC_ROOT="${PROJECT_ROOT}/src"
    export PROJECT_ROOT SRC_ROOT MISE_PROJECT_ROOT="$SRC_ROOT"
}

# Source src/lib/common.sh (which sources src/lib/platform.sh)
_load_common() {
    # shellcheck source=../src/lib/common.sh
    source "${SRC_ROOT}/lib/common.sh"
}

# Create an isolated test GNUPGHOME with its own gpg-agent.
# This prevents any interaction with the system gpg-agent.
_setup_test_gnupghome() {
    export GNUPGHOME="${BATS_TEST_TMPDIR}/gnupg"
    mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

    # Prevent connecting to the system gpg-agent
    unset GPG_AGENT_INFO

    cp "${SRC_ROOT}/config/gpg.conf" "$GNUPGHOME/"
    local pinentry="/bin/false"
    [[ "$(uname)" == "Darwin" ]] && pinentry="/usr/bin/false"
    cat > "$GNUPGHOME/gpg-agent.conf" <<EOF
allow-loopback-pinentry
pinentry-program ${pinentry}
default-cache-ttl 600
max-cache-ttl 600
no-grab
EOF
    # Start a fresh agent bound to this GNUPGHOME
    gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
    gpg-agent --homedir "$GNUPGHOME" --daemon --allow-loopback-pinentry 2>/dev/null || true
}

_teardown_test_gnupghome() {
    if [[ -n "${GNUPGHOME:-}" ]]; then
        gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true
        rm -rf "$GNUPGHOME"
    fi
}

# Create isolated test XDG dirs
_setup_test_xdg() {
    export YK_GPG_CONFIG_DIR="${BATS_TEST_TMPDIR}/config/yk-gpg"
    export YK_GPG_DATA_DIR="${BATS_TEST_TMPDIR}/data/yk-gpg"
    export YK_GPG_STATE_DIR="${BATS_TEST_TMPDIR}/state/yk-gpg"
    mkdir -p "$YK_GPG_CONFIG_DIR" "$YK_GPG_DATA_DIR/identities" "$YK_GPG_DATA_DIR/backups" "$YK_GPG_STATE_DIR"
}

# Set up mock gpg for card tests. Call in setup() AFTER _common_setup and _load_common.
_setup_mock_gpg() {
    MOCK_GPG_STATE_DIR="${BATS_TEST_TMPDIR}/mock-gpg-state"
    export MOCK_GPG_STATE_DIR
    mkdir -p "$MOCK_GPG_STATE_DIR"

    # Save path to real gpg before prepending mock
    MOCK_GPG_REAL="$(command -v gpg)"
    export MOCK_GPG_REAL

    # Install canned output files into state dir
    for f in card-status-factory.txt card-status-setup.txt card-status-provisioned.txt \
             list-keys-colon.txt secret-keys-stub.txt secret-keys-local.txt; do
        cp "${PROJECT_ROOT}/test/fixtures/${f}" "$MOCK_GPG_STATE_DIR/"
    done

    # Create mock gpg bin dir
    local mock_bin_dir="${BATS_TEST_TMPDIR}/mock-bin"
    mkdir -p "$mock_bin_dir"
    cp "${PROJECT_ROOT}/test/fixtures/mock-gpg" "$mock_bin_dir/gpg"
    chmod +x "$mock_bin_dir/gpg"

    # Stubs for check_card_deps
    printf '#!/bin/sh\nexit 0\n' > "$mock_bin_dir/gpg-card"
    printf '#!/bin/sh\nexit 0\n' > "$mock_bin_dir/scdaemon"
    printf '#!/bin/sh\nexit 0\n' > "$mock_bin_dir/pgrep"
    chmod +x "$mock_bin_dir/gpg-card" "$mock_bin_dir/scdaemon" "$mock_bin_dir/pgrep"

    # Prepend to PATH so card task scripts find mock gpg first
    export PATH="${mock_bin_dir}:${PATH}"
}
