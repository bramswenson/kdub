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

_run_create() {
    bash "${SRC_ROOT}/mise-tasks/gpg/create" "$@"
}

@test "creates ed25519 key in batch mode with --passphrase" {
    export usage_identity="Test User <test@example.com>"
    export usage_key_type="ed25519"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"

    run _run_create
    assert_success

    # Verify key exists
    run gpg --with-colons --list-secret-keys "Test User"
    assert_success
    assert_output --partial 'sec:'
}

@test "creates 1 certify + 3 subkeys (sign/encrypt/auth)" {
    export usage_identity="SubkeyTest <subkey@example.com>"
    export usage_key_type="ed25519"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"

    _run_create

    # Count sec (certify) and ssb (subkey) lines
    local sec_count ssb_count
    sec_count="$(gpg --with-colons --list-secret-keys "SubkeyTest" | grep -c '^sec:')"
    ssb_count="$(gpg --with-colons --list-secret-keys "SubkeyTest" | grep -c '^ssb:')"

    [[ "$sec_count" -eq 1 ]]
    [[ "$ssb_count" -eq 3 ]]
}

@test "creates metadata JSON at YK_GPG_DATA_DIR" {
    export usage_identity="MetaTest <meta@example.com>"
    export usage_key_type="ed25519"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"

    _run_create

    local fp
    fp="$(gpg --with-colons --list-keys "MetaTest" | grep '^fpr:' | head -1 | cut -d: -f10)"
    assert_file_exists "${YK_GPG_DATA_DIR}/identities/${fp}.json"

    run jq -r '.identity' "${YK_GPG_DATA_DIR}/identities/${fp}.json"
    assert_output "MetaTest <meta@example.com>"

    run jq -r '.key_type' "${YK_GPG_DATA_DIR}/identities/${fp}.json"
    assert_output "ed25519"
}

@test "creates rsa4096 key successfully" {
    export usage_identity="RSA Test <rsa@example.com>"
    export usage_key_type="rsa4096"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"

    run _run_create
    assert_success

    run gpg --with-colons --list-secret-keys "RSA Test"
    assert_success
    assert_output --partial 'sec:'
}

@test "batch mode errors when --passphrase missing" {
    export usage_identity="NoPass <nopass@example.com>"
    export usage_key_type="ed25519"
    export usage_expiration="2y"
    unset usage_passphrase

    run _run_create
    assert_failure
    assert_output --partial "passphrase is required"
}

@test "errors on invalid key type" {
    export usage_identity="BadType <bad@example.com>"
    export usage_key_type="dsa1024"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"

    run _run_create
    assert_failure
    assert_output --partial "Unsupported key type"
}
