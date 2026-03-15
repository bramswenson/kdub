#!/usr/bin/env bash
# Smoke test: boot Tails in QEMU, connect via remote shell, verify it's Tails.
#
# Uses direct kernel boot to inject autotest_never_use_this_option into
# the kernel command line (avoids ISO modification). The remote shell
# daemon starts before GDM, so we don't need to dismiss the Greeter.
#
# Requires: qemu-system-x86_64, xorriso (to extract kernel/initrd from ISO)
# Optional: /dev/kvm for hardware acceleration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TAILS_VERSION="$(cat "$PROJECT_ROOT/.tails-version" | tr -d '[:space:]')"
TAILS_ISO="${TAILS_ISO:-/tmp/tails.iso}"
TAILS_EXTRACT_DIR="/tmp/tails-kernel"
REMOTE_SHELL_SOCK="/tmp/tails-remote-shell.sock"
REMOTE_SHELL="$SCRIPT_DIR/tails-remote-shell.py"
QEMU_PID_FILE="/tmp/tails-qemu.pid"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
CHUTNEY_DIR="${CHUTNEY_DIR:-/tmp/chutney}"
CHUTNEY_TORRC="/tmp/chutney-torrc.conf"
CHUTNEY_READY=false

info()    { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# shellcheck disable=SC2329
cleanup() {
    info "Cleaning up..."
    if [[ -d "/tmp/chutney-data/nodes" ]]; then
        CHUTNEY_DATA_DIR="/tmp/chutney-data" "$CHUTNEY_DIR/chutney" stop 2>/dev/null || true
    fi
    if [[ -f "$QEMU_PID_FILE" ]]; then
        local pid
        pid="$(cat "$QEMU_PID_FILE")"
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rm -f "$QEMU_PID_FILE"
    fi
    rm -f "$REMOTE_SHELL_SOCK"
    rm -rf "$TAILS_EXTRACT_DIR"
}
trap cleanup EXIT

# --- Step 1: Download Tails ISO (if not cached) and verify GPG signature ---
TAILS_BASE_URL="https://download.tails.net/tails/stable/tails-amd64-${TAILS_VERSION}"
TAILS_SIGNING_KEY="A490D0F4D311A4153E2BB7CADBB802B258ACD84F"
TAILS_SIG="${TAILS_ISO}.sig"

if [[ ! -f "$TAILS_ISO" ]]; then
    info "Downloading Tails ${TAILS_VERSION} ISO..."
    curl -fSL -o "$TAILS_ISO" "${TAILS_BASE_URL}/tails-amd64-${TAILS_VERSION}.iso"
    success "Downloaded Tails ISO ($(du -h "$TAILS_ISO" | cut -f1))"
else
    info "Using cached Tails ISO: $TAILS_ISO ($(du -h "$TAILS_ISO" | cut -f1))"
fi

# Always verify signature (catches corrupted downloads and poisoned caches).
# We import only the official Tails signing key into an isolated keyring,
# so "Good signature" guarantees the ISO was signed by a Tails key.
info "Verifying Tails ISO GPG signature..."
TAILS_VERIFY_HOME="$(mktemp -d)"
curl -fSL -o "$TAILS_SIG" "${TAILS_BASE_URL}/tails-amd64-${TAILS_VERSION}.iso.sig"
curl -fSL -o "$TAILS_VERIFY_HOME/tails-signing.key" "https://tails.net/tails-signing.key"
gpg --homedir "$TAILS_VERIFY_HOME" --no-default-keyring --keyring "$TAILS_VERIFY_HOME/tails.kbx" \
    --import "$TAILS_VERIFY_HOME/tails-signing.key" 2>/dev/null
# Verify that the imported key is the expected Tails signing key
if ! gpg --homedir "$TAILS_VERIFY_HOME" --no-default-keyring --keyring "$TAILS_VERIFY_HOME/tails.kbx" \
    --with-colons --list-keys 2>/dev/null | grep -q "^fpr:::::::::${TAILS_SIGNING_KEY}:"; then
    error "Imported key does not match expected Tails signing key ${TAILS_SIGNING_KEY}"
    rm -rf "$TAILS_VERIFY_HOME"
    exit 1
fi
VERIFY_OUTPUT="$(gpg --homedir "$TAILS_VERIFY_HOME" --no-default-keyring --keyring "$TAILS_VERIFY_HOME/tails.kbx" \
    --verify "$TAILS_SIG" "$TAILS_ISO" 2>&1)" || true
if echo "$VERIFY_OUTPUT" | grep -q "Good signature"; then
    success "Tails ISO signature verified (key: ${TAILS_SIGNING_KEY})"
else
    error "Tails ISO signature verification FAILED — refusing to boot"
    error "$VERIFY_OUTPUT"
    rm -f "$TAILS_ISO" "$TAILS_SIG"
    rm -rf "$TAILS_VERIFY_HOME"
    exit 1
fi
rm -f "$TAILS_SIG"
rm -rf "$TAILS_VERIFY_HOME"

# --- Step 2: Extract kernel + initrd from ISO ---
info "Extracting kernel and initrd from ISO..."
mkdir -p "$TAILS_EXTRACT_DIR"
xorriso -osirrox on -indev "$TAILS_ISO" \
    -extract /live/vmlinuz "$TAILS_EXTRACT_DIR/vmlinuz" \
    -extract /live/initrd.img "$TAILS_EXTRACT_DIR/initrd.img" \
    2>/dev/null
success "Extracted vmlinuz ($(du -h "$TAILS_EXTRACT_DIR/vmlinuz" | cut -f1)) and initrd.img ($(du -h "$TAILS_EXTRACT_DIR/initrd.img" | cut -f1))"

# --- Step 2.5: Set up Chutney simulated Tor network ---
# Tails' own test suite uses Chutney (a simulated Tor network on the host)
# rather than the real Tor network. We do the same so the VM can bootstrap
# Tor and run apt-get through Tor's SOCKS proxy.
if command -v tor &>/dev/null; then
    CHUTNEY_COMMIT="$(grep -v '^#' "$PROJECT_ROOT/.chutney-commit" | tr -d '[:space:]')"
    if [[ ! -f "$CHUTNEY_DIR/chutney" ]] || ! (cd "$CHUTNEY_DIR" && git rev-parse HEAD 2>/dev/null | grep -q "$CHUTNEY_COMMIT"); then
        info "Cloning Chutney (pinned: ${CHUTNEY_COMMIT:0:12})..."
        rm -rf "$CHUTNEY_DIR"
        git clone https://gitlab.torproject.org/tpo/core/chutney.git "$CHUTNEY_DIR"
        (cd "$CHUTNEY_DIR" && git checkout "$CHUTNEY_COMMIT")
    else
        info "Using cached Chutney at pinned commit ${CHUTNEY_COMMIT:0:12}"
    fi
    # Always ensure Python deps are installed (cache only preserves the git clone)
    if ! python3 -c "import chutney" 2>/dev/null; then
        info "Installing Chutney Python dependencies..."
        pip install "$CHUTNEY_DIR" 2>&1 | tail -3
    fi
    CHUTNEY_DATA="/tmp/chutney-data"
    export CHUTNEY_DATA_DIR="$CHUTNEY_DATA"
    # Add 10.0.2.2 (SLIRP gateway) as loopback alias. Chutney nodes bind to
    # and advertise this address. The VM reaches it via SLIRP → host loopback.
    # CI has passwordless sudo; locally: sudo ip addr add 10.0.2.2/32 dev lo
    LOOPBACK_OK=true
    if ! ip addr show lo 2>/dev/null | grep -q 10.0.2.2; then
        if ! sudo -n ip addr add 10.0.2.2/32 dev lo 2>/dev/null; then
            warn "Cannot add 10.0.2.2 to loopback (run: sudo ip addr add 10.0.2.2/32 dev lo)"
            LOOPBACK_OK=false
        fi
    fi

    if [[ "$LOOPBACK_OK" == "true" ]]; then
    info "Starting Chutney simulated Tor network..."
    export CHUTNEY_TOR_SANDBOX=0
    # Init with 10.0.2.2 so DirAuthority/Address use this IP consistently.
    # Then rewrite ORPort/DirPort/SocksPort/ControlPort bind to 0.0.0.0 so
    # both direct (10.0.2.2) and SLIRP-forwarded (127.0.0.1) connections work.
    "$CHUTNEY_DIR/chutney" --data-dir "$CHUTNEY_DATA" init --net basic-min --listen-address 10.0.2.2
    CHUTNEY_DATA_DIR="$CHUTNEY_DATA" "$CHUTNEY_DIR/chutney" --data-dir "$CHUTNEY_DATA" configure
    for f in "$CHUTNEY_DATA"/nodes/*/torrc; do
        sed -i 's/^OrPort 10\.0\.2\.2:/OrPort 0.0.0.0:/' "$f"
        sed -i 's/^DirPort 10\.0\.2\.2:/DirPort 0.0.0.0:/' "$f"
        sed -i 's/^SocksPort 10\.0\.2\.2:/SocksPort 0.0.0.0:/' "$f"
        sed -i 's/^ControlPort 10\.0\.2\.2:/ControlPort 0.0.0.0:/' "$f"
    done
    if CHUTNEY_DATA_DIR="$CHUTNEY_DATA" "$CHUTNEY_DIR/chutney" --data-dir "$CHUTNEY_DATA" start && \
       CHUTNEY_DATA_DIR="$CHUTNEY_DATA" "$CHUTNEY_DIR/chutney" --data-dir "$CHUTNEY_DATA" wait_for_bootstrap; then
        {
            echo "TestingTorNetwork 1"
            echo "AssumeReachable 1"
            echo "PathsNeededToBuildCircuits 0.67"
            grep -rhE '^(Alternate)?(Dir|Bridge)Authority' "$CHUTNEY_DATA/nodes/"*/torrc \
                | sort -u
        } > "$CHUTNEY_TORRC"
        CHUTNEY_READY=true
        success "Chutney Tor network ready"
        cat "$CHUTNEY_TORRC"
    else
        warn "Chutney failed to bootstrap"
        # Print first authority log for debugging
        cat "$CHUTNEY_DATA"/nodes/000a/notice.log 2>/dev/null | tail -20 || true
    fi
    fi  # loopback alias check
