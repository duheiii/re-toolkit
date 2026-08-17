param(
    # menu (default) | status | setup | configure | test
    [ValidateSet("menu", "status", "setup", "configure", "test")]
    [string]$Action = "menu"
)

$ErrorActionPreference = "Stop"

# Binary Ninja MCP setup / check / repair for OpenCode (native Windows).
#
# This tool ONLY prepares and checks the AI <-> Binary Ninja MCP integration:
#   * Node/npm/npx and OpenCode availability
#   * the Binary Ninja MCP server on localhost:9009
#   * OpenCode's MCP configuration for the `binary-ninja` server
#
# It does NOT manage debugger servers (see re-tools\remote-debug\debug-server.ps1).
#
# Node/npm/npx are never installed through NVM; if already present they are
# left untouched. Missing pieces are installed with supported Windows methods
# (winget, npm -g). OpenCode is checked before any install is attempted.
#
# OpenCode's own `opencode mcp add` wizard is used for configuration instead
# of editing OpenCode's internal config directly.

$Script:McpName = "binary-ninja"
$Script:McpCommand = "npx -y binary-ninja-mcp --host localhost --port 9009"
$Script:BnHost = "localhost"
$Script:BnPort = 9009

$Script:NodeStatus = "missing"
$Script:NpmStatus = "missing"
$Script:NpxStatus = "missing"
$Script:OpencodeStatus = "missing"
$Script:BnStatus = "unreachable"
$Script:BnNote = ""
$Script:McpConfigured = "missing"
$Script:McpStatus = "unknown"
$Script:McpNote = ""

function Test-Tool {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Check-Dependencies {
    $Script:NodeStatus = if (Test-Tool "node") { "found" } else { "missing" }
    $Script:NpmStatus = if (Test-Tool "npm") { "found" } else { "missing" }
    $Script:NpxStatus = if (Test-Tool "npx") { "found" } else { "missing" }
    $Script:OpencodeStatus = if (Test-Tool "opencode") { "found" } else { "missing" }
}

function Test-BnEndpoint {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Script:BnHost, $Script:BnPort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(3000)) {
            $client.Close()
            return $false
        }
        $client.EndConnect($async)
        $client.Close()
        return $true
    } catch {
        $client.Close()
        return $false
    }
}

function Check-BnEndpoint {
    $Script:BnNote = ""
    if (Test-BnEndpoint) {
        $Script:BnStatus = "reachable"
    } else {
        $Script:BnStatus = "unreachable"
        $Script:BnNote = "Is Binary Ninja running with its MCP server started?"
    }
}

function Get-OpencodeMcpList {
    if (-not (Test-Tool "opencode")) {
        return $null
    }
    $out = & opencode mcp list 2>&1 | Out-String
    $out = $out -replace "\x1b\[[0-9;]*[mK]", ""
    return $out
}

function Check-OpencodeMcp {
    $Script:McpConfigured = "missing"
    $Script:McpStatus = "unknown"
    $Script:McpNote = ""

    $list = Get-OpencodeMcpList
    if ($null -eq $list) {
        return
    }

    $found = $false
    # Match the server name as a standalone token, not as part of the command
    # line (e.g. `binary-ninja-mcp` must not match a server named `binary-ninja`).
    $nameRe = "(^|[^a-zA-Z0-9_-])$($Script:McpName)([^a-zA-Z0-9_-]|$)"
    foreach ($line in ($list -split "`r?`n")) {
        if ($line -match $nameRe) {
            $found = $true
            if ($line -match "connected") {
                $Script:McpStatus = "connected"
            } elseif ($line -match "disconnected") {
                $Script:McpStatus = "disconnected"
            } else {
                $Script:McpStatus = "unknown"
            }
        }
    }

    if ($found) {
        $Script:McpConfigured = "configured"
    }

    if ($list -match "binary-ninja-mcp" -and $Script:McpConfigured -eq "missing") {
        $Script:McpNote = "an equivalent server using binary-ninja-mcp exists under another name"
    }
}

function Show-Status {
    Check-Dependencies
    Check-BnEndpoint
    Check-OpencodeMcp

    Write-Host ""
    Write-Host "Binary Ninja MCP"
    Write-Host "================"
    Write-Host ""
    Write-Host "Environment:"
    Write-Host "  OS: Windows"
    Write-Host "  WSL: no"
    Write-Host ""
    Write-Host "Dependencies:"
    Write-Host "  Node:       $($Script:NodeStatus)"
    Write-Host "  npm:        $($Script:NpmStatus)"
    Write-Host "  npx:        $($Script:NpxStatus)"
    Write-Host "  OpenCode:   $($Script:OpencodeStatus)"
    Write-Host ""
    Write-Host "Binary Ninja:"
    Write-Host "  $($Script:BnHost):$($Script:BnPort): $($Script:BnStatus)"
    if ($Script:BnNote) {
        Write-Host "    $($Script:BnNote)"
    }
    Write-Host ""
    Write-Host "OpenCode MCP:"
    Write-Host "  $($Script:McpName): $($Script:McpConfigured)"
    Write-Host "  status: $($Script:McpStatus)"
    if ($Script:McpNote) {
        Write-Host "    $($Script:McpNote)"
    }
    Write-Host ""
}

