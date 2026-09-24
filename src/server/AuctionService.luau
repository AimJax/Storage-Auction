--!nonstrict
-- StorageAuction — concurrent per-unit auction sessions (authoritative server).
--
-- Two independent auction sessions (Unit 1, Unit 2) run SIMULTANEOUSLY in
-- their own loops. There is no global queue and no unit rotation: each
-- session owns its state, loot, NPCs, timers, and physical unit handles.
-- States per session: Waiting -> Inspection -> Bidding -> Sold ->
-- Rummaging -> Cleanup -> loop. All bid validation, winner selection, cash
-- deduction, item generation, and container access checks happen here.
-- Clients get one broadcast per session, keyed by unitIndex.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local ItemUtils = require(Shared.ItemUtils)
local UnitGeneratorService = require(script.Parent.UnitGeneratorService)

local AuctionService = {}

local EconomyService = nil
local InventoryService = nil
local NPCBidderService = nil
local MapBuilder = nil
local Remotes = nil
local PlayerStatsService = nil
local DisplayService = nil

-- Sessions own ALL mutable auction state. Nothing auction-related lives in
-- module globals (only service refs + the session list itself).
local Sessions = {} -- [unitIndex] = session

local function now()
	return os.clock()
end

local function newSession(unitIndex, handles)
	return {
		UnitIndex = unitIndex,
		Handles = handles,
		State = "Waiting",
		StateEndsAt = now() + GameConfig.WaitingDuration,
		CurrentBid = 0,
		CurrentBidder = "", -- player Name or NPC name; "" = none
		CurrentBidderType = "", -- "Player" | "NPC" | ""
		CurrentBidderUserId = nil, -- set only for player bids
		WinnerName = "",
		WinnerType = "", -- "Player" | "NPC" | ""
		WinnerUserId = nil, -- nil => NPC won / no winner
		NpcBidders = {},
		HiddenValue = 0, -- server-only true total of hidden loot
		CurrentUnit = nil, -- full UnitGeneratorService unit (server only)
		ContainerItems = {}, -- [containerId] = itemInstance (pre-generated, hidden)
		ContainerOpened = {}, -- [containerId] = true once opened
		BidExtensionsUsed = 0, -- anti-snipe cap counter, per auction
		LastBidTime = -1000, -- os.clock of last accepted bid (NPC pacing)
		-- Active human bidders this auction: [UserId] = true on first
		-- accepted bid. Reset every auction. Drives NPC filler pressure.
		ActiveHumanBidders = {},
		-- Pending Sell/Keep decisions, [UserId] = itemInstance. Per session:
		-- opening in Unit 2 never touches Unit 1 state. Server-owned; one
		-- pending decision per player PER SESSION max.
		PendingByUser = {},
		-- Decision grace deadline (os.clock timestamp) when the rummage
		-- timer expires mid-decision; nil when no grace is active.
		RummageGraceEndsAt = nil,
	}
end

local function resolveSession(unitIndex)
	unitIndex = tonumber(unitIndex)
	local s = if unitIndex then Sessions[unitIndex] else nil
	if not s then
		return nil, "Unknown auction unit."
	end
	return s, nil
end

local function timeLeft(s)
	return math.max(0, s.StateEndsAt - now())
end

local function activeHumanCount(s)
	local n = 0
	for _ in pairs(s.ActiveHumanBidders) do
		n += 1
	end
	return n
end

-- Funds a player already has committed as the leading bidder in OTHER
-- sessions. Guards the win-two-auctions-at-once edge: a new bid is only
-- accepted when cash covers it PLUS every outstanding lead elsewhere.
-- finishBidding re-validates at resolution as a backstop, and DeductCash
-- itself never lets a balance go negative.
local function leadingCommitment(userId, exceptSession)
	local total = 0
	for _, s in pairs(Sessions) do
		if s ~= exceptSession and s.CurrentBidderUserId == userId then
			total += s.CurrentBid
		end
	end
	return total
end

local function snapshotOf(s)
	local center = s.Handles and s.Handles.BidCenter
	return {
		unitIndex = s.UnitIndex,
		state = s.State,
		timeLeft = math.floor(timeLeft(s) + 0.5),
		currentBid = s.CurrentBid,
		bidder = s.CurrentBidder,
		bidderType = s.CurrentBidderType,
		minIncrement = ItemUtils.BidIncrementFor(s.CurrentBid),
		winner = s.WinnerName,
		winnerType = s.WinnerType,
		isWinner = false, -- client compares winner to its own name
		bidRadius = GameConfig.BidRadius,
		bidCenter = if center then { x = center.X, y = center.Y, z = center.Z } else nil,
		inspection = nil, -- filled below during Inspection only
	}
