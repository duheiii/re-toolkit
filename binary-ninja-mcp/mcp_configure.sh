#!/usr/bin/env bash
set -u
set -o pipefail

# Binary Ninja MCP setup / check / repair for OpenCode.
#
# This tool ONLY prepares and checks the AI <-> Binary Ninja MCP integration:
#   * Node/npm/npx and OpenCode availability
#   * the Binary Ninja MCP server on localhost:9009
#   * OpenCode's MCP configuration for the Binary Ninja MCP server
#     (identified by its `binary-ninja-mcp` command, under any entry name)
#
# It does NOT manage debugger servers (see re-tools/remote-debug/debug-server.sh).
#
# Environment detection is done at runtime, so the same script works on
# native Linux and inside WSL. Native Windows uses mcp_configure.ps1 instead.
#
# Node/npm/npx are never installed through NVM; if they are already present
# they are left untouched. Missing pieces are installed with the detected
# OS's own supported method. OpenCode is checked before any install is
# attempted and is never installed twice.
#
# OpenCode's own `opencode mcp add` wizard is used for configuration instead
# of editing OpenCode's internal config directly.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Desired MCP server.
MCP_NAME="${ROT_MCP_NAME:-binary-ninja}"
MCP_COMMAND='npx -y binary-ninja-mcp --host localhost --port 9009'
BN_HOST="${ROT_MCP_HOST:-localhost}"
BN_PORT="${ROT_MCP_PORT:-9009}"
BN_URL="http://$BN_HOST:$BN_PORT/"

# Elevation for package installs. Unset -> "sudo". Set to empty to disable
# (used by the automated test suite with fake package managers).
ROT_SUDO="${ROT_MCP_SUDO-sudo}"

# ---------------------------------------------------------------------------
# Report state (filled by the check functions)
# ---------------------------------------------------------------------------
OS_LABEL=""
WSL="no"
NODE_STATUS="missing"
NPM_STATUS="missing"
NPX_STATUS="missing"
OPENCODE_STATUS="missing"
BN_STATUS="unreachable"
BN_NOTE=""
MCP_CONFIGURED="missing"
MCP_STATUS="unknown"
MCP_NOTE=""
MCP_FOUND_NAME=""
MCP_FOUND_BACKEND=""
MCP_FOUND_HOST=""
MCP_FOUND_PORT=""
MIRRORED_STATUS="unknown"
INTEROP_STATUS="unavailable"

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------
is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

distro_id() {
    local id=""
    if [[ -r /etc/os-release ]]; then
        id="$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '"')"
    fi
    printf '%s' "${id:-unknown}"
}

detect_os() {
    local id
    id="$(distro_id)"
    if is_wsl; then
        OS_LABEL="WSL ($id)"
        WSL="yes"
    else
        OS_LABEL="Linux ($id)"
        WSL="no"
    fi
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
check_dependencies() {
    NODE_STATUS="missing"
    NPM_STATUS="missing"
    NPX_STATUS="missing"
    OPENCODE_STATUS="missing"

    command -v node >/dev/null 2>&1 && NODE_STATUS="found"
    command -v npm >/dev/null 2>&1 && NPM_STATUS="found"
    command -v npx >/dev/null 2>&1 && NPX_STATUS="found"
    command -v opencode >/dev/null 2>&1 && OPENCODE_STATUS="found"
}

detect_pkg_manager() {
    if command -v pacman >/dev/null 2>&1; then
        printf 'pacman'
    elif command -v apt-get >/dev/null 2>&1; then
        printf 'apt'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'dnf'
    else
        printf 'unsupported'
    fi
}

# Install Node.js + npm + npx using the detected OS's supported method.
# NVM is deliberately NOT used: the requirement is a working node/npm/npx.
install_node_toolchain() {
    local pm
    pm="$(detect_pkg_manager)"

    local -a elevate=()
    if [[ -n "$ROT_SUDO" && "$(id -u)" -ne 0 ]]; then
        elevate=( "$ROT_SUDO" )
    fi

    case "$pm" in
        apt)
            printf '  %s apt-get update\n' "${elevate[*]:-apt-get}"
            "${elevate[@]}" apt-get update
            printf '  %s apt-get install -y nodejs npm\n' "${elevate[*]:-apt-get}"
            "${elevate[@]}" apt-get install -y nodejs npm
            ;;
        pacman)
            printf '  %s pacman -S --needed --noconfirm nodejs npm\n' "${elevate[*]:-pacman}"
            "${elevate[@]}" pacman -S --needed --noconfirm nodejs npm
            ;;
        dnf)
            printf '  %s dnf install -y nodejs npm\n' "${elevate[*]:-dnf}"
            "${elevate[@]}" dnf install -y nodejs npm
            ;;
        unsupported)
            printf 'Unsupported package manager.\n' >&2
            printf 'Install Node.js LTS (which includes npm and npx) from https://nodejs.org and re-run setup.\n' >&2
            return 1
            ;;
    esac

    check_dependencies
    if [[ "$NODE_STATUS" == "found" && "$NPM_STATUS" == "found" && "$NPX_STATUS" == "found" ]]; then
        printf 'Verified Node toolchain: %s\n' "$(node --version)"
        return 0
    fi

    printf 'ERROR: node/npm/npx were not all found after installation.\n' >&2
    return 1
}

