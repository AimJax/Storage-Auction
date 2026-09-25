# Storage Auction

Multiplayer Roblox loop across THREE simultaneous independent auction units
(Unit 1 = Budget, Unit 2 = Standard, Unit 3 = High Roller): inspect unit →
bid vs humans + filler NPCs → winner rummages → open boxes → reveal
randomized items → sell/keep → Cash → next auction. Cash, inventory, wins,
debt, warehouse level and displays persist; plots and live auctions do not.

## Project layout
- `default.project.json` — Rojo project (Shared/Server/Client sync).
  Workspace is intentionally NOT mapped: the map is Studio-owned.
- `src/shared/` — GameConfig, RarityConfig, ItemDefinitions, ItemUtils.
- `src/server/` — AuctionService (3 sessions), Economy, Inventory, NPCs,
  MapBuilder (behavior over Studio geometry — creates no parts),
  PlayerData (+autosave), DebtService, WarehouseService, DisplayService,
  PlotService, PlayerStatsService, RemoteGuardService, init.server.
- `src/client/` — UIController, AuctionClient, init.client.
- `tests/` — deterministic Lune regression suites + `run-all.ps1`
  (never mapped into the game).
- `tools/BuildMapOnce.luau` — LEGACY failing stub (ancient one-unit
  prototype; errors on purpose — do not run it).
- `AGENTS.md` — architecture + agent instructions.

## Manual Map Editing

Who owns what:

- **Studio owns** `Workspace/StorageAuctionMap` (units, doors, barriers,
  signs, boxes, mats, chairs, BidCenters, ReturnPoints, spawn, ATM,
  warehouse district, warehouse template) inside
  `StorageAuction-place.rbxl`. Edit it freely: move, resize, recolor,
  restyle. Gameplay adapts (bid centers, return points, unit bounds, box
  positions, slot layout are all read live from the parts).
- **Rojo owns code**: `ReplicatedStorage/Shared`,
  `ServerScriptService/Server`, `StarterPlayerScripts/Client`
  (`default.project.json`, port 34872). It never touches Workspace.
- **Argon owns the map on disk**: `Workspace/StorageAuctionMap` ↔
  `map/StorageAuctionMap/` (`map.project.json`, port 8000).
- **Git tracks** code, docs, `tools/`, `tests/`, AND `map/` — NOT the `.rbxl`
  (gitignored). The place file is your local world file; back it up by
  copying `StorageAuction-place.rbxl` before big map edits.

## Sync workflow (normal case: Rojo only)

1. Terminal: `D:\Roblox\Dev\rojo\rojo.exe serve` (code, :34872).
2. Open `StorageAuction-place.rbxl`. Connect the Rojo plugin.
3. **Argon stays disconnected.** Disconnect it before pressing Play so
   runtime state (door Transparency, prompt Enabled, box dimming) never
   syncs back to `map/`.
4. Code edits happen in `src/`; commit/push via Git.

Filesystem map changes (rare): edit `map/` while Argon is disconnected →
connect Argon with **SERVER priority** once → sync into Studio → save
`.rbxl` → disconnect Argon. Manual Studio authoring: Argon disconnected →
edit → save/backup; only to capture to filesystem intentionally: connect
**CLIENT priority** once → inspect diff → disconnect → restore SERVER
priority.

Rules that keep this safe:

- **One owner per subtree.** Never add Workspace to `default.project.json`;
  never add code services to `map.project.json`. Rojo and Argon must not
  overlap or they will fight.
- **If sync disconnects:** 1) stop Play if running, 2) check both terminals
  for errors, 3) restart the dead server, 4) reconnect that plugin and
  accept/decline the change prompt carefully (decline Studio→disk prompts
  that came from a Play session), 5) `git status` to confirm nothing
  unexpected changed on disk.
- **Recovery:** Map files restore via `git checkout -- map/`.
  NEVER delete `map/StorageAuctionMap/init.meta.json`: it declares the root
  class (`Model`). Without it Argon resolves the empty folder as `Folder`,
  Studio's `Model` never matches it, and the whole subtree goes untracked —
  symptom: "Synced" with zero files, and additions serialize inline into
  `map.project.json` instead of `map/`. If that happens: restore
  `map.project.json` from Git, re-add the seed file, restart serve.
  If Argon reports a duplicate-name error for `StorageAuctionMap`: search
  Explorer for `StorageAuctionMap` — if TWO exist, expand both, keep the
  FULL one, delete the empty/stale copy, Save, restart `argon serve`,
  reconnect once with Client priority. Never paste Studio contents inline
  into `map.project.json`: the map must stay a `$path` reference to `map/`.

Required vs optional map pieces (missing required = clear red error in
Output at Play, never a silent rebuild): each `StorageUnit(2/3)` needs
`Door`, `Barrier`, `Floor`, `ReturnPoint`, ≥1 `Container_*` (unique
ContainerIds per unit), plus its `AuctionArea(2/3)/BidCenter`. Optional
(ignored if absent): `Sign`, `Mat`, `Seats`, `UnitBounds` (falls back to
unit extents), `SpawnLocation` (warned if nowhere), `ATM` (warned if
absent; loans/recovery UI need it), `WarehouseTemplate`.

## Prerequisites
1. Roblox Studio installed (its system files under %LOCALAPPDATA% are fine).
2. Rojo CLI at `D:\Roblox\Dev\rojo\rojo.exe` (7.7.0, already downloaded).
3. Rojo Studio plugin: either `D:\Roblox\Dev\rojo\rojo.exe plugin install`
   (installs into Studio plugins) or via
   https://create.roblox.com/marketplace/asset/13916111004/Rojo
4. Argon CLI at `D:\Roblox\Dev\argon\argon.exe` (2.0.29) for map sync
   (only needed when touching the map). Plugin installed via
   `argon.exe plugin install` (already done once; re-run after major CLI updates).
