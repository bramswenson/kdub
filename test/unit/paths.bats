#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _load_common
}

@test "yk_gpg_config_dir defaults to \$HOME/.config/yk-gpg" {
    unset YK_GPG_CONFIG_DIR XDG_CONFIG_HOME
    run yk_gpg_config_dir
    assert_success
    assert_output "$HOME/.config/yk-gpg"
}

@test "yk_gpg_config_dir respects YK_GPG_CONFIG_DIR override" {
    YK_GPG_CONFIG_DIR="/custom/config/path"
    run yk_gpg_config_dir
    assert_success
    assert_output "/custom/config/path"
}

@test "yk_gpg_config_dir respects XDG_CONFIG_HOME fallback" {
    unset YK_GPG_CONFIG_DIR
    XDG_CONFIG_HOME="/xdg/config"
    run yk_gpg_config_dir
    assert_success
    assert_output "/xdg/config/yk-gpg"
}

@test "yk_gpg_data_dir defaults to \$HOME/.local/share/yk-gpg" {
    unset YK_GPG_DATA_DIR XDG_DATA_HOME
    run yk_gpg_data_dir
    assert_success
    assert_output "$HOME/.local/share/yk-gpg"
}

@test "yk_gpg_data_dir respects YK_GPG_DATA_DIR override" {
    YK_GPG_DATA_DIR="/custom/data"
    run yk_gpg_data_dir
    assert_success
    assert_output "/custom/data"
}

@test "yk_gpg_data_dir respects XDG_DATA_HOME fallback" {
    unset YK_GPG_DATA_DIR
    XDG_DATA_HOME="/xdg/data"
    run yk_gpg_data_dir
    assert_success
    assert_output "/xdg/data/yk-gpg"
}

@test "yk_gpg_state_dir defaults to \$HOME/.local/state/yk-gpg" {
    unset YK_GPG_STATE_DIR XDG_STATE_HOME
    run yk_gpg_state_dir
    assert_success
    assert_output "$HOME/.local/state/yk-gpg"
}

@test "yk_gpg_state_dir respects YK_GPG_STATE_DIR override" {
    YK_GPG_STATE_DIR="/custom/state"
    run yk_gpg_state_dir
    assert_success
    assert_output "/custom/state"
}

@test "YK_GPG_*_DIR takes precedence over XDG_*_HOME" {
    YK_GPG_CONFIG_DIR="/explicit"
    XDG_CONFIG_HOME="/xdg"
    run yk_gpg_config_dir
    assert_success
    assert_output "/explicit"
}
