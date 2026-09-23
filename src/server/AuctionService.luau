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

local AuctionService = {}

local EconomyService = nil
local InventoryService = nil
local NPCBidderService = nil
local MapBuilder = nil
local MapHandles = nil
local Remotes = nil
local PlayerStatsService = nil
local DisplayService = nil

-- Auction state (single active unit for M1)
local State = "Waiting"
local StateEndsAt = os.clock() + GameConfig.WaitingDuration
local CurrentBid = 0
local CurrentBidder = "" -- player Name or NPC name; "" = none
local CurrentBidderUserId = nil -- set only for player bids
local WinnerName = ""
local WinnerUserId = nil -- nil => NPC won / no winner
local NpcBidders = {}
local HiddenValue = 0
local ContainerItems = {} -- [containerId] = itemInstance (pre-generated, hidden)
local ContainerOpened = {} -- [containerId] = true once opened

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
		local center = MapHandles and MapHandles.BidCenter
		ev:FireAllClients({
			state = State,
			timeLeft = math.floor(timeLeft() + 0.5),
			currentBid = CurrentBid,
			bidder = CurrentBidder,
			minIncrement = GameConfig.MinBidIncrement,
			winner = WinnerName,
			isWinner = false, -- client compares winner to its own name
			bidRadius = GameConfig.BidRadius,
			bidCenter = if center then { x = center.X, y = center.Y, z = center.Z } else nil,
		})
	end
end

local function setState(next, duration)
	State = next
	StateEndsAt = now() + duration
	broadcast()
end

local function hiddenTotal()
	local total = 0
	for _, item in pairs(ContainerItems) do
		total += item.FinalValue
	end
	return total
end

local function pregenerateContents()
	ContainerItems = {}
	ContainerOpened = {}
	local rng = Random.new()
	-- Container set is discovered from the Studio map (see MapBuilder).
	for containerId, _box in pairs(MapHandles.Containers) do
		ContainerItems[containerId] = ItemUtils.GenerateInstance(rng)
	end
	HiddenValue = hiddenTotal()
end

local function resetForNextAuction()
	CurrentBid = GameConfig.BidStartPrice
	CurrentBidder = ""
	CurrentBidderUserId = nil
	WinnerName = ""
	WinnerUserId = nil
	NpcBidders = {}
	ContainerItems = {}
	ContainerOpened = {}
	PendingByUser = {}
	RummageGraceEndsAt = nil
	HiddenValue = 0
	if MapHandles then
		MapBuilder.SetDoorOpen(MapHandles, false)
		MapBuilder.SetBarrier(MapHandles, true)
		MapBuilder.ResetContainers(MapHandles)
	end
end

-- Server-side bid attempt. bidderPlayer nil for NPCs.
-- Returns (ok: boolean, message: string)
function AuctionService.TryBid(playerOrNil, amount, isNPC, npcName)
	if State ~= "Bidding" then
		return false, "Auction is not accepting bids right now."
	end
	amount = math.floor(tonumber(amount) or 0)
	local minValid = CurrentBid + GameConfig.MinBidIncrement
	if amount < minValid then
		return false, "Bid must be at least $" .. minValid .. "."
	end
	if isNPC then
		CurrentBid = amount
		CurrentBidder = npcName or "NPC"
		CurrentBidderUserId = nil
		broadcast()
		return true, "NPC bid accepted."
	end
	local player = playerOrNil
	if not player then
		return false, "Invalid bidder."
	end
	-- Local auction: must stand near the unit. Server-authoritative; the
	-- client button is only a UX hint.
	if not MapBuilder.IsWithinBidRadius(MapHandles, player, GameConfig.BidRadius) then
		return false, "Move closer to the auction to bid."
	end
	-- affordability check (deduct only on win for M1 simplicity)
	if EconomyService.GetCash(player) < amount then
		return false, "Not enough Cash (need $" .. amount .. ")."
	end
	CurrentBid = amount
	CurrentBidder = player.Name
	CurrentBidderUserId = player.UserId
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
	MapBuilder.MarkContainerOpened(MapHandles, containerId)

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

-- Resolve the pending decision as SELL: FinalValue straight to Cash, never
-- into the inventory. Falls back to selling an owned Bag item so the remote
-- keeps its original contract. Server looks up all values itself.
function AuctionService.TrySellItem(player, instanceId)
	local pending = PendingByUser[player.UserId]
	if pending and (instanceId == nil or instanceId == pending.InstanceId) then
		PendingByUser[player.UserId] = nil
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
	local center = MapHandles and MapHandles.BidCenter
	return {
		state = State,
		timeLeft = math.floor(timeLeft() + 0.5),
		currentBid = CurrentBid,
		bidder = CurrentBidder,
		minIncrement = GameConfig.MinBidIncrement,
		winner = WinnerName,
		bidRadius = GameConfig.BidRadius,
		bidCenter = if center then { x = center.X, y = center.Y, z = center.Z } else nil,
	}
