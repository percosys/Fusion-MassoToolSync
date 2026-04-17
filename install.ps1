# MassoToolSync for VCarve Pro - Installer
#
# This PowerShell script:
#   1. Detects the installed VCarve Pro version and its gadgets folder
#   2. Downloads the official SQLite3 CLI tools from sqlite.org
#   3. Copies the MassoToolSync_VCarve gadget into place
#   4. Extracts sqlite3.exe into the gadget's resources folder
#
# Usage (from the repo root):
#   Right-click -> Run with PowerShell
# Or from an elevated or regular PowerShell prompt:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# No admin rights are required because the target folder lives under
# Public Documents which is writable by any user.

[CmdletBinding()]
param(
    [string]$GadgetSource = "",
    [string]$SQLiteVersion = "3460000",  # Fallback if no local zip is found
    [switch]$SkipSQLite
)

$ErrorActionPreference = "Stop"

function Write-Step  { param($msg) Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK    { param($msg) Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2 { param($msg) Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err2  { param($msg) Write-Host "    $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Resolve the gadget source path
#
# Try multiple strategies because $PSScriptRoot can be empty depending on
# how the script is invoked (dot-sourced, param defaults, older PowerShell).
# ---------------------------------------------------------------------------

if (-not $GadgetSource) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue
    }
    if (-not $scriptDir) {
        $scriptDir = (Get-Location).Path
    }
    $GadgetSource = Join-Path $scriptDir "MassoToolSync_VCarve"
}

# If it still doesn't exist, try the current working directory
if (-not (Test-Path $GadgetSource)) {
    $fallback = Join-Path (Get-Location).Path "MassoToolSync_VCarve"
    if (Test-Path $fallback) {
        $GadgetSource = $fallback
    }
}

# ---------------------------------------------------------------------------
# 1. Locate the VCarve Pro gadgets folder
# ---------------------------------------------------------------------------

Write-Step "Locating VCarve Pro gadgets folder..."

$gadgetRoots = @(
    "$env:PUBLIC\Documents\Vectric Files\Gadgets",
    "C:\Users\Public\Documents\Vectric Files\Gadgets",
    "$env:ProgramData\Vectric\VCarve Pro\Gadgets",
    "$env:ProgramData\Vectric\Aspire\Gadgets"
)

$vcarveGadgetDir = $null
foreach ($root in $gadgetRoots) {
    if (Test-Path $root) {
        # Look for VCarve Pro V* or Aspire V* subfolder — pick the newest
        $candidates = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match "^(VCarve Pro|Aspire) V" } |
                      Sort-Object Name -Descending
        if ($candidates) {
            $vcarveGadgetDir = $candidates[0].FullName
            break
        }
    }
}

if (-not $vcarveGadgetDir) {
    Write-Err2 "Could not find a VCarve Pro or Aspire gadgets folder."
    Write-Err2 "Expected something like:"
    Write-Err2 "  C:\Users\Public\Documents\Vectric Files\Gadgets\VCarve Pro V12.5\"
    Write-Err2 ""
    Write-Err2 "Please install VCarve Pro first, or specify the path manually."
    exit 1
}

Write-OK "Found: $vcarveGadgetDir"

# ---------------------------------------------------------------------------
# 2. Validate the gadget source folder
# ---------------------------------------------------------------------------

Write-Step "Validating gadget source..."

if (-not (Test-Path $GadgetSource)) {
    Write-Err2 "Gadget source folder not found: $GadgetSource"
    Write-Err2 "Run this script from the repository root, or pass -GadgetSource <path>"
    exit 1
}

$mainLua = Join-Path $GadgetSource "MassoToolSync.lua"
if (-not (Test-Path $mainLua)) {
    Write-Err2 "Main gadget file missing: $mainLua"
    exit 1
}

Write-OK "Gadget source: $GadgetSource"

# ---------------------------------------------------------------------------
# 3. Download and extract sqlite3.exe (optional)
# ---------------------------------------------------------------------------

$gadgetDestName = Split-Path $GadgetSource -Leaf
$gadgetDest     = Join-Path $vcarveGadgetDir $gadgetDestName
$resourcesDir   = Join-Path $GadgetSource   "resources"
$sqliteTarget   = Join-Path $resourcesDir   "sqlite3.exe"

if ($SkipSQLite) {
    Write-Step "Skipping SQLite download (--SkipSQLite)"
} elseif (Test-Path $sqliteTarget) {
    Write-Step "SQLite3.exe already present, skipping download"
    Write-OK "Found: $sqliteTarget"
} else {
    # Check if the user already has a sqlite-tools zip locally (in script dir
    # or current directory) and use that instead of re-downloading.
    $searchDirs = @((Split-Path -Parent $GadgetSource), (Get-Location).Path)
    $localZip = $null
    foreach ($dir in $searchDirs) {
        if ($dir) {
            $found = Get-ChildItem -Path $dir -Filter "sqlite-tools-win-x64-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $localZip = $found.FullName; break }
        }
    }

    if ($localZip) {
        Write-Step "Found local SQLite zip, using it instead of downloading"
        Write-OK "Source: $localZip"
    } else {
        Write-Step "Downloading SQLite3 CLI tools from sqlite.org..."
    }

    $sqliteUrl = "https://www.sqlite.org/2024/sqlite-tools-win-x64-$SQLiteVersion.zip"
    $tempZip   = Join-Path $env:TEMP "sqlite-tools-$SQLiteVersion.zip"
    $tempDir   = Join-Path $env:TEMP "sqlite-tools-$SQLiteVersion"

    try {
        if ($localZip) {
            Copy-Item $localZip $tempZip -Force
            Write-OK "Copied local zip to: $tempZip"
        } else {
            Write-OK "URL: $sqliteUrl"

            # Force TLS 1.2 for older PowerShell versions
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            Invoke-WebRequest -Uri $sqliteUrl -OutFile $tempZip -UseBasicParsing
            Write-OK "Downloaded to: $tempZip"
        }

        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
        Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
        Write-OK "Extracted to: $tempDir"

        $foundExe = Get-ChildItem -Path $tempDir -Recurse -Filter "sqlite3.exe" |
                    Select-Object -First 1
        if (-not $foundExe) {
            throw "sqlite3.exe not found in extracted archive"
        }

        if (-not (Test-Path $resourcesDir)) {
            New-Item -ItemType Directory -Path $resourcesDir -Force | Out-Null
        }
        Copy-Item -Path $foundExe.FullName -Destination $sqliteTarget -Force
        Write-OK "Placed sqlite3.exe at: $sqliteTarget"

        # Cleanup temp files
        Remove-Item $tempZip  -Force -ErrorAction SilentlyContinue
        Remove-Item $tempDir  -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warn2 "Could not download sqlite3.exe: $($_.Exception.Message)"
        Write-Warn2 "You can still use the gadget with CSV or Fusion file sources."
        Write-Warn2 "To add sqlite3 manually later, download from https://sqlite.org/download.html"
        Write-Warn2 "and place sqlite3.exe at: $sqliteTarget"
    }
}

# ---------------------------------------------------------------------------
# 4. Copy the gadget into the VCarve gadgets folder
# ---------------------------------------------------------------------------

Write-Step "Installing gadget to VCarve..."

# Preserve the tool-groups cache across reinstalls. Regenerating it costs
# ~5 seconds of sqlite3 subprocess time on Parallels, and the cache is
# auto-invalidated anyway when the .vtdb file size changes.
# Check for both the current name (.dat) and the legacy name (.lua).
$savedCache = $null
foreach ($name in @("groups_cache.dat", "groups_cache.lua")) {
    $maybe = Join-Path $gadgetDest $name
    if (Test-Path $maybe) {
        $savedCache = Get-Content $maybe -Raw -Encoding UTF8
        Write-OK "Preserving $name across reinstall"
        break
    }
}

if (Test-Path $gadgetDest) {
    Write-Warn2 "Existing installation found -- removing: $gadgetDest"
    Remove-Item $gadgetDest -Recurse -Force
}

Copy-Item -Path $GadgetSource -Destination $gadgetDest -Recurse -Force
Write-OK "Gadget copied to: $gadgetDest"

if ($savedCache) {
    Set-Content -Path (Join-Path $gadgetDest "groups_cache.dat") `
                -Value $savedCache -Encoding UTF8
    Write-OK "Restored groups_cache.dat"
}

# ---------------------------------------------------------------------------
# 4.5 Prime the tool-groups cache
#
# The first-time sqlite3 query for tool groups takes ~5 seconds on
# Parallels (subprocess spawn overhead). We can eliminate that cold-start
# penalty by priming the cache right now from the installer, which
# already has sqlite3.exe in hand. The gadget will then find a valid
# cache on the very first open.
# ---------------------------------------------------------------------------

function Escape-LuaString {
    param([string]$s)
    if ($null -eq $s) { return 'nil' }
    $escaped = $s -replace '\\', '\\\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n'
    return '"' + $escaped + '"'
}

function Prime-GroupsCache {
    param(
        [string]$SqliteExe,
        [string]$DbPath,
        [string]$CachePath
    )

    try {
        $sql = "SELECT id, name, parent_group_id FROM tool_tree_entry WHERE tool_geometry_id IS NULL ORDER BY name"
        $csvOutput = & $SqliteExe -csv -header $DbPath $sql 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0 -or -not $csvOutput) {
            Write-Warn2 "sqlite3 query returned no output; skipping cache prime"
            return $false
        }

        $rows = $csvOutput | ConvertFrom-Csv
        if (-not $rows) {
            Write-Warn2 "No tool groups found in database; skipping cache prime"
            return $false
        }

        # Build lookup and group list
        $byId = @{}
        $groups = @()
        foreach ($row in $rows) {
            $parent = if ([string]::IsNullOrEmpty($row.parent_group_id)) { $null } else { $row.parent_group_id }
            $g = [PSCustomObject]@{
                id        = $row.id
                name      = $row.name
                parent_id = $parent
                path      = $null
            }
            $byId[$g.id] = $g
            $groups += $g
        }

        # Compute "Parent > Child" paths
        foreach ($g in $groups) {
            $parts = New-Object System.Collections.ArrayList
            [void]$parts.Add($g.name)
            $current = $g.parent_id
            $safety = 0
            while ($current -and $byId.ContainsKey($current) -and $safety -lt 20) {
                [void]$parts.Insert(0, $byId[$current].name)
                $current = $byId[$current].parent_id
                $safety++
            }
            $g.path = $parts -join ' > '
        }

        # Sort by path to match the Lua serializer's ordering
        $sortedGroups = $groups | Sort-Object path

        # File size for cache-validity check
        $dbSize = (Get-Item $DbPath).Length

        # Build the Lua-syntax cache content
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("return {")
        [void]$sb.AppendLine("  db_size = $dbSize,")
        [void]$sb.AppendLine("  groups = {")
        foreach ($g in $sortedGroups) {
            $idStr     = Escape-LuaString $g.id
            $nameStr   = Escape-LuaString $g.name
            $parentStr = if ($null -eq $g.parent_id) { 'nil' } else { Escape-LuaString $g.parent_id }
            $pathStr   = Escape-LuaString $g.path
            [void]$sb.AppendLine("    { id = $idStr, name = $nameStr, parent_id = $parentStr, path = $pathStr },")
        }
        [void]$sb.AppendLine("  },")
        [void]$sb.AppendLine("}")

        [System.IO.File]::WriteAllText(
            $CachePath,
            $sb.ToString(),
            (New-Object System.Text.UTF8Encoding($false))
        )
        return $groups.Count
    } catch {
        Write-Warn2 "Failed to prime cache: $($_.Exception.Message)"
        return $false
    }
}

Write-Step "Priming tool-groups cache..."

# Locate a tools.vtdb file. VCarve's schema puts it under either
# C:\ProgramData\Vectric\... or the Public Documents Vectric Files folder.
$vtdbPath = $null
$vtdbRoots = @(
    "$env:ProgramData\Vectric",
    "$env:PUBLIC\Documents\Vectric Files",
    "C:\Users\Public\Documents\Vectric Files"
)
foreach ($root in $vtdbRoots) {
    if (Test-Path $root) {
        $found = Get-ChildItem -Path $root -Recurse -Filter "tools.vtdb" `
                    -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First 1
        if ($found) {
            $vtdbPath = $found.FullName
            break
        }
    }
}

if (-not $vtdbPath) {
    Write-Warn2 "VCarve tool database not found; cache will be built on first gadget open"
} elseif (-not (Test-Path $sqliteTarget)) {
    Write-Warn2 "sqlite3.exe not installed; cache will be built on first gadget open"
} else {
    Write-OK "Database: $vtdbPath"
    $cachePath = Join-Path $gadgetDest "groups_cache.dat"
    $count = Prime-GroupsCache -SqliteExe $sqliteTarget -DbPath $vtdbPath -CachePath $cachePath
    if ($count) {
        Write-OK "Primed cache with $count tool groups"
    }
}

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  MASSO Tool Sync installed successfully" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Close VCarve Pro if it is running"
Write-Host "  2. Re-open VCarve Pro"
Write-Host "  3. Open Gadgets menu -> MassoToolSync"
Write-Host ""
