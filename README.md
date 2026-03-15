# yk-gpg

Cross-platform GPG key lifecycle management with OpenPGP smart card support (YubiKey and others). Based on [drduh/YubiKey-Guide](https://github.com/drduh/YubiKey-Guide), wrapped in [mise](https://mise.jdx.dev/) tasks.

**Primary target**: Tails OS (Debian, GnuPG 2.4+)
**Also supported**: Ubuntu/Debian, Fedora, Arch Linux, macOS (Homebrew)

## What it does

- Create GPG identities with certify key + sign/encrypt/auth subkeys
- Backup and restore keys to/from persistent storage
- Provision subkeys to OpenPGP smart cards (YubiKey, Nitrokey, etc.)
- Renew expiring subkeys or rotate to new key material
- Publish public keys to keyservers, GitHub, WKD, or files
- Ephemeral RAM-backed GNUPGHOME — key material never touches disk during generation

## Installation

```bash
# Clone the repo
git clone https://github.com/bramswenson/yk-gpg.git
cd yk-gpg/src

# Install mise (if not already installed)
./install-mise.sh
source ~/.bashrc  # or restart your shell

# Initialize directories and config
mise run setup:init

# Install system packages (gpg, scdaemon, pcscd, jq, ykman)
mise run setup:install-deps
```

### Tails OS

After each Tails boot (packages don't persist):

```bash
cd /path/to/yk-gpg/src
mise run tails:install-deps
```

On first use, wire XDG directories into Tails persistent storage:

```bash
mise run tails:setup-persistence
```

## Usage

### Creating an identity

**Disable networking before generating keys.**

```bash
# Auto-detects key type from connected YubiKey
mise run gpg:create -- "Alice Smith <alice@example.com>"

# Explicit key type and expiration
mise run gpg:create -- "Work <work@corp.com>" --key-type rsa4096 --expiration 1y
```

This creates a certify-only master key (no expiration), generates a strong passphrase (displayed once — record it), and creates sign/encrypt/auth subkeys with expiration.

### Backing up keys

```bash
mise run gpg:backup -- 0xKEYID
```

### Restoring from backup

```bash
mise run gpg:restore -- FINGERPRINT
```

### Setting up a smart card

```bash
# Configure PINs, KDF, cardholder info
mise run card:setup -- 0xKEYID

# Transfer subkeys to card
mise run card:provision -- 0xKEYID

# YubiKey 5+: enable touch requirement
mise run yubikey:setup-touch
```

### Publishing your public key

```bash
mise run gpg:publish -- 0xKEYID --keyserver    # keys.openpgp.org
mise run gpg:publish -- 0xKEYID --github       # requires GITHUB_TOKEN
mise run gpg:publish -- 0xKEYID --file pubkey.asc
mise run gpg:publish -- 0xKEYID --wkd /path/to/webroot
```

### Key lifecycle

```bash
# Extend subkey expiration
mise run gpg:renew -- "Alice Smith" --expiration 2y

# Rotate to new subkeys (optionally revoke old)
mise run gpg:rotate -- "Alice Smith" --revoke-old

# List all managed identities
mise run gpg:list
```

| Scenario | Action |
|---|---|
| Subkeys expiring, no concerns | `gpg:renew` |
| Annual maintenance | `gpg:rotate` |
| Suspected compromise | `gpg:rotate --revoke-old` |
| Upgrading algorithm | `gpg:rotate --key-type ed25519` |

### Smart card management

```bash
mise run card:info         # OpenPGP card status
mise run yubikey:info      # YubiKey-specific details (via ykman)
mise run card:reset        # Factory reset (DESTRUCTIVE)
```

## Daily usage

After provisioning, your smart card works for signing, encryption, and SSH:

```bash
# Sign
echo "test" | gpg --armor --clearsign
git commit -S -m "signed commit"

# Encrypt/decrypt
gpg --recipient alice@example.com --encrypt doc.txt
gpg --decrypt doc.txt.gpg

# SSH via gpg-agent
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
ssh user@host
```

## Task reference

| Namespace | Task | Description |
|---|---|---|
| `setup:` | `init` | Initialize directories and config files |
| | `install-deps` | Install system packages (cross-platform) |
| `gpg:` | `create` | Create identity with certify key + subkeys |
| | `backup` | Backup keys to data directory |
| | `restore` | Restore keys from backup |
| | `list` | List managed identities and status |
| | `renew` | Extend subkey expiration |
| | `rotate` | Generate new subkeys (full rotation) |
| | `publish` | Publish public key (keyserver/GitHub/WKD/file) |
| `card:` | `info` | Show OpenPGP smart card status |
| | `setup` | Configure PINs, KDF, cardholder metadata |
| | `provision` | Transfer subkeys to smart card |
| | `reset` | Factory reset OpenPGP applet |
| `yubikey:` | `info` | YubiKey details via ykman |
| | `setup-touch` | Configure touch policy |
| `tails:` | `install-deps` | Install packages (must run each boot) |
| | `setup-persistence` | Wire XDG dirs into Tails persistent storage |

## Project structure

```
src/
  lib/           # Shared libraries (platform.sh, common.sh)
  config/        # GPG config templates (gpg.conf, dirmngr.conf)
  mise-tasks/    # All task scripts (gpg/, card/, yubikey/, tails/, setup/)
  mise.toml      # Distribution mise config
  install-mise.sh
test/
  unit/          # Bats unit tests
  integration/   # Bats integration tests (GPG lifecycle, card mocks)
  ci/            # Tails QEMU test infrastructure
```

## Platform support

| Feature | Tails | Linux | macOS |
|---|---|---|---|
| GPG key management | Yes | Yes | Yes |
| Smart card ops | Yes | Yes | Yes |
| Ephemeral GNUPGHOME | /dev/shm (tmpfs) | /dev/shm or XDG_RUNTIME_DIR | RAM disk |
| Package install | `tails:install-deps` | `setup:install-deps` | `setup:install-deps` (Homebrew) |
| Tor proxy | Built-in | Optional (`YK_GPG_TOR_PROXY`) | Optional |

## YubiKey compatibility

| Feature | YubiKey 4 | YubiKey 5 (fw 5.2.3+) |
|---|---|---|
| RSA 4096 | Yes | Yes |
| ed25519 / cv25519 | No | Yes |
| Touch policy | No | Yes |
| KDF (PIN hashing) | No | Yes |

Key type is auto-detected from the connected YubiKey.

## Security considerations

- **Disable networking** before generating or handling key material
- **Certify key passphrase** is the most critical secret — store it in a physically secure location, separate from the YubiKey
- **PINs** protect smart card operations — record them separately from the card
- Ephemeral GNUPGHOME on tmpfs ensures key material never touches persistent disk during generation
- **Batch mode**: `--passphrase` flag values are visible in process listings. Use CI secrets or a trusted environment. Interactive mode (default) is not affected
- On Tails, persistent storage is encrypted at rest

## Troubleshooting

### "No YubiKey detected"
- Ensure the YubiKey is inserted
- `sudo systemctl start pcscd`
- `ykman info` to verify connectivity

### "gpg: selecting card failed"
- `gpgconf --kill gpg-agent`
- `gpgconf --kill scdaemon`

### "Operation not supported by device"
- Your YubiKey may not support the requested algorithm
- Use `--key-type rsa4096` for YubiKey 4

### "gpg: signing failed: No secret key"
- Ensure the correct YubiKey is inserted
- `gpg-connect-agent "scd serialno" "learn --force" /bye`

## License

MIT
