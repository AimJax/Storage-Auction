# Storage Auction — Milestone 1 (playable prototype)

Multiplayer Roblox loop: inspect unit → bid vs NPCs → winner rummages →
open boxes → reveal randomized items → sell/keep → next auction.

## Project layout
- `default.project.json` — Rojo project (Shared/Server/Client sync).
  Workspace is intentionally NOT mapped: the map is Studio-owned.
- `src/shared/` — GameConfig, RarityConfig, ItemDefinitions, ItemUtils.
- `src/server/` — AuctionService, Economy, Inventory, NPCs, MapBuilder
  (behavior over Studio geometry — creates no parts), PlayerData,
  init.server (bootstrap).
- `src/client/` — UIController, AuctionClient, init.client.
- `tools/BuildMapOnce.luau` — one-time command-bar migration that generates
  the initial `Workspace/StorageAuctionMap` (not synced, never runs at runtime).
- `AGENTS.md` — architecture + agent instructions.

## Manual Map Editing

Who owns what:

- **Studio owns** `Workspace/StorageAuctionMap` (walls, roof, floor, door,
  barrier, sign, boxes, mat, chairs, BidCenter, ReturnPoint, spawn) inside
  `StorageAuction-place.rbxl`. Edit it freely: move, resize, recolor,
  restyle. Gameplay adapts (bid center, return point, unit bounds, and box
  positions are all read live from the parts).
- **Rojo owns code**: `ReplicatedStorage/Shared`,
  `ServerScriptService/Server`, `StarterPlayerScripts/Client`
  (`default.project.json`, port 34872). It never touches Workspace.
- **Argon owns the map on disk**: `Workspace/StorageAuctionMap` ↔
  `map/StorageAuctionMap/` (`map.project.json`, port 8000). Bidirectional.
- **Git tracks** code, docs, `tools/`, AND `map/` — NOT the `.rbxl`
  (gitignored, including `StorageAuction-place-before-bidirectional-sync.rbxl`,
  your local backup). The place file is your local world file; back it up by
  copying `StorageAuction-place.rbxl` before big map edits.

## Everyday Workflow (bidirectional map sync)

Map edits in Studio now land on disk automatically, and file edits flow
back into Studio. Required plugin settings (Argon plugin → gear icon,
set once): **Two-Way Sync ON**, **Only Code Mode OFF**,
**Syncback Properties ON**, **Keep Unknowns ON** (protects Baseplate,
Camera, and Rojo-synced code from deletion).

First sync ever (pulls the Studio map to disk, once):

1. Terminal 1: `D:\Roblox\Dev\rojo\rojo.exe serve` (code, :34872).
2. Terminal 2: `D:\Roblox\Dev\argon\argon.exe serve map.project.json`
   (map, :8000). Leave both running.
3. Open `StorageAuction-place.rbxl` in Studio (do NOT press Play).
4. Argon plugin settings → **Initial Sync Priority = Client** (Studio wins).
5. Connect the Argon plugin → accept the incoming-changes prompt. The map
   (~60 instances) writes to `map/StorageAuctionMap/` on disk.
6. Set **Initial Sync Priority back to Server** (normal direction guard).
7. Connect the Rojo plugin as usual. Save the place (Ctrl+S).

Everyday loop:

1. Start both servers (commands above).
2. Open `StorageAuction-place.rbxl`.
3. Connect Argon + Rojo plugins.
4. Edit the map in Studio → files under `map/` update automatically.
5. OpenCode reads the latest map + code from disk.
6. OpenCode edits `map/` or `src/` → Studio reflects it live.
7. No manual export/import, ever.
8. Save the place (Ctrl+S) to keep the `.rbxl` in step.
9. `git add map/ src/`, commit, push.

Rules that keep this safe:

- **Edit-mode only.** Disconnect Argon (or stop its server) before pressing
  Play. Runtime changes (door Transparency, prompt Enabled, box dimming)
  must never sync back to disk. (`Transparency`/`CanCollide`/`Enabled` are
  additionally excluded in `map.project.json` syncback, but the Edit-mode
  rule is the real guard.)
- **One owner per subtree.** Never add Workspace to `default.project.json`;
  never add code services to `map.project.json`. Rojo and Argon must not
  overlap or they will fight.