5. Lune CLI at `D:\Roblox\Dev\lune\lune.exe` for `tests/run-all.ps1`.
6. Game Settings → Security → enable **Enable Studio Access to API Services**
   ONLY if you want DataStore saves while testing (optional; offline fallback
   keeps the game fully playable).

## Roblox Studio setup (exact steps)
1. Open Roblox Studio → open `StorageAuction-place.rbxl`
   (local only — gitignored, never commit the .rbxl).
2. Open a terminal in `D:\Roblox\Projects\StorageAuction` and run:
   `D:\Roblox\Dev\rojo\rojo.exe serve`
3. In Studio: click the **Rojo** toolbar button → **Connect** (default
   `localhost:34872`).
4. Verify sync: ServerScriptService → Server (AuctionService,
   EconomyService…), ReplicatedStorage → Shared (GameConfig…),
   StarterPlayer → StarterPlayerScripts → Client (AuctionClient…).
   If nodes are missing, check the Rojo log in the terminal.

## Testing procedure (solo)
1. In Studio: **Play** (F5). Top bar shows tier + state + countdown + bid
   + Cash (starts at $1000; saved Cash restores on rejoin).
2. Each unit runs Waiting (8s) → Inspection (15s, door opens, boxes
   visible, barrier blocks entry) → Bidding (30s) → Sold → Rummaging/Cleanup.
   All three units cycle independently (staggered starts, natural drift).
3. Bidding: stand near a unit (mat/chairs area, 24 studs) and press
   **BID $X** — HUD shows the NEAREST in-range unit (BUDGET $25 /
   STANDARD $100 / HIGH ROLLER $500 openings). Walk away and the auction HUD
   hides — the server rejects distant bids. NPCs counter-bid as filler.
   Standard needs $300 cash; High Roller needs $2,500 + (3 wins or $5,000
   net worth). Sitting still counts as near.
4. SOLD: if you won, Cash is deducted — you stay exactly where you are.
   No teleport. The entrance opens (door gone; barrier drops at Rummaging).
   If an NPC won, you never gain access; wait for reset.
5. As winner during RUMMAGING: physically WALK into the unit whenever you
   like, hold **E** on a box (must stand close — remote opens are
   range-checked). Opening reveals the item but does NOT Bag it — a pending
   decision appears. The reveal panel stays open even if you walk to another
   unit; it closes only on Sell/Keep or server timeout. Anyone may walk in,
   but only the winner can open boxes (others get a rejection toast).
   Reveal panel shows Name / Rarity / Condition / Value.
6. Press **SELL** → server adds FinalValue to Cash (25% auto-repays any
   debt), panel auto-closes. A failed Sell leaves the panel OPEN. Press
   **KEEP** → item moves into your **Bag** (unless the warehouse is full —
   then Sell or upgrade first). The final box keeps Rummaging alive until
   you decide; if the timer expires mid-decision you get a 10s grace (full
   warehouse auto-sells instead of deleting).
7. Open all 3 boxes (or wait 90s) → Cleanup → Waiting → next auction. If you
   are still inside when the unit closes, you are moved to that unit's
   ReturnPoint (safety fallback only).
8. Disconnect mid-rummage with a pending item: it is auto-kept (or
   auto-sold if full) and saved — value is never destroyed.

Multi-client: Studio **Test** tab → **Clients and Servers** → 2 Players →
**Start**. Bid from one window, watch the other update. Both players can
bid different units simultaneously.

## ATM / debt / recovery test (solo)
9. Broke or curious: walk to the green ATM east of the units (X≈120),
   press **E** → panel shows Cash/Debt/loans. Loan A ($250→$300) is open;
   B/C show lock reasons. Take A → cash +250, debt 300; second loan
   refuses. Sell loot → 25% of each sale pays debt (never overpays).
10. Drop cash under $50 → recovery tops up to exactly $125 (debt untouched);
    immediate re-claim refuses (300s cooldown, survives rejoin).
11. Leave with debt → rejoin → debt intact, second loan still blocked.

## Warehouse test (solo)
12. KEEP items → Bag count rises; Bag panel shows `Collection $X · Won N`.
    Joining assigns NOTHING — claim a plot manually: walk to the warehouse
    district, hold **E** on an AVAILABLE plot sign → warehouse spawns,
    sign shows your name. Another player's plot refuses.
13. Bag → item → DISPLAY → pick a slot: rarity-colored proxy appears in YOUR
    warehouse. Same item into another slot moves it (never two slots).
    REMOVE DISPLAY keeps the item; selling a displayed item auto-clears it.
14. Walk to the blue upgrade kiosk inside your warehouse, press **E** →
    panel shows Level/storage/slots + next cost/wins. Upgrade deducts cash,
    unlocks slots/capacity immediately (picker grows without relog).
15. Fill storage (Lv 1 = 25) → Keep refuses ("Warehouse storage is full");
    Sell works; upgrade or clear space, then Keep works.
16. Leave → rejoin → claim a DIFFERENT plot → same level, same displays
    rebuilt there. Plot signs free up on leave for others.

## Known limitations
- Rummaging is physically open: anyone may walk in, but only the winner can
  open boxes (server-enforced, rejection toast otherwise).
- If a player is still inside when the unit closes, they are moved to that
  unit's ReturnPoint (safety fallback only — normal play never moves you).
- DataStore saves need API access enabled; otherwise the game runs fully
  session-only with a warning.
- Timings/economy are tuned in `src/shared/GameConfig.luau`.
- UI is compact but not final art. Toasts last ~3s; Bag is toggleable.
- Automated regression: `tests/run-all.ps1` (Lune). Green suite +
  `rojo build` required before gameplay commits.
