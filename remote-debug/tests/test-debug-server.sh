#!/usr/bin/env bash
set -u

# Test suite for debug-server.sh
#
# Uses temporary XDG_DATA_HOME / XDG_STATE_HOME and a FULLY ISOLATED test
# PATH so the host machine's real package managers, sudo, powershell.exe, and
# lldb-server can never be discovered by accident.
#
# Isolation strategy: the debug-server.sh subprocess runs with PATH pointing
# ONLY at the sandbox bin directory. That directory contains:
#   * fake tools for the scenario under test (pacman / apt-get / lldb-server /
#     powershell.exe / wslpath)
#   * symlinks to a small set of safe system utilities the script itself needs
#     (bash, grep, sed, head, tr, readlink, realpath, date, mkdir, rm, sleep,
#     kill, nohup, id, tail, dirname)
#
# No host directory is ever on the test PATH, so a fake-apt test can never see
# the host's pacman and vice versa, and no real package manager can ever run.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEBUG_SERVER="$SCRIPT_DIR/../debug-server.sh"
DEBUG_PS1="$SCRIPT_DIR/../debug-server.ps1"
WINDOWS_OWNERSHIP_TEST="$SCRIPT_DIR/test-windows-ownership.ps1"
HARNESS_BASH="$(command -v bash)"

PASS=0
FAIL=0
FAILED_TESTS=""

# All fake PIDs we spawn, plus every sandbox bin dir, so cleanup never leaks.
ALL_PIDS=()
ALL_BINS=()

say()   { printf '\n== %s\n' "$*"; }
ok()    { PASS=$((PASS+1)); printf '   ok   %s\n' "$*"; }
fail()  { FAIL=$((FAIL+1)); FAILED_TESTS="$FAILED_TESTS $*"; printf '   FAIL %s\n' "$*"; }

# Safe system utilities the script genuinely relies on, symlinked into the
# sandbox bin dir. This is a curated allow-list, not a copy of the OS.
SAFE_TOOLS=(bash grep sed head tr readlink realpath date mkdir rm sleep kill nohup id tail dirname)

# ---------------------------------------------------------------------------
# Test harness helpers
# ---------------------------------------------------------------------------
# Create a fresh sandbox with fake tooling.
new_sandbox() {
    TMP="$(mktemp -d)"
    XDG_DATA="$TMP/data"
    XDG_STATE="$TMP/state"
    BIN="$TMP/bin"
    mkdir -p "$XDG_DATA" "$XDG_STATE" "$BIN"
    ALL_BINS+=( "$BIN" )

    # Link the safe system utilities into the sandbox bin dir.
    local t src
    for t in "${SAFE_TOOLS[@]}"; do
        src="$(command -v "$t")"
        if [[ -z "$src" ]]; then
            printf '   ERROR: cannot locate required safe tool %s on host\n' "$t" >&2
            exit 1
        fi
        ln -s "$src" "$BIN/$t"
    done
}

track_pid() {
    local pid="$1"
    [[ -n "$pid" ]] && ALL_PIDS+=( "$pid" )
}

kill_tracked() {
    local pid
    for pid in "${ALL_PIDS[@]:-}"; do
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
    ALL_PIDS=()
}

destroy_sandbox() {
    kill_tracked
    rm -rf "$TMP"
    TMP=""
    XDG_DATA=""
    XDG_STATE=""
    BIN=""
}

# Catch any fake lldb-server still running under any test bin dir (even if the
# test failed before its PID was captured).
cleanup_all() {
    kill_tracked
    local bin p pid cmd
    for bin in "${ALL_BINS[@]:-}"; do
        for p in /proc/[0-9]*; do
            [[ -r "$p/cmdline" ]] || continue
            pid="${p#/proc/}"
            cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"
            case "$cmd" in
                *"$bin/lldb-server"*)
                    kill -9 "$pid" 2>/dev/null
                    ;;
            esac
        done
    done
}
trap cleanup_all EXIT INT TERM

# Write a fake executable.
make_fake() {
    local path="$1"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$path"
    chmod +x "$path"
}