- **If sync disconnects:** 1) stop Play if running, 2) check both terminals
  for errors, 3) restart the dead server, 4) reconnect that plugin and
  accept/decline the change prompt carefully (decline Studio→disk prompts
  that came from a Play session), 5) `git status` to confirm nothing
  unexpected changed on disk.
- **Recovery:** the place backup
  `StorageAuction-place-before-bidirectional-sync.rbxl` restores the
  pre-sync world. Map files restore via `git checkout -- map/`.
  NEVER delete `map/StorageAuctionMap/init.meta.json`: it declares the root
  class (`Model`). Without it Argon resolves the empty folder as `Folder`,
  Studio's `Model` never matches it, and the whole subtree goes untracked —
  symptom: "Synced" with zero files, and additions serialize inline into
  `map.project.json` instead of `map/`. If that happens: restore
  `map.project.json` from Git, re-add the seed file, restart serve.
  If Argon reports a duplicate-name error for `StorageAuctionMap`: search
  Explorer for `StorageAuctionMap` — if TWO exist, expand both, keep the
  FULL one (StorageUnit + AuctionArea + SpawnLocation), delete the
  empty/stale copy, Save, restart `argon serve`, reconnect once with Client
  priority. Never paste Studio contents inline into `map.project.json`:
  the map must stay a `$path` reference to `map/`.

First-time migration (once ever):

1. `rojo serve` NOT required; keep the Rojo plugin disconnected.
2. Open `StorageAuction-place.rbxl` in Studio (do NOT press Play).
3. View → Command Bar. Paste the entire contents of
   `tools/BuildMapOnce.luau`, press Enter.
4. Output shows `[SA] Map migration complete`. If your Baseplate top is not
   at Y = 0, move `StorageAuctionMap` vertically to fit, then continue.
5. Save the place (Ctrl+S). Done — the map is persistent.

Everyday workflow (code + map):

1. Start `rojo serve` AND `argon serve map.project.json` (two terminals).
2. Open `StorageAuction-place.rbxl`, connect both plugins.
3. Select anything under `Workspace/StorageAuctionMap` and edit it —
   files under `map/` update automatically.
4. Disconnect Argon, then press Play to test.
5. Save the place in Studio to keep map edits (Ctrl+S).
6. Code edits happen in `src/` files; map edits land in `map/`;
   commit/push both via Git.
7. Ownership split is load-bearing: Rojo = code only, Argon = map only.
   Never add Workspace to `default.project.json` or code services to
   `map.project.json`.

Required vs optional map pieces (missing required = clear red error in
Output at Play, never a silent rebuild): required are `StorageUnit` with
`Door`, `Barrier`, `Floor`, `ReturnPoint`, ≥1 `Container_*`, plus
`AuctionArea/BidCenter`. Optional (ignored if absent): `Sign`, `Mat`,
`Seats`, `UnitBounds` (falls back to unit extents), `SpawnLocation`
(warned if nowhere).

## Prerequisites
1. Roblox Studio installed (its system files under %LOCALAPPDATA% are fine).
2. Rojo CLI at `D:\Roblox\Dev\rojo\rojo.exe` (7.7.0, already downloaded).
3. Rojo Studio plugin: either `D:\Roblox\Dev\rojo\rojo.exe plugin install`
   (installs into Studio plugins) or via
   https://create.roblox.com/marketplace/asset/13916111004/Rojo
4. Argon CLI at `D:\Roblox\Dev\argon\argon.exe` (2.0.29) for bidirectional
   map sync. Plugin installed via `argon.exe plugin install` (already done
   once; re-run after major CLI updates).

## Roblox Studio setup (exact steps)
1. Open Roblox Studio → New → **Baseplate** (any baseplate place).
2. Save it as e.g. `D:\Roblox\Projects\StorageAuction\StorageAuction-place.rbxl`
   (local only — gitignored, never commit the .rbxl).
3. Open a terminal in `D:\Roblox\Projects\StorageAuction` and run:
   `D:\Roblox\Dev\rojo\rojo.exe serve`
4. In Studio: click the **Rojo** toolbar button → **Connect** (default
   `localhost:34872`).
