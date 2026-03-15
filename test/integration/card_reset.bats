#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _setup_test_xdg
    _load_common
    _setup_mock_gpg
    export BATCH_MODE=true
}

_run_card_reset() {
    bash "${SRC_ROOT}/mise-tasks/card/reset" "$@"
}

@test "card:reset --force resets to factory state" {
    touch "$MOCK_GPG_STATE_DIR/setup-done"
    touch "$MOCK_GPG_STATE_DIR/provisioned"
    export usage_force="true"
    run _run_card_reset
    assert_success
    assert_output --partial "Card reset to factory defaults"
    assert_file_not_exists "$MOCK_GPG_STATE_DIR/setup-done"
    assert_file_not_exists "$MOCK_GPG_STATE_DIR/provisioned"
}

@test "card:reset shows default PIN info after reset" {
    touch "$MOCK_GPG_STATE_DIR/setup-done"
    export usage_force="true"
    run _run_card_reset
    assert_success
    assert_output --partial "123456"
    assert_output --partial "12345678"
}

@test "card:reset shows card status before reset" {
    export usage_force="true"
    run _run_card_reset
    assert_success
    assert_output --partial "CARD FACTORY RESET"
}
