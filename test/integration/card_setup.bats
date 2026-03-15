#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _setup_test_xdg
    _load_common
    _setup_mock_gpg
    export BATCH_MODE=true
}

_run_card_setup() {
    bash "${SRC_ROOT}/mise-tasks/card/setup" "$@"
}

@test "card:setup with --factory-pins changes PINs" {
    export usage_factory_pins="true"
    export usage_new_admin_pin="12341234"
    export usage_new_user_pin="654321"
    export usage_skip_kdf="true"
    run _run_card_setup
    assert_success
    assert_output --partial "Admin PIN changed"
    assert_output --partial "User PIN changed"
    assert_file_exists "$MOCK_GPG_STATE_DIR/setup-done"
}

@test "card:setup batch mode errors without --factory-pins or --admin-pin" {
    run _run_card_setup
    assert_failure
    assert_output --partial "--factory-pins or --admin-pin is required"
}

@test "card:setup with --admin-pin skips PIN change" {
    export usage_admin_pin="12341234"
    export usage_skip_kdf="true"
    run _run_card_setup
    assert_success
    refute_output --partial "Admin PIN changed"
}

@test "card:setup sets cardholder name when --identity provided" {
    export usage_factory_pins="true"
    export usage_new_admin_pin="12341234"
    export usage_new_user_pin="654321"
    export usage_skip_kdf="true"
    export usage_identity="Test User <test@example.com>"
    run _run_card_setup
    assert_success
    assert_output --partial "Setting cardholder"
}

@test "card:setup enables KDF when factory pins and not skipped" {
    export usage_factory_pins="true"
    export usage_new_admin_pin="12341234"
    export usage_new_user_pin="654321"
    run _run_card_setup
    assert_success
    assert_output --partial "KDF enabled"
}

@test "card:setup skips KDF when --skip-kdf provided" {
    export usage_factory_pins="true"
    export usage_new_admin_pin="12341234"
    export usage_new_user_pin="654321"
    export usage_skip_kdf="true"
    run _run_card_setup
    assert_success
    refute_output --partial "KDF enabled"
}

@test "card:setup shows verification card status at end" {
    export usage_factory_pins="true"
    export usage_new_admin_pin="12341234"
    export usage_new_user_pin="654321"
    export usage_skip_kdf="true"
    run _run_card_setup
    assert_success
    assert_output --partial "Card setup complete"
}
