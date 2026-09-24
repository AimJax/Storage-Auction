--!nonstrict
-- StorageAuction — client glue: remotes, bid/sell/open wiring.
-- Tracks BOTH auction sessions (snapshots[unitIndex]) and shows the HUD for
-- whichever session the player is physically nearest to (inside its radius).
-- All bidding/sell/keep calls address that session explicitly by unitIndex;
-- the server validates everything authoritatively.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local UIController = require(script.Parent.UIController)

local AuctionClient = {}

local player = Players.LocalPlayer
local remotes = nil

local function blankSnapshot()
	return { unitIndex = 0, state = "Waiting", timeLeft = 0, currentBid = 0, bidder = "", minIncrement = 25, winner = "" }
end

-- One snapshot per session; the server broadcasts each with its unitIndex.
local snapshots = { [1] = blankSnapshot(), [2] = blankSnapshot() }
local prevStates = { [1] = "Waiting", [2] = "Waiting" }
local lastSeenBid = { [1] = -1, [2] = -1 }
-- Session the local player is currently interacting with (nearest center
-- inside its radius), or nil when near neither. Pure UX; server validates.
local nearUnit = nil
local inRadius = false
local cash = 0
-- Session that produced the open reveal panel (Sell/Keep resolves there).
local revealUnit = nil
local displayState = { slots = {} }

local function getRemote(name, className)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = remotes:WaitForChild(name, 10)
	end
	return r
end

local function formatMoney(n)
	n = math.floor(tonumber(n) or 0)
	local s = tostring(n)
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, #s - 3)
	end
	return s .. out
end

-- Snapshot currently on screen: the nearby session's, or a blank hidden one.
local function displaySnapshot()
	if nearUnit and snapshots[nearUnit] then
		return snapshots[nearUnit]
	end
	return blankSnapshot()
end

