mod fixture;

use predicates::prelude::*;

/// `--keyserver` with a bogus keyserver URL (via KDUB_KEYSERVER env) should fail
/// at the network call, not before.
/// This proves the keyserver publish path is wired up through to the HTTP layer.
#[test]
fn test_key_publish_keyserver_fails_at_network() {
    let tmp = tempfile::tempdir().unwrap();
    let data_dir = fixture::setup_key(&tmp);

    fixture::kdub_cmd_with_data_dir(&tmp, &data_dir)
        // Override keyserver to an unreachable address
        .env("KDUB_KEYSERVER", "hkps://127.0.0.1:1")
        .args(["key", "publish", fixture::FINGERPRINT, "--keyserver"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("keyserver upload failed"));
}

/// `GITHUB_TOKEN` env var with an invalid token should get past token resolution
/// and fail at the GitHub API call (not with a "token required" error).
#[test]
fn test_key_publish_github_invalid_token_fails_at_api() {
    let tmp = tempfile::tempdir().unwrap();
    let data_dir = fixture::setup_key(&tmp);

    fixture::kdub_cmd_with_data_dir(&tmp, &data_dir)
        .env("GITHUB_TOKEN", "not-a-real-token-just-for-test")
        .args(["key", "publish", fixture::FINGERPRINT, "--github"])
        .assert()
        .failure()
        // Should fail at GitHub API, not at "token required" validation
        .stderr(predicate::str::contains("GitHub upload failed"));
}
