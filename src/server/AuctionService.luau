--!nonstrict
-- StorageAuction M1 — auction state machine (authoritative server).
--
-- States: Waiting -> Inspection -> Bidding -> Sold -> Rummaging -> Cleanup -> loop
-- All bid validation, winner selection, cash deduction, item generation,
-- and container access checks happen here. Clients only get broadcasts.

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
local MapHandles = nil
local Remotes = nil
local PlayerStatsService = nil
local DisplayService = nil
local DebtService = nil

-- Auction state (single ACTIVE auction at a time, rotating tiers).
-- Option A: 3 physical units exist; exactly one runs an auction per cycle.
local State = "Waiting"
local StateEndsAt = os.clock() + GameConfig.WaitingDuration
local CurrentTierId = "Budget"
local CurrentTier = GameConfig.AuctionTiers.Budget
local TierIndex = 0 -- position in AuctionTierOrder; advanced each auction
local U = nil -- ACTIVE unit handles (MapBuilder per-unit table)
local CurrentBid = 0
local CurrentBidder = "" -- player Name or NPC name; "" = none
local CurrentBidderType = "" -- "Player" | "NPC" | "" (shared auction)
local CurrentBidderUserId = nil -- set only for player bids
local WinnerName = ""
local WinnerType = "" -- "Player" | "NPC" | ""
local WinnerUserId = nil -- nil => NPC won / no winner
local NpcBidders = {}
local HiddenValue = 0 -- server-only true total of hidden loot
local CurrentUnit = nil -- full UnitGeneratorService unit (server only)
local ContainerItems = {} -- [containerId] = itemInstance (pre-generated, hidden)
local ContainerOpened = {} -- [containerId] = true once opened
local BidExtensionsUsed = 0 -- anti-snipe cap counter, per auction
local LastBidTime = -1000 -- os.clock of last accepted bid (NPC pacing)
-- Active human bidders this auction: [UserId] = true on first accepted bid.
-- Session-local, reset every auction. Drives NPC filler pressure (never PvP).
local ActiveHumanBidders = {}

local function ActiveHumanCount()
	local n = 0
	for _ in pairs(ActiveHumanBidders) do
		n += 1
	end
	return n
end

-- Pending Sell/Keep decisions. [UserId] = itemInstance the player revealed
-- but has not resolved yet. Server-owned: opening never grants ownership;
-- only TryKeepItem moves the item into the inventory, only TrySellItem
-- converts it to Cash. One pending decision per player max.
local PendingByUser = {}

-- Decision grace deadline (os.clock timestamp) when the rummage timer
-- expires mid-decision; nil when no grace is active.
local RummageGraceEndsAt = nil

local function now()
	return os.clock()
end

local function timeLeft()
	return math.max(0, StateEndsAt - now())
end

local function broadcast()
	if not Remotes then
		return
	end
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.AuctionState)
	if ev then
		-- Safe fallbacks: a client snapshot field must never kill the loop.
		-- (Genuine map misconfiguration still errors loudly at selection.)
		local tier = CurrentTier or GameConfig.AuctionTiers.Budget
		local center = U and U.BidCenter
		local inspection = nil
		if State == "Inspection" and CurrentUnit and CurrentUnit.VisibleItems then
			local clues = {}
			for _, item in ipairs(CurrentUnit.VisibleItems) do
				-- Safe fields only: never values, never hidden identities.
				table.insert(clues, { name = item.Name, condition = item.ConditionName, rarity = item.Rarity })
			end
			inspection = {
				visibleCount = #CurrentUnit.VisibleItems,
				hiddenCount = #(CurrentUnit.HiddenItems or {}),
				totalItemCount = #(CurrentUnit.AllItems or CurrentUnit.VisibleItems),
				clues = clues,
			}
		end
		ev:FireAllClients({
			state = State,
			timeLeft = math.floor(timeLeft() + 0.5),
			tier = CurrentTierId,
			tierName = tier.DisplayName or "?",
			startingBid = tier.StartingBid or 0,
			currentBid = CurrentBid,
			bidder = CurrentBidder,
			bidderType = CurrentBidderType,
			minIncrement = ItemUtils.BidIncrementFor(CurrentBid),
			winner = WinnerName,
			winnerType = WinnerType,
			isWinner = false, -- client compares winner to its own name
			bidRadius = GameConfig.BidRadius,
			bidCenter = if center then { x = center.X, y = center.Y, z = center.Z } else nil,
			inspection = inspection, -- visible clues only; never true values
		})
	end
