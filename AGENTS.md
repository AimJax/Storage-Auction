# AGENTS.md — Storage Auction (AI agent instructions)

## What this is
**Storage Auction** is a multiplayer Roblox game. Core loop per auction unit:
Waiting → Inspection → Bidding (vs humans + filler NPCs) → Sold → winner
Rummages the unit → opens boxes → randomized item reveal → Sell/Keep →
Cash → next auction. THREE units run these loops SIMULTANEOUSLY and
independently (Unit 1 = Budget, Unit 2 = Standard, Unit 3 = High Roller).
See README.md for manual Studio test steps.

## Project locations (HARD RULE)
- Everything lives under `D:\Roblox\Projects\StorageAuction`. Never create
  project files, repos, sources, artifacts, caches, or exports on C:.
- Tooling binaries live in `D:\Roblox\Dev\` (rojo, argon, lune). Test
  execution staging goes to `D:\Roblox\Temp\sa-tests` (never the repo).
- Studio system files under `%LOCALAPPDATA%\Roblox` are unavoidable — leave them.

## Architecture
Rojo file-sync project (`default.project.json`):
- `src/shared/` → ReplicatedStorage.Shared (ModuleScripts: GameConfig,
  RarityConfig, ItemDefinitions, ItemUtils — data + pure math, no services).
- `src/server/` → ServerScriptService.Server (authoritative logic).
- `src/client/` → StarterPlayerScripts.Client (UI + remote wiring only).
- `tests/` exists but is NEVER mapped into the game.

Runtime-created instances (no manual Studio setup): `ReplicatedStorage/SA_Remotes`
folder (events + functions, classes validated at boot); `leaderstats/Cash`.
The map (`Workspace/StorageAuctionMap`) is STUDIO-AUTHORED: it lives in the
`.rbxl` place file, is hand-editable, and Rojo never touches Workspace (see
`default.project.json` — no Workspace mapping).

### Auction architecture (CURRENT — do not redesign)
- `AuctionService.luau` owns `Sessions[1..3]`, one `runLoop` coroutine each.
  Permanent tier mapping from `GameConfig.UnitTiers`, tier stored per session.
  No queue, no rotation, no shared mutable auction state, no global tier.
- Anti-snipe (extend capped), tier starting bids (25/100/500), price-tiered
  bid increments, 24-stud XZ bid radius, container proximity checks.
- `NPCBidderService.luau` — filler role: estimates from VISIBLE clues only;
  interest rolls with 1–3 active cap; human-pressure scaling; late
  suppression + no-late-join; reaction pause; per-NPC bid history;
  per-tier hidden-guess baseline + budget scale. TrueTotalValue is never an input.
- `UnitGeneratorService.luau` — pre-Inspection hidden loot + visible clues +
  true total (server only; rummage reveals these exact instances). Tier
  weights/junk/luck/scale flow in explicitly per session.
- Bids carry explicit `unitIndex`; cross-session cash-commitment protection;
  winner re-validated at resolution; `DeductCash` never goes negative.

### Progression (CURRENT)
- Persistent (SA_M1_v1 DataStore, schema v2): Cash, Inventory (data-only),
  AuctionsWon, Debt, RecoveryAvailableAt, WarehouseLevel, DisplayAssignments.
- Session-only: plot identity/position, live auctions/bids/loot, NPC state,
  pending rummage decisions, HUD/proximity state.
- `PlayerDataService.luau` — sole save/load owner: ready/save-allowed flags,
  sanitized schema, save-before-clear ordering, 120s autosave (loaded only),
  bounded BindToClose sweep. Never force-push/writes for unloaded players.
- `DebtService.luau` — runtime ATM loans (A/B/C fixed offers, one active),
  25%-of-sale auto-repayment (never overpays), recovery top-up to $125 with
  300s wall-clock cooldown. No persistence of its own ( PlayerDataService owns it).
- `WarehouseService.luau` — per-player level (persistent) + runtime clone on
  claimed plot + procedural display grid past the 6 template markers +
  upgrade terminal (owner-only, proximity-checked) + commitment-aware upgrade
  purchases. Plot assignment stays session-local.
- `PlotService.luau` — manual plot claims (sign prompt E, one plot per player,
  no stealing, release on leave). Never persisted, never auto-assigned.
- `DisplayService.luau` — id-keyed display assignments (server-validated),
  level-aware slot bounds, proxies rebuilt per claimed warehouse, ghost
  cleanup on sale. Never allocates plots, never touches other players.
- `PlayerStatsService.luau` — AuctionsWon + collection value (computed).
- `EconomyService.luau` — Cash ledger. Only writer of balances.
- `InventoryService.luau` — server-side ownership (defensive copies out),
  level-gated keeps (grandfathered over-cap sells normally).
- `MapBuilder.luau` — map BEHAVIOR over Studio-authored geometry (never
  creates parts): per-unit handles, rotation-safe bounds, container range.
- `RemoteGuardService.luau` — tiny per-user remote throttle (advisory only;
  every remote still validates fully).

### Client modules (`src/client/`)
- `init.client.luau` → `AuctionClient` → `UIController`.
- UI built in code (ScreenGui SA_UI). Auction HUD follows the nearest
  in-radius session; reveal panel lifecycle is proximity-independent
  (closes only on Sell/Keep success or server closeReveal).
- Client NEVER decides cash/bids/winner/values. It invokes RemoteFunctions and
  renders server broadcasts.

## Sync workflow (follow exactly)
- **Rojo** (`rojo.exe serve`, :34872): ALWAYS connected for normal
  development. Code only.
- **Argon**: normally DISCONNECTED. Never run `argon init`.
- **Code-only work** (the default): Rojo only, no Argon. Play/test with
  Rojo connected, Argon disconnected.
- **Filesystem map changes**: edit `map/` while Argon is disconnected →
  connect Argon with **SERVER priority** once → sync into Studio → save
  `.rbxl` → disconnect Argon.
- **Manual Studio map authoring**: Argon disconnected → edit → save/backup.
  Only if intentionally capturing to filesystem: connect **CLIENT priority**
  once → inspect diff → disconnect → restore SERVER priority.
- **Play/Test**: Rojo connected, Argon disconnected (edit mode only, so
  runtime door/prompt/box state never syncs back to `map/`).
- `$keepUnknowns` can preserve Studio-only stale objects (e.g. legacy
  PlayerShowroom is auto-removed on load); if odd objects appear, prefer
  deleting them in Studio over working around them in code.
- NEVER inline Studio instances into `map.project.json` (keep the `$path`
  reference). Never add Workspace to `default.project.json`. Never merge
  `backup-broken-2026-09-24` into main. Never force-push.
- `tools/BuildMapOnce.luau` is a LEGACY failing stub: it builds only the
  ancient one-unit prototype and errors on purpose. Canonical map recovery
  is `map/StorageAuctionMap` from version control + Argon SERVER sync.

## Coding conventions
- Luau, `--!nonstrict`. Small focused modules.
- Shared tuning ONLY in `GameConfig` / `RarityConfig` / `ItemDefinitions`.
  No magic numbers in services. Value formula centralized in `ItemUtils`.
- Security: validate every RemoteFunction arg server-side (loading state,
  state, ownership, proximity, affordability, container IDs). Never trust
  client-sent values. Mutating remotes pass `RemoteGuardService` first.
- Item instances are tables: InstanceId (`sa_<guid>`, legacy `m1_...`
  still valid), ItemId, Name, BaseValue, Rarity, Condition, FinalValue,
  Modifiers={} (reserved). Persist data-only subsets, never Instances.
- Player lifecycle has ONE owner: `init.server` (`bootstrapped` guard,
  Load once, save-before-clear, bounded shutdown). No service may
  independently clear player state on leave.
- Keep it simple. No trading/vehicles/crafting/quests/pets/battle pass.

## Tests
- Suites live in `tests/` (see `tests/README.md`); run with
  `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1`.
  Green suite + `rojo build` are required before any gameplay commit.
- Cash/NPC/economy feel targets: same as ever — filler NPCs, inspection
  skill matters, bargains possible but uncommon, overpays possible.

## Git workflow
- Repo: https://github.com/AimJax/Storage-Auction.git — local
  `D:\Roblox\Projects\StorageAuction`, branch `main`.
- Before edits: `git status`, `git branch --show-current`, inspect files.
  Do NOT `git pull` blindly mid-task; report divergence instead.
- Commit milestones with descriptive messages (`feat:`/`fix:`/`chore:`).
  Push after meaningful milestones, not every edit. Never force-push /
  rewrite history / delete remote branches.
- Before commit: `git status`, review diff, ensure .gitignore excludes build/
  *.rbxl(x), logs, secrets. Never commit tokens/keys.
- If push needs auth: STOP, tell the user exactly what to approve.

## For future agents
Read this file + README.md + GameConfig before coding. Preserve existing work,
verify with `D:\Roblox\Dev\rojo\rojo.exe build`, keep changes minimal per
milestone, and keep this file truthful when architecture changes.
