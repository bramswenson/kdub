#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _setup_test_xdg
    _load_common
    _setup_mock_gpg
    export BATCH_MODE=true
}

_run_card_info() {
    bash "${SRC_ROOT}/mise-tasks/card/info" "$@"
}

@test "card:info shows card status" {
    run _run_card_info
    assert_success
    assert_output --partial "OpenPGP Card Status"
    assert_output --partial "Serial number"
}

@test "card:info shows factory state for unprovisioned card" {
    run _run_card_info
    assert_success
    assert_output --partial "KDF setting ......: off"
    assert_output --partial "General key info..: [none]"
}

@test "card:info shows provisioned state when card has keys" {
    touch "$MOCK_GPG_STATE_DIR/provisioned"
    run _run_card_info
    assert_success
    assert_output --partial "Serial number ....: 00001234"
    assert_output --partial "ssb>"
}

@test "card:info exits 1 when no card detected" {
    rm -f "$MOCK_GPG_STATE_DIR"/card-status-*.txt
    run _run_card_info
    assert_failure
}