end

local function setState(next, duration)
	local prev = State
	State = next
	StateEndsAt = now() + duration
	if GameConfig.DebugAuction then
		print(string.format("[SA] STATE %s -> %s tier=%s", tostring(prev), tostring(next), tostring(CurrentTierId)))
	end
	broadcast()
end

local function pregenerateContents()
	ContainerItems = {}
	ContainerOpened = {}
	local rng = Random.new()
	-- Container set comes from the ACTIVE unit (see MapBuilder per-unit).
	local ids = {}
	for containerId, _box in pairs(U.Containers) do
		table.insert(ids, containerId)
	end
	-- The unit (hidden loot + visible clues + true total) is fixed NOW.
	-- Rummaging later reveals these exact instances, never rerolls.
	CurrentUnit = UnitGeneratorService.GenerateUnit(rng, ids, CurrentTierId)
	for _, entry in ipairs(CurrentUnit.Containers) do
		ContainerItems[entry.ContainerId] = entry.Items[1]
	end
	HiddenValue = CurrentUnit.TrueTotalValue
end

local function resetForNextAuction()
	CurrentBid = (CurrentTier and CurrentTier.StartingBid) or GameConfig.BidStartPrice
	CurrentBidder = ""
	CurrentBidderType = ""
	CurrentBidderUserId = nil
	WinnerName = ""
	WinnerType = ""
	WinnerUserId = nil
	NpcBidders = {}
	CurrentUnit = nil
	ContainerItems = {}
	ContainerOpened = {}
	PendingByUser = {}
	RummageGraceEndsAt = nil
	BidExtensionsUsed = 0
	LastBidTime = -1000
	ActiveHumanBidders = {}
	HiddenValue = 0
	if MapHandles and MapHandles.Units then
		-- Close/reset EVERY unit: only the active one was ever opened,
		-- but this is idempotent and crash-safe.
		for _, uh in pairs(MapHandles.Units) do
			MapBuilder.SetDoorOpen(uh, false)
			MapBuilder.SetBarrier(uh, true)
			MapBuilder.ResetContainers(uh)
		end
	end
end