end

local function broadcast(s)
	if not Remotes then
		return
	end
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.AuctionState)
	if ev then
		local snap = snapshotOf(s)
		if s.State == "Inspection" and s.CurrentUnit then
			local clues = {}
			for _, item in ipairs(s.CurrentUnit.VisibleItems) do
				-- Safe fields only: never values, never hidden identities.
				table.insert(clues, { name = item.Name, condition = item.ConditionName, rarity = item.Rarity })
			end
			snap.inspection = {
				visibleCount = #s.CurrentUnit.VisibleItems,
				hiddenCount = #s.CurrentUnit.HiddenItems,
				totalItemCount = #s.CurrentUnit.AllItems,
				clues = clues,
			}
		end
		ev:FireAllClients(snap)
	end
end

local function setState(s, next, duration)
	s.State = next
	s.StateEndsAt = now() + duration
	broadcast(s)
end

local function pregenerateContents(s)
	s.ContainerItems = {}
	s.ContainerOpened = {}
	local rng = Random.new()
	-- Container set comes from THIS session's physical unit.
	local ids = {}
	for containerId, _box in pairs(s.Handles.Containers) do
		table.insert(ids, containerId)
	end
	-- The unit (hidden loot + visible clues + true total) is fixed NOW.
	-- Rummaging later reveals these exact instances, never rerolls.
	s.CurrentUnit = UnitGeneratorService.GenerateUnit(rng, ids)
	for _, entry in ipairs(s.CurrentUnit.Containers) do
		s.ContainerItems[entry.ContainerId] = entry.Items[1]
	end
	s.HiddenValue = s.CurrentUnit.TrueTotalValue
end

local function resetSession(s)
	s.CurrentBid = GameConfig.BidStartPrice
	s.CurrentBidder = ""
	s.CurrentBidderType = ""
	s.CurrentBidderUserId = nil
	s.WinnerName = ""
	s.WinnerType = ""
	s.WinnerUserId = nil
	s.NpcBidders = {}
	s.CurrentUnit = nil
	s.ContainerItems = {}
	s.ContainerOpened = {}
	s.PendingByUser = {}
	s.RummageGraceEndsAt = nil
	s.BidExtensionsUsed = 0
	s.LastBidTime = -1000
	s.ActiveHumanBidders = {}
	s.HiddenValue = 0
	if s.Handles then
		MapBuilder.SetDoorOpen(s.Handles, false)
		MapBuilder.SetBarrier(s.Handles, true)
		MapBuilder.ResetContainers(s.Handles)
	end
end

-- Anti-snipe: a valid bid inside the window pushes the timer out, capped.
local function applyAntiSnipe(s)
	if timeLeft(s) < GameConfig.AntiSnipeWindow
		and s.BidExtensionsUsed < GameConfig.AntiSnipeMaxExtensions
	then
		s.StateEndsAt = now() + GameConfig.AntiSnipeExtension
		s.BidExtensionsUsed += 1
	end
end

-- Internal bid path once the target session is known.
local function tryBid(s, playerOrNil, amount, isNPC, npcName)
	if s.State ~= "Bidding" then
		return false, "Auction is not accepting bids right now."
	end
	amount = math.floor(tonumber(amount) or 0)
	local minValid = s.CurrentBid + ItemUtils.BidIncrementFor(s.CurrentBid)
	if amount < minValid then
		return false, "Bid must be at least $" .. minValid .. "."
	end
	if isNPC then
		s.CurrentBid = amount
		s.CurrentBidder = npcName or "NPC"
		s.CurrentBidderType = "NPC"
		s.CurrentBidderUserId = nil
		s.LastBidTime = now()
		applyAntiSnipe(s)
		broadcast(s)
		return true, "NPC bid accepted."
	end
	local player = playerOrNil
	if not player then
		return false, "Invalid bidder."
	end
	-- Local auction: must stand near THIS unit. Server-authoritative; the
	-- client button is only a UX hint.
	if not MapBuilder.IsWithinBidRadius(s.Handles, player, GameConfig.BidRadius) then
		return false, "Move closer to the auction to bid."
	end
	-- Affordability: cash must cover this bid PLUS any outstanding leading
	-- bids in the other session (deduct happens only on win; resolution
	-- re-validates as a backstop).
	local committed = leadingCommitment(player.UserId, s)
	if EconomyService.GetCash(player) < amount + committed then
		return false, "Not enough Cash (need $" .. (amount + committed) .. ")."
	end
	s.CurrentBid = amount
	s.CurrentBidder = player.Name
	s.CurrentBidderType = "Player"
	s.CurrentBidderUserId = player.UserId
	s.LastBidTime = now()
	if not s.ActiveHumanBidders[player.UserId] then
		s.ActiveHumanBidders[player.UserId] = true
		if GameConfig.DebugAuction then
			print(string.format("[SA] Unit %d ActiveHumanBidders=%d", s.UnitIndex, activeHumanCount(s)))
		end
	end
	applyAntiSnipe(s)
	broadcast(s)
	return true, "Bid accepted."
