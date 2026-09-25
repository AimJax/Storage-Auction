# StorageAuction automated test suite

Deterministic [Lune](https://lune-org.github.io/docs) harnesses that run the
REAL game modules (staged flat, require-rewrites only) against mocked
Roblox services. No Studio needed.

## Suites

| File | Covers |
|---|---|
| `harden1.luau` | Player-data lifecycle: debt/cooldown survive bootstrap, ready/save-allowed matrix, ready gates, idempotent join, pending-resolve-before-save, warehouse cache clear, autosave + shutdown skips |
| `harden2.luau` | Gameplay interactions: starting bids, container/ATM/terminal proximity + ownership, commitment-aware upgrades, remote rate limits, GUID ids, defensive copies, rotated bounds, duplicate ContainerIds, MaxCash loans |
| `conc3.luau` | 3 simultaneous independent auction sessions, isolation, anti-snipe, commitments |
| `tier4.luau` | Budget/Standard/HighRoller tiers, gates, generation distributions, clue integrity |
| `debt5a.luau` | ATM loans, 25% sale split, recovery top-up + cooldown |
| `persist5b.luau` | SA_M1_v1 schema, reconnects, autosave, failure safety, plot exclusion |
| `warehouse6.luau` | Warehouse levels, capacity gate, displays, plots, upgrade flow |
| `tiergen.luau` | 10,000 generated units per tier (slow) |
| `main.luau` | 1,000-auction economy simulation, Standard session (slow) |

Superseded legacy harnesses (`rot`, `conc`, `main_solo.bak`) were intentionally
NOT migrated; they tested the removed rotation architecture.

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1 -Quick  # skips tiergen + main
```

`run-all.ps1` stages `src/` into `D:\Roblox\Temp\sa-tests` (execution only;
the repo stays the source of truth), runs every suite, and exits nonzero on
any failure. Requires the Lune CLI (`-Lune <path>` override supported).

`tests/` is deliberately NOT mapped by `default.project.json`, so nothing
here ever enters the Roblox game.
