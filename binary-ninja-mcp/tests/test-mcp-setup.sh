#!/usr/bin/env bash
set -u

# Test suite for re-tools/binary-ninja-mcp/mcp_configure.sh
#
# Uses a FULLY ISOLATED test PATH so the host's real node, npm, npx,
# opencode, curl, powershell.exe, and package managers can never be reached.
# The sandbox bin dir contains fake tools for the scenario under test plus
# symlinks to the safe system utilities the script itself needs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/../mcp_configure.sh"
HARNESS_BASH="$(command -v bash)"

PASS=0
FAIL=0
FAILED_TESTS=""

say()   { printf '\n== %s\n' "$*"; }
ok()    { PASS=$((PASS+1)); printf '   ok   %s\n' "$*"; }
fail()  { FAIL=$((FAIL+1)); FAILED_TESTS="$FAILED_TESTS $*"; printf '   FAIL %s\n' "$*"; }

SAFE_TOOLS=(bash grep sed tr head awk dirname readlink realpath date mkdir rm sleep kill id tail python3)

new_sandbox() {
    TMP="$(mktemp -d)"
    BIN="$TMP/bin"
    mkdir -p "$BIN"
    ALL_BINS+=( "$BIN" )

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

destroy_sandbox() {
    rm -rf "$TMP"
    TMP=""
    BIN=""
}

trap destroy_sandbox EXIT INT TERM

make_fake() {
    local path="$1"
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$path"
    chmod +x "$path"
}

# Standard fake toolset. `with` selects which fakes land on PATH:
#   all   - node/npm/npx/opencode/curl all present
#   deps  - curl only (no node/npm/npx/opencode)
install_fakes() {
    local with="$1"

    make_fake "$BIN/node" 'printf "v24.0.0\n"'
    make_fake "$BIN/npm" 'printf "10.0.0\n"'
    make_fake "$BIN/npx" 'printf "10.0.0\n"'

    # Fake OpenCode. `list` output is controlled by FAKE_MCP_LIST (the entry
    # header line: name + status) and FAKE_MCP_CMD (the command line). %b turns
    # the \033 escapes into real ANSI codes, matching real `opencode` output.
    make_fake "$BIN/opencode" '
case "$1" in
    mcp)
        if [ "$2" = "list" ]; then
            printf "MCP Servers\n"
            printf "%b\n" "${FAKE_MCP_LIST:-binary-ninja \033[90mconnected}"
            printf "%b\n" "${FAKE_MCP_CMD:-  \033[90mnpx -y binary-ninja-mcp --host localhost --port 9009}"
        fi
        ;;
    --version)
        printf "1.18.18\n"
        ;;
    *)
        exit 0
        ;;
esac
'

    # Fake curl: FAKE_BN=reachable -> HTTP 200; anything else -> connect refused.
    make_fake "$BIN/curl" '
if [ "${FAKE_BN:-reachable}" = "reachable" ]; then
    printf "200\n"
    exit 0
fi
exit 7
'

    if [[ "$with" == "deps" ]]; then
        rm -f "$BIN/node" "$BIN/npm" "$BIN/npx" "$BIN/opencode"
    fi
}

run_script() {
    local stdin="$1"
    shift
    FAKE_BN="${FAKE_BN:-reachable}" \
    FAKE_MCP_LIST="${FAKE_MCP_LIST:-}" \
    FAKE_MCP_CMD="${FAKE_MCP_CMD:-}" \
    PATH="$BIN" \
    "$HARNESS_BASH" "$SETUP" "$@" <<< "$stdin"
}

# ---------------------------------------------------------------------------
# 1. Bash syntax
# ---------------------------------------------------------------------------
test_bash_syntax() {
    say "bash -n $SETUP"
    if "$HARNESS_BASH" -n "$SETUP" 2>"$TMP/syntax.err"; then
        ok "bash syntax"
    else
        fail "bash syntax: $(cat "$TMP/syntax.err")"
    fi
}

# ---------------------------------------------------------------------------
# 2. NVM must never be used (Node is installed via OS methods only)
# ---------------------------------------------------------------------------
test_no_nvm() {
    say "mcp_configure.sh never invokes nvm (no NVM_DIR / nvm.sh / nvm install)"
    if grep -Eq 'nvm install|nvm\.sh|NVM_DIR' "$SETUP"; then
        fail "functional nvm usage found in mcp_configure.sh"
    else
        ok "no functional nvm usage"
    fi
}

# ---------------------------------------------------------------------------
# 3. Full status report with everything present
# ---------------------------------------------------------------------------
test_status_all_found() {
    say "status with all dependencies present"
    new_sandbox
    install_fakes all
    FAKE_BN=reachable
    FAKE_MCP_LIST="binary-ninja \033[90mconnected"
    run_script "" status >"$TMP/out" 2>&1

    if grep -q 'Binary Ninja MCP' "$TMP/out" \
        && grep -q 'Node:       found' "$TMP/out" \
        && grep -q 'npm:        found' "$TMP/out" \
        && grep -q 'npx:        found' "$TMP/out" \
        && grep -q 'OpenCode:   found' "$TMP/out" \
        && grep -q 'localhost:9009: reachable' "$TMP/out" \
        && grep -q 'found:   yes' "$TMP/out" \
        && grep -q 'name:    binary-ninja' "$TMP/out" \
        && grep -q 'backend: binary-ninja-mcp' "$TMP/out" \
        && grep -q 'host:    localhost' "$TMP/out" \
        && grep -q 'port:    9009' "$TMP/out" \
        && grep -q 'status:  connected' "$TMP/out"; then
        ok "full status report rendered correctly"
    else
        fail "status report wrong; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 4. Status with dependencies missing and endpoint unreachable
# ---------------------------------------------------------------------------
test_status_missing() {
    say "status with missing dependencies and unreachable endpoint"
    new_sandbox
    install_fakes deps
    FAKE_BN=unreachable
    run_script "" status >"$TMP/out" 2>&1

    if grep -q 'Node:       missing' "$TMP/out" \
        && grep -q 'npm:        missing' "$TMP/out" \
        && grep -q 'npx:        missing' "$TMP/out" \
        && grep -q 'OpenCode:   missing' "$TMP/out" \
        && grep -q 'localhost:9009: unreachable' "$TMP/out" \
        && grep -q 'found:   no' "$TMP/out" \
        && grep -q 'status:  unknown' "$TMP/out"; then
        ok "missing state rendered correctly"
    else
        fail "missing state wrong; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 5. A differently-named server using binary-ninja-mcp IS detected
# ---------------------------------------------------------------------------
test_underscore_name_detected() {
    say "binary_ninja_poncho_mcp using binary-ninja-mcp is detected"
    new_sandbox
    install_fakes all
    FAKE_BN=reachable
    FAKE_MCP_LIST="binary_ninja_poncho_mcp \033[90mconnected"
    run_script "" status >"$TMP/out" 2>&1

    if grep -q 'found:   yes' "$TMP/out" \
        && grep -q 'name:    binary_ninja_poncho_mcp' "$TMP/out" \
        && grep -q 'backend: binary-ninja-mcp' "$TMP/out" \
        && grep -q 'status:  connected' "$TMP/out"; then
        ok "underscore-named binary-ninja-mcp server detected"
    else
        fail "underscore-named server not detected; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 6. An arbitrary MCP name (binja) using binary-ninja-mcp is detected
# ---------------------------------------------------------------------------
test_binja_name_detected() {
    say "binja using binary-ninja-mcp is detected"
    new_sandbox
    install_fakes all
    FAKE_BN=reachable
    FAKE_MCP_LIST="binja \033[90mconnected"
    run_script "" status >"$TMP/out" 2>&1

    if grep -q 'found:   yes' "$TMP/out" \
        && grep -q 'name:    binja' "$TMP/out" \
        && grep -q 'backend: binary-ninja-mcp' "$TMP/out" \
        && grep -q 'status:  connected' "$TMP/out"; then
        ok "binja-named binary-ninja-mcp server detected"
    else
        fail "binja-named server not detected; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 7. An unrelated MCP is NOT mistaken for the Binary Ninja MCP
# ---------------------------------------------------------------------------
test_unrelated_not_mistaken() {
    say "a server with a different backend is not detected as Binary Ninja MCP"
    new_sandbox
    install_fakes all
    FAKE_BN=reachable
    FAKE_MCP_LIST="github \033[90mconnected"
    FAKE_MCP_CMD="  \033[90mnpx -y @modelcontextprotocol/server-github"
    run_script "" status >"$TMP/out" 2>&1

    if grep -q 'found:   no' "$TMP/out" \
        && grep -q 'status:  unknown' "$TMP/out" \
        && ! grep -q 'backend: binary-ninja-mcp' "$TMP/out"; then
        ok "unrelated MCP not mistaken for Binary Ninja MCP"
    else
        fail "unrelated MCP misdetected; out=$(cat "$TMP/out")"
    fi
    unset FAKE_MCP_CMD
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 8. A detected differently-named server does not trigger a duplicate setup
# ---------------------------------------------------------------------------
test_no_duplicate_setup() {
    say "differently-named binary-ninja-mcp server is not duplicated by setup"
    new_sandbox
    install_fakes all
    FAKE_BN=reachable
    FAKE_MCP_LIST="binja \033[90mconnected"
    run_script "" --setup >"$TMP/out" 2>&1
    local rc=$?

    if [[ "$rc" -eq 0 ]] \
        && ! grep -q 'is not configured in OpenCode' "$TMP/out" \
        && ! grep -q 'Configure it now' "$TMP/out" \
        && grep -q 'found:   yes' "$TMP/out" \
        && grep -q 'name:    binja' "$TMP/out"; then
        ok "setup left the existing differently-named server alone"
    else
        fail "setup offered a duplicate entry; rc=$rc out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 9. Connected/disconnected status detection
# ---------------------------------------------------------------------------
test_disconnected_status() {
    say "disconnected status is reported"
    new_sandbox
    install_fakes all
    FAKE_BN=reachable
    FAKE_MCP_LIST="binja \033[90mdisconnected"
    run_script "" status >"$TMP/out" 2>&1

    if grep -q 'found:   yes' "$TMP/out" \
        && grep -q 'name:    binja' "$TMP/out" \
        && grep -q 'status:  disconnected' "$TMP/out"; then
        ok "disconnected status detected"
    else
        fail "disconnected status wrong; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 10. Interactive menu renders immediately WITHOUT the full status scan
# ---------------------------------------------------------------------------
test_menu_no_full_scan() {
    say "interactive menu appears without running the full status scan"
    new_sandbox
    install_fakes all
    FAKE_BN=unreachable
    FAKE_MCP_LIST="binary-ninja \033[90mconnected"
    run_script "5
" >"$TMP/out" 2>&1
    local rc=$?

    if [[ "$rc" -eq 0 ]] && grep -q 'Binary Ninja MCP' "$TMP/out" \
        && grep -q '1) Setup / repair' "$TMP/out" \
        && grep -q '5) Exit' "$TMP/out" \
        && ! grep -q 'localhost:9009' "$TMP/out" \
        && ! grep -q 'Node:' "$TMP/out" \
        && ! grep -q 'OpenCode MCP:' "$TMP/out" \
        && ! grep -q 'found:' "$TMP/out"; then
        ok "menu rendered without a full status/network scan"
    else
        fail "menu triggered a full status scan; rc=$rc out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 11. Menu "Show status" performs the full scan on demand
# ---------------------------------------------------------------------------
test_menu_show_status() {
    say "menu Show status (2) performs the full scan"
    new_sandbox
    install_fakes all
    FAKE_BN=reachable
    FAKE_MCP_LIST="binary-ninja \033[90mconnected"
    run_script "2
5
" >"$TMP/out" 2>&1
    local rc=$?

    if [[ "$rc" -eq 0 ]] && grep -q 'localhost:9009: reachable' "$TMP/out" \
        && grep -q 'found:   yes' "$TMP/out" \
        && grep -q 'name:    binary-ninja' "$TMP/out" \
        && grep -q 'status:  connected' "$TMP/out"; then
        ok "Show status ran the full scan"
    else
        fail "Show status did not run the full scan; rc=$rc out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# 12. Connection test subcommand
# ---------------------------------------------------------------------------
test_connection_subcommand() {
    say "--test-connection reports reachability"
    new_sandbox
    install_fakes all
    FAKE_BN=reachable
    run_script "" --test-connection >"$TMP/out" 2>&1

    if grep -q 'localhost:9009: reachable' "$TMP/out"; then
        ok "connection test reported reachable"
    else
        fail "connection test wrong; out=$(cat "$TMP/out")"
    fi
    destroy_sandbox
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
main() {
    say "Running MCP setup test suite"

    new_sandbox
    test_bash_syntax
    test_no_nvm
    destroy_sandbox

    test_status_all_found
    test_status_missing
    test_underscore_name_detected
    test_binja_name_detected
    test_unrelated_not_mistaken
    test_no_duplicate_setup
    test_disconnected_status
    test_menu_no_full_scan
    test_menu_show_status
    test_connection_subcommand

    printf '\n'
    printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
    if [[ -n "$FAILED_TESTS" ]]; then
        printf 'Failed:%s\n' "$FAILED_TESTS"
        return 1
    fi
    return 0
}

main "$@"
