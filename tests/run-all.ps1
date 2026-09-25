# StorageAuction repo test runner (Windows PowerShell).
#
# Stages src/shared + src/server modules flat (require rewrites only),
# copies tests/*.luau alongside, and runs every deterministic Lune suite:
#   harden1  - player-data lifecycle (ready/save gates, pending resolve, idempotent join)
#   harden2  - gameplay interactions (proximity, commitments, throttle, GUID, bounds)
#   conc3    - 3 simultaneous independent auction sessions
#   tier4    - Budget/Standard/HighRoller tiers + gates + generation
#   debt5a   - ATM loans, 25% debt split, recovery cooldown
#   persist5b- SA_M1_v1 schema, reconnect, autosave, failure safety
#   warehouse6 - warehouse levels, capacity gate, displays, plots
#   tiergen  - 10k generated units per tier (distribution audit)
#   main     - 1000-auction economy simulation (Standard session)
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1 -Quick   # skips main + tiergen
#
# Exit code 0 = every suite passed. Anything else failed (see table).
# Execution happens in a temp dir; the repo only gains test sources.
# Rojo never maps tests/ (see default.project.json).

param(
	[switch]$Quick,
	[string]$Lune = "D:\Roblox\Dev\lune\lune.exe",
	[string]$ExecDir = "D:\Roblox\Temp\sa-tests"
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $Lune)) {
	Write-Host "LUNE NOT FOUND at $Lune (pass -Lune <path>)"
	exit 2
}
if (-not (Test-Path $ExecDir)) {
	New-Item -ItemType Directory -Force -Path $ExecDir | Out-Null
}
# Clean slate (but keep the dir itself).
Get-ChildItem $ExecDir | Remove-Item -Recurse -Force

$files = @(
	@{ s = "src\shared\GameConfig.luau"; d = "GameConfig.luau" },
	@{ s = "src\shared\RarityConfig.luau"; d = "RarityConfig.luau" },
	@{ s = "src\shared\ItemDefinitions.luau"; d = "ItemDefinitions.luau" },
	@{ s = "src\shared\ItemUtils.luau"; d = "ItemUtils.luau" },
	@{ s = "src\server\UnitGeneratorService.luau"; d = "UnitGeneratorService.luau" },
	@{ s = "src\server\NPCBidderService.luau"; d = "NPCBidderService.luau" },
	@{ s = "src\server\MapBuilder.luau"; d = "MapBuilder.luau" },
	@{ s = "src\server\EconomyService.luau"; d = "EconomyService.luau" },
	@{ s = "src\server\PlayerStatsService.luau"; d = "PlayerStatsService.luau" },
	@{ s = "src\server\AuctionService.luau"; d = "AuctionService.luau" },
	@{ s = "src\server\DebtService.luau"; d = "DebtService.luau" },
	@{ s = "src\server\InventoryService.luau"; d = "InventoryService.luau" },
	@{ s = "src\server\PlayerDataService.luau"; d = "PlayerDataService.luau" },
	@{ s = "src\server\WarehouseService.luau"; d = "WarehouseService.luau" },
	@{ s = "src\server\DisplayService.luau"; d = "DisplayService.luau" },
	@{ s = "src\server\PlotService.luau"; d = "PlotService.luau" },
	@{ s = "src\server\RemoteGuardService.luau"; d = "RemoteGuardService.luau" }
)
foreach ($f in $files) {
	$src = Join-Path $repo $f.s
	if (-not (Test-Path $src)) {
		Write-Host "MISSING SOURCE: $($f.s)"
		exit 2
	}
	$t = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
	$t = [regex]::Replace($t, 'require\(Shared\.(\w+)\)', 'require("./$1")')
	$t = [regex]::Replace($t, 'require\(script\.Parent\.(\w+)\)', 'require("./$1")')
	[IO.File]::WriteAllText((Join-Path $ExecDir $f.d), $t, [Text.UTF8Encoding]::new($false))
}

$suites = @("harden1", "harden2", "conc3", "tier4", "debt5a", "persist5b", "warehouse6", "shutdown1")
if (-not $Quick) {
	$suites += @("tiergen", "main")
}
foreach ($s in $suites) {
	$src = Join-Path (Join-Path $repo "tests") ($s + ".luau")
	if (-not (Test-Path $src)) {
		Write-Host "MISSING SUITE: tests\$s.luau"
		exit 2
	}
	Copy-Item $src (Join-Path $ExecDir ($s + ".luau"))
}

$failed = @()
foreach ($s in $suites) {
	Write-Host "===== suite: $s ====="
	$logFile = Join-Path $ExecDir ("log_" + $s + ".txt")
	$code = 0
	try {
		& $Lune run (Join-Path $ExecDir ($s + ".luau")) > $logFile 2>&1
		$code = $LASTEXITCODE
	} catch {
		$code = 1
		"runner exception: " + $_.Exception.Message | Out-File -Append $logFile
	}
	$out = ""
	try { $out = Get-Content $logFile -Raw } catch { $out = "" }
	$tail = ($out -split "`r?`n" | Where-Object { $_ -match 'ALL PASS|FAILED|failures=|TEST: ' } | Select-Object -Last 6) -join "`n"
	Write-Host $tail
	$bad = $false
	if ($code -ne 0) { $bad = $true }
	if ($out -match 'FAILED') { $bad = $true }
	if ($out -match 'failures=([1-9][0-9]*)') { $bad = $true }
	if ($bad) {
		$failed += $s
		Write-Host "--> $s FAILED"
	} else {
		Write-Host "--> $s passed"
	}
}

Write-Host ""
Write-Host "suites run: $($suites.Count), failed: $($failed.Count)"
if ($failed.Count -gt 0) {
	Write-Host ("failed suites: " + ($failed -join ", "))
	exit 1
}
Write-Host "FULL SUITE: ALL PASS"
exit 0