install_opencode() {
    printf 'Installing OpenCode...\n'
    curl -fsSL https://opencode.ai/install | bash
    export PATH="$HOME/.opencode/bin:$PATH"
    if command -v opencode >/dev/null 2>&1; then
        printf 'Verified OpenCode: %s\n' "$(opencode --version)"
        return 0
    fi
    printf 'ERROR: OpenCode was not found after installation.\n' >&2
    return 1
}

# ---------------------------------------------------------------------------
# Binary Ninja MCP endpoint
# ---------------------------------------------------------------------------
# A TCP connect that yields an HTTP reply (rc 0), an empty reply, or any other
# response means the server is listening. Only connection refused / timeout
# (rc 7 / rc 28) count as unreachable.
check_bn_endpoint() {
    local rc
    BN_NOTE=""
    curl -s -m 3 -o /dev/null -w '%{http_code}' "$BN_URL" 2>/dev/null >/dev/null
    rc=$?
    if [[ "$rc" -eq 0 || "$rc" -eq 52 || "$rc" -eq 56 ]]; then
        BN_STATUS="reachable"
    else
        BN_STATUS="unreachable"
    fi
}

# ---------------------------------------------------------------------------
# WSL networking helpers
# ---------------------------------------------------------------------------
windows_interop_available() {
    command -v powershell.exe >/dev/null 2>&1 &&
        command -v wslpath >/dev/null 2>&1
}

wsl_host_ip() {
    local ip=""
    ip="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
    if [[ -z "$ip" ]]; then
        ip="$(sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null | head -n1)"
    fi
    printf '%s' "$ip"
}

wslconfig_path() {
    local win_profile_win win_profile
    windows_interop_available || return 1
    win_profile_win="$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r')"
    [[ -n "$win_profile_win" ]] || return 1
    win_profile="$(wslpath "$win_profile_win" 2>/dev/null)" || return 1
    printf '%s/.wslconfig' "$win_profile"
}

# Report the [wsl2] networkingMode as mirrored / not mirrored / unknown.
check_mirrored_networking() {
    MIRRORED_STATUS="unknown"
    local wslconfig
    wslconfig="$(wslconfig_path)" || { MIRRORED_STATUS="unknown (no Windows interop)"; return; }
    [[ -f "$wslconfig" ]] || { MIRRORED_STATUS="not set (.wslconfig missing)"; return; }

    if python3 - "$wslconfig" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(1)

in_wsl2 = False
for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        in_wsl2 = s.lower() == "[wsl2]"
        continue
    if in_wsl2 and s.lower().startswith("networkingmode="):
        value = s.split("=", 1)[1].strip().lower()
        sys.exit(0 if value == "mirrored" else 1)
sys.exit(2)
PY
    then
        MIRRORED_STATUS="mirrored"
    else
        MIRRORED_STATUS="not mirrored"
    fi
}