-- Advance to the next tier in rotation and bind its physical unit.
-- Tiers whose map unit is missing are SKIPPED (warned once per skip) so one
-- bad unit can never freeze the rotation. Errors only when NO tier has a
-- unit at all (total misconfiguration — caller retries safely).
local function selectNextTierUnit()
	local order = GameConfig.AuctionTierOrder
	for step = 1, #order do
		TierIndex = (TierIndex % #order) + 1
		local tierId = order[TierIndex]
		local uh = MapHandles and MapHandles.Units and MapHandles.Units[tierId]
		if uh then
			CurrentTierId = tierId
			CurrentTier = GameConfig.AuctionTiers[CurrentTierId] or GameConfig.AuctionTiers.Standard
			U = uh
			return uh
		end
		warn("[SA] Skipping tier with no physical unit: " .. tostring(tierId))
	end
	error("[SA] No physical unit for ANY tier — check map TierId attributes.", 0)
end

-- Server-authoritative tier access. Returns nil when allowed, else a
-- human-readable denial (surfaced to the bidder, never silent).
local function tierAccessError(player)
	local t = CurrentTier
	if EconomyService.GetCash(player) < (t.MinAccessCash or 0) then
		return string.format("%s requires $%d cash.", t.DisplayName, t.MinAccessCash or 0)
	end
	local needWins = t.MinWins or 0
	local needWorth = t.MinNetWorth or 0
	if needWins > 0 or needWorth > 0 then
		local wins = PlayerStatsService.GetWins(player)
		local worth = DebtService.NetWorth(player)
		if wins < needWins and worth < needWorth then
			return string.format("%s requires %d wins or $%d net worth.",
				t.DisplayName, needWins, needWorth)
		end
	end
	return nil
end

-- Anti-snipe: a valid bid inside the window pushes the timer out, capped.
local function applyAntiSnipe()
	if timeLeft() < GameConfig.AntiSnipeWindow
		and BidExtensionsUsed < GameConfig.AntiSnipeMaxExtensions
	then
		StateEndsAt = now() + GameConfig.AntiSnipeExtension
		BidExtensionsUsed += 1
	end
end

-- Server-side bid attempt. bidderPlayer nil for NPCs.
-- Returns (ok: boolean, message: string)
function AuctionService.TryBid(playerOrNil, amount, isNPC, npcName)
	if State ~= "Bidding" then
		return false, "Auction is not accepting bids right now."
	end
	amount = math.floor(tonumber(amount) or 0)
	local minValid = CurrentBid + ItemUtils.BidIncrementFor(CurrentBid)
	if amount < minValid then
		return false, "Bid must be at least $" .. minValid .. "."
	end
	if isNPC then
		CurrentBid = amount
		CurrentBidder = npcName or "NPC"
		CurrentBidderType = "NPC"
		CurrentBidderUserId = nil
		LastBidTime = now()
		applyAntiSnipe()
		broadcast()
		return true, "NPC bid accepted."
	end
	local player = playerOrNil
	if not player then
		return false, "Invalid bidder."
	end
	-- Local auction: must stand near the ACTIVE unit. Server-authoritative;
	-- the client button is only a UX hint.
	if not MapBuilder.IsWithinBidRadius(U, player, GameConfig.BidRadius) then
		return false, "Move closer to the auction to bid."
	end
	-- Tier access: server-authoritative, never silent on denial.
	local accessErr = tierAccessError(player)
	if accessErr then
		return false, accessErr
	end
	-- affordability check (deduct only on win for M1 simplicity)
	if EconomyService.GetCash(player) < amount then
		return false, "Not enough Cash (need $" .. amount .. ")."
	end
	CurrentBid = amount
	CurrentBidder = player.Name
	CurrentBidderType = "Player"
	CurrentBidderUserId = player.UserId
	LastBidTime = now()
	if not ActiveHumanBidders[player.UserId] then
		ActiveHumanBidders[player.UserId] = true
		if GameConfig.DebugAuction then
			print(string.format("[SA] ActiveHumanBidders=%d", ActiveHumanCount()))
		end
	end
	applyAntiSnipe()
	broadcast()
	return true, "Bid accepted."
end

-- Winner-only container opening. Produces a PENDING decision: the item is
-- revealed but NOT added to the inventory. The player must resolve it via
-- TryKeepItem / TrySellItem. Returns (ok, itemOrMessage).
function AuctionService.TryOpenContainer(player, containerId)
	if State ~= "Rummaging" then
		return false, "Containers can only be opened during rummaging."
	end
	if WinnerUserId ~= player.UserId then
		return false, "Only the auction winner can open this box."
	end
	if U == nil or U.Containers[containerId] == nil then
		return false, "That box is not part of this auction."
	end
	if PendingByUser[player.UserId] ~= nil then
		return false, "Choose Sell or Keep first."
	end
	if ContainerOpened[containerId] then
		return false, "That box is already opened."
	end
	local item = ContainerItems[containerId]
	if not item then
		return false, "Unknown container."
	end
	ContainerOpened[containerId] = true
	PendingByUser[player.UserId] = item
	MapBuilder.MarkContainerOpened(U, containerId)

	-- Push reveal UI to the opener.
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.ItemRevealed)
	if ev then
		ev:FireClient(player, item)
	end
	return true, item
end

-- Resolve the pending decision as KEEP. Only the matching pending
-- InstanceId is accepted; no client-supplied item data is trusted.
function AuctionService.TryKeepItem(player, instanceId)
	local pending = PendingByUser[player.UserId]
	if not pending then
		return false, "No pending item to keep."
	end
	if instanceId ~= nil and instanceId ~= pending.InstanceId then
		return false, "That item is no longer pending."
	end
	PendingByUser[player.UserId] = nil
	InventoryService.AddItem(player, pending)
	PlayerStatsService.Push(player)
	return true, pending
end

-- Resolve the pending decision as SELL: FinalValue converts to Cash via
-- DebtService (automatic loan collection), never into the inventory. Falls
-- back to selling an owned Bag item. Server looks up all values itself.
-- Success returns { cashGain, debtPaid, debtRemaining } (never raw totals).
function AuctionService.TrySellItem(player, instanceId)
	local pending = PendingByUser[player.UserId]
	if pending and (instanceId == nil or instanceId == pending.InstanceId) then
		PendingByUser[player.UserId] = nil
		local sale = DebtService.CollectFromSale(player, pending.FinalValue)
		return true, sale
	end
	local removed = InventoryService.RemoveItem(player, instanceId)
	if not removed then
		return false, "Item not found in your inventory."
	end
	local sale = DebtService.CollectFromSale(player, removed.FinalValue)
	DisplayService.OnItemRemoved(player, instanceId)
	return true, sale
