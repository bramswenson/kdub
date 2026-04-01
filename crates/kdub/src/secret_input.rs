use std::io::BufRead;

use kdub_lib::error::KdubError;
use kdub_lib::types::ParseError;
use secrecy::{ExposeSecret, SecretString};

/// Resolve a secret value using the standard precedence:
/// 1. CLI flag value (`flag_value`)
/// 2. stdin (if `stdin_flag` is true — read one line)
/// 3. Environment variable (`env_var_name`)
/// 4. Interactive prompt (using `dialoguer::Password`)
///
/// When `confirm` is true, the interactive prompt asks the user to type
/// the secret twice. Use this when setting a new passphrase (key create,
/// persist), not when entering an existing one (backup, provision).
///
/// In batch mode, returns an error if no value is available from
/// steps 1-3 (interactive prompting is not allowed).
pub fn resolve_secret<T: std::str::FromStr<Err = ParseError>>(
    flag_value: Option<&str>,
    stdin_flag: bool,
    env_var_name: &str,
    prompt: &str,
    batch: bool,
) -> Result<T, KdubError> {
    resolve_secret_inner(flag_value, stdin_flag, env_var_name, prompt, batch, false)
}

/// Like [`resolve_secret`] but with confirmation prompting for new secrets.
pub fn resolve_secret_confirmed<T: std::str::FromStr<Err = ParseError>>(
    flag_value: Option<&str>,
    stdin_flag: bool,
    env_var_name: &str,
    prompt: &str,
    batch: bool,
) -> Result<T, KdubError> {
    resolve_secret_inner(flag_value, stdin_flag, env_var_name, prompt, batch, true)
}

fn resolve_secret_inner<T: std::str::FromStr<Err = ParseError>>(
    flag_value: Option<&str>,
    stdin_flag: bool,
    env_var_name: &str,
    prompt: &str,
    batch: bool,
    confirm: bool,
) -> Result<T, KdubError> {
    // 1. CLI flag
    if let Some(val) = flag_value {
        return val.parse::<T>().map_err(KdubError::Parse);
    }

    // 2. stdin
    if stdin_flag {
        let line = read_line_from_stdin()?;
        return line.expose_secret().parse::<T>().map_err(KdubError::Parse);
    }

    // 3. Environment variable
    if let Ok(val) = std::env::var(env_var_name)
        && !val.is_empty()
    {
        return val.parse::<T>().map_err(KdubError::Parse);
    }

    // 4. Interactive prompt (only in non-batch mode)
    if batch {
        return Err(KdubError::UsageError(
            "batch mode requires secret via flag, stdin, or env var".to_string(),
        ));
    }

    let input = if confirm {
        dialoguer::Password::new()
            .with_prompt(prompt)
            .with_confirmation("Confirm passphrase", "Passphrases don't match, try again")
            .interact()
    } else {
        dialoguer::Password::new().with_prompt(prompt).interact()
    }
    .map_err(|e| KdubError::Io(std::io::Error::other(e)))?;

    input.parse::<T>().map_err(KdubError::Parse)
}

/// Read a single line from stdin.
fn read_line_from_stdin() -> Result<SecretString, KdubError> {
    let stdin = std::io::stdin();
    let mut line = String::new();
    stdin.lock().read_line(&mut line).map_err(KdubError::Io)?;
    if line.is_empty() {
        return Err(KdubError::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "no input on stdin",
        )));
    }
    Ok(SecretString::from(line.trim().to_string()))
}

/// Validate that at most one stdin-consuming flag is set.
/// Multiple `--*-stdin` flags would race for the same stdin stream.
pub fn check_stdin_conflicts(flags: &[(&str, bool)]) -> Result<(), KdubError> {
    let active: Vec<&str> = flags
        .iter()
        .filter(|(_, set)| *set)
        .map(|(name, _)| *name)
        .collect();
    if active.len() > 1 {
        return Err(KdubError::UsageError(format!(
            "conflicting stdin flags: {} — only one can read stdin",
            active.join(", ")
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_stdin_conflicts_no_flags() {
        let result =
            check_stdin_conflicts(&[("--passphrase-stdin", false), ("--pin-stdin", false)]);
        assert!(result.is_ok());
    }

    #[test]
    fn check_stdin_conflicts_single_active_ok() {
        let result = check_stdin_conflicts(&[("--passphrase-stdin", true), ("--pin-stdin", false)]);
        assert!(result.is_ok());
    }

    #[test]
    fn check_stdin_conflicts_multiple_active_error() {
        let result = check_stdin_conflicts(&[("--passphrase-stdin", true), ("--pin-stdin", true)]);
        assert!(result.is_err());
        let err = result.unwrap_err();
        // Error message should mention both conflicting flags
        let msg = err.to_string();
        assert!(
            msg.contains("--passphrase-stdin") && msg.contains("--pin-stdin"),
            "error should name both flags, got: {msg}"
        );
    }

    #[test]
    fn check_stdin_conflicts_three_flags_two_active_error() {
        let result = check_stdin_conflicts(&[
            ("--passphrase-stdin", true),
            ("--admin-pin-stdin", false),
            ("--user-pin-stdin", true),
        ]);
        assert!(result.is_err());
    }

    #[test]
    fn check_stdin_conflicts_empty_slice_ok() {
        let result = check_stdin_conflicts(&[]);
        assert!(result.is_ok());
    }
}