# Check the WSL <-> Windows localhost arrangement for the MCP connection:
#   usable      - BN reachable on localhost from WSL
#   via-host-ip - BN reachable only via the Windows host IP (NAT mode)
#   unusable    - BN not reachable from WSL at all
#   n/a         - not running under WSL
check_wsl_arrangement() {
    BN_NOTE=""
    if [[ "$WSL" != "yes" ]]; then
        return
    fi

    if [[ "$BN_STATUS" == "reachable" ]]; then
        BN_NOTE="localhost usable from WSL"
        return
    fi

    if windows_interop_available; then
        local host_ip port_rc
        host_ip="$(wsl_host_ip)"
        if [[ -n "$host_ip" && "$host_ip" != "127.0.0.1" ]]; then
            curl -s -m 3 -o /dev/null "http://$host_ip:$BN_PORT/" 2>/dev/null
            port_rc=$?
            if [[ "$port_rc" -eq 0 || "$port_rc" -eq 52 || "$port_rc" -eq 56 ]]; then
                BN_NOTE="Binary Ninja looks reachable via Windows host $host_ip:$BN_PORT, but not via localhost. Consider mirrored networking."
                return
            fi
        fi
    fi

    BN_NOTE="not reachable from WSL; is Binary Ninja running with its MCP server started?"
}

# Configure [wsl2] networkingMode=mirrored in the Windows .wslconfig,
# preserving every unrelated setting already present.
configure_mirrored_networking() {
    printf '\nConfiguring WSL mirrored networking\n'

    if ! windows_interop_available; then
        printf '[!] powershell.exe/wslpath are unavailable from WSL; skipping .wslconfig setup.\n'
        return 1
    fi

    local wslconfig
    wslconfig="$(wslconfig_path)" || {
        printf '[!] could not locate the Windows user profile.\n'
        return 1
    }

    python3 - "$wslconfig" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8") if path.exists() else ""
lines = text.splitlines()

out = []
in_wsl2 = False
saw_wsl2 = False
networking_written = False

for line in lines:
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        if in_wsl2 and not networking_written:
            out.append("networkingMode=mirrored")

        in_wsl2 = stripped.lower() == "[wsl2]"
        if in_wsl2:
            saw_wsl2 = True
            networking_written = False

        out.append(line)
        continue

    if in_wsl2 and stripped.lower().startswith("networkingmode="):
        out.append("networkingMode=mirrored")
        networking_written = True
    else:
        out.append(line)

if in_wsl2 and not networking_written:
    out.append("networkingMode=mirrored")

if not saw_wsl2:
    if out and out[-1].strip():
        out.append("")
    out.extend([
        "[wsl2]",
        "networkingMode=mirrored",
    ])

path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
PY

    printf '[+] Mirrored networking configured in: %s\n' "$wslconfig"
    printf '[!] If this changed .wslconfig, run "wsl --shutdown" from Windows PowerShell before testing localhost access.\n'
}

# ---------------------------------------------------------------------------
# OpenCode MCP configuration / status
# ---------------------------------------------------------------------------
# Uses `opencode mcp list` to determine whether a Binary Ninja MCP server is
# configured and whether it reports connected / disconnected / unknown.
#
# The integration is identified by its command/backend (`binary-ninja-mcp`),
# NOT by the entry name: users may name the MCP entry anything they like. The
# default/suggested name (MCP_NAME / ROT_MCP_NAME) is preferred when a matching
# entry uses it, but is never required for detection.

# Strip ANSI escapes, CRs, and the leading box-drawing/whitespace that
# `opencode mcp list` uses, leaving a plain line.
strip_list_formatting() {
    printf '%s\n' "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g' | tr -d '\r' | sed -r 's/^[^[:alnum:]_]*//'
}

