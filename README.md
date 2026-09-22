# Storage Auction — Milestone 1 (playable prototype)

Multiplayer Roblox loop: inspect unit → bid vs NPCs → winner rummages →
open boxes → reveal randomized items → sell/keep → next auction.

## Project layout
- `default.project.json` — Rojo project (Shared/Server/Client sync).
- `src/shared/` — GameConfig, RarityConfig, ItemDefinitions, ItemUtils.
- `src/server/` — AuctionService, Economy, Inventory, NPCs, MapBuilder,
  PlayerData, init.server (bootstrap).
- `src/client/` — UIController, AuctionClient, init.client.
- `AGENTS.md` — architecture + agent instructions.

## Prerequisites
1. Roblox Studio installed (its system files under %LOCALAPPDATA% are fine).
2. Rojo CLI at `D:\Roblox\Dev\rojo\rojo.exe` (7.7.0, already downloaded).
3. Rojo Studio plugin: either `D:\Roblox\Dev\rojo\rojo.exe plugin install`
   (installs into Studio plugins) or via
   https://create.roblox.com/marketplace/asset/13916111004/Rojo

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
3. WAIT (8s) → INSPECTION (15s, door fades, boxes visible, barrier blocks entry).
4. BIDDING (30s): press **BID $X**. NPCs (Dealer Dan, Collector Kate) will
   counter-bid. Outbid them.
5. SOLD: if you won, Cash is deducted and you are teleported inside
   (door swings open; invisible barrier keeps everyone else out).
   If an NPC won, wait for reset (~5s Cleanup → Waiting → next loop).
6. As winner during RUMMAGING: walk to a box, hold **E** (ProximityPrompt).
   Opened boxes dim and their prompts turn off. Reveal panel (compact,
   centered) shows Name / Rarity / Condition / Value.
7. Press **SELL** → Cash increases, panel auto-closes. **KEEP** → panel
   auto-closes, item stays in your **Bag** (bottom-right button, hidden
   by default — click to open).
8. Open all 3 boxes (or wait 90s) → Cleanup: you are teleported back
   outside facing the unit, door swings shut → Waiting → next auction.

Multi-client: Studio **Test** tab → **Clients and Servers** → 2 Players →
**Start**. Bid from one window, watch the other update.

## Known limitations (M1)
- During Rummaging the invisible barrier stays up: only the teleported winner
  is inside. If the winner dies mid-rummage they respawn outside and must wait
  for the timer — the loop still completes safely, nobody gets trapped.
- Non-winners standing at the open doorway are within prompt range but the
  server rejects their opens; prompts are also distance-limited (10 studs).
- Inventory Keep is session-only; only Cash persists via DataStore.
- No anti-exploit rate limiting beyond server validation; no admin tools.
- Timings/economy are placeholder-tuned in `src/shared/GameConfig.luau`.
- UI is compact but not final art. Toasts last ~3s; Bag is toggleable.

## Next milestones (do NOT build yet)
M2: polish rummage feel + sound; M3: persistence of collections;
M4: showroom/social; later: monetization. Await explicit instruction.
