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
		ev:FireAllClients({
			state = State,
			timeLeft = math.floor(timeLeft() + 0.5),
			currentBid = CurrentBid,
			bidder = CurrentBidder,
			minIncrement = GameConfig.MinBidIncrement,
			winner = WinnerName,
			isWinner = false, -- client compares winner to its own name
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
	if MapHandles then
		for containerId, _box in pairs(MapHandles.Containers) do
			ContainerItems[containerId] = ItemUtils.GenerateInstance(rng)
		end
	else
		for i = 1, GameConfig.ContainersPerUnit do
			ContainerItems["box_" .. i] = ItemUtils.GenerateInstance(rng)
		end
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

-- Winner-only container opening. Returns (ok, itemOrMessage).
function AuctionService.TryOpenContainer(player, containerId)
	if State ~= "Rummaging" then
		return false, "Containers can only be opened during rummaging."
	end
	if WinnerUserId ~= player.UserId then
		return false, "Only the auction winner can open containers."
	end
	if ContainerOpened[containerId] then
		return false, "That box is already opened."
	end
	local item = ContainerItems[containerId]
	if not item then
		return false, "Unknown container."
	end
	ContainerOpened[containerId] = true
	InventoryService.AddItem(player, item)

	if MapHandles and MapHandles.Containers[containerId] then
		local box = MapHandles.Containers[containerId]
		box:SetAttribute("Opened", true)
		box.Transparency = 0.6
	end

	-- Push reveal UI to the opener.
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.ItemRevealed)
	if ev then
		ev:FireClient(player, item)
	end
	return true, item
end

-- Sell an owned item instance. Server looks up FinalValue — never trusts client.
function AuctionService.TrySellItem(player, instanceId)
	local removed = InventoryService.RemoveItem(player, instanceId)
	if not removed then
		return false, "Item not found in your inventory."
	end
	EconomyService.AddCash(player, removed.FinalValue)
	return true, removed.FinalValue
end

function AuctionService.GetSnapshot()
	return {
		state = State,
		timeLeft = math.floor(timeLeft() + 0.5),
		currentBid = CurrentBid,
		bidder = CurrentBidder,
		minIncrement = GameConfig.MinBidIncrement,
		winner = WinnerName,
	}
end

local function teleportWinnerInside()
	if WinnerUserId == nil then
		return
	end
	local player = Players:GetPlayerByUserId(WinnerUserId)
	if not player then
		return
	end
	local char = player.Character
	if not char then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and MapHandles then
		root.CFrame = CFrame.new(MapHandles.UnitCenter + Vector3.new(0, 5, 2))
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
					MapBuilder.SetBarrier(MapHandles, false)
					MapBuilder.SetPromptsEnabled(MapHandles, true)
					teleportWinnerInside()
					setState("Rummaging", GameConfig.RummageDuration)
				else
					-- NPC won or no bids: show result, then next auction.
					setState("Cleanup", GameConfig.CleanupDuration)
				end
			end
			task.wait(0.5)
		elseif State == "Rummaging" then
			-- End early if all boxes opened.
			local allOpened = true
			for id, _ in pairs(ContainerItems) do
				if not ContainerOpened[id] then
					allOpened = false
					break
				end
			end
			if allOpened or timeLeft() <= 0 then
				setState("Cleanup", GameConfig.CleanupDuration)
			end
			task.wait(0.5)
		elseif State == "Cleanup" then
			if timeLeft() <= 0 then
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

	-- ProximityPrompt path (server-authoritative, no client trust needed).
	if MapHandles then
		for containerId, box in pairs(MapHandles.Containers) do
			local prompt = box:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Enabled = false
				prompt.Triggered:Connect(function(player)
					AuctionService.TryOpenContainer(player, containerId)
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
