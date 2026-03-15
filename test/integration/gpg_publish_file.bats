#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _setup_test_xdg
    _setup_test_gnupghome
    _load_common
    export BATCH_MODE=true
}

teardown() {
    _teardown_test_gnupghome
}

@test "publish --file creates valid PGP public key file" {
    # Create a test key
    export usage_identity="Publish Test <publish@example.com>"
    export usage_key_type="ed25519"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"
    bash "${SRC_ROOT}/mise-tasks/gpg/create"

    local fp
    fp="$(gpg --with-colons --list-keys "Publish Test" | grep '^fpr:' | head -1 | cut -d: -f10)"
    local keyid="0x${fp: -16}"
    local outfile="${BATS_TEST_TMPDIR}/test-pubkey.asc"

    export usage_keyid="$keyid"
    export usage_keyserver="false"
    export usage_github="false"
    export usage_wkd=""
    export usage_file="$outfile"
    export usage_all="false"

    run bash "${SRC_ROOT}/mise-tasks/gpg/publish"
    assert_success

    # File should exist and contain PGP public key block
    assert_file_exists "$outfile"
    run grep "BEGIN PGP PUBLIC KEY BLOCK" "$outfile"
    assert_success

    # Should be importable into a separate GNUPGHOME
    # Use short path to stay under macOS 104-byte Unix socket limit
    local other_gnupg="/tmp/yk-test-$$"
    mkdir -p "$other_gnupg" && chmod 700 "$other_gnupg"
    run gpg --homedir "$other_gnupg" --import "$outfile"
    gpgconf --homedir "$other_gnupg" --kill all 2>/dev/null || true
    rm -rf "$other_gnupg"
    assert_success
}