end

-- Server-side bid attempt targeting one session. bidderPlayer nil for NPCs.
-- Returns (ok: boolean, message: string). A bid for one unit never touches
-- the other session.
function AuctionService.TryBid(unitIndex, playerOrNil, amount, isNPC, npcName)
	local s, err = resolveSession(unitIndex)
	if not s then
		return false, err
	end
	return tryBid(s, playerOrNil, amount, isNPC, npcName)
end

-- Winner-only container opening within one session. Produces a PENDING
-- decision: the item is revealed but NOT added to the inventory. The player
-- must resolve it via TryKeepItem / TrySellItem. Returns (ok, itemOrMessage).
function AuctionService.TryOpenContainer(unitIndex, player, containerId)
	local s, err = resolveSession(unitIndex)
	if not s then
		return false, err
	end
	if s.State ~= "Rummaging" then
		return false, "Containers can only be opened during rummaging."
	end
	if s.WinnerUserId ~= player.UserId then
		return false, "Only the auction winner can open this box."
	end
	if s.PendingByUser[player.UserId] ~= nil then
		return false, "Choose Sell or Keep first."
	end
	if s.ContainerOpened[containerId] then
		return false, "That box is already opened."
	end
	local item = s.ContainerItems[containerId]
	if not item then
		return false, "Unknown container."
	end
	s.ContainerOpened[containerId] = true
	s.PendingByUser[player.UserId] = item
	MapBuilder.MarkContainerOpened(s.Handles, containerId)

	-- Push reveal UI to the opener (unitIndex travels alongside so Sell/Keep
	-- resolves against this same session).
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.ItemRevealed)
	if ev then
		ev:FireClient(player, item, s.UnitIndex)
	end
	return true, item
end

-- Resolve the pending decision as KEEP within one session. Only the matching
-- pending InstanceId is accepted; no client-supplied item data is trusted.
function AuctionService.TryKeepItem(unitIndex, player, instanceId)
	local s, err = resolveSession(unitIndex)
	if not s then
		return false, err
	end
	local pending = s.PendingByUser[player.UserId]
	if not pending then
		return false, "No pending item to keep."
	end
	if instanceId ~= nil and instanceId ~= pending.InstanceId then
		return false, "That item is no longer pending."
	end
	s.PendingByUser[player.UserId] = nil
	InventoryService.AddItem(player, pending)
	PlayerStatsService.Push(player)
	return true, pending
end

-- Resolve the pending decision as SELL within one session: FinalValue
-- straight to Cash, never into the inventory. Falls back to selling an owned
-- Bag item so the remote keeps its original contract. Server looks up all
-- values itself.
function AuctionService.TrySellItem(unitIndex, player, instanceId)
	local s, err = resolveSession(unitIndex)
	if not s then
		return false, err
	end
	local pending = s.PendingByUser[player.UserId]
	if pending and (instanceId == nil or instanceId == pending.InstanceId) then
		s.PendingByUser[player.UserId] = nil
		EconomyService.AddCash(player, pending.FinalValue)
		PlayerStatsService.Push(player)
		return true, pending.FinalValue
	end
	local removed = InventoryService.RemoveItem(player, instanceId)
	if not removed then
		return false, "Item not found in your inventory."
	end
	EconomyService.AddCash(player, removed.FinalValue)
	DisplayService.OnItemRemoved(player, instanceId)
	PlayerStatsService.Push(player)
	return true, removed.FinalValue
