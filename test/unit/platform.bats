#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _load_common
}

@test "detect_platform returns linux or macos" {
    run detect_platform
    assert_success
    assert_output --regexp '^(linux|macos|tails)$'
}

@test "is_linux returns true on Linux" {
    if [[ "$(uname)" != "Linux" ]]; then
        skip "Not on Linux"
    fi
    run is_linux
    assert_success
}

@test "is_macos returns true on macOS" {
    if [[ "$(uname)" != "Darwin" ]]; then
        skip "Not on macOS"
    fi
    run is_macos
    assert_success
}

@test "is_tails returns false on non-Tails" {
    # Unless we're actually on Tails, this should be false
    if grep -q "Tails" /etc/os-release 2>/dev/null; then
        skip "Actually on Tails"
    fi
    run is_tails
    assert_failure
}

@test "is_batch returns true when BATCH_MODE=true" {
    BATCH_MODE=true run is_batch
    assert_success
}

@test "is_batch returns true when CI=true" {
    unset BATCH_MODE
    # Need to re-source to pick up CI-based detection
    CI=true source "${SRC_ROOT}/lib/platform.sh"
    run is_batch
    assert_success
}

@test "is_batch returns false when unset" {
    unset BATCH_MODE CI
    source "${SRC_ROOT}/lib/platform.sh"
    run is_batch
    assert_failure
}
