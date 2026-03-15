#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _setup_test_xdg
    _load_common
    _setup_mock_gpg
    export BATCH_MODE=true
}

_run_card_provision() {
    bash "${SRC_ROOT}/mise-tasks/card/provision" "$@"
}

@test "card:provision transfers subkeys to card" {
    touch "$MOCK_GPG_STATE_DIR/setup-done"
    export usage_keyid="AAAABBBBCCCCDDDDEEEEFFFFAAAABBBBCCCCDDDD"
    export usage_admin_pin="12341234"
    export usage_passphrase="testpassphrase123"
    export usage_force="true"
    run _run_card_provision
    assert_success
    assert_output --partial "Subkeys transferred to card"
    assert_file_exists "$MOCK_GPG_STATE_DIR/provisioned"
}

@test "card:provision shows ssb> stubs after transfer" {
    touch "$MOCK_GPG_STATE_DIR/setup-done"
    export usage_keyid="AAAABBBBCCCCDDDDEEEEFFFFAAAABBBBCCCCDDDD"
    export usage_admin_pin="12341234"
    export usage_passphrase="testpassphrase123"
    export usage_force="true"
    run _run_card_provision
    assert_success
    assert_output --partial "ssb>"
}

@test "card:provision updates metadata with card_serial" {
    touch "$MOCK_GPG_STATE_DIR/setup-done"
    export usage_keyid="AAAABBBBCCCCDDDDEEEEFFFFAAAABBBBCCCCDDDD"
    export usage_admin_pin="12341234"
    export usage_passphrase="testpassphrase123"
    export usage_force="true"
    _run_card_provision

    local meta_file="${YK_GPG_DATA_DIR}/identities/AAAABBBBCCCCDDDDEEEEFFFFAAAABBBBCCCCDDDD.json"
    assert_file_exists "$meta_file"
    run jq -r '.card_serial' "$meta_file"
    assert_output "00001234"
    run jq -r '.provisioned' "$meta_file"
    refute_output "null"
}

@test "card:provision batch mode errors without --admin-pin" {
    export usage_keyid="AAAABBBBCCCCDDDDEEEEFFFFAAAABBBBCCCCDDDD"
    export usage_passphrase="testpassphrase123"
    run _run_card_provision
    assert_failure
    assert_output --partial "--admin-pin required"
}

@test "card:provision batch mode errors without --passphrase" {
    export usage_keyid="AAAABBBBCCCCDDDDEEEEFFFFAAAABBBBCCCCDDDD"
    export usage_admin_pin="12341234"
    run _run_card_provision
    assert_failure
    assert_output --partial "--passphrase required"
}

@test "card:provision errors when key not found" {
    export usage_keyid="NONEXISTENT"
    export usage_admin_pin="12341234"
    export usage_passphrase="testpassphrase123"
    # Remove the list-keys fixture so mock returns nothing
    echo -n "" > "$MOCK_GPG_STATE_DIR/list-keys-colon.txt"
    run _run_card_provision
    assert_failure
    assert_output --partial "Key not found"
}