end

-- Safety sweep only: right before the unit closes for the next auction,
-- move out anyone still physically inside. Any other time, players walk
-- freely and are never relocated. Never errors on missing characters.
local function ejectAnyoneStillInside()
	if MapHandles == nil then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		MapBuilder.MovePlayerOutsideIfInside(MapHandles, player)
	end
end

local function finishBidding()
	-- Determine winner.
	if CurrentBidder == "" then
		WinnerName = ""
		WinnerUserId = nil
	elseif CurrentBidderUserId ~= nil then
		local player = Players:GetPlayerByUserId(CurrentBidderUserId)
		if player and EconomyService.GetCash(player) >= CurrentBid then
			local ok = EconomyService.DeductCash(player, CurrentBid)
			if ok then
				WinnerName = player.Name
				WinnerUserId = player.UserId
				PlayerStatsService.RecordWin(player)
			else
				WinnerName = ""
				WinnerUserId = nil
			end
		else
			-- Winner left or can't pay: reset cleanly, no winner.
			WinnerName = ""
			WinnerUserId = nil
		end
	else
		-- NPC won.
		WinnerName = CurrentBidder
		WinnerUserId = nil
	end
	setState("Sold", GameConfig.SoldDuration)
end

local function stateLoop()
	while true do
		broadcast()
		if State == "Waiting" then
			if timeLeft() <= 0 then
				resetForNextAuction()
				pregenerateContents()
				NpcBidders = NPCBidderService.CreateBidders(GameConfig.NPCs, HiddenValue)
				-- Bidding starts at BidStartPrice; first valid bid must exceed it.
				CurrentBid = GameConfig.BidStartPrice - GameConfig.MinBidIncrement
				if CurrentBid < 0 then
					CurrentBid = 0
				end
				MapBuilder.SetDoorOpen(MapHandles, true)
				MapBuilder.SetBarrier(MapHandles, true)
				MapBuilder.ResetContainers(MapHandles)
				setState("Inspection", GameConfig.InspectionDuration)
			end
			task.wait(0.5)
		elseif State == "Inspection" then
			if timeLeft() <= 0 then
				setState("Bidding", GameConfig.BiddingDuration)
			end
			task.wait(0.5)
		elseif State == "Bidding" then
			-- NPC tick ~every 0.7s
			local t = now()
			local function npcTryBid(name, amount, _isNPC)
				AuctionService.TryBid(nil, amount, true, name)
			end
			NPCBidderService.Tick(NpcBidders, t, CurrentBid, GameConfig.MinBidIncrement, npcTryBid)
			if timeLeft() <= 0 then
				finishBidding()
			end
			task.wait(0.7)
		elseif State == "Sold" then
			if timeLeft() <= 0 then
				if WinnerUserId ~= nil then
					-- Player won: no teleport. Entrance opens, winner walks
					-- in whenever they choose. Prompts turn on for Rummaging.
					MapBuilder.SetBarrier(MapHandles, false)
					MapBuilder.SetPromptsEnabled(MapHandles, true)
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
				MapBuilder.SetPromptsEnabled(MapHandles, false)
				MapBuilder.SetBarrier(MapHandles, false)
				setState("Cleanup", GameConfig.CleanupDuration)
			elseif timeLeft() <= 0 then
				if winnerHasPending() then
					-- Decision grace: prompts off, reveal stays, player
					-- still gets to choose. Never auto-keep here.
					if RummageGraceEndsAt == nil then
						RummageGraceEndsAt = now() + GameConfig.DecisionGracePeriod
						MapBuilder.SetPromptsEnabled(MapHandles, false)
					elseif now() >= RummageGraceEndsAt then
						-- Grace ran out: keep (never delete), then Cleanup.
						if WinnerUserId ~= nil then
							forceKeepPending(WinnerUserId)
						end
						RummageGraceEndsAt = nil
						MapBuilder.SetBarrier(MapHandles, false)
						setState("Cleanup", GameConfig.CleanupDuration)
					end
				else
					RummageGraceEndsAt = nil
					MapBuilder.SetPromptsEnabled(MapHandles, false)
					MapBuilder.SetBarrier(MapHandles, false)
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
	if MapHandles then
		for containerId, box in pairs(MapHandles.Containers) do
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

	resetForNextAuction()
	State = "Waiting"
	StateEndsAt = now() + GameConfig.WaitingDuration
	task.spawn(stateLoop)
end

return AuctionService