# Is $1 a command launcher (first token of a command line) rather than an MCP
# server name?
is_command_starter() {
    case "$1" in
        npx|npx.cmd|npx.exe|npm|npm.cmd|bun|bunx|node|node.exe|deno|python|python3)
            return 0 ;;
    esac
    [[ "$1" == */* ]] && return 0
    return 1
}

# Connected / disconnected / unknown for an entry header line.
list_entry_status() {
    local norm="$1"
    case " $norm " in
        *" disconnected "*) printf 'disconnected' ;;
        *" connected "*)    printf 'connected' ;;
        *)                  printf 'unknown' ;;
    esac
}

# Name from an entry header line: drop a trailing status keyword (and, when
# name + command share a line, the command itself) so multi-word names are kept.
list_entry_name() {
    local norm="$1"
    norm="$(printf '%s\n' "$norm" | sed -r 's/[[:space:]]+(connected|disconnected|pending|failed|disabled|needs[_-]?auth)[[:space:]]*$//I')"
    printf '%s\n' "$norm" | sed -r 's/[[:space:]]+(npx|npx\.cmd|npx\.exe|npm|npm\.cmd|bun|bunx|node|node\.exe|deno|python|python3)([[:space:]].*)?$//'
}

# Extract the --host / --port value from an MCP command line, if present.
command_host_port() {
    local cmdline="$1" which="$2"
    case "$which" in
        host)
            printf '%s\n' "$cmdline" | sed -n -r 's/.*--host[= ][[:space:]]*([^[:space:]]+).*/\1/p' | head -n1
            ;;
        port)
            printf '%s\n' "$cmdline" | sed -n -r 's/.*--port[= ][[:space:]]*([^[:space:]]+).*/\1/p' | head -n1
            ;;
    esac
}

check_opencode_mcp() {
    MCP_CONFIGURED="missing"
    MCP_STATUS="unknown"
    MCP_NOTE=""
    MCP_FOUND_NAME=""
    MCP_FOUND_BACKEND=""
    MCP_FOUND_HOST=""
    MCP_FOUND_PORT=""

    command -v opencode >/dev/null 2>&1 || return 1

    local out list line norm first
    local entry_name="" entry_status=""
    local match_name="" match_status=""
    local cmdline=""
    local found="" named_seen=""

    out="$(opencode mcp list 2>&1 || true)"
    list="$(printf '%s\n' "$out" | sed -r 's/\x1B\[[0-9;]*[mK]//g' | tr -d '\r')"

    while IFS= read -r line; do
        norm="$(strip_list_formatting "$line")"
        [[ -z "$norm" ]] && continue

        if [[ "$norm" == *"binary-ninja-mcp"* ]]; then
            # Command line for the Binary Ninja MCP backend.
            cmdline="$norm"
            first="${norm%% *}"
            if ! is_command_starter "$first"; then
                # Name and command share the same line.
                entry_name="$(list_entry_name "$norm")"
                entry_status="$(list_entry_status "$norm")"
            fi
            if [[ -n "$entry_name" ]]; then
                found="1"
                if [[ -z "$match_name" || "$entry_name" == "$MCP_NAME" ]]; then
                    match_name="$entry_name"
                    match_status="$entry_status"
                fi
            fi
            continue
        fi

        first="${norm%% *}"
        if is_command_starter "$first"; then
            continue
        fi
        [[ "$norm" == "MCP Servers" ]] && continue
        [[ "$norm" =~ ^[0-9]+[[:space:]]+server\(s\)$ ]] && continue

        entry_name="$(list_entry_name "$norm")"
        entry_status="$(list_entry_status "$norm")"
        [[ "$entry_name" == "$MCP_NAME" ]] && named_seen="1"
    done <<< "$list"

    if [[ -n "$found" ]]; then
        MCP_CONFIGURED="configured"
        MCP_STATUS="${match_status:-unknown}"
        MCP_FOUND_NAME="$match_name"
        MCP_FOUND_BACKEND="binary-ninja-mcp"
        MCP_FOUND_HOST="$(command_host_port "$cmdline" host)"
        MCP_FOUND_PORT="$(command_host_port "$cmdline" port)"
    elif [[ -n "$named_seen" ]]; then
        MCP_NOTE="a server named '$MCP_NAME' exists but does not use binary-ninja-mcp"
    fi
}