function AuctionClient.Start()
	remotes = ReplicatedStorage:WaitForChild(GameConfig.RemotesFolderName)
	local refs = UIController.Build()
	local function refresh()
		UIController.UpdateStatus(displaySnapshot(), cash, player.Name, inRadius)
	end
	refresh()

	local function handleSessionData(data)
		local idx = tonumber(data.unitIndex)
		if idx ~= 1 and idx ~= 2 then
			return
		end
		local prevState = prevStates[idx]
		prevStates[idx] = data.state
		snapshots[idx] = data
		refresh()
		-- Toasts only for the session the player is standing at.
		local watching = inRadius and nearUnit == idx
		if watching
			and data.state == "Bidding"
			and (data.currentBid or 0) > lastSeenBid[idx]
			and (data.bidder or "") ~= ""
			and data.bidder ~= player.Name
		then
			UIController.ShowToast(data.bidder .. " bid $" .. formatMoney(data.currentBid))
		end
		lastSeenBid[idx] = data.currentBid or 0
		if data.state == "Sold" and prevState ~= "Sold" then
			lastSeenBid[idx] = -1 -- reset for next auction
			if watching then
				if data.winner and data.winner ~= "" then
					if data.winner == player.Name then
						UIController.ShowToast("You won unit " .. idx .. " for $" .. formatMoney(data.currentBid) .. "!", 4)
					else
						UIController.ShowToast(data.winner .. " won unit " .. idx .. " for $" .. formatMoney(data.currentBid))
					end
				else
					UIController.ShowToast("No winner at unit " .. idx)
				end
			end
		end
	end

	-- Server -> client streams
	getRemote(GameConfig.RemoteNames.AuctionState, "RemoteEvent").OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then
			return
		end
		if typeof(data.auctions) == "table" then
			-- Full picture (join/rejoin recovery): both sessions at once.
			for _, sess in pairs(data.auctions) do
				if typeof(sess) == "table" then
					handleSessionData(sess)
				end
			end
			return
		end
		handleSessionData(data)
	end)
	getRemote(GameConfig.RemoteNames.CashChanged, "RemoteEvent").OnClientEvent:Connect(function(amount)
		cash = tonumber(amount) or 0
		refresh()
	end)
	getRemote(GameConfig.RemoteNames.InventoryChanged, "RemoteEvent").OnClientEvent:Connect(function(items)
		if typeof(items) == "table" then
			UIController.UpdateInventory(items, function(item)
				UIController.SetSelectedItem(item)
			end)
			-- Drop the detail popup if its item left the Bag (sold/removed).
			local selectedId = UIController.GetSelectedItemId()
			if selectedId then
				local stillOwned = false
				for _, it in ipairs(items) do
					if it.InstanceId == selectedId then
						stillOwned = true
						break
					end
				end
				if not stillOwned then
					UIController.HideItemPanel()
					UIController.HideSlotPicker()
				end
			end
		end
	end)
	getRemote(GameConfig.RemoteNames.ItemRevealed, "RemoteEvent").OnClientEvent:Connect(function(item, unitIndex)
		if typeof(item) == "table" then
			local idx = tonumber(unitIndex)
			revealUnit = if idx == 1 or idx == 2 then idx else nearUnit
			UIController.ShowReveal(item)
		end
	end)
	getRemote(GameConfig.RemoteNames.DisplayChanged, "RemoteEvent").OnClientEvent:Connect(function(state)
		if typeof(state) == "table" then
			displayState = state
			if UIController.IsSlotPickerVisible() then
				UIController.RefreshSlotPicker(displayState)
			end
		end
	end)
	getRemote(GameConfig.RemoteNames.StatsChanged, "RemoteEvent").OnClientEvent:Connect(function(stats)
		if typeof(stats) == "table" then
			UIController.UpdateStats(stats)
		end
	end)
	getRemote(GameConfig.RemoteNames.Notify, "RemoteEvent").OnClientEvent:Connect(function(payload)
		if typeof(payload) == "table" then
			if payload.closeReveal then
				UIController.HideReveal()
			end
			if inRadius then
				UIController.ShowToast(tostring(payload.text))
			end
		else
			if inRadius then
				UIController.ShowToast(tostring(payload))
			end
		end
	end)

	-- Bid (targets the nearby session explicitly)
	refs.BidButton.MouseButton1Click:Connect(function()
		if not nearUnit then
			return
		end
		local snap = snapshots[nearUnit]
		local fn = getRemote(GameConfig.RemoteNames.PlaceBid, "RemoteFunction")
		if not fn then
			return
		end
		local amount = (snap.currentBid or 0) + (snap.minIncrement or 25)
		local unit = nearUnit
		local ok, res = pcall(function()
			return fn:InvokeServer(unit, amount)
		end)
		if ok and typeof(res) == "table" then
			if res.ok then
				lastSeenBid[unit] = amount -- don't toast our own bid back at ourselves
				UIController.ShowToast("Your bid: $" .. formatMoney(amount))
			else
				UIController.ShowToast(tostring(res.message))
			end
			if typeof(res.snapshot) == "table" then
				snapshots[unit] = res.snapshot
				refresh()
			end
		else
			UIController.ShowToast("Bid failed")
		end
	end)

	-- Sell / Keep (both auto-close the reveal panel; resolve in the
	-- session that produced the reveal)
	refs.SellButton.MouseButton1Click:Connect(function()
		local instanceId = UIController.GetRevealInstanceId()
		if not instanceId then
			return
		end
		local unit = revealUnit or nearUnit or 1
		local fn = getRemote(GameConfig.RemoteNames.SellItem, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer(unit, instanceId)
		end)
		UIController.HideReveal()
		if ok and typeof(res) == "table" and res.ok then
			UIController.ShowToast("Sold for $" .. formatMoney(res.result) .. "!")
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Sell failed"
			UIController.ShowToast(msg)
		end
	end)
	refs.KeepButton.MouseButton1Click:Connect(function()
		local instanceId = UIController.GetRevealInstanceId()
		if not instanceId then
			return
		end
		local unit = revealUnit or nearUnit or 1
		local fn = getRemote(GameConfig.RemoteNames.KeepItem, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer(unit, instanceId)
		end)
		if ok and typeof(res) == "table" and res.ok then
			UIController.HideReveal()
			UIController.ShowToast("Kept! Find it in your Bag")
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Keep failed"
			UIController.ShowToast(msg)
		end
	end)

	-- Bag item detail: DISPLAY opens the slot picker, SELL sells from Bag.
	refs.ItemDisplayBtn.MouseButton1Click:Connect(function()
		local instanceId = UIController.GetSelectedItemId()
		if not instanceId then
			return
		end
		UIController.ShowSlotPicker(displayState)
	end)
	refs.ItemSellBtn.MouseButton1Click:Connect(function()
		local instanceId = UIController.GetSelectedItemId()
		if not instanceId then
			return
		end
		local fn = getRemote(GameConfig.RemoteNames.SellItem, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer(nearUnit or 1, instanceId)
		end)
		if ok and typeof(res) == "table" and res.ok then
			UIController.HideItemPanel()
			UIController.HideSlotPicker()
			UIController.ShowToast("Sold for $" .. formatMoney(res.result) .. "!")
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Sell failed"
			UIController.ShowToast(msg)
		end
	end)
	refs.ItemCloseBtn.MouseButton1Click:Connect(function()
		UIController.HideItemPanel()
	end)

	-- Slot picker: assign selected Bag item, or remove its display.
	for i, btn in ipairs(refs.SlotButtons) do
		local slotIndex = i
		btn.MouseButton1Click:Connect(function()
			local instanceId = UIController.GetSelectedItemId()
			if not instanceId then
				return
			end
			local fn = getRemote(GameConfig.RemoteNames.DisplayItem, "RemoteFunction")
			local ok, res = pcall(function()
				return fn:InvokeServer(instanceId, slotIndex)
			end)
			if ok and typeof(res) == "table" and res.ok then
				UIController.HideSlotPicker()
				UIController.HideItemPanel()
				UIController.ShowToast("Displayed " .. tostring(res.result.Name) .. " in Slot " .. slotIndex)
			else
				local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Display failed"
				UIController.ShowToast(msg)
			end
		end)
	end
	refs.SlotRemoveBtn.MouseButton1Click:Connect(function()
		local instanceId = UIController.GetSelectedItemId()
		if not instanceId then
			return
		end
		local fn = getRemote(GameConfig.RemoteNames.RemoveDisplay, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer(instanceId)
		end)
		if ok and typeof(res) == "table" and res.ok then
			UIController.ShowToast("Display removed")
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Remove failed"
			UIController.ShowToast(msg)
		end
	end)
	refs.SlotCloseBtn.MouseButton1Click:Connect(function()
		UIController.HideSlotPicker()
	end)
	-- Local proximity check across BOTH sessions (UX only; server validates).
	-- Picks the nearest BidCenter inside its radius; overlapping zones
	-- resolve deterministically to the nearer unit (ties keep unit 1).
	-- Runs on a slow tick so walking between units updates the HUD without
	-- spamming anything.
	task.spawn(function()
		while true do
			task.wait(0.5)
			nearUnit, inRadius = AuctionClient.NearestSession()
			refresh()
		end
	end)
