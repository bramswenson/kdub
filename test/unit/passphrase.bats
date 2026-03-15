#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _load_common
}

@test "generate_passphrase default length is 20 chars" {
    run generate_passphrase
    assert_success
    # Output includes trailing newline; trim it
    local result="${output}"
    assert_equal "${#result}" 20
}

@test "generate_passphrase custom length works" {
    run generate_passphrase 10
    assert_success
    local result="${output}"
    assert_equal "${#result}" 10
}

@test "generate_passphrase output charset is valid" {
    run generate_passphrase 100
    assert_success
    # Should only contain characters from the allowed set
    local result="${output}"
    local cleaned
    cleaned="$(echo "$result" | tr -d 'ABCDEFGHJKLMNPQRTVWXYZ234679')"
    assert_equal "$cleaned" ""
}

@test "generate_passphrase two calls produce different output" {
    local p1 p2
    p1="$(generate_passphrase 40)"
    p2="$(generate_passphrase 40)"
    # With 40 chars from a 28-char alphabet, collision is astronomically unlikely
    [[ "$p1" != "$p2" ]]
}