# Launch OpenCode's own wizard, then verify the result. The wizard is
# interactive (OpenCode's supported CLI exposes no documented non-interactive
# flags for a local server's type/command), so the required values are printed
# first and the result is checked with `opencode mcp list` afterwards.
configure_opencode_mcp() {
    command -v opencode >/dev/null 2>&1 || {
        printf 'OpenCode is not installed. Run "Setup / repair" first.\n' >&2
        return 1
    }

    printf '\nOpenCode will configure the MCP server itself.\n'
    printf 'In the wizard choose:\n'
    printf '  Type:    Local\n'
    printf '  Name:    %s\n' "$MCP_NAME"
    printf '  Command: %s\n' "$MCP_COMMAND"
    printf '\n'

    read -r -p "Launch 'opencode mcp add' now? [Y/n] " answer
    case "${answer:-Y}" in
        [Yy]|[Yy][Ee][Ss])
            opencode mcp add
            printf '\nVerifying configuration...\n'
            opencode mcp list || true
            ;;
        *)
            printf 'Skipped. Run it later with:\n'
            printf '  opencode mcp add\n'
            printf '  Name: %s, Command: %s\n' "$MCP_NAME" "$MCP_COMMAND"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Status report
# ---------------------------------------------------------------------------
render_status() {
    detect_os
    check_dependencies
    check_bn_endpoint
    check_opencode_mcp
    check_mirrored_networking
    check_wsl_arrangement

    printf '\nBinary Ninja MCP\n'
    printf '================\n'
    printf '\n'
    printf 'Environment:\n'
    printf '  OS: %s\n' "$OS_LABEL"
    printf '  WSL: %s\n' "$WSL"
    printf '\n'
    printf 'Dependencies:\n'
    printf '  Node:       %s\n' "$NODE_STATUS"
    printf '  npm:        %s\n' "$NPM_STATUS"
    printf '  npx:        %s\n' "$NPX_STATUS"
    printf '  OpenCode:   %s\n' "$OPENCODE_STATUS"
    printf '\n'
    printf 'Binary Ninja:\n'
    printf '  %s:%s: %s\n' "$BN_HOST" "$BN_PORT" "$BN_STATUS"
    if [[ -n "$BN_NOTE" ]]; then
        printf '    %s\n' "$BN_NOTE"
    fi
    printf '\n'
    printf 'OpenCode MCP:\n'
    if [[ "$MCP_CONFIGURED" == "configured" ]]; then
        printf '  found:   yes\n'
        printf '  name:    %s\n' "$MCP_FOUND_NAME"
        printf '  backend: %s\n' "$MCP_FOUND_BACKEND"
        if [[ -n "$MCP_FOUND_HOST" ]]; then
            printf '  host:    %s\n' "$MCP_FOUND_HOST"
            printf '  port:    %s\n' "$MCP_FOUND_PORT"
        fi
    else
        printf '  found:   no\n'
    fi
    printf '  status:  %s\n' "$MCP_STATUS"
    if [[ -n "$MCP_NOTE" ]]; then
        printf '    %s\n' "$MCP_NOTE"
    fi
    if [[ "$WSL" == "yes" ]]; then
        printf '\n'
        printf 'WSL networking:\n'
        printf '  Windows interop: %s\n' "$(windows_interop_available && printf 'available' || printf 'unavailable')"
        printf '  mirrored networking: %s\n' "$MIRRORED_STATUS"
    fi
    printf '\n'
}