# Build the standard fake toolset. `has_lldb` controls whether a fake
# lldb-server lands on PATH. `pm` selects which package manager fakes to
# install (pacman | apt | both | none).
install_fakes() {
    local has_lldb="$1" pm="$2"

    # A fake lldb-server that stays alive and accepts any args.
    make_fake "$BIN/lldb-server" '
while true; do sleep 1; done
'
    if [[ "$has_lldb" != "yes" ]]; then
        rm -f "$BIN/lldb-server"
    fi

    if [[ "$pm" == "pacman" || "$pm" == "both" ]]; then
        make_fake "$BIN/pacman" '
printf "PACMAN:%s\n" "$*" >> "$FAKE_LOG"
exit "${PACMAN_EXIT:-0}"
'
    fi

    if [[ "$pm" == "apt" || "$pm" == "both" ]]; then
        make_fake "$BIN/apt-get" '
printf "APTGET:%s\n" "$*" >> "$FAKE_LOG"
exit "${APTGET_EXIT:-0}"
'
    fi

    # Fake Windows interop so the real powershell.exe is never reached.
    # Honors FAKE_WIN_STATUS (running/stopped), FAKE_WIN_PROBE
    # (found/missing) and FAKE_WIN_INSTALL (ok/fail/missing) so tests can
    # simulate each Windows scenario.
    make_fake "$BIN/powershell.exe" '
printf "POWERSHELL:%s\n" "$*" >> "$FAKE_LOG"
case " $* " in
    *" -Action Status "*)
        if [ "${FAKE_WIN_STATUS:-stopped}" = "running" ]; then
            printf "status=running\npid=12345\nlisten=127.0.0.1:31338\n"
        else
            printf "status=stopped\n"
        fi
        ;;
    *" -Action Probe "*)
        if [ "${FAKE_WIN_PROBE:-missing}" = "found" ]; then
            printf "available=true\npath=Z:\\\\fake\\\\dbgsrv.exe\n"
        else
            printf "available=false\n"
        fi
        ;;
    *" -Action Install "*)
        case "${FAKE_WIN_INSTALL:-ok}" in
            ok)
                printf "installed=true\npath=Z:\\\\Program Files (x86)\\\\Windows Kits\\\\10\\\\Debuggers\\\\x64\\\\dbgsrv.exe\n"
                ;;
            fail)
                printf "  installer exit code: 1\n"
                printf "installed=false\nerror=installer-failed\n"
                ;;
            missing)
                printf "ERROR: the installer reported success but dbgsrv.exe still cannot be resolved.\n"
                printf "installed=false\nerror=dbgsrv-not-found-after-install\n"
                ;;
        esac
        ;;
    *" -Action StopAll "* | *" -Action Stop "*)
        printf "Windows debug server stopped.\n"
        ;;
    *" -Action Start "*)
        printf "Windows debug server started.\n"
        ;;
esac
'
    make_fake "$BIN/wslpath" '
printf "%s\n" "Z:\\\\fake\\\\debug-server.ps1"
'
}

# Run the debug server script non-interactively with given stdin, using the
# fully isolated PATH (sandbox bin dir only -- no host directories).
run_script() {
    local stdin="$1"
    shift
    # shellcheck disable=SC2034
    LLDB_SERVER="${LLDB_SERVER:-}" \
    XDG_DATA_HOME="$XDG_DATA" \
    XDG_STATE_HOME="$XDG_STATE" \
    FAKE_LOG="$TMP/fake.log" \
    FAKE_WIN_STATUS="${FAKE_WIN_STATUS:-}" \
    FAKE_WIN_PROBE="${FAKE_WIN_PROBE:-}" \
    FAKE_WIN_INSTALL="${FAKE_WIN_INSTALL:-}" \
    ROT_DEBUG_SUDO="" \
    ROT_DEBUG_TERM_WAIT="${ROT_DEBUG_TERM_WAIT:-}" \
    PATH="$BIN" \
    "$HARNESS_BASH" "$DEBUG_SERVER" "$@" <<< "$stdin"

    local rc=$?
    # Reset fake-scenario variables so a test can never leak its Windows
    # scenario into a later test.
    FAKE_WIN_STATUS=""
    FAKE_WIN_PROBE=""
    FAKE_WIN_INSTALL=""
    return $rc
}

# ---------------------------------------------------------------------------
# 1. Bash syntax
# ---------------------------------------------------------------------------
test_bash_syntax() {
    say "bash -n $DEBUG_SERVER"
    if "$HARNESS_BASH" -n "$DEBUG_SERVER" 2>"$TMP/syntax.err"; then
        ok "bash syntax"
    else
        fail "bash syntax: $(cat "$TMP/syntax.err")"
    fi
}