else
    info "tor binary not found — Chutney will not be started (lifecycle tests will be skipped)"
fi

# --- Step 3: Start QEMU ---
rm -f "$REMOTE_SHELL_SOCK"

QEMU_ARGS=(
    -m 4096
    -smp 2
    -display none
    -no-reboot
    -cdrom "$TAILS_ISO"
    -kernel "$TAILS_EXTRACT_DIR/vmlinuz"
    -initrd "$TAILS_EXTRACT_DIR/initrd.img"
    -append "boot=live config autotest_never_use_this_option nopersistence noprompt timezone=Etc/UTC block.events_dfl_poll_msecs=10 quiet"
    -device virtio-serial
    -chardev "socket,path=${REMOTE_SHELL_SOCK},server=on,wait=off,id=rs0"
    -device "virtserialport,chardev=rs0,name=org.tails.remote_shell.0"
    -serial mon:stdio
    -netdev "user,id=net0"
    -device "virtio-net-pci,netdev=net0"
)

# Use KVM if available
if [[ -w /dev/kvm ]]; then
    info "KVM available — using hardware acceleration"
    QEMU_ARGS+=(-enable-kvm -cpu host)
else
    info "KVM not available — using software emulation (slow)"
fi

info "Starting QEMU (Tails ${TAILS_VERSION})..."
qemu-system-x86_64 "${QEMU_ARGS[@]}" &
QEMU_PID=$!
echo "$QEMU_PID" > "$QEMU_PID_FILE"
info "QEMU started (PID: $QEMU_PID)"