# ---------------------------------------------------------------------------
# Setup / repair
# ---------------------------------------------------------------------------
setup_tools() {
    printf '\nSetup / repair\n'
    detect_os
    check_dependencies
    check_bn_endpoint
    check_opencode_mcp

    local rc=0

    if [[ "$NODE_STATUS" == "found" && "$NPM_STATUS" == "found" && "$NPX_STATUS" == "found" ]]; then
        printf 'Node toolchain already available: %s\n' "$(node --version)"
    else
        printf 'Node toolchain incomplete (node=%s npm=%s npx=%s).\n' \
            "$NODE_STATUS" "$NPM_STATUS" "$NPX_STATUS"
        read -r -p "Install the missing Node toolchain via the system package manager? [Y/n] " answer
        case "${answer:-Y}" in
            [Yy]|[Yy][Ee][Ss]) install_node_toolchain || rc=1 ;;
            *) printf 'Skipped. Install Node.js LTS and re-run setup.\n' ;;
        esac
    fi

    if [[ "$OPENCODE_STATUS" == "found" ]]; then
        printf 'OpenCode already available: %s\n' "$(opencode --version)"
    else
        printf 'OpenCode is missing.\n'
        read -r -p "Install OpenCode from the official installer? [Y/n] " answer
        case "${answer:-Y}" in
            [Yy]|[Yy][Ee][Ss]) install_opencode || rc=1 ;;
            *) printf 'Skipped. Install OpenCode and re-run setup.\n' ;;
        esac
    fi

    if [[ "$WSL" == "yes" ]]; then
        if windows_interop_available; then
            printf 'Windows interop: available\n'
            check_mirrored_networking
            if [[ "$MIRRORED_STATUS" != "mirrored" ]]; then
                printf 'Mirrored networking is not active (%s).\n' "$MIRRORED_STATUS"
                read -r -p "Configure [wsl2] networkingMode=mirrored in .wslconfig? [Y/n] " answer
                case "${answer:-Y}" in
                    [Yy]|[Yy][Ee][Ss]) configure_mirrored_networking || rc=1 ;;
                    *) printf 'Skipped. localhost between Windows and WSL may not work.\n' ;;
                esac
            else
                printf 'Mirrored networking: active\n'
            fi
        else
            printf 'Windows interop: unavailable (powershell.exe/wslpath missing).\n'
        fi
    fi

    if [[ "$MCP_CONFIGURED" != "configured" ]]; then
        printf '\nThe %s MCP server is not configured in OpenCode.\n' "$MCP_NAME"
        read -r -p "Configure it now? [Y/n] " answer
        case "${answer:-Y}" in
            [Yy]|[Yy][Ee][Ss]) configure_opencode_mcp || rc=1 ;;
            *) printf 'Skipped. Use "Configure OpenCode MCP" later.\n' ;;
        esac
    fi

    printf '\nDone. Current status:\n'
    render_status
    return $rc
}

# ---------------------------------------------------------------------------
# Connection test
# ---------------------------------------------------------------------------
test_connection() {
    detect_os
    check_bn_endpoint
    check_wsl_arrangement

    printf '\nBinary Ninja MCP connection\n'
    printf '  %s:%s: %s\n' "$BN_HOST" "$BN_PORT" "$BN_STATUS"
    if [[ -n "$BN_NOTE" ]]; then
        printf '  %s\n' "$BN_NOTE"
    fi
    printf '\n'
    printf 'In Binary Ninja: Plugins -> Start MCP Server.\n'
    printf 'From the terminal you can also try:\n'
    printf '  curl %s\n' "$BN_URL"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
show_menu() {
    printf 'Binary Ninja MCP\n'
    printf '================\n'
    printf '\n'
    printf '1) Setup / repair\n'
    printf '2) Show status\n'
    printf '3) Configure OpenCode MCP\n'
    printf '4) Test Binary Ninja connection\n'
    printf '5) Exit\n'
}

handle_choice() {
    local choice="$1"
    case "$choice" in
        1) setup_tools ;;
        2) render_status ;;
        3) configure_opencode_mcp ;;
        4) test_connection ;;
        5) exit 0 ;;
        *) printf 'Invalid selection.\n' ;;
    esac
}

main_loop() {
    local choice

    while true; do
        show_menu
        printf '\n'
        read -rp '> ' choice || { printf '\n'; exit 0; }
        handle_choice "$choice"
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    status|--status)
        render_status
        ;;
    --setup)
        setup_tools
        ;;
    --configure-opencode)
        configure_opencode_mcp
        ;;
    --test-connection)
        test_connection
        ;;
    '')
        main_loop
        ;;
    *)
        printf 'Usage: %s [status|--setup|--configure-opencode|--test-connection]\n' "$0" >&2
        exit 1
        ;;
esac