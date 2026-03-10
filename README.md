# GPG + YubiKey Management for Tails OS

Automated GPG key lifecycle management with YubiKey hardware tokens on Tails OS.
Based on [drduh/YubiKey-Guide](https://github.com/drduh/YubiKey-Guide), wrapped in [mise](https://mise.jdx.dev/) tasks for repeatable multi-identity workflows.

## Prerequisites

### Tails Persistent Storage Features

Enable these in Tails persistent storage settings:

- **GnuPG** - persists `~/.gnupg` across reboots
- **Additional Software** - persists installed packages
- **Persistent Folder** - general persistent storage
- **Dotfiles** - persists shell configuration (for mise activation)

### Hardware

- YubiKey 4 NFC (RSA up to 4096 only)
- YubiKey 5 NFC fw 5.2.3+ (RSA 2048-4096, ed25519, cv25519)

## Installation

```bash
# Install mise task runner
./install-mise.sh
source ~/.bashrc

# Install required packages (yubikey-manager, scdaemon, pcscd, etc.)
mise run gpg:install-deps
```

After installing packages, open Tails "Additional Software" settings and mark each package as "Install Every Time" so they persist across reboots.

## Creating an Identity

**Disable networking before generating keys.**

```bash
# Auto-detects key type from connected YubiKey
mise run gpg:create -- "Alice Smith <alice@example.com>"

# Explicit key type and expiration
mise run gpg:create -- "Work Identity <work@corp.com>" --key-type rsa4096 --expiration 1y
```

This will:
1. Create a certify-only master key (no expiration)
2. Generate a strong passphrase for the certify key (displayed once - record it!)
3. Create sign, encrypt, and authenticate subkeys (with expiration)
4. Optionally continue to backup

## Backing Up Keys

```bash
# Backup to Tails persistent storage
mise run gpg:backup -- 0xABCD1234
```

Keys are exported and imported into the Tails persistent GNUPGHOME (`/home/bram/TailsData/gnupg/`), which is encrypted at rest by Tails.

## Setting Up a YubiKey

Configure a fresh or factory-reset YubiKey before transferring keys:

```bash
# Basic setup: configure PINs, KDF, and touch policy
mise run gpg:yubikey-setup

# With identity metadata and public key URL
mise run gpg:yubikey-setup -- --identity 0xABCD1234 --url https://keys.openpgp.org/vks/v1/by-fingerprint/FINGERPRINT
```

This will:
1. Detect YubiKey model and firmware
2. Enable KDF (PIN hashing) on YubiKey 5
3. Generate and set new Admin PIN (8 digits) and User PIN (6 digits)
4. Set cardholder name and login from identity (if provided)
5. Set public key URL on card (if provided)
6. Enable touch requirement for crypto operations on YubiKey 5

## Provisioning a YubiKey

Transfer GPG subkeys to a YubiKey that has already been set up:

```bash
mise run gpg:yubikey-provision -- 0xABCD1234
```

This will:
1. Verify the YubiKey has been configured (rejects factory-default PINs)
2. Transfer sign, encrypt, and authenticate subkeys to the card
3. Verify the transfer succeeded (keys show as stubs)
4. Save provisioning metadata

## Publishing Your Public Key

After creating keys, publish your public key to make it discoverable:

```bash
# Upload to keys.openpgp.org (requires email verification after upload)
mise run gpg:publish -- 0xABCD1234 --keyserver

# Upload to GitHub (requires GITHUB_TOKEN env var)
mise run gpg:publish -- 0xABCD1234 --github

# Export to a file
mise run gpg:publish -- 0xABCD1234 --file /tmp/pubkey.asc

# Export for Web Key Directory
mise run gpg:publish -- 0xABCD1234 --wkd /path/to/webroot

# Interactive mode (asks which destinations)
mise run gpg:publish -- 0xABCD1234
```

## Daily Usage

After provisioning, your YubiKey works for:

### Signing
```bash
echo "test" | gpg --armor --clearsign
git commit -S -m "signed commit"
```

### Encrypting
```bash
gpg --recipient alice@example.com --encrypt document.txt
gpg --decrypt document.txt.gpg
```

### SSH Authentication
```bash
# GPG agent provides SSH key from YubiKey auth subkey
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
ssh-add -L  # should show your GPG auth key
ssh user@host
```

## Managing Multiple YubiKeys

When switching between YubiKeys with different identities:

```bash
# Tell gpg-agent to learn the new card
gpg-connect-agent "scd serialno" "learn --force" /bye

# Verify the correct key is active
gpg --card-status
```

## Key Lifecycle Management

### Renewing Subkeys (extending expiration)

Use when subkeys are approaching expiration but you don't need new key material:

```bash
mise run gpg:renew -- "Alice Smith" --expiration 2y
```

### Rotating Subkeys (generating new ones)

Use annually or when you suspect key compromise. Creates new subkeys and optionally revokes old ones:

```bash
mise run gpg:rotate -- "Alice Smith"
mise run gpg:rotate -- "Alice Smith" --key-type ed25519 --expiration 2y
```

### When to Renew vs Rotate

| Scenario | Action |
|---|---|
| Subkeys expiring, no concerns | Renew |
| Annual maintenance | Rotate |
| Suspected compromise | Rotate + revoke old |
| Upgrading algorithm (RSA→ed25519) | Rotate |

## Listing Identities
```bash
mise run gpg:list
```

Shows all managed identities with:
- Key IDs and fingerprints
- Subkey expiration status (highlights expired or expiring-within-90-days)
- Associated YubiKey serial numbers
- Current YubiKey status if connected

## YubiKey Reset

Factory reset the OpenPGP applet (destroys all keys on the YubiKey):

```bash
mise run gpg:yubikey-reset
```

## YubiKey Compatibility

| Feature | YubiKey 4 NFC | YubiKey 5 NFC (fw 5.2.3+) |
|---|---|---|
| RSA 2048 | Yes | Yes |
| RSA 4096 | Yes | Yes |
| ed25519 / cv25519 | No | Yes |
| NIST P-256/P-384 | No | Yes |
| Touch policy | No | Yes |
| KDF (PIN hashing) | No | Yes |

The scripts auto-detect the connected YubiKey and select the best algorithm.

## Security Considerations

- **Disable networking** before generating or handling key material
- **Certify key passphrase** is the most critical secret - store it in a physically secure location (e.g., safe, separate from YubiKey)
- **PINs** protect YubiKey operations - record them securely but separately from the YubiKey
- **Persistent storage** on Tails is encrypted at rest, but the certify key is still accessible when Tails is running
- The tmpfs-based temporary GNUPGHOME ensures key material never touches persistent disk during generation

## Troubleshooting

### "No YubiKey detected"
- Ensure the YubiKey is properly inserted
- Run `sudo systemctl start pcscd`
- Try `ykman info` to verify basic connectivity

### "gpg: selecting card failed"
- Kill and restart gpg-agent: `gpgconf --kill gpg-agent`
- Restart scdaemon: `gpgconf --kill scdaemon`
- Remove stale scdaemon socket: `rm ~/.gnupg/S.scdaemon`

### "Operation not supported by device"
- Your YubiKey may not support the requested algorithm
- Use `--key-type rsa4096` for YubiKey 4

### "gpg: signing failed: No secret key"
- Ensure the correct YubiKey is inserted
- Run `gpg-connect-agent "scd serialno" "learn --force" /bye`
- Check `gpg --card-status`

### Permission errors
- Ensure pcscd is running: `sudo systemctl start pcscd`
- Check udev rules are in place for YubiKey access
