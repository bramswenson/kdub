# Tails command help text

Verify help text is available for all tails subcommands.

## tails subcommand help

```console
$ kdub tails --help
Tails USB creation and setup

Usage: kdub tails [OPTIONS] <COMMAND>

Commands:
  download  Download and verify the latest Tails ISO image
  flash     Write a verified Tails image to a USB device
  persist   Create encrypted persistent storage on a Tails USB
  help      Print this message or the help of the given subcommand(s)

Options:
...

```

## tails download help

```console
$ kdub tails download --help
Download and verify the latest Tails ISO image.
...
      --force
          Re-download even if cached
...

```

## tails flash help

```console
$ kdub tails flash --help
Write a verified Tails image to a USB device
...
      --device <DEVICE>      Use this device (skips interactive prompt)
...
      --yes                  Skip typing device path confirmation (scripting)
...

```

## tails persist help

```console
$ kdub tails persist --help
Create encrypted persistent storage on a Tails USB
...
      --passphrase <PASSPHRASE>  LUKS passphrase (visible in process listings)
      --passphrase-stdin         Read passphrase from stdin
...
      --device <DEVICE>          Target USB device (must already have Tails flashed)
...
      --skip-preseed             Skip kdub config pre-seeding
...

```
