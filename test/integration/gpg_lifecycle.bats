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

# Helper: create a test key and export its fingerprint
_create_test_key() {
    export usage_identity="Lifecycle Test <lifecycle@example.com>"
    export usage_key_type="ed25519"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"
    bash "${SRC_ROOT}/mise-tasks/gpg/create"
    TEST_FP="$(gpg --with-colons --list-keys "Lifecycle Test" | grep '^fpr:' | head -1 | cut -d: -f10)"
    TEST_KEYID="0x${TEST_FP: -16}"
}

@test "backup exports keys to YK_GPG_DATA_DIR/backups/<fp>/" {
    _create_test_key

    export usage_keyid="$TEST_KEYID"
    export usage_passphrase="testpassphrase123"
    run bash "${SRC_ROOT}/mise-tasks/gpg/backup"
    assert_success

    local backup_dir="${YK_GPG_DATA_DIR}/backups/${TEST_FP}"
    assert_file_exists "${backup_dir}/certify-key.asc"
    assert_file_exists "${backup_dir}/subkeys.asc"
    assert_file_exists "${backup_dir}/public-key.asc"
    assert_file_exists "${backup_dir}/ownertrust.txt"
    assert_file_exists "${backup_dir}/revocation-cert.asc"
}

@test "restore imports keys into fresh GNUPGHOME" {
    _create_test_key

    # Backup
    export usage_keyid="$TEST_KEYID"
    export usage_passphrase="testpassphrase123"
    bash "${SRC_ROOT}/mise-tasks/gpg/backup"

    # Create a new clean GNUPGHOME
    _teardown_test_gnupghome
    _setup_test_gnupghome

    # Restore
    export usage_fingerprint="$TEST_FP"
    export usage_passphrase="testpassphrase123"
    run bash "${SRC_ROOT}/mise-tasks/gpg/restore"
    assert_success

    # Verify the key is present in the new GNUPGHOME
    run gpg --with-colons --list-keys "Lifecycle Test"
    assert_success
    assert_output --partial "fpr:::::::::${TEST_FP}:"
}

@test "list outputs without error" {
    _create_test_key

    run bash "${SRC_ROOT}/mise-tasks/gpg/list"
    assert_success
    assert_output --partial "Lifecycle Test"
}

@test "renew extends expiry" {
    _create_test_key

    # Get original expiry of first subkey
    local orig_exp
    orig_exp="$(gpg --with-colons --list-keys "$TEST_FP" | grep '^sub:' | head -1 | cut -d: -f7)"

    export usage_identity="Lifecycle Test"
    export usage_expiration="3y"
    export usage_passphrase="testpassphrase123"
    run bash "${SRC_ROOT}/mise-tasks/gpg/renew"
    assert_success

    # Get new expiry
    local new_exp
    new_exp="$(gpg --with-colons --list-keys "$TEST_FP" | grep '^sub:' | head -1 | cut -d: -f7)"

    # New expiry should be later than original
    [[ "$new_exp" -gt "$orig_exp" ]]
}

@test "rotate creates new subkeys" {
    _create_test_key

    # Original subkey count
    local orig_count
    orig_count="$(gpg --with-colons --list-keys "$TEST_FP" | grep -c '^sub:')"

    export usage_identity="Lifecycle Test"
    export usage_key_type="ed25519"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"
    export usage_revoke_old="false"
    run bash "${SRC_ROOT}/mise-tasks/gpg/rotate"
    assert_success

    # New subkey count should be higher (3 original + 3 new)
    local new_count
    new_count="$(gpg --with-colons --list-keys "$TEST_FP" | grep -c '^sub:')"
    [[ "$new_count" -gt "$orig_count" ]]
}

@test "rotate with --revoke-old revokes old subkeys" {
    _create_test_key

    export usage_identity="Lifecycle Test"
    export usage_key_type="ed25519"
    export usage_expiration="2y"
    export usage_passphrase="testpassphrase123"
    export usage_revoke_old="true"
    run bash "${SRC_ROOT}/mise-tasks/gpg/rotate"
    assert_success

    # Should have revoked subkeys (shown as 'r' trust in colon output)
    run gpg --with-colons --list-keys "$TEST_FP"
    assert_output --partial 'sub:r:'
}
