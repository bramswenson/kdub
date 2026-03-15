#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _setup_test_xdg
    _load_common
}

@test "save_metadata creates JSON file at expected path" {
    save_metadata "ABCDEF1234" "identity" "Test User <test@example.com>"
    assert_file_exists "${YK_GPG_DATA_DIR}/identities/ABCDEF1234.json"
}

@test "save_metadata writes valid JSON with all k/v pairs" {
    save_metadata "ABCDEF1234" \
        "identity" "Test User" \
        "fingerprint" "ABCDEF1234" \
        "key_type" "ed25519"

    run jq -r '.identity' "${YK_GPG_DATA_DIR}/identities/ABCDEF1234.json"
    assert_output "Test User"

    run jq -r '.fingerprint' "${YK_GPG_DATA_DIR}/identities/ABCDEF1234.json"
    assert_output "ABCDEF1234"

    run jq -r '.key_type' "${YK_GPG_DATA_DIR}/identities/ABCDEF1234.json"
    assert_output "ed25519"
}

@test "save_metadata updates existing metadata (merge)" {
    save_metadata "ABCDEF1234" "identity" "Test User" "key_type" "ed25519"
    save_metadata "ABCDEF1234" "backed_up" "2026-03-10T00:00:00Z"

    # Original fields preserved
    run jq -r '.identity' "${YK_GPG_DATA_DIR}/identities/ABCDEF1234.json"
    assert_output "Test User"

    run jq -r '.key_type' "${YK_GPG_DATA_DIR}/identities/ABCDEF1234.json"
    assert_output "ed25519"

    # New field added
    run jq -r '.backed_up' "${YK_GPG_DATA_DIR}/identities/ABCDEF1234.json"
    assert_output "2026-03-10T00:00:00Z"
}

@test "load_metadata returns contents" {
    save_metadata "ABCDEF1234" "identity" "Test User"

    run load_metadata "ABCDEF1234"
    assert_success
    # Should be valid JSON containing the identity
    echo "$output" | jq -e '.identity == "Test User"'
}

@test "load_metadata returns 1 for missing file" {
    run load_metadata "NONEXISTENT"
    assert_failure
}
