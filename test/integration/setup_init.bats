#!/usr/bin/env bats

setup() {
    load '../test_helper'
    _common_setup
    _setup_test_xdg
    _load_common
}

@test "setup:init creates XDG directories" {
    export BATCH_MODE=true
    run bash "${SRC_ROOT}/mise-tasks/setup/init"
    assert_success

    assert_dir_exists "$YK_GPG_CONFIG_DIR"
    assert_dir_exists "${YK_GPG_DATA_DIR}/identities"
    assert_dir_exists "${YK_GPG_DATA_DIR}/backups"
}

@test "setup:init copies gpg.conf" {
    export BATCH_MODE=true
    bash "${SRC_ROOT}/mise-tasks/setup/init"

    assert_file_exists "${YK_GPG_CONFIG_DIR}/gpg.conf"
    # Should have content from our gpg.conf
    run grep "personal-cipher-preferences" "${YK_GPG_CONFIG_DIR}/gpg.conf"
    assert_success
}

@test "setup:init generates gpg-agent.conf and scdaemon.conf" {
    export BATCH_MODE=true
    bash "${SRC_ROOT}/mise-tasks/setup/init"

    assert_file_exists "${YK_GPG_CONFIG_DIR}/gpg-agent.conf"
    assert_file_exists "${YK_GPG_CONFIG_DIR}/scdaemon.conf"

    run grep "pinentry-program" "${YK_GPG_CONFIG_DIR}/gpg-agent.conf"
    assert_success

    run grep "disable-ccid" "${YK_GPG_CONFIG_DIR}/scdaemon.conf"
    assert_success
}

@test "setup:init does NOT create dirmngr.conf without YK_GPG_TOR_PROXY" {
    export BATCH_MODE=true
    unset YK_GPG_TOR_PROXY
    bash "${SRC_ROOT}/mise-tasks/setup/init"

    assert_not_exists "${YK_GPG_CONFIG_DIR}/dirmngr.conf"
}

@test "setup:init creates dirmngr.conf when YK_GPG_TOR_PROXY is set" {
    export BATCH_MODE=true
    export YK_GPG_TOR_PROXY="socks5h://127.0.0.1:9050"
    bash "${SRC_ROOT}/mise-tasks/setup/init"

    assert_file_exists "${YK_GPG_CONFIG_DIR}/dirmngr.conf"
}