# --- Step 4: Wait for remote shell ---
info "Waiting for Tails remote shell (timeout: ${BOOT_TIMEOUT}s)..."
python3 "$REMOTE_SHELL" "$REMOTE_SHELL_SOCK" wait "$BOOT_TIMEOUT"

# --- Step 5: Transfer project into VM ---
info "Creating project tarball..."
SRC_TARBALL="/tmp/yk-gpg-src.tar.gz"
tar -czf "$SRC_TARBALL" -C "$PROJECT_ROOT" \
    src/lib src/config src/mise-tasks src/mise.toml src/install-mise.sh
info "Tarball: $(du -h "$SRC_TARBALL" | cut -f1)"

info "Uploading project to VM..."
python3 "$REMOTE_SHELL" "$REMOTE_SHELL_SOCK" write-file /tmp/yk-gpg-src.tar.gz "$SRC_TARBALL"

# --- Step 6: Tests ---
FAILURES=0

# Helper: run command as root inside VM
rexec() {
    python3 "$REMOTE_SHELL" "$REMOTE_SHELL_SOCK" exec "$1"
}

run_test() {
    local name="$1"
    local cmd="$2"
    local expect="$3"
    local output

    info "Test: $name"
    if output="$(rexec "$cmd" 2>&1)"; then
        if echo "$output" | grep -q "$expect"; then
            success "  PASS — output contains '$expect'"
        else
            error "  FAIL — output does not contain '$expect'"
            error "  Output: $output"
            FAILURES=$((FAILURES + 1))
        fi
    else
        error "  FAIL — command exited with error"
        error "  Output: $output"
        FAILURES=$((FAILURES + 1))
    fi
}