# ---------------------------------------------------------------------------
# 2. PowerShell syntax (only when PowerShell available)
# ---------------------------------------------------------------------------
test_pwsh_syntax() {
    if command -v pwsh >/dev/null 2>&1; then
        say "pwsh syntax $DEBUG_PS1"
        if pwsh -NoProfile -Command "
            \$errs = \$null
            \$null = [System.Management.Automation.PSParser]::Tokenize(
                (Get-Content -Raw '$DEBUG_PS1'), [ref]\$errs)
            if (\$errs.Count -gt 0) { \$errs | ForEach-Object { \$_.Message }; exit 1 }
        " 2>"$TMP/pwsh.err"; then
            ok "PowerShell syntax"
        else
            fail "PowerShell syntax: $(cat "$TMP/pwsh.err")"
        fi
    elif command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        say "powershell.exe syntax $DEBUG_PS1 (read-only Tokenize)"
        local win_script
        win_script="$(wslpath -w "$DEBUG_PS1")"
        if powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
            \$errs = \$null
            \$null = [System.Management.Automation.PSParser]::Tokenize(
                (Get-Content -Raw '$win_script'), [ref]\$errs)
            if (\$errs.Count -gt 0) { \$errs | ForEach-Object { \$_.Message }; exit 1 }
        " 2>"$TMP/pwsh.err"; then
            ok "PowerShell syntax (powershell.exe)"
        else
            fail "PowerShell syntax: $(cat "$TMP/pwsh.err")"
        fi
    else
        printf '   skip PowerShell syntax (no pwsh / powershell.exe available)\n'
    fi
}

# ---------------------------------------------------------------------------
# 3. Package manager detection
#    The isolated PATH guarantees a fake-apt test cannot see the host's pacman
#    and vice versa, because no host directory is on the test PATH at all.
# ---------------------------------------------------------------------------
test_pacman_detection() {
    say "Arch/pacman detection"
    new_sandbox
    install_fakes no pacman
    run_script "3
4
" >"$TMP/out" 2>&1
    if grep -q 'package manager: pacman' "$TMP/out" && grep -q 'PACMAN:-S --needed --noconfirm lldb' "$TMP/fake.log"; then
        ok "pacman selected"
    else
        fail "pacman not selected; log=$(cat "$TMP/fake.log" 2>/dev/null)"
    fi
    if grep -q 'APTGET:' "$TMP/fake.log" 2>/dev/null; then
        fail "host apt-get leaked into pacman test"
    else
        ok "apt-get not visible in pacman test"
    fi
    destroy_sandbox
}

test_apt_detection() {
    say "Debian/Ubuntu apt detection"
    new_sandbox
    install_fakes no apt
    run_script "3
4
" >"$TMP/out" 2>&1
    if grep -q 'package manager: apt' "$TMP/out" && grep -q 'APTGET:update' "$TMP/fake.log" && grep -q 'APTGET:install -y lldb' "$TMP/fake.log"; then
        ok "apt selected"
    else
        fail "apt not selected; log=$(cat "$TMP/fake.log" 2>/dev/null)"
    fi
    if grep -q 'PACMAN:' "$TMP/fake.log" 2>/dev/null || grep -q 'package manager: pacman' "$TMP/out"; then
        fail "host pacman leaked into apt test"
    else
        ok "pacman not visible in apt test"
    fi
    destroy_sandbox
}

test_both_pm_precedence() {
    say "both package managers -> deterministic pacman precedence"
    new_sandbox
    install_fakes no both
    run_script "3
4
" >"$TMP/out" 2>&1
    if grep -q 'package manager: pacman' "$TMP/out" && grep -q 'PACMAN:-S --needed --noconfirm lldb' "$TMP/fake.log"; then
        ok "pacman wins over apt"
    else
        fail "pacman did not win; out=$(cat "$TMP/out") log=$(cat "$TMP/fake.log" 2>/dev/null)"
    fi
    if grep -q 'APTGET:' "$TMP/fake.log" 2>/dev/null; then
        fail "apt-get was also invoked"
    else
        ok "apt-get not invoked when pacman present"
    fi
    destroy_sandbox
}

test_unsupported_pm() {
    say "no package manager -> unsupported"
    new_sandbox
    install_fakes no none
    run_script "3
4
" >"$TMP/out" 2>&1
    if grep -q 'Unsupported package manager' "$TMP/out"; then
        ok "reported unsupported"
    else
        fail "did not report unsupported; out=$(cat "$TMP/out")"
    fi
    if grep -qE 'PACMAN:|APTGET:' "$TMP/fake.log" 2>/dev/null; then
        fail "a package manager was invoked with no fakes"
    else
        ok "no package manager invoked"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 4. Already-installed lldb-server skips install
# ---------------------------------------------------------------------------
test_installed_skips_install() {
    say "already-installed lldb-server skips install"
    new_sandbox
    install_fakes yes both
    run_script "3
4
" >"$TMP/out" 2>&1
    if grep -q 'lldb-server already available' "$TMP/out" && ! grep -qE 'PACMAN:|APTGET:' "$TMP/fake.log"; then
        ok "install skipped"
    else
        fail "install not skipped; log=$(cat "$TMP/fake.log" 2>/dev/null)"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 5. Missing lldb-server invokes correct package manager
#    and package-manager success followed by missing lldb-server is failure
# ---------------------------------------------------------------------------
test_missing_invokes_pm() {
    say "missing lldb-server invokes correct package manager"
    new_sandbox
    install_fakes no apt
    run_script "3
4
" >"$TMP/out" 2>&1
    if grep -q 'APTGET:update' "$TMP/fake.log" && grep -q 'APTGET:install -y lldb' "$TMP/fake.log"; then
        ok "apt-get invoked"
    else
        fail "apt-get not invoked; log=$(cat "$TMP/fake.log" 2>/dev/null)"
    fi
    destroy_sandbox
}

test_pm_success_but_missing() {
    say "package-manager success followed by missing lldb-server is failure"
    new_sandbox
    install_fakes no apt
    run_script "3
4
" >"$TMP/out" 2>&1
    if grep -q 'lldb-server was not found after installation' "$TMP/out"; then
        ok "treated as failure"
    else
        fail "did not report failure; out=$(tail -n 20 "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 6. lldb-server resolution precedence
# ---------------------------------------------------------------------------
test_explicit_lldb_server_precedence() {
    say "explicit LLDB_SERVER precedence"
    new_sandbox
    install_fakes yes both
    # Extra lldb-server on PATH + explicit override.
    mkdir -p "$BIN/extra"
    cp "$BIN/lldb-server" "$BIN/extra/lldb-server"
    LLDB_SERVER="$BIN/extra/lldb-server" \
    XDG_DATA_HOME="$XDG_DATA" XDG_STATE_HOME="$XDG_STATE" \
    FAKE_LOG="$TMP/fake.log" ROT_DEBUG_SUDO="" \
    PATH="$BIN" "$HARNESS_BASH" "$DEBUG_SERVER" <<< "1
3
" >"$TMP/out" 2>&1

    local state="$XDG_STATE/rot-tools/debug-server/linux.state"
    if [[ -f "$state" ]] && grep -q 'exe='"$BIN/extra/lldb-server" "$state"; then
        ok "explicit LLDB_SERVER used"
        PID1="$(sed -n 's/^pid=//p' "$state")"
        track_pid "$PID1"
    else
        fail "explicit LLDB_SERVER not used; state=$(cat "$state" 2>/dev/null)"
    fi
    destroy_sandbox
}

test_bn_managed_precedence() {
    say "Binary Ninja managed-server precedence (plugins/lldb/lldb-server wins over PATH)"
    new_sandbox
    install_fakes yes both
    # The current managed Binary Ninja package layout:
    #   $XDG_DATA_HOME/rot-tools/debuggers/binary-ninja/linux/plugins/lldb/lldb-server
    local bn="$XDG_DATA/rot-tools/debuggers/binary-ninja/linux/plugins/lldb/lldb-server"
    mkdir -p "$(dirname "$bn")"
    cp "$BIN/lldb-server" "$bn"
    run_script "1
3
" >"$TMP/out" 2>&1

    local state="$XDG_STATE/rot-tools/debug-server/linux.state"
    if [[ -f "$state" ]] && grep -q 'exe='"$bn" "$state"; then
        ok "Binary Ninja managed server used"
        PID1="$(sed -n 's/^pid=//p' "$state")"
        track_pid "$PID1"
    else
        fail "BN managed server not used; state=$(cat "$state" 2>/dev/null)"
    fi
    destroy_sandbox
}

test_bn_new_layout_over_legacy() {
    say "plugins/lldb/lldb-server wins over legacy managed layouts"
    new_sandbox
    install_fakes yes both
    local bn_new="$XDG_DATA/rot-tools/debuggers/binary-ninja/linux/plugins/lldb/lldb-server"
    local bn_legacy="$XDG_DATA/rot-tools/debuggers/binary-ninja/linux/lldb-server"
    mkdir -p "$(dirname "$bn_new")"
    cp "$BIN/lldb-server" "$bn_new"
    cp "$BIN/lldb-server" "$bn_legacy"
    run_script "1
3
" >"$TMP/out" 2>&1

    local state="$XDG_STATE/rot-tools/debug-server/linux.state"
    if [[ -f "$state" ]] && grep -q 'exe='"$bn_new" "$state"; then
        ok "new plugins layout preferred"
        PID1="$(sed -n 's/^pid=//p' "$state")"
        track_pid "$PID1"
    else
        fail "new plugins layout not preferred; state=$(cat "$state" 2>/dev/null)"
    fi
    destroy_sandbox
}

test_path_fallback() {
    say "PATH fallback"
    new_sandbox
    install_fakes yes both
    run_script "1
3
" >"$TMP/out" 2>&1

    local state="$XDG_STATE/rot-tools/debug-server/linux.state"
    if [[ -f "$state" ]] && grep -q 'exe='"$BIN/lldb-server" "$state"; then
        ok "PATH lldb-server used"
        PID1="$(sed -n 's/^pid=//p' "$state")"
        track_pid "$PID1"
    else
        fail "PATH lldb-server not used; state=$(cat "$state" 2>/dev/null)"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 7. Start records state
# ---------------------------------------------------------------------------
test_start_records_state() {
    say "start records state"
    new_sandbox
    install_fakes yes both
    run_script "1
3
" >"$TMP/out" 2>&1

    local state="$XDG_STATE/rot-tools/debug-server/linux.state"
    if [[ -f "$state" ]] \
        && grep -q '^backend=linux$' "$state" \
        && grep -q '^listen=127.0.0.1:31337$' "$state" \
        && grep -q '^port=31337$' "$state" \
        && grep -q '^source=system package$' "$state" \
        && grep -q '^pid=[0-9]' "$state"; then
        ok "state recorded"
        PID1="$(sed -n 's/^pid=//p' "$state")"
        track_pid "$PID1"
    else
        fail "state not recorded; state=$(cat "$state" 2>/dev/null)"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 8. Restart detects already-running server
# ---------------------------------------------------------------------------
test_restart_detects_running() {
    say "restart detects already-running server"
    new_sandbox
    install_fakes yes both
    run_script "1
3
" >"$TMP/out1" 2>&1

    local state="$XDG_STATE/rot-tools/debug-server/linux.state"
    PID1="$(sed -n 's/^pid=//p' "$state")"
    track_pid "$PID1"

    run_script "3
" >"$TMP/out2" 2>&1

    if grep -q 'Status: RUNNING' "$TMP/out2" && grep -q "PID:    $PID1" "$TMP/out2"; then
        ok "restart detected running server"
    else
        fail "did not detect running server; out2=$(cat "$TMP/out2")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 9. Normal stop only stops owned PID
# ---------------------------------------------------------------------------
test_normal_stop_owned_only() {
    say "normal stop only stops owned PID"
    new_sandbox
    install_fakes yes both

    # Start two fake lldb-server processes directly. Record only one.
    "$BIN/lldb-server" >/dev/null 2>&1 &
    PID1=$!
    track_pid "$PID1"
    "$BIN/lldb-server" >/dev/null 2>&1 &
    PID2=$!
    track_pid "$PID2"

    local state="$XDG_STATE/rot-tools/debug-server"
    mkdir -p "$state"
    {
        printf 'backend=linux\n'
        printf 'pid=%s\n' "$PID1"
        printf 'exe=%s\n' "$BIN/lldb-server"
        printf 'listen=127.0.0.1:31337\n'
        printf 'port=31337\n'
        printf 'source=system package\n'
    } > "$state/linux.state"

    run_script "1
4
" >"$TMP/out" 2>&1

    if ! kill -0 "$PID1" 2>/dev/null && kill -0 "$PID2" 2>/dev/null; then
        ok "only owned PID stopped"
    else
        fail "owned PID alive or unowned PID killed"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 10. Stale PID state is cleaned
# ---------------------------------------------------------------------------
test_stale_state_cleaned() {
    say "stale PID state is cleaned"
    new_sandbox
    install_fakes yes both

    local state="$XDG_STATE/rot-tools/debug-server"
    mkdir -p "$state"
    {
        printf 'backend=linux\n'
        printf 'pid=999999\n'
        printf 'exe=%s\n' "$BIN/lldb-server"
        printf 'listen=127.0.0.1:31337\n'
        printf 'port=31337\n'
    } > "$state/linux.state"

    run_script "3
" >"$TMP/out" 2>&1

    if [[ ! -f "$state/linux.state" ]] && grep -q 'No debug server is running' "$TMP/out"; then
        ok "stale state cleaned"
    else
        fail "stale state not cleaned; state=$(cat "$state/linux.state" 2>/dev/null)"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 11. Stop-all handles all recorded Rot-owned servers
# ---------------------------------------------------------------------------
test_stop_all_owned() {
    say "stop-all handles all recorded Rot-owned servers"
    new_sandbox
    install_fakes yes both

    "$BIN/lldb-server" >/dev/null 2>&1 &
    PID1=$!
    track_pid "$PID1"
    "$BIN/lldb-server" >/dev/null 2>&1 &
    PID2=$!
    track_pid "$PID2"

    local state="$XDG_STATE/rot-tools/debug-server"
    mkdir -p "$state"
    for f in linux.state second.state; do
        local pid
        if [[ "$f" == "linux.state" ]]; then pid=$PID1; else pid=$PID2; fi
        {
            printf 'backend=linux\n'
            printf 'pid=%s\n' "$pid"
            printf 'exe=%s\n' "$BIN/lldb-server"
            printf 'listen=127.0.0.1:31337\n'
            printf 'port=31337\n'
        } > "$state/$f"
    done

    run_script "2
4
" >"$TMP/out" 2>&1

    if ! kill -0 "$PID1" 2>/dev/null && ! kill -0 "$PID2" 2>/dev/null \
        && [[ ! -f "$state/linux.state" ]] && [[ ! -f "$state/second.state" ]]; then
        ok "all recorded servers stopped"
    else
        fail "stop-all did not stop all recorded servers"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 12. Stop-all refuses an unverifiable PID
# ---------------------------------------------------------------------------
test_stop_all_unverifiable() {
    say "stop-all refuses an unverifiable PID"
    new_sandbox
    install_fakes yes both

    # A live process that is NOT the recorded lldb-server.
    sleep 1000 &
    PID1=$!
    track_pid "$PID1"

    local state="$XDG_STATE/rot-tools/debug-server"
    mkdir -p "$state"
    {
        printf 'backend=linux\n'
        printf 'pid=%s\n' "$PID1"
        printf 'exe=%s\n' "$BIN/lldb-server"
        printf 'listen=127.0.0.1:31337\n'
        printf 'port=31337\n'
    } > "$state/linux.state"

    run_script "4
4
" >"$TMP/out" 2>&1

    if kill -0 "$PID1" 2>/dev/null && grep -q 'NOT killing it' "$TMP/out"; then
        ok "unverifiable PID not killed"
    else
        fail "unverifiable PID killed or no warning; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 13. Windows machine-readable status is parsed and rendered by the menu
# ---------------------------------------------------------------------------
test_windows_machine_readable_status() {
    say "windows machine-readable status parsed and rendered"
    new_sandbox
    install_fakes yes both
    FAKE_WIN_STATUS=running
    run_script "3
" >"$TMP/out" 2>&1

    if grep -q 'Windows debug server' "$TMP/out" \
        && grep -q 'Status: RUNNING' "$TMP/out" \
        && grep -q 'PID:    12345' "$TMP/out" \
        && grep -q 'Listen: 127.0.0.1:31338' "$TMP/out"; then
        ok "windows running status rendered from machine-readable output"
    else
        fail "windows running status not rendered; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 13b. Windows debugger availability probe
# ---------------------------------------------------------------------------
test_windows_probe_found() {
    say "windows probe: dbgsrv.exe found"
    new_sandbox
    install_fakes yes both
    FAKE_WIN_STATUS=stopped
    FAKE_WIN_PROBE=found
    run_script "4
" >"$TMP/out" 2>&1

    if grep -q 'Windows interop: available' "$TMP/out" \
        && grep -q 'Windows debugger: found (Z:\\fake\\dbgsrv.exe)' "$TMP/out"; then
        ok "probe found rendered with path"
    else
        fail "probe found not rendered; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

test_windows_probe_missing() {
    say "windows probe: dbgsrv.exe missing"
    new_sandbox
    install_fakes yes both
    FAKE_WIN_STATUS=stopped
    FAKE_WIN_PROBE=missing
    run_script "4
" >"$TMP/out" 2>&1

    if grep -q 'Windows interop: available' "$TMP/out" \
        && grep -q 'Windows debugger: missing' "$TMP/out"; then
        ok "probe missing rendered as missing"
    else
        fail "probe missing not rendered; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

test_windows_interop_unavailable() {
    say "no powershell.exe / wslpath -> interop unavailable"
    new_sandbox
    install_fakes yes both
    rm -f "$BIN/powershell.exe" "$BIN/wslpath"
    run_script "3
" >"$TMP/out" 2>&1

    if grep -q 'Windows interop: unavailable' "$TMP/out" \
        && ! grep -q 'Start Windows server' "$TMP/out"; then
        ok "interop unavailable rendered without Windows start option"
    else
        fail "interop unavailable not rendered; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

test_start_windows_dbg_missing() {
    say "start windows with dbgsrv.exe missing shows sources and does not start"
    new_sandbox
    install_fakes yes both
    FAKE_WIN_STATUS=stopped
    FAKE_WIN_PROBE=missing
    run_script "2
4
" >"$TMP/out" 2>&1

    if grep -q 'ERROR: dbgsrv.exe could not be found.' "$TMP/out" \
        && grep -q 'DBGSRV_PATH' "$TMP/out" \
        && grep -q 'BN_DEBUGGER_WIN32' "$TMP/out" \
        && grep -q 'Windows SDK Debugging Tools' "$TMP/out" \
        && ! grep -q 'Windows debug server started.' "$TMP/out"; then
        ok "start refused with source hints"
    else
        fail "start not refused with hints; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 13c. Setup / repair: Windows debugger auto-install through the mock boundary
# ---------------------------------------------------------------------------
test_setup_windows_already_installed() {
    say "setup with dbgsrv.exe present does not invoke the installer"
    new_sandbox
    install_fakes yes both
    FAKE_WIN_STATUS=stopped
    FAKE_WIN_PROBE=found
    run_script "3
4
" >"$TMP/out" 2>&1

    if grep -q 'Windows debugger: installed' "$TMP/out" \
        && grep -q 'Z:\\fake\\dbgsrv.exe' "$TMP/out" \
        && ! grep -q -- '-Action Install' "$TMP/fake.log"; then
        ok "installer not invoked when dbgsrv.exe present"
    else
        fail "installer invoked or state wrong; out=$(cat "$TMP/out") log=$(cat "$TMP/fake.log" 2>/dev/null)"
    fi
    destroy_sandbox
}

test_setup_windows_installs_missing() {
    say "setup with dbgsrv.exe missing installs and reports the resolved path"
    new_sandbox
    install_fakes yes both
    FAKE_WIN_STATUS=stopped
    FAKE_WIN_PROBE=missing
    FAKE_WIN_INSTALL=ok
    run_script "3
4
" >"$TMP/out" 2>&1

    if grep -q 'Windows debugger: missing' "$TMP/out" \
        && grep -q -- '-Action Install' "$TMP/fake.log" \
        && grep -q 'Windows debugger installed:' "$TMP/out" \
        && grep -q 'Z:\\Program Files (x86)\\Windows Kits\\10\\Debuggers\\x64\\dbgsrv.exe' "$TMP/out"; then
        ok "installer invoked and resolved dbgsrv.exe reported"
    else
        fail "install flow wrong; out=$(cat "$TMP/out") log=$(cat "$TMP/fake.log" 2>/dev/null)"
    fi
    destroy_sandbox
}

test_setup_windows_installer_fails() {
    say "setup fails when the installer returns failure"
    new_sandbox
    install_fakes yes both
    FAKE_WIN_STATUS=stopped
    FAKE_WIN_PROBE=missing
    FAKE_WIN_INSTALL=fail
    run_script "3
4
" >"$TMP/out" 2>&1

    if grep -q 'installer exit code: 1' "$TMP/out" \
        && grep -q 'ERROR: dbgsrv.exe could not be resolved after installing Debugging Tools for Windows.' "$TMP/out"; then
        ok "installer failure reported as setup failure"
    else
        fail "installer failure not reported; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

test_setup_windows_false_success() {
    say "setup fails when installer reports success but dbgsrv.exe stays missing"
    new_sandbox
    install_fakes yes both
    FAKE_WIN_STATUS=stopped
    FAKE_WIN_PROBE=missing
    FAKE_WIN_INSTALL=missing
    run_script "3
4
" >"$TMP/out" 2>&1

    if grep -q 'the installer reported success but dbgsrv.exe still cannot be resolved.' "$TMP/out" \
        && grep -q 'ERROR: dbgsrv.exe could not be resolved after installing Debugging Tools for Windows.' "$TMP/out" \
        && ! grep -q 'Windows debugger installed:' "$TMP/out"; then
        ok "false-success not claimed as installed"
    else
        fail "false-success mishandled; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

test_setup_linux_only() {
    say "setup with no Windows interop only repairs Linux"
    new_sandbox
    install_fakes yes both
    rm -f "$BIN/powershell.exe" "$BIN/wslpath"
    run_script "2
3
" >"$TMP/out" 2>&1

    if grep -q 'lldb-server already available:' "$TMP/out" \
        && grep -q 'Windows interop: unavailable' "$TMP/out" \
        && ! grep -qE 'PACMAN:|APTGET:' "$TMP/fake.log" 2>/dev/null \
        && ! grep -q 'Windows debugger installed:' "$TMP/out"; then
        ok "Linux-only setup intact without Windows interop"
    else
        fail "Linux-only setup broken; out=$(cat "$TMP/out") log=$(cat "$TMP/fake.log" 2>/dev/null)"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 14. PowerShell ownership tests (run when a PowerShell host exists)
# ---------------------------------------------------------------------------
test_windows_ownership() {
    if command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        say "PowerShell ownership tests (powershell.exe)"
        local win_script
        win_script="$(wslpath -w "$WINDOWS_OWNERSHIP_TEST")"
        if timeout 300 powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win_script"; then
            ok "windows ownership tests (powershell.exe)"
        else
            fail "windows ownership tests (powershell.exe) failed"
        fi
    elif command -v pwsh >/dev/null 2>&1; then
        say "PowerShell ownership tests (pwsh, Linux: windows-only cases skip)"
        if timeout 120 pwsh -NoProfile -File "$WINDOWS_OWNERSHIP_TEST"; then
            ok "windows ownership tests (pwsh)"
        else
            fail "windows ownership tests (pwsh) failed"
        fi
    else
        printf '   skip windows ownership tests (no PowerShell host available)\n'
    fi
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
main() {
    say "Running debug-server test suite"

    new_sandbox
    test_bash_syntax
    test_pwsh_syntax
    destroy_sandbox

    test_pacman_detection
    test_apt_detection
    test_both_pm_precedence
    test_unsupported_pm
    test_installed_skips_install
    test_missing_invokes_pm
    test_pm_success_but_missing
    test_explicit_lldb_server_precedence
    test_bn_managed_precedence
    test_bn_new_layout_over_legacy
    test_path_fallback
    test_start_records_state
    test_restart_detects_running
    test_normal_stop_owned_only
    test_stale_state_cleaned
    test_stop_all_owned
    test_stop_all_unverifiable
    test_windows_machine_readable_status
    test_windows_probe_found
    test_windows_probe_missing
    test_windows_interop_unavailable
    test_start_windows_dbg_missing
    test_setup_windows_already_installed
    test_setup_windows_installs_missing
    test_setup_windows_installer_fails
    test_setup_windows_false_success
    test_setup_linux_only
    test_windows_ownership

    # Make sure cleanup did not leave fake servers behind.
    local leftover=0
    for bin in "${ALL_BINS[@]:-}"; do
        for p in /proc/[0-9]*; do
            [[ -r "$p/cmdline" ]] || continue
            case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)" in
                *"$bin/lldb-server"*)
                    leftover=$((leftover+1))
                    ;;
            esac
        done
    done
    if [[ "$leftover" -eq 0 ]]; then
        ok "no fake lldb-server processes left behind"
    else
        fail "leftover fake lldb-server processes: $leftover"
    fi

    printf '\n'
    printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
    if [[ -n "$FAILED_TESTS" ]]; then
        printf 'Failed:%s\n' "$FAILED_TESTS"
        return 1
    fi
    return 0
}

main "$@"