end

-- Recovery eligibility needs this (DebtService dep, no require cycle:
-- AuctionService never requires DebtService at file top).
function AuctionService.HasPendingItem(player)
	if not player then
		return false
	end
	return PendingByUser[player.UserId] ~= nil
end

-- True while the current winner still owes a Sell/Keep decision (and is
-- still in the game). Gates the early Rummaging -> Cleanup transition.
local function winnerHasPending()
	if WinnerUserId == nil then
		return false
	end
	if PendingByUser[WinnerUserId] == nil then
		return false
	end
	return Players:GetPlayerByUserId(WinnerUserId) ~= nil
end

-- Grace expiry fallback: never delete value. Auto-keep the pending item so
-- an idle/disconnected-decision player keeps what they opened.
local function forceKeepPending(userId)
	local pending = PendingByUser[userId]
	if not pending then
		return
	end
	PendingByUser[userId] = nil
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
		PendingByUser[player.UserId] = nil
	end
end

function AuctionService.GetSnapshot()
	local center = U and U.BidCenter
	local tier = CurrentTier or GameConfig.AuctionTiers.Budget
	return {
		state = State,
		timeLeft = math.floor(timeLeft() + 0.5),
		tier = CurrentTierId,
		tierName = tier.DisplayName or "?",
		startingBid = tier.StartingBid or 0,
		currentBid = CurrentBid,
		bidder = CurrentBidder,
		bidderType = CurrentBidderType,
		minIncrement = ItemUtils.BidIncrementFor(CurrentBid),
		winner = WinnerName,
		winnerType = WinnerType,
		bidRadius = GameConfig.BidRadius,
		bidCenter = if center then { x = center.X, y = center.Y, z = center.Z } else nil,
	}
end

-- Safety sweep only: right before the unit closes for the next auction,
-- move out anyone still physically inside. Any other time, players walk
-- freely and are never relocated. Never errors on missing characters.
local function ejectAnyoneStillInside()
	if U == nil then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		MapBuilder.MovePlayerOutsideIfInside(U, player)
	end
end

local function finishBidding()
	-- Determine winner.
	if CurrentBidder == "" then
		WinnerName = ""
		WinnerType = ""
		WinnerUserId = nil
	elseif CurrentBidderUserId ~= nil then
		local player = Players:GetPlayerByUserId(CurrentBidderUserId)
		if player and EconomyService.GetCash(player) >= CurrentBid then
			local ok = EconomyService.DeductCash(player, CurrentBid)
			if ok then
				WinnerName = player.Name
				WinnerType = "Player"
				WinnerUserId = player.UserId
				PlayerStatsService.RecordWin(player)
			else
				WinnerName = ""
				WinnerType = ""
				WinnerUserId = nil
			end
		else
			-- Winner left or can't pay: reset cleanly, no winner.
			WinnerName = ""
			WinnerType = ""
			WinnerUserId = nil
		end
	else
		-- NPC won.
		WinnerName = CurrentBidder
		WinnerType = "NPC"
		WinnerUserId = nil
	end
	if GameConfig.DebugAuction then
		print(string.format("[SA] Auction result winner=%s type=%s bid=%d trueValue=%d",
			tostring(WinnerName), tostring(WinnerType), CurrentBid, HiddenValue))
	end
	setState("Sold", GameConfig.SoldDuration)
end

