#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _load_common
}

@test "best_key_type returns ed25519 for YubiKey 5.2.3" {
    YUBIKEY_FIRMWARE="5.2.3"
    run best_key_type
    assert_success
    assert_output "ed25519"
}

@test "best_key_type returns ed25519 for YubiKey 5.4.0" {
    YUBIKEY_FIRMWARE="5.4.0"
    run best_key_type
    assert_success
    assert_output "ed25519"
}

@test "best_key_type returns rsa4096 for YubiKey 5.1.0" {
    YUBIKEY_FIRMWARE="5.1.0"
    run best_key_type
    assert_success
    assert_output "rsa4096"
}

@test "best_key_type returns rsa4096 for YubiKey 4.3.7" {
    YUBIKEY_FIRMWARE="4.3.7"
    run best_key_type
    assert_success
    assert_output "rsa4096"
}

@test "is_yubikey5 returns true for 5.x.x firmware" {
    YUBIKEY_FIRMWARE="5.4.3"
    run is_yubikey5
    assert_success
}

@test "is_yubikey5 returns false for 4.x.x firmware" {
    YUBIKEY_FIRMWARE="4.3.7"
    run is_yubikey5
    assert_failure
}