end

-- True while the session winner still owes a Sell/Keep decision (and is
-- still in the game). Gates the early Rummaging -> Cleanup transition.
local function winnerHasPending(s)
	if s.WinnerUserId == nil then
		return false
	end
	if s.PendingByUser[s.WinnerUserId] == nil then
		return false
	end
	return Players:GetPlayerByUserId(s.WinnerUserId) ~= nil
end

-- Grace expiry fallback: never delete value. Auto-keep the pending item so
-- an idle/disconnected-decision player keeps what they opened.
local function forceKeepPending(s, userId)
	local pending = s.PendingByUser[userId]
	if not pending then
		return
	end
	s.PendingByUser[userId] = nil
	local player = Players:GetPlayerByUserId(userId)
	if player then
		InventoryService.AddItem(player, pending)
		PlayerStatsService.Push(player)
		local notify = Remotes and Remotes:FindFirstChild(GameConfig.RemoteNames.Notify)
		if notify then
			notify:FireClient(player, { text = "Time expired - kept " .. pending.Name, closeReveal = true })
		end
	end
end

function AuctionService.ClearPlayer(player)
	if player then
		for _, s in pairs(Sessions) do
			s.PendingByUser[player.UserId] = nil
		end
	end
end

-- Per-session snapshot (also returned by the bid/open remotes).
function AuctionService.GetSessionSnapshot(unitIndex)
	local s = Sessions[tonumber(unitIndex)]
	if not s then
		return nil
	end
	return snapshotOf(s)
end

-- Full picture for client init/rejoin: BOTH sessions, keyed by unitIndex,
-- so a joining client never waits for the next state transition.
function AuctionService.GetSnapshot()
	local auctions = {}
	for i, s in pairs(Sessions) do
		auctions[i] = snapshotOf(s)
	end
	return { auctions = auctions }
end

-- Safety sweep only: right before the unit closes for the next auction,
-- move out anyone still physically inside. Any other time, players walk
-- freely and are never relocated. Never errors on missing characters.
local function ejectAnyoneStillInside(s)
	if s.Handles == nil then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		MapBuilder.MovePlayerOutsideIfInside(s.Handles, player)
	end
end

local function finishBidding(s)
	-- Determine winner.
	if s.CurrentBidder == "" then
		s.WinnerName = ""
		s.WinnerType = ""
		s.WinnerUserId = nil
	elseif s.CurrentBidderUserId ~= nil then
		local player = Players:GetPlayerByUserId(s.CurrentBidderUserId)
		-- Re-validated at resolution (backstop for simultaneous leads):
		-- a winner who can no longer cover the bid simply doesn't win,
		-- and DeductCash itself never drives a balance negative.
		if player and EconomyService.GetCash(player) >= s.CurrentBid then
			local ok = EconomyService.DeductCash(player, s.CurrentBid)
			if ok then
				s.WinnerName = player.Name
				s.WinnerType = "Player"
				s.WinnerUserId = player.UserId
				PlayerStatsService.RecordWin(player)
			else
				s.WinnerName = ""
				s.WinnerType = ""
				s.WinnerUserId = nil
			end
		else
			-- Winner left or can't pay: reset cleanly, no winner.
			s.WinnerName = ""
			s.WinnerType = ""
			s.WinnerUserId = nil
		end
	else
		-- NPC won.
		s.WinnerName = s.CurrentBidder
		s.WinnerType = "NPC"
		s.WinnerUserId = nil
	end
	if GameConfig.DebugAuction then
		print(string.format("[SA] Unit %d auction result winner=%s type=%s bid=%d trueValue=%d",
			s.UnitIndex, tostring(s.WinnerName), tostring(s.WinnerType), s.CurrentBid, s.HiddenValue))
	end
	setState(s, "Sold", GameConfig.SoldDuration)
end