5. Verify sync: ServerScriptService → Server (AuctionService, EconomyService…),
   ReplicatedStorage → Shared (GameConfig…),
   StarterPlayer → StarterPlayerScripts → Client (AuctionClient…).
   If nodes are missing, check the Rojo log in the terminal.
6. Game Settings → Security → enable **Enable Studio Access to API Services**
   ONLY if you want DataStore saves while testing (optional; game works without).

## Testing procedure (solo, M1 Definition of Done)
1. In Studio: **Play** (F5). You spawn at (0,3,0), unit is at (0,0,40).
2. Top bar shows state + countdown + bid + Cash (starts at $1000).
3. WAIT (8s) → INSPECTION (15s, door disappears, boxes visible, barrier blocks entry).
4. BIDDING (30s): stand near the unit (dark mat / chairs area, 24 studs)
   and press **BID $X**. Walk far away and the auction HUD hides — the server
   rejects distant bids with "Move closer to the auction to bid". NPCs
   (Dealer Dan, Collector Kate) will counter-bid. Outbid them.
   Chairs: 4 seats in two pairs face the unit; sitting still counts as near.
5. SOLD: if you won, Cash is deducted — you stay exactly where you are.
   No teleport. The entrance opens (door gone; barrier drops at Rummaging).
   If an NPC won, you never gain access; wait for reset (~5s Cleanup →
   Waiting → next loop).
6. As winner during RUMMAGING: physically WALK into the unit whenever you
   like, hold **E** on a box. Opening reveals the item but does NOT Bag it —
   a pending decision appears. You may walk back out freely at any time.
   Anyone may walk in, but only the winner can open boxes (others get a
   rejection toast). Opening a second box before deciding shows
   "Choose Sell or Keep first".
   Reveal panel (compact, centered) shows Name / Rarity / Condition / Value.
7. Press **SELL** → server adds FinalValue to Cash (never Bagged), panel
   auto-closes. Press **KEEP** → server moves the item into your **Bag**
   (bottom-right button, hidden by default — click to open), panel
   auto-closes. The final box keeps Rummaging alive until you decide; if the
   timer expires mid-decision you get a 10s grace (prompts off) to choose.
8. Open all 3 boxes (or wait 90s) → Cleanup: entrance stays open as a grace
   period so you can walk out naturally. If you are still inside when the
   next auction resets, you are moved to a safe spot outside (safety
   fallback only) and the door reappears → Waiting → next auction.

Multi-client: Studio **Test** tab → **Clients and Servers** → 2 Players →
**Start**. Bid from one window, watch the other update.

## Showroom / collection test (solo)
9. KEEP an item → Bag count rises; Bag panel shows
   `Collection $X · Won N` and premium LOCKED status.
10. Open Bag → click the item → DISPLAY → pick Slot 1. A rarity-colored
    proxy with name/rarity/value appears on the showroom slot (showroom is
    east of the unit at x≈38, outside the bid radius — walk there).
11. DISPLAY the same item into Slot 2 → Slot 1 clears, Slot 2 shows it.
    One item never occupies two slots.
12. Slot picker → REMOVE DISPLAY → proxy disappears, item stays in Bag.
13. DISPLAY again, then SELL it from the Bag → proxy auto-clears, Cash rises.
14. Win auctions / grow collection → Bag stats update; at 5 wins or $5,000
    collection the premium line switches to UNLOCKED (teaser only).

## Known limitations (M1)
- Rummaging is physically open: anyone may walk in, but only the winner can
  open boxes (server-enforced, rejection toast otherwise).
- If a player is still inside when the next auction resets, they are moved
  to a safe spot outside (safety fallback only — normal play never moves you).
- If the winner dies mid-rummage they respawn outside and can simply walk
  back in; unopened boxes wait until the timer expires.
- Inventory Keep is session-only; only Cash persists via DataStore.
- No anti-exploit rate limiting beyond server validation; no admin tools.
- Timings/economy are placeholder-tuned in `src/shared/GameConfig.luau`.
- UI is compact but not final art. Toasts last ~3s; Bag is toggleable.

## Next milestones (do NOT build yet)
M2: polish rummage feel + sound; M3: persistence of collections;
M4: showroom/social; later: monetization. Await explicit instruction.
