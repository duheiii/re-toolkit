# RE Debugger Server

State-driven debugger-server management for reverse engineering work.

- Linux: persistent `lldb-server`
- Windows: `dbgsrv.exe` via PowerShell (directly, or through WSL interop)

Run:

```bash
./debug-server.sh
```

or, directly from Windows PowerShell:

```powershell
.\debug-server.ps1
```

The debugger server is a state-driven, persistent workflow: it starts a server
once, shows its status on every run, and only stops processes it can positively
identify as its own from its state files.

## Menu

The Linux entry point (`debug-server.sh`) renders a menu that always shows the
current state first:

- Status (Linux and Windows servers)
- Start server (Linux / Windows)
- Stop server
- Stop all Rot debug servers (emergency, ownership-verified only)
- Setup / repair debugger tools

When a server is running the menu shrinks to `Stop server` / `Stop all Rot
debug servers` / `Exit`.

## Linux server

```text
lldb-server
persistent server mode
default bind: 127.0.0.1
default port: 31337
```

Use "Setup / repair debugger tools" to install `lldb-server` (via `pacman` or
`apt-get`) if it is missing. Binary Ninja's managed debugger package is
preferred when present at:

```text
~/.local/share/rot-tools/debuggers/binary-ninja/linux/plugins/lldb/lldb-server
```

The resolution order is: explicit `LLDB_SERVER`, then the managed Binary Ninja
package, then legacy managed layouts, then `lldb-server` from `PATH`.

In Binary Ninja:

- Debugger → Connect to Remote Process
- Adapter: `LLDB`
- Address: `localhost`
- Port: `31337`

The Linux server is persistent; it stays running between sessions and is
stopped from this menu (`Stop server` / `Stop all Rot debug servers`).

## Windows server

```text
dbgsrv.exe
invoked through PowerShell / WSL interop when available
default bind: 127.0.0.1
default port: 31338
```

`debug-server.sh` delegates Windows management to `debug-server.ps1` through
`powershell.exe` / `wslpath` when WSL interop is available.

You can also run the PowerShell script directly from Windows, without WSL:

```powershell
.\debug-server.ps1
```

Typical direct use:

```powershell
.\debug-server.ps1 -Action Status
.\debug-server.ps1 -Action Start -Port 31338
.\debug-server.ps1 -Action Stop
.\debug-server.ps1 -Action Probe   # read-only: reports whether dbgsrv.exe can be located
```

`dbgsrv.exe` is located via `DBGSRV_PATH`, `BN_DEBUGGER_WIN32`, a local
`debugger-win32` package next to the script, or the Windows SDK Debugging Tools
installation.

If Windows interop is available but `dbgsrv.exe` cannot be resolved,
"Setup / repair debugger tools" automatically installs Microsoft's official
Debugging Tools for Windows: it downloads `winsdksetup.exe`, runs only the
Debugging Tools feature (`/features OptionId.WindowsDesktopDebuggers /quiet
/norestart`), waits for completion, then re-resolves `dbgsrv.exe`. Success is
reported only when `dbgsrv.exe` is actually found afterward — never from the
installer exit code alone. You can run the same flow directly:

```powershell
.\debug-server.ps1 -Action Install
```

The Windows side records the PID, the resolved executable path, the process
start time, and the listen address in per-user state under
`%LOCALAPPDATA%\rot-tools\debug-server`. `Status` reports the recorded listen
address rather than the current defaults. A process is only stopped when all
recorded identity fields still match; stale or unverifiable PIDs are never
killed.

Startup captures the executable path and start time of the just-launched
process before writing any state. If that identity cannot be captured, the
process is terminated and startup fails — no state is written from a guess.

The Linux menu reports `Windows interop: available/unavailable` (whether
`powershell.exe`/`wslpath` work) separately from
`Windows debugger: found (path)/missing` (whether `dbgsrv.exe` resolves).

## Stop safety

"Stop all Rot debug servers" only stops servers positively identified from
Rot-owned state files. It never runs `pkill`/`killall lldb-server`/`taskkill
/IM dbgsrv.exe`. Unverifiable processes are refused and reported.

## Environment overrides

All settings have localhost-only defaults and can be overridden through the
environment:

| Variable               | Default        | Purpose                                     |
| ---------------------- | -------------- | ------------------------------------------- |
| `ROT_DEBUG_LINUX_BIND` | `127.0.0.1`    | Linux lldb-server bind address              |
| `ROT_DEBUG_LINUX_PORT` | `31337`        | Linux lldb-server port                      |
| `ROT_DEBUG_WINDOWS_BIND` | `127.0.0.1`  | Windows dbgsrv.exe bind address             |
| `ROT_DEBUG_WINDOWS_PORT` | `31338`      | Windows dbgsrv.exe port                     |
| `ROT_DEBUG_WINDOWS_ARCH` | `amd64`      | `dbgsrv.exe` architecture (`amd64`/`x86`)   |
| `LLDB_SERVER`          | (unset)        | Explicit path to `lldb-server`              |
| `ROT_DEBUG_SUDO`       | `sudo`         | Elevation command for package installs      |
| `ROT_DEBUG_TERM_WAIT`  | `2`            | Graceful-stop window (seconds) before SIGKILL |

Windows side (in `debug-server.ps1`): `DBGSRV_PATH`, `BN_DEBUGGER_WIN32`,
`ROT_DEBUG_WIN_STATE_DIR`. Test-only overrides (`ROT_DEBUG_WIN_INSTALL_URL`,
`ROT_DEBUG_WIN_INSTALL_EXE`, `ROT_DEBUG_WIN_INSTALL_ARGS`,
`ROT_DEBUG_WIN_FORCE_NO_IDENTITY`) are documented in the script.

## State files

- Linux: `$XDG_STATE_HOME/rot-tools/debug-server/linux.state` and
  `lldb-server.log` (default `~/.local/state/...`)
- Windows: `%LOCALAPPDATA%\rot-tools\debug-server\dbgsrv.state`

## Tests

Linux test suite (self-contained; uses fake tools, never touches the host):

```bash
./tests/test-debug-server.sh
```

Windows ownership/lifecycle tests (Windows-only live-process cases SKIP on
non-Windows hosts):

```powershell
.\tests\test-windows-ownership.ps1
```