end

-- Mirrors the server's XZ bid-radius check against one session's center.
-- Missing data/character counts as outside (button hidden, never a bid).
function AuctionClient.IsWithinBidRadius(snap)
	snap = snap or displaySnapshot()
	local center = snap.bidCenter
	local radius = snap.bidRadius or GameConfig.BidRadius
	if typeof(center) ~= "table" then
		return false
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local dx = root.Position.X - (tonumber(center.x) or 0)
	local dz = root.Position.Z - (tonumber(center.z) or 0)
	return (dx * dx + dz * dz) <= radius * radius
end

-- Returns (unitIndex|nil, inRadius). Scans sessions in order, replacing the
-- pick only on a strictly nearer center, so ties are deterministic.
function AuctionClient.NearestSession()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil, false
	end
	local best, bestD2 = nil, nil
	for idx = 1, 2 do
		local snap = snapshots[idx]
		local center = snap and snap.bidCenter
		if typeof(center) == "table" then
			local radius = snap.bidRadius or GameConfig.BidRadius
			local dx = root.Position.X - (tonumber(center.x) or 0)
			local dz = root.Position.Z - (tonumber(center.z) or 0)
			local d2 = dx * dx + dz * dz
			if d2 <= radius * radius and (bestD2 == nil or d2 < bestD2) then
				best, bestD2 = idx, d2
			end
		end
	end
	return best, best ~= nil
end

return AuctionClient