run_test_capture() {
    local name="$1" cmd="$2" var_name="$3"
    local output
    info "Test: $name"
    if output="$(rexec "$cmd" 2>&1)"; then
        output="${output%"${output##*[![:space:]]}"}"
        printf -v "$var_name" '%s' "$output"
        success "  PASS — captured ${var_name}=${output}"
    else
        error "  FAIL — command exited with error"
        error "  Output: $output"
        FAILURES=$((FAILURES + 1))
    fi
}

run_test_match() {
    local name="$1" cmd="$2" expected="$3"
    local output
    info "Test: $name"
    if output="$(rexec "$cmd" 2>&1)"; then
        output="${output%"${output##*[![:space:]]}"}"
        if [[ "$output" == *"$expected"* ]]; then
            success "  PASS — output contains expected value"
        else
            error "  FAIL — expected to contain '$expected', got '$output'"
            FAILURES=$((FAILURES + 1))
        fi
    else
        error "  FAIL — command exited with error"
        error "  Output: $output"
        FAILURES=$((FAILURES + 1))
    fi
}

info "Extracting project in VM..."
rexec "mkdir -p /tmp/yk-gpg && tar -xzf /tmp/yk-gpg-src.tar.gz -C /tmp/yk-gpg"
success "Project uploaded to /tmp/yk-gpg"

# Lifecycle test shared variables
LIFECYCLE_ENV="GNUPGHOME=/dev/shm/yk-gpg-lifecycle-test MISE_PROJECT_ROOT=/tmp/yk-gpg/src BATCH_MODE=true HOME=/home/amnesia"
LIFECYCLE_PASS="tails-test-passphrase-2026"
LIFECYCLE_FP=""
LIFECYCLE_KEYID=""
DEPS_INSTALLED=false

# --- 6a: Basic environment ---
run_test \
    "os-release contains Tails" \
    "cat /etc/os-release" \
    "Tails"

run_test \
    "running as root" \
    "id -u" \
    "0"

run_test \
    "amnesia user exists" \
    "id amnesia" \
    "amnesia"

# --- 6b: Platform detection ---
run_test \
    "detect_platform returns tails" \
    "bash -c '. /tmp/yk-gpg/src/lib/platform.sh && detect_platform'" \
    "tails"

run_test \
    "is_tails returns true" \
    "bash -c '. /tmp/yk-gpg/src/lib/platform.sh && is_tails && echo YES'" \
    "YES"

run_test \
    "is_linux returns true on Tails" \
    "bash -c '. /tmp/yk-gpg/src/lib/platform.sh && is_linux && echo YES'" \
    "YES"

# --- 6c: Key Tails packages pre-installed ---
run_test \
    "gpg is available" \
    "command -v gpg" \
    "gpg"

run_test \
    "gnupg version is 2.4+" \
    "gpg --version | head -1" \
    "2\."

# --- 6d: setup:init on Tails ---
run_test \
    "setup:init creates XDG dirs" \
    "export MISE_PROJECT_ROOT=/tmp/yk-gpg/src BATCH_MODE=true HOME=/home/amnesia && bash /tmp/yk-gpg/src/mise-tasks/setup/init && test -f /home/amnesia/.config/yk-gpg/gpg.conf && echo INIT_OK" \
    "INIT_OK"

# --- 6e: tails:setup-persistence (partial — no persistent volume) ---
# Tails persistence is not available in our QEMU setup, so we test
# the non-persistence code path (dotfiles warning).
run_test \
    "tails:setup-persistence creates data dir" \
    "export MISE_PROJECT_ROOT=/tmp/yk-gpg/src BATCH_MODE=true HOME=/home/amnesia && mkdir -p /home/amnesia/Persistent && bash /tmp/yk-gpg/src/mise-tasks/tails/setup-persistence && test -d /home/amnesia/Persistent/yk-gpg/identities && echo PERSIST_OK" \
    "PERSIST_OK"

# --- 6f: Tails-specific config verification ---
run_test \
    "gpg-agent.conf has Tails pinentry" \
    "grep -q pinentry-gnome3 /home/amnesia/.config/yk-gpg/gpg-agent.conf && echo PINENTRY_OK" \
    "PINENTRY_OK"

run_test \
    "scdaemon.conf has disable-ccid, no macOS PCSC" \
    "grep -q disable-ccid /home/amnesia/.config/yk-gpg/scdaemon.conf && ! grep -q PCSC.framework /home/amnesia/.config/yk-gpg/scdaemon.conf && echo SCDAEMON_OK" \
    "SCDAEMON_OK"

run_test \
    "gpg.conf has hardened cipher preferences" \
    "grep -q 'personal-cipher-preferences' /home/amnesia/.config/yk-gpg/gpg.conf && echo GPG_CONF_OK" \
    "GPG_CONF_OK"

# --- 6g: Ephemeral GNUPGHOME on Tails ---
run_test \
    "setup_temp_gnupghome uses tmpfs on Tails" \
    "bash -c '. /tmp/yk-gpg/src/lib/common.sh && setup_temp_gnupghome && (echo \$GNUPGHOME | grep -qE \"^(/dev/shm|/run/user/)\" && echo TMPFS_OK) && rm -rf \$GNUPGHOME'" \
    "TMPFS_OK"

# --- 6h: tails:install-deps ---
# In autotest mode, Tails doesn't auto-configure networking (Greeter not dismissed).
# We use Chutney (simulated Tor on the host) + SLIRP networking.
if [[ "$CHUTNEY_READY" == "true" ]]; then
    # Configure SLIRP networking in the VM.
    # Tails blocklists ALL network drivers in /etc/modprobe.d/all-net-blocklist.conf
    # to prevent hardware fingerprinting. We must remove the blocklist entries for
    # virtio_net (and its dependency net_failover), load the module, then assign
    # a static IP since dhclient is not available in Tails.
    info "Configuring VM network interface..."
    rexec "sed -i '/virtio_net/d; /net_failover/d' /etc/modprobe.d/all-net-blocklist.conf && modprobe virtio_net" 2>/dev/null || true
    sleep 1
    rexec "ip link set eth0 up && ip addr add 10.0.2.15/24 dev eth0 && ip route add default via 10.0.2.2 dev eth0" 2>/dev/null || true

    NIC_UP=false
    if rexec "ping -c 1 -W 2 10.0.2.2" &>/dev/null; then
        NIC_UP=true
        success "  VM network up — can reach host via SLIRP"
    else
        warn "  VM cannot reach host — NIC setup failed"
        rexec "ip -br addr 2>/dev/null; ip route 2>/dev/null" 2>/dev/null || true
    fi

    if [[ "$NIC_UP" != "true" ]]; then
        warn "Skipping Tor/lifecycle tests — no network"
    fi

    # Configure Tor to use Chutney (simulated Tor network on host)
    if [[ "$NIC_UP" == "true" ]]; then
    info "Configuring Tor to use Chutney..."
    python3 "$REMOTE_SHELL" "$REMOTE_SHELL_SOCK" write-file /tmp/chutney-torrc.conf "$CHUTNEY_TORRC"
    rexec "sed -i '/DisableNetwork/d' /etc/tor/torrc /usr/share/tor/tor-service-defaults-torrc 2>/dev/null; cat /tmp/chutney-torrc.conf >> /etc/tor/torrc; systemctl restart tor@default 2>/dev/null" 2>/dev/null || true

    # Poll for Tor bootstrap (should be fast with local Chutney network)
    info "Waiting for Tor to bootstrap via Chutney (up to 120s)..."
    TOR_BOOTSTRAPPED=false
    for tor_attempt in $(seq 1 24); do
        if tor_status="$(rexec "journalctl -u tor@default --no-pager -n 50 2>/dev/null | grep -o 'Bootstrapped [0-9]*%' | tail -1" 2>/dev/null)"; then
            if echo "$tor_status" | grep -q "Bootstrapped 100%"; then
                TOR_BOOTSTRAPPED=true
                break
            fi
            [[ -n "$tor_status" ]] && info "  Tor: $tor_status (attempt $tor_attempt/24)"
        fi
        sleep 5
    done

    if [[ "$TOR_BOOTSTRAPPED" == "true" ]]; then
        success "Tor bootstrapped via Chutney"

        run_test \
            "tails:install-deps installs packages" \
            "export MISE_PROJECT_ROOT=/tmp/yk-gpg/src BATCH_MODE=true HOME=/home/amnesia && bash /tmp/yk-gpg/src/mise-tasks/tails/install-deps" \
            "Tails dependencies installed"

        run_test \
            "jq and ykman available after install-deps" \
            "command -v jq && command -v ykman && echo DEPS_AVAIL" \
            "DEPS_AVAIL"

        if rexec "command -v jq" &>/dev/null; then
            DEPS_INSTALLED=true
        else
            warn "jq not available after install-deps — skipping lifecycle tests (6i-6q)"
        fi
    else
        warn "Tor did not bootstrap via Chutney — skipping lifecycle tests (6i-6q)"
        rexec "journalctl -u tor@default --no-pager -n 30 2>/dev/null || true" 2>/dev/null || true
    fi
    fi  # NIC_UP
else
    warn "Chutney not available — skipping tails:install-deps and lifecycle tests (6i-6q)"
fi

# --- Lifecycle tests (6i-6q) — require deps installed ---
if [[ "$DEPS_INSTALLED" == "true" ]]; then

# --- 6i: Lifecycle setup ---
run_test \
    "create lifecycle GNUPGHOME with loopback pinentry" \
    "mkdir -p /dev/shm/yk-gpg-lifecycle-test && chmod 700 /dev/shm/yk-gpg-lifecycle-test && cp /tmp/yk-gpg/src/config/gpg.conf /dev/shm/yk-gpg-lifecycle-test/gpg.conf && printf 'allow-loopback-pinentry\npinentry-program /bin/false\nenable-ssh-support\ndefault-cache-ttl 60\nmax-cache-ttl 120\n' > /dev/shm/yk-gpg-lifecycle-test/gpg-agent.conf && echo GNUPGHOME_OK" \
    "GNUPGHOME_OK"

run_test \
    "persistence dirs and symlink ready" \
    "test -d /home/amnesia/Persistent/yk-gpg/identities && test -d /home/amnesia/Persistent/yk-gpg/backups && test -L /home/amnesia/.local/share/yk-gpg && echo PERSIST_DIRS_OK" \
    "PERSIST_DIRS_OK"

# --- 6j: Key creation ---
run_test \
    "gpg:create creates certify key and subkeys" \
    "export $LIFECYCLE_ENV usage_identity='Tails Test <tails@yk-gpg.test>' usage_key_type=ed25519 usage_passphrase='$LIFECYCLE_PASS' && bash /tmp/yk-gpg/src/mise-tasks/gpg/create" \
    "Certify key created"

run_test_capture \
    "capture key fingerprint" \
    "GNUPGHOME=/dev/shm/yk-gpg-lifecycle-test gpg --with-colons --list-keys 'Tails Test' | grep '^fpr:' | head -1 | cut -d: -f10" \
    LIFECYCLE_FP

LIFECYCLE_KEYID="0x${LIFECYCLE_FP: -16}"
info "Lifecycle key: FP=$LIFECYCLE_FP KEYID=$LIFECYCLE_KEYID"

# --- 6k: Key backup ---
run_test \
    "gpg:backup exports keys" \
    "export $LIFECYCLE_ENV usage_keyid='$LIFECYCLE_KEYID' usage_passphrase='$LIFECYCLE_PASS' && bash /tmp/yk-gpg/src/mise-tasks/gpg/backup" \
    "Backup complete"

run_test \
    "all 5 backup files exist and certify-key has PGP data" \
    "test -f /home/amnesia/Persistent/yk-gpg/backups/$LIFECYCLE_FP/certify-key.asc && test -f /home/amnesia/Persistent/yk-gpg/backups/$LIFECYCLE_FP/subkeys.asc && test -f /home/amnesia/Persistent/yk-gpg/backups/$LIFECYCLE_FP/public-key.asc && test -f /home/amnesia/Persistent/yk-gpg/backups/$LIFECYCLE_FP/ownertrust.txt && test -f /home/amnesia/Persistent/yk-gpg/backups/$LIFECYCLE_FP/revocation-cert.asc && grep -q 'BEGIN PGP' /home/amnesia/Persistent/yk-gpg/backups/$LIFECYCLE_FP/certify-key.asc && echo BACKUP_FILES_OK" \
    "BACKUP_FILES_OK"

# --- 6l: Key listing ---
run_test \
    "gpg:list shows created identity" \
    "export $LIFECYCLE_ENV && bash /tmp/yk-gpg/src/mise-tasks/gpg/list" \
    "Tails Test"

# --- 6m: Simulated reboot ---
run_test \
    "destroy ephemeral GNUPGHOME (simulated reboot)" \
    "GNUPGHOME=/dev/shm/yk-gpg-lifecycle-test gpgconf --kill all 2>/dev/null || true; rm -rf /dev/shm/yk-gpg-lifecycle-test && ! test -d /dev/shm/yk-gpg-lifecycle-test && echo DESTROYED" \
    "DESTROYED"

run_test \
    "persistent backup and metadata survive reboot" \
    "test -f /home/amnesia/Persistent/yk-gpg/backups/$LIFECYCLE_FP/certify-key.asc && test -f /home/amnesia/Persistent/yk-gpg/identities/${LIFECYCLE_FP}.json && echo PERSIST_SURVIVED" \
    "PERSIST_SURVIVED"

run_test \
    "recreate GNUPGHOME (post-reboot setup)" \
    "mkdir -p /dev/shm/yk-gpg-lifecycle-test && chmod 700 /dev/shm/yk-gpg-lifecycle-test && cp /tmp/yk-gpg/src/config/gpg.conf /dev/shm/yk-gpg-lifecycle-test/gpg.conf && printf 'allow-loopback-pinentry\npinentry-program /bin/false\nenable-ssh-support\ndefault-cache-ttl 60\nmax-cache-ttl 120\n' > /dev/shm/yk-gpg-lifecycle-test/gpg-agent.conf && echo GNUPGHOME_RECREATED" \
    "GNUPGHOME_RECREATED"

# --- 6n: Key restore ---
run_test \
    "gpg:restore restores keys from backup" \
    "export $LIFECYCLE_ENV usage_fingerprint='$LIFECYCLE_FP' usage_passphrase='$LIFECYCLE_PASS' && bash /tmp/yk-gpg/src/mise-tasks/gpg/restore" \
    "Keys restored"

run_test_match \
    "restored key fingerprint matches original" \
    "GNUPGHOME=/dev/shm/yk-gpg-lifecycle-test gpg --with-colons --list-keys 'Tails Test' | grep '^fpr:' | head -1 | cut -d: -f10" \
    "$LIFECYCLE_FP"

# --- 6o: Post-restore operations ---
run_test \
    "gpg:renew extends subkey expiration" \
    "export $LIFECYCLE_ENV usage_identity='Tails Test' usage_expiration=3y usage_passphrase='$LIFECYCLE_PASS' && bash /tmp/yk-gpg/src/mise-tasks/gpg/renew" \
    "extended"

run_test \
    "gpg:publish exports public key to file" \
    "export $LIFECYCLE_ENV usage_keyid='$LIFECYCLE_KEYID' usage_file=/tmp/pubkey.asc && bash /tmp/yk-gpg/src/mise-tasks/gpg/publish && grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /tmp/pubkey.asc && echo PUBKEY_OK" \
    "PUBKEY_OK"

run_test \
    "gpg:rotate creates new subkeys" \
    "export $LIFECYCLE_ENV usage_identity='Tails Test' usage_key_type=ed25519 usage_passphrase='$LIFECYCLE_PASS' usage_revoke_old=false && bash /tmp/yk-gpg/src/mise-tasks/gpg/rotate" \
    "New subkeys created"

# --- 6p: Metadata integrity ---
run_test \
    "metadata JSON has lifecycle fields" \
    "jq -e '.identity and .fingerprint and .created and .backed_up' /home/amnesia/Persistent/yk-gpg/identities/${LIFECYCLE_FP}.json >/dev/null && echo METADATA_OK" \
    "METADATA_OK"

# --- 6q: Library functions on Tails ---
run_test_match \
    "generate_passphrase 24 produces 24-char output" \
    "bash -c '. /tmp/yk-gpg/src/lib/common.sh && p=\$(generate_passphrase 24) && echo \${#p}'" \
    "24"

run_test_match \
    "yk_gpg_data_dir returns XDG path" \
    "bash -c 'HOME=/home/amnesia . /tmp/yk-gpg/src/lib/platform.sh && yk_gpg_data_dir'" \
    ".local/share/yk-gpg"

else
    warn "Skipping lifecycle tests (6i-6q) — deps not installed"
fi

# --- Step 7: Report ---
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    success "All Tails tests passed ($((FAILURES + 0)) failures)"
    exit 0
else
    error "$FAILURES test(s) failed"
    exit 1
fi
