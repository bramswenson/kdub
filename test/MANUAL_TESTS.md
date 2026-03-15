# Manual Test Checklist

Tests requiring physical YubiKey hardware or full Tails desktop.

## YubiKey Tests (any platform)

Requires: YubiKey 4 or 5, `ykman` installed

- [ ] `mise run yubikey:info` — shows device type, serial, firmware
- [ ] `mise run card:info` — shows OpenPGP card status
- [ ] `mise run card:setup --factory-pins` — changes PINs, enables KDF (YubiKey 5)
- [ ] `mise run gpg:create -- "Test <test@example.com>" --key-type ed25519 --expiration 1y`
- [ ] `mise run card:provision -- <keyid> --admin-pin <pin> --passphrase <pass>`
- [ ] `gpg -K` shows `ssb>` stubs after provisioning
- [ ] `mise run yubikey:setup-touch --admin-pin <pin>` — sets touch policy (YubiKey 5 only)
- [ ] Sign/encrypt/authenticate operations require touch
- [ ] `mise run card:reset --force` — factory resets the OpenPGP applet

## Tails Tests (boot into Tails)

Requires: Tails USB, YubiKey

- [ ] `bash src/install-mise.sh` — installs mise to `~/Persistent/bin` via Tor
- [ ] `mise run tails:install-deps` — installs gnupg, scdaemon, pcscd, ykman, jq
- [ ] `mise run setup:init` — creates XDG dirs, generates platform configs
- [ ] `mise run tails:setup-persistence` — symlinks data dir to Persistent
- [ ] Full key lifecycle: create → backup → provision → verify
- [ ] Reboot Tails and verify: persistence symlinks survive, deps need reinstall
