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
3. WAIT (8s) → INSPECTION (15s, door disappears, boxes visible, barrier blocks entry).
4. BIDDING (30s): stand near the unit (dark mat / chairs area, 35 studs)
   and press **BID $X**. Walk far away and the BID button hides — the server
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
