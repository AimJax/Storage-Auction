# AGENTS.md — Storage Auction (AI agent instructions)

## What this is
**Storage Auction** is a multiplayer Roblox game. Core loop: Waiting → Inspection
→ Auction (bidding vs simple NPCs) → Sold → winner Rummages unit → opens
containers → randomized item reveal → Sell/Keep → Cash → next auction.

Milestone 1 (current): smallest playable loop. 1 unit, 3 containers,
10 placeholder items, 1 currency (Cash), simple NPC bidders, basic UI.
See README.md for manual Studio test steps.

## Project locations (HARD RULE)
- Everything lives under `D:\Roblox\Projects\StorageAuction`. Never create
  project files, repos, sources, artifacts, caches, or exports on C:.
- Tooling binary: `D:\Roblox\Dev\rojo\rojo.exe` (Rojo 7.7.0). Keep
  project-specific tooling/config on D:.
- Studio system files under `%LOCALAPPDATA%\Roblox` are unavoidable — leave them.

## Architecture
Rojo file-sync project (`default.project.json`):
- `src/shared/` → ReplicatedStorage.Shared (ModuleScripts: GameConfig,
  RarityConfig, ItemDefinitions, ItemUtils — data + pure math, no services).
- `src/server/` → ServerScriptService.Server (authoritative logic).
- `src/client/` → StarterPlayerScripts.Client (UI + remote wiring only).

Runtime-created instances (no manual Studio setup): `ReplicatedStorage/SA_Remotes`
folder with 4 RemoteEvents + 3 RemoteFunctions; `Workspace/SA_Unit` map;
`leaderstats/Cash`. Server builds all of this on start.

### Server modules (`src/server/`)
- `init.server.luau` — bootstrap: remotes, services, map, auction loop, players.
- `AuctionService.luau` — state machine (Waiting/Inspection/Bidding/Sold/
  Rummaging/Cleanup), bid validation, winner selection, deduction, container auth.
- `EconomyService.luau` — Cash ledger. Only writer of balances.
- `InventoryService.luau` — server-side ownership list.
- `ItemGenerationService` logic lives in shared `ItemUtils.GenerateInstance`
  (server calls it; client never generates).
- `NPCBidderService.luau` — maxWilling = hiddenValue × noise; chance + delay.
- `MapBuilder.luau` — builds unit/door/barrier/containers/prompts at runtime.
- `PlayerDataService.luau` — DataStore (pcall-guarded; session-only fallback).

### Client modules (`src/client/`)
- `init.client.luau` → `AuctionClient` → `UIController`.
- UI built in code (ScreenGui SA_UI). No .rbxmx assets in M1.
- Client NEVER decides cash/bids/winner/values. It invokes RemoteFunctions and
  renders server broadcasts.

## Coding conventions
- Luau, `--!nonstrict` for M1 (beginner-friendly). Small focused modules.
- Shared tuning ONLY in `GameConfig` / `RarityConfig` / `ItemDefinitions`.
  No magic numbers in services. Value formula centralized in `ItemUtils`.
- Security: validate every RemoteFunction arg server-side (state, ownership,
  affordability, container IDs). Never trust client-sent values.
- Item instances are tables: InstanceId, ItemId, Name, BaseValue, Rarity,
  Condition, FinalValue, Modifiers={} (reserved for Signed/Golden/Sealed/etc).
- Keep it simple. No trading/vehicles/crafting/quests/pets/battle pass in M1.

## Git workflow
- Repo: https://github.com/AimJax/Storage-Auction.git — local
  `D:\Roblox\Projects\StorageAuction`, branch `main` unless repo says otherwise.
- Before edits: `git status`, `git branch --show-current`, inspect files, pull.
- Commit milestones with descriptive messages (`feat: ...`). Push after
  meaningful milestones, not every edit. Never force-push / rewrite history /
  delete remote branches.
- Before commit: `git status`, review diff, ensure .gitignore excludes build/
  *.rbxl(x), logs, secrets. Never commit tokens/keys.
- If push needs auth: STOP, tell the user exactly what to approve.

## Current milestone & scope
M1 Definition of Done: join → see Cash → inspection → bid vs NPC → win →
deduct → enter unit → open box (E) → reveal w/ rarity/condition/value →
sell → Cash++ → reset → next auction. Solo + multi-client Studio testable.
OUT OF SCOPE: trading, restoration, crafting, open world, quests, clans,
battle pass, pets, complex NPC AI, big progression, showrooms, monetization.

## For future agents
Read this file + README.md + GameConfig before coding. Preserve existing work,
verify with `D:\Roblox\Dev\rojo\rojo.exe build`, keep changes minimal per
milestone, update this file's milestone section when M1 closes.