function Install-NodeToolchain {
    Write-Host "Installing Node.js LTS (includes npm and npx)..."
    if (Test-Tool "winget") {
        & winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: winget install failed (exit $LASTEXITCODE)." -ForegroundColor Red
            Write-Host "Install Node.js LTS from https://nodejs.org and reopen the terminal, then re-run setup." -ForegroundColor Red
            return $false
        }
    } else {
        Write-Host "winget is not available." -ForegroundColor Yellow
        Write-Host "Install Node.js LTS from https://nodejs.org and reopen the terminal, then re-run setup." -ForegroundColor Yellow
        return $false
    }

    # PATH changes from winget only take effect in new shells; help the user here.
    Write-Host "If 'node' is not recognized, close and reopen the terminal so the new PATH is picked up."
    return $true
}

function Install-Opencode {
    Write-Host "Installing OpenCode..."
    if (Test-Tool "npm") {
        & npm install -g opencode-ai@latest
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    if (Test-Tool "winget") {
        & winget install -e --id opencode --accept-source-agreements --accept-package-agreements
        return ($LASTEXITCODE -eq 0)
    }
    if (Test-Tool "choco") {
        & choco install opencode -y
        return ($LASTEXITCODE -eq 0)
    }
    if (Test-Tool "scoop") {
        & scoop install opencode
        return ($LASTEXITCODE -eq 0)
    }
    Write-Host "ERROR: could not find a supported installer (npm / winget / choco / scoop)." -ForegroundColor Red
    Write-Host "Install OpenCode per https://opencode.ai/docs and reopen the terminal, then re-run setup." -ForegroundColor Red
    return $false
}

function Set-OpencodeMcp {
    if (-not (Test-Tool "opencode")) {
        Write-Host "OpenCode is not installed. Run 'Setup / repair' first." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "OpenCode will configure the MCP server itself."
    Write-Host "In the wizard choose:"
    Write-Host "  Type:    Local"
    Write-Host "  Name:    $($Script:McpName)"
    Write-Host "  Command: $($Script:McpCommand)"
    Write-Host ""

    $answer = Read-Host "Launch 'opencode mcp add' now? [Y/n]"
    if ($answer -match "^[Yy]|^$") {
        & opencode mcp add
        Write-Host ""
        Write-Host "Verifying configuration..."
        & opencode mcp list
    } else {
        Write-Host "Skipped. Run it later with:"
        Write-Host "  opencode mcp add"
        Write-Host "  Name: $($Script:McpName), Command: $($Script:McpCommand)"
    }
}

function Setup-Tools {
    Write-Host ""
    Write-Host "Setup / repair"
    Check-Dependencies
    Check-BnEndpoint
    Check-OpencodeMcp

    if ($Script:NodeStatus -eq "found" -and $Script:NpmStatus -eq "found" -and $Script:NpxStatus -eq "found") {
        Write-Host "Node toolchain already available: $(node --version)"
    } else {
        Write-Host "Node toolchain incomplete (node=$($Script:NodeStatus) npm=$($Script:NpmStatus) npx=$($Script:NpxStatus))."
        $answer = Read-Host "Install the missing Node toolchain? [Y/n]"
        if ($answer -match "^[Yy]|^$") {
            $null = Install-NodeToolchain
        } else {
            Write-Host "Skipped. Install Node.js LTS and re-run setup."
        }
    }

    if ($Script:OpencodeStatus -eq "found") {
        Write-Host "OpenCode already available: $(opencode --version)"
    } else {
        Write-Host "OpenCode is missing."
        $answer = Read-Host "Install OpenCode? [Y/n]"
        if ($answer -match "^[Yy]|^$") {
            $null = Install-Opencode
        } else {
            Write-Host "Skipped. Install OpenCode and re-run setup."
        }
    }

    if ($Script:McpConfigured -ne "configured") {
        Write-Host ""
        Write-Host "The $($Script:McpName) MCP server is not configured in OpenCode."
        $answer = Read-Host "Configure it now? [Y/n]"
        if ($answer -match "^[Yy]|^$") {
            Set-OpencodeMcp
        } else {
            Write-Host "Skipped. Use 'Configure OpenCode MCP' later."
        }
    }

    Write-Host ""
    Write-Host "Done. Current status:"
    Show-Status
}

function Test-Connection {
    Check-BnEndpoint

    Write-Host ""
    Write-Host "Binary Ninja MCP connection"
    Write-Host "  $($Script:BnHost):$($Script:BnPort): $($Script:BnStatus)"
    if ($Script:BnNote) {
        Write-Host "  $($Script:BnNote)"
    }
    Write-Host ""
    Write-Host "In Binary Ninja: Plugins -> Start MCP Server."
    Write-Host "From the terminal you can also try:"
    Write-Host "  curl http://$($Script:BnHost):$($Script:BnPort)/"
    Write-Host ""
}

function Show-Menu {
    Write-Host "1) Setup / repair"
    Write-Host "2) Show status"
    Write-Host "3) Configure OpenCode MCP"
    Write-Host "4) Test Binary Ninja connection"
    Write-Host "5) Exit"
}

function Invoke-Menu {
    while ($true) {
        Show-Status
        Show-Menu
        Write-Host ""
        $choice = Read-Host ">"
        switch ($choice) {
            "1" { Setup-Tools }
            "2" { Show-Status }
            "3" { Set-OpencodeMcp }
            "4" { Test-Connection }
            "5" { return }
            default { Write-Host "Invalid selection." }
        }
    }
}

switch ($Action) {
    "status" { Show-Status }
    "setup" { Setup-Tools }
    "configure" { Set-OpencodeMcp }
    "test" { Test-Connection }
    "menu" { Invoke-Menu }
}