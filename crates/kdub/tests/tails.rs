use assert_cmd::Command;
use predicates::prelude::*;

// ---------------------------------------------------------------------------
// Help text tests
// ---------------------------------------------------------------------------

#[test]
fn tails_help_shows_subcommands() {
    Command::cargo_bin("kdub")
        .unwrap()
        .args(["tails", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("download"))
        .stdout(predicate::str::contains("flash"))
        .stdout(predicate::str::contains("persist"));
}

#[test]
fn tails_download_help_shows_force() {
    Command::cargo_bin("kdub")
        .unwrap()
        .args(["tails", "download", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("--force"));
}

#[test]
fn tails_persist_help_shows_options() {
    Command::cargo_bin("kdub")
        .unwrap()
        .args(["tails", "persist", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("--passphrase"))
        .stdout(predicate::str::contains("--device"))
        .stdout(predicate::str::contains("--skip-preseed"));
}

#[test]
fn tails_flash_help_shows_options() {
    Command::cargo_bin("kdub")
        .unwrap()
        .args(["tails", "flash", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("--device"))
        .stdout(predicate::str::contains("--yes"));
}

// ---------------------------------------------------------------------------
// Error-path integration tests
// ---------------------------------------------------------------------------

/// On non-Linux, `kdub tails persist` should reject with platform guidance.
#[test]
#[cfg(not(target_os = "linux"))]
fn tails_persist_rejects_non_linux() {
    Command::cargo_bin("kdub")
        .unwrap()
        .args([
            "tails",
            "persist",
            "--device",
            "/dev/sdb",
            "--passphrase",
            "testpass123",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("requires Linux"));
}

/// On Linux, `kdub tails persist` without --device should fail with clear error.
#[test]
#[cfg(target_os = "linux")]
fn tails_persist_requires_device() {
    Command::cargo_bin("kdub")
        .unwrap()
        .args(["tails", "persist", "--passphrase", "testpass123"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("--device is required"));
}

/// On Linux in batch mode, persist without passphrase should fail.
#[test]
#[cfg(target_os = "linux")]
fn tails_persist_batch_requires_passphrase() {
    Command::cargo_bin("kdub")
        .unwrap()
        .args(["--batch", "tails", "persist", "--device", "/dev/sdb"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("batch mode requires passphrase"));
}

/// `kdub tails flash` without a cached ISO should fail with guidance.
/// Use a custom XDG_CACHE_HOME to ensure no cached ISO exists.
#[test]
fn tails_flash_no_cached_iso() {
    let tmp = tempfile::tempdir().unwrap();
    Command::cargo_bin("kdub")
        .unwrap()
        .env("XDG_CACHE_HOME", tmp.path())
        .args(["tails", "flash"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("No Tails image found"));
}

/// `kdub tails download` without network should fail but get past dispatch.
/// This verifies the command handler is wired up (not NotImplemented).
/// Use a bogus proxy to force a quick network failure.
#[test]
fn tails_download_fails_at_network() {
    Command::cargo_bin("kdub")
        .unwrap()
        .env("KDUB_TOR_PROXY", "socks5h://127.0.0.1:1")
        .args(["tails", "download", "--force"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("tails download error"));
}

/// On Linux, `KDUB_PASSPHRASE` env var is accepted for tails persist.
/// The command gets past passphrase resolution and fails at the device check
/// (--device is required), proving the env var path is wired up.
#[test]
#[cfg(target_os = "linux")]
fn tails_persist_passphrase_via_env() {
    Command::cargo_bin("kdub")
        .unwrap()
        .env("KDUB_PASSPHRASE", "testpass123")
        .args(["--batch", "tails", "persist"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("--device is required"));
}