local function stateLoop()
	while true do
		-- Guarded iteration: ANY runtime error is logged with a traceback
		-- and the loop recovers to idle Waiting instead of dying silently.
		-- Every state (including Inspection) therefore always terminates,
		-- advances, or retries — never freezes forever.
		local ok, err = xpcall(function()
		broadcast()
		if State == "Waiting" then
			if timeLeft() <= 0 then
				resetForNextAuction()
				-- Bind the next tier's physical unit. Guarded: a map
				-- misconfiguration retries instead of killing the loop.
				local ok, uh = pcall(selectNextTierUnit)
				if not ok or not uh then
					warn("[SA] Tier select failed: " .. tostring(uh) .. " — retrying.")
					StateEndsAt = now() + 10
				else
					pregenerateContents()
					NpcBidders = NPCBidderService.CreateBidders(
						GameConfig.NPCs,
						if CurrentUnit then CurrentUnit.VisibleItems else {},
						if CurrentUnit then #CurrentUnit.HiddenItems else 0)
					-- Bidding starts at the tier starting bid; first valid bid
					-- must exceed it by one increment.
					CurrentBid = CurrentTier.StartingBid - ItemUtils.BidIncrementFor(CurrentTier.StartingBid)
					if CurrentBid < 0 then
						CurrentBid = 0
					end
					if GameConfig.DebugAuction then
						print(string.format("[SA] Tier=%s StartingBid=%d",
							CurrentTierId, CurrentTier.StartingBid))
					end
					MapBuilder.SetDoorOpen(U, true)
					MapBuilder.SetBarrier(U, true)
					MapBuilder.ResetContainers(U)
					setState("Inspection", GameConfig.InspectionDuration)
				end
			end
			task.wait(0.5)
		elseif State == "Inspection" then
			if timeLeft() <= 0 then
				setState("Bidding", GameConfig.BiddingDuration)
			end
			task.wait(0.5)
		elseif State == "Bidding" then
			-- NPC tick ~every 0.7s, reacting to the GLOBAL current bid
			-- no matter who placed it (human or NPC). Tier pressure applies
			-- only while no human participates (empty-server filler boost).
			local t = now()
			local function npcTryBid(name, amount)
				local ok, _msg = AuctionService.TryBid(nil, amount, true, name)
				return ok
			end
			local tierMult = if ActiveHumanCount() == 0 then (CurrentTier.NPCPressureMult or 1) else 1
			NPCBidderService.Tick(NpcBidders, t, CurrentBid, CurrentBidder,
				LastBidTime, ActiveHumanCount(), timeLeft(), CurrentBidderType == "Player", tierMult, npcTryBid)
			if timeLeft() <= 0 then
				finishBidding()
			end
			task.wait(0.7)
		elseif State == "Sold" then
			if timeLeft() <= 0 then
				if WinnerUserId ~= nil then
					-- Player won: no teleport. Entrance opens, winner walks
					-- in whenever they choose. Prompts turn on for Rummaging.
					MapBuilder.SetBarrier(U, false)
					MapBuilder.SetPromptsEnabled(U, true)
					setState("Rummaging", GameConfig.RummageDuration)
				else
					-- NPC won or no bids: show result, then next auction.
					setState("Cleanup", GameConfig.CleanupDuration)
				end
			end
			task.wait(0.5)
		elseif State == "Rummaging" then
			-- End early only when every box is opened AND the winner has
			-- resolved their pending decision (final-box reveal must survive).
			local allOpened = true
			for id, _ in pairs(ContainerItems) do
				if not ContainerOpened[id] then
					allOpened = false
					break
				end
			end
			if allOpened and not winnerHasPending() then
				RummageGraceEndsAt = nil
				-- Cleanup is a grace period: prompts off, but the entrance
				-- stays open so everyone can walk out naturally.
				MapBuilder.SetPromptsEnabled(U, false)
				MapBuilder.SetBarrier(U, false)
				setState("Cleanup", GameConfig.CleanupDuration)
			elseif timeLeft() <= 0 then
				if winnerHasPending() then
					-- Decision grace: prompts off, reveal stays, player
					-- still gets to choose. Never auto-keep here.
					if RummageGraceEndsAt == nil then
						RummageGraceEndsAt = now() + GameConfig.DecisionGracePeriod
						MapBuilder.SetPromptsEnabled(U, false)
					elseif now() >= RummageGraceEndsAt then
						-- Grace ran out: keep (never delete), then Cleanup.
						if WinnerUserId ~= nil then
							forceKeepPending(WinnerUserId)
						end
						RummageGraceEndsAt = nil
						MapBuilder.SetBarrier(U, false)
						setState("Cleanup", GameConfig.CleanupDuration)
					end
				else
					RummageGraceEndsAt = nil
					MapBuilder.SetPromptsEnabled(U, false)
					MapBuilder.SetBarrier(U, false)
					setState("Cleanup", GameConfig.CleanupDuration)
				end
			end
			task.wait(0.5)
		elseif State == "Cleanup" then
			if timeLeft() <= 0 then
				-- Unit is about to close: safety-eject anyone still inside,
				-- then reset. Nobody can be sealed in.
				ejectAnyoneStillInside()
				resetForNextAuction()
				setState("Waiting", GameConfig.WaitingDuration)
			end
			task.wait(0.5)
		else
			task.wait(0.5)
		end
		end, debug.traceback)
		if not ok then
			warn("[SA] Auction loop error:\n" .. tostring(err))
			-- Recover (itself guarded) with a backoff so a persistent
			-- failure warns periodically instead of tight-looping.
			local ok2, err2 = xpcall(function()
				resetForNextAuction()
				State = "Waiting"
				StateEndsAt = now() + GameConfig.WaitingDuration
			end, debug.traceback)
			if not ok2 then
				warn("[SA] Auction recovery failed:\n" .. tostring(err2))
			end
			task.wait(2)
		end
	end
end

function AuctionService.Init(deps)
	EconomyService = deps.EconomyService
	InventoryService = deps.InventoryService
	NPCBidderService = deps.NPCBidderService
	MapBuilder = deps.MapBuilder
	MapHandles = deps.MapHandles
	Remotes = deps.Remotes
	PlayerStatsService = deps.PlayerStatsService
	DisplayService = deps.DisplayService
	DebtService = deps.DebtService

	-- Startup validation: every rotation tier needs a physical unit. Missing
	-- tiers are skipped at runtime (see selectNextTierUnit); absent entirely
	-- the loop retries loudly instead of freezing silently.
	if GameConfig.AuctionTierOrder then
		for _, tierId in ipairs(GameConfig.AuctionTierOrder) do
			local uh = MapHandles and MapHandles.Units and MapHandles.Units[tierId]
			if not uh then
				warn("[SA] No physical unit for tier " .. tostring(tierId) .. " — it will be skipped in rotation.")
			else
				local problems = {}
				if not uh.Door then table.insert(problems, "Door") end
				if not uh.Barrier then table.insert(problems, "Barrier") end
				if not uh.BidCenter then table.insert(problems, "BidCenter") end
				if not uh.Containers or next(uh.Containers) == nil then table.insert(problems, "Containers") end
				if #problems > 0 then
					warn("[SA] Unit for tier " .. tostring(tierId) .. " is missing: " .. table.concat(problems, ", "))
				end
			end
		end
	end

	-- Wire RemoteFunctions.
	local placeBid = Remotes:FindFirstChild(GameConfig.RemoteNames.PlaceBid)
	if placeBid and placeBid:IsA("RemoteFunction") then
		placeBid.OnServerInvoke = function(player, amount)
			local ok, msg = AuctionService.TryBid(player, amount, false, nil)
			return { ok = ok, message = msg, snapshot = AuctionService.GetSnapshot() }
		end
	end
	local openContainer = Remotes:FindFirstChild(GameConfig.RemoteNames.OpenContainer)
	if openContainer and openContainer:IsA("RemoteFunction") then
		openContainer.OnServerInvoke = function(player, containerId)
			local ok, result = AuctionService.TryOpenContainer(player, containerId)
			return { ok = ok, result = result, snapshot = AuctionService.GetSnapshot() }
		end
	end
	local sellItem = Remotes:FindFirstChild(GameConfig.RemoteNames.SellItem)
	if sellItem and sellItem:IsA("RemoteFunction") then
		sellItem.OnServerInvoke = function(player, instanceId)
			local ok, result = AuctionService.TrySellItem(player, instanceId)
			return { ok = ok, result = result, cash = EconomyService.GetCash(player) }
		end
	end
	local keepItem = Remotes:FindFirstChild(GameConfig.RemoteNames.KeepItem)
	if keepItem and keepItem:IsA("RemoteFunction") then
		keepItem.OnServerInvoke = function(player, instanceId)
			local ok, result = AuctionService.TryKeepItem(player, instanceId)
			return { ok = ok, result = result }
		end
	end

	-- ProximityPrompt path (server-authoritative, no client trust needed).
	-- Rejections are pushed back as toasts so non-winners get feedback.
	-- Wired for EVERY unit once; only the active unit's prompts are enabled.
	if MapHandles and MapHandles.Units then
		for _, uh in pairs(MapHandles.Units) do
			for containerId, box in pairs(uh.Containers) do
				local prompt = box:FindFirstChildOfClass("ProximityPrompt")
				if prompt then
					prompt.Enabled = false
					prompt.Triggered:Connect(function(player)
						local ok, result = AuctionService.TryOpenContainer(player, containerId)
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
	end

	resetForNextAuction()
	State = "Waiting"
	StateEndsAt = now() + GameConfig.WaitingDuration
	-- Pre-bind the first tier's unit so pre-auction broadcasts already carry
	-- its bid center (the Waiting branch rebinds identically each cycle).
	if MapHandles.Units then
		U = MapHandles.Units.Budget
	end
	task.spawn(stateLoop)
end

return AuctionService