-- One independent loop per session. Sessions never read or write each
-- other's state; they drift apart naturally via anti-snipe extensions and
-- rummage/cleanup durations.
local function runLoop(s)
	while true do
		broadcast(s)
		if s.State == "Waiting" then
			if timeLeft(s) <= 0 then
				resetSession(s)
				pregenerateContents(s)
				s.NpcBidders = NPCBidderService.CreateBidders(
					GameConfig.NPCs,
					if s.CurrentUnit then s.CurrentUnit.VisibleItems else {},
					if s.CurrentUnit then #s.CurrentUnit.HiddenItems else 0)
				-- Bidding starts at BidStartPrice; first valid bid must exceed it.
				s.CurrentBid = GameConfig.BidStartPrice - ItemUtils.BidIncrementFor(GameConfig.BidStartPrice)
				if s.CurrentBid < 0 then
					s.CurrentBid = 0
				end
				MapBuilder.SetDoorOpen(s.Handles, true)
				MapBuilder.SetBarrier(s.Handles, true)
				MapBuilder.ResetContainers(s.Handles)
				setState(s, "Inspection", GameConfig.InspectionDuration)
			end
			task.wait(0.5)
		elseif s.State == "Inspection" then
			if timeLeft(s) <= 0 then
				setState(s, "Bidding", GameConfig.BiddingDuration)
			end
			task.wait(0.5)
		elseif s.State == "Bidding" then
			-- NPC tick ~every 0.7s, reacting to THIS session's current bid
			-- no matter who placed it (human or NPC).
			local t = now()
			local function npcTryBid(name, amount)
				local ok, _msg = tryBid(s, nil, amount, true, name)
				return ok
			end
			NPCBidderService.Tick(s.NpcBidders, t, s.CurrentBid, s.CurrentBidder,
				s.LastBidTime, activeHumanCount(s), timeLeft(s), s.CurrentBidderType == "Player", npcTryBid)
			if timeLeft(s) <= 0 then
				finishBidding(s)
			end
			task.wait(0.7)
		elseif s.State == "Sold" then
			if timeLeft(s) <= 0 then
				if s.WinnerUserId ~= nil then
					-- Player won: no teleport. Entrance opens, winner walks
					-- in whenever they choose. Prompts turn on for Rummaging.
					MapBuilder.SetBarrier(s.Handles, false)
					MapBuilder.SetPromptsEnabled(s.Handles, true)
					setState(s, "Rummaging", GameConfig.RummageDuration)
				else
					-- NPC won or no bids: show result, then next auction.
					setState(s, "Cleanup", GameConfig.CleanupDuration)
				end
			end
			task.wait(0.5)
		elseif s.State == "Rummaging" then
			-- End early only when every box is opened AND the winner has
			-- resolved their pending decision (final-box reveal must survive).
			local allOpened = true
			for id, _ in pairs(s.ContainerItems) do
				if not s.ContainerOpened[id] then
					allOpened = false
					break
				end
			end
			if allOpened and not winnerHasPending(s) then
				s.RummageGraceEndsAt = nil
				-- Cleanup is a grace period: prompts off, but the entrance
				-- stays open so everyone can walk out naturally.
				MapBuilder.SetPromptsEnabled(s.Handles, false)
				MapBuilder.SetBarrier(s.Handles, false)
				setState(s, "Cleanup", GameConfig.CleanupDuration)
			elseif timeLeft(s) <= 0 then
				if winnerHasPending(s) then
					-- Decision grace: prompts off, reveal stays, player
					-- still gets to choose. Never auto-keep here.
					if s.RummageGraceEndsAt == nil then
						s.RummageGraceEndsAt = now() + GameConfig.DecisionGracePeriod
						MapBuilder.SetPromptsEnabled(s.Handles, false)
					elseif now() >= s.RummageGraceEndsAt then
						-- Grace ran out: keep (never delete), then Cleanup.
						if s.WinnerUserId ~= nil then
							forceKeepPending(s, s.WinnerUserId)
						end
						s.RummageGraceEndsAt = nil
						MapBuilder.SetBarrier(s.Handles, false)
						setState(s, "Cleanup", GameConfig.CleanupDuration)
					end
				else
					s.RummageGraceEndsAt = nil
					MapBuilder.SetPromptsEnabled(s.Handles, false)
					MapBuilder.SetBarrier(s.Handles, false)
					setState(s, "Cleanup", GameConfig.CleanupDuration)
				end
			end
			task.wait(0.5)
		elseif s.State == "Cleanup" then
			if timeLeft(s) <= 0 then
				-- Unit is about to close: safety-eject anyone still inside
				-- THIS unit, then reset. Nobody can be sealed in. The other
				-- session is untouched: no shared reset, no rotation.
				ejectAnyoneStillInside(s)
				resetSession(s)
				setState(s, "Waiting", GameConfig.WaitingDuration)
			end
			task.wait(0.5)
		else
			task.wait(0.5)
		end
	end
end

-- Stagger between session boot times (seconds): unit N waits (N-1) * 6s, so
-- the loops don't open lockstep (better UX, easier manual testing).
-- One-time only: afterwards durations and anti-snipe extensions drift the
-- sessions naturally. NOT a queue — no session ever waits for another
-- after boot. Generic over the session count.
local BOOT_STAGGER_STEP_SECONDS = 6

function AuctionService.Init(deps)
	EconomyService = deps.EconomyService
	InventoryService = deps.InventoryService
	NPCBidderService = deps.NPCBidderService
	MapBuilder = deps.MapBuilder
	local topHandles = deps.MapHandles
	if not topHandles or type(topHandles.Units) ~= "table"
		or topHandles.Units[1] == nil or topHandles.Units[2] == nil
		or topHandles.Units[3] == nil
	then
		error("[SA] AuctionService needs MapHandles.Units[1], [2] and [3] (see MapBuilder.GetHandles).", 0)
	end
	Remotes = deps.Remotes
	PlayerStatsService = deps.PlayerStatsService
	DisplayService = deps.DisplayService

	-- One independent session per physical unit. Generic loop: extending to
	-- another unit is one entry here (plus map + handles).
	Sessions = {}
	for i, unitHandles in ipairs(topHandles.Units) do
		Sessions[i] = newSession(i, unitHandles)
	end

	-- Wire RemoteFunctions. Clients address a session explicitly by
	-- unitIndex; the server validates everything against THAT session.
	local placeBid = Remotes:FindFirstChild(GameConfig.RemoteNames.PlaceBid)
	if placeBid and placeBid:IsA("RemoteFunction") then
		placeBid.OnServerInvoke = function(player, unitIndex, amount)
			local ok, msg = AuctionService.TryBid(unitIndex, player, amount, false, nil)
			return { ok = ok, message = msg, snapshot = AuctionService.GetSessionSnapshot(unitIndex) }
		end
	end
	local openContainer = Remotes:FindFirstChild(GameConfig.RemoteNames.OpenContainer)
	if openContainer and openContainer:IsA("RemoteFunction") then
		openContainer.OnServerInvoke = function(player, unitIndex, containerId)
			local ok, result = AuctionService.TryOpenContainer(unitIndex, player, containerId)
			return { ok = ok, result = result, snapshot = AuctionService.GetSessionSnapshot(unitIndex) }
		end
	end
	local sellItem = Remotes:FindFirstChild(GameConfig.RemoteNames.SellItem)
	if sellItem and sellItem:IsA("RemoteFunction") then
		sellItem.OnServerInvoke = function(player, unitIndex, instanceId)
			local ok, result = AuctionService.TrySellItem(unitIndex, player, instanceId)
			return { ok = ok, result = result, cash = EconomyService.GetCash(player) }
		end
	end
	local keepItem = Remotes:FindFirstChild(GameConfig.RemoteNames.KeepItem)
	if keepItem and keepItem:IsA("RemoteFunction") then
		keepItem.OnServerInvoke = function(player, unitIndex, instanceId)
			local ok, result = AuctionService.TryKeepItem(unitIndex, player, instanceId)
			return { ok = ok, result = result }
		end
	end

	-- ProximityPrompt path (server-authoritative, no client trust needed).
	-- Each prompt closure captures its OWN session: a prompt inside one
	-- unit can never read or mutate another unit's state.
	for _, s in pairs(Sessions) do
		for containerId, box in pairs(s.Handles.Containers) do
			local prompt = box:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Enabled = false
				prompt.Triggered:Connect(function(player)
					local ok, result = AuctionService.TryOpenContainer(s.UnitIndex, player, containerId)
					if not ok then
						local notify = Remotes:FindFirstChild(GameConfig.RemoteNames.Notify)
						if notify then
							notify:FireClient(player, tostring(result))
						end
					end
				end)
			end
		end
	end

	-- All units boot closed/inert; each loop drives its own from here.
	for _, s in pairs(Sessions) do
		resetSession(s)
		s.State = "Waiting"
		s.StateEndsAt = now() + GameConfig.WaitingDuration
			+ (s.UnitIndex - 1) * BOOT_STAGGER_STEP_SECONDS
	end
	for _, s in pairs(Sessions) do
		task.spawn(runLoop, s)
	end
end

return AuctionService
