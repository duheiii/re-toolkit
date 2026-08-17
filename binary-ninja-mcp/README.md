# Binary Ninja MCP Setup

Prepares and checks the AI <-> Binary Ninja MCP integration for OpenCode.

This tool does **not** manage debugger servers. Debugger tooling lives in
[`re-tools/remote-debug/`](../remote-debug/).

The MCP connection it sets up:

```text
OpenCode
  ->  npx -y binary-ninja-mcp --host localhost --port 9009
  ->  Binary Ninja MCP server
```

Run it:

```bash
./mcp_configure.sh          # Linux or WSL (interactive menu)
./mcp_configure.sh status   # non-interactive status report
```

```powershell
.\mcp_configure.ps1         # native Windows (interactive menu)
.\mcp_configure.ps1 -Action status
```

## What it checks

```text
Environment:   OS, WSL yes/no
Dependencies:  Node, npm, npx, OpenCode (found/missing)
Binary Ninja:  localhost:9009 (reachable/unreachable)
OpenCode MCP:  found via its `binary-ninja-mcp` backend under any entry name
               (found yes/no, name, backend, host/port, connected/disconnected/unknown)
```

## Platform behavior

### Native Linux

- Checks Node/npm/npx and OpenCode.
- Checks the Binary Ninja MCP endpoint on `localhost:9009`.
- Checks OpenCode's MCP configuration/status via `opencode mcp list`.

### WSL

Everything from native Linux, plus:

- detects that Binary Ninja may be running on Windows;
- checks whether Windows interop (`powershell.exe` / `wslpath`) is available;
- checks whether the `localhost` arrangement needed for the MCP connection is
  usable from WSL (mirrored networking makes Windows `localhost` services
  reachable from WSL; otherwise Binary Ninja is reachable only via the Windows
  host IP);
- can set `[wsl2] networkingMode=mirrored` in the Windows `.wslconfig`,
  preserving all unrelated settings already present.

If `.wslconfig` changes, restart WSL once from Windows PowerShell:

```powershell
wsl --shutdown
```

### Native Windows

Equivalent behavior through `mcp_configure.ps1`:

- checks Node/npm/npx and OpenCode;
- checks `localhost:9009`;
- helps configure/test the Binary Ninja MCP connection.

## Install behavior

- Node/npm/npx are never installed through NVM. If they already work, they are
  left alone. Missing pieces are installed with the detected OS's supported
  method:
  - Linux: system package manager (`apt-get` / `pacman` / `dnf`)
  - Windows: `winget install OpenJS.NodeJS.LTS`
- OpenCode is checked before any install is attempted:
  - Linux/WSL: `curl -fsSL https://opencode.ai/install | bash`
  - Windows: `npm install -g opencode-ai@latest` (falling back to
    `winget`/`choco`/`scoop`)
- Existing user configuration is never modified unnecessarily.

## OpenCode MCP configuration

OpenCode's own supported CLI is used rather than editing OpenCode's internal
config:

```bash
opencode mcp add
```

Choose:

- Type: `Local`
- Name: `binary-ninja`
- Command:

```text
npx -y binary-ninja-mcp --host localhost --port 9009
```

The wizard is interactive (OpenCode exposes no documented non-interactive
flags for a local server's type/command). After the wizard finishes, the setup
tool verifies the result with `opencode mcp list`.

The MCP entry is detected by its command/backend (`binary-ninja-mcp`), not by
its name, so OpenCode users may name the entry anything (e.g. `binja`); the
tool then reports the actual discovered name. `binary-ninja` remains the
suggested name for new entries. A differently-named entry is never duplicated
by Setup / repair.

## Menu

```text
Binary Ninja MCP
================

1) Setup / repair
2) Show status
3) Configure OpenCode MCP
4) Test Binary Ninja connection
5) Exit
```

The interactive menu appears immediately without running the (slower) status
scan; the full scan runs only when an action needs it — "Show status",
Setup / repair, Configure OpenCode MCP, or Test Binary Ninja connection.

"Show status" (or `./mcp_configure.sh status`) renders:

```text
Binary Ninja MCP
================

Environment:
  OS: ...
  WSL: yes/no

Dependencies:
  Node:       found/missing
  npm:        found/missing
  npx:        found/missing
  OpenCode:   found/missing

Binary Ninja:
  localhost:9009: reachable/unreachable

OpenCode MCP:
  found:   yes/no
  name:    <discovered entry name>
  backend: binary-ninja-mcp
  host:    <configured host>
  port:    <configured port>
  status:  connected/disconnected/unknown
```

## Environment overrides (test- / integration-oriented)

| Variable        | Default      | Purpose                        |
| --------------- | ------------ | ------------------------------ |
| `ROT_MCP_NAME`  | `binary-ninja` | Preferred MCP server name for new entries; detection never requires it |
| `ROT_MCP_HOST`  | `localhost`  | Binary Ninja MCP host          |
| `ROT_MCP_PORT`  | `9009`       | Binary Ninja MCP port          |
| `ROT_MCP_SUDO`  | `sudo`       | Elevation command for package installs |

## Tests

```bash
./tests/test-mcp-setup.sh   # self-contained; uses fake tools
```