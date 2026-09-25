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
-- Session count derives from config (UnitTiers) so map and client agree.
local SESSION_COUNT = #GameConfig.UnitTiers
local snapshots = {}
local prevStates = {}
local lastSeenBid = {}
for i = 1, SESSION_COUNT do
	snapshots[i] = blankSnapshot()
	prevStates[i] = "Waiting"
	lastSeenBid[i] = -1
end
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
	if r and className and not r:IsA(className) then
		warn("[SA] Remote '" .. name .. "' has wrong class; waiting for the right one.")
		r = nil
	end
	if not r then
		r = remotes:WaitForChild(name, 10)
		if r and className and not r:IsA(className) then
			warn("[SA] Remote '" .. name .. "' has wrong class after wait.")
			return nil
		end
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
		if idx == nil or idx < 1 or idx > SESSION_COUNT then
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
			revealUnit = if idx ~= nil and idx >= 1 and idx <= SESSION_COUNT then idx else nearUnit
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
			-- Server-targeted notices (plot/warehouse/timeout/auto-sale)
			-- always display; only ambient auction-chatter toasts stay
			-- radius-gated (handled at their own call sites).
			UIController.ShowToast(tostring(payload.text))
		else
			UIController.ShowToast(tostring(payload))
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

	-- Sell / Keep (resolve in the session that produced the reveal).
	-- Reveal closes ONLY on success; a failed Sell/Keep leaves it open so
	-- the pending decision is never stranded by a dismiss.
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
		if ok and typeof(res) == "table" and res.ok then
			UIController.HideReveal()
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

	-- Slot picker: assign selected Bag item (dynamic level-aware buttons).
	UIController.SetSlotClickFactory(function(btn, slotIndex)
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
	end)
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

	-- ATM: server owns all state; client only sends loan IDs / actions and
	-- renders the returned state.
	local lastATMState = nil
	local function refreshATM()
		local fn = getRemote(GameConfig.RemoteNames.GetATMState, "RemoteFunction")
		if not fn then
			return
		end
		local ok, res = pcall(function()
			return fn:InvokeServer()
		end)
		if ok and typeof(res) == "table" and res.ok and typeof(res.state) == "table" then
			lastATMState = res.state
			UIController.RefreshATM(res.state)
		end
	end
	getRemote(GameConfig.RemoteNames.ATMOpened, "RemoteEvent").OnClientEvent:Connect(function()
		UIController.ShowATM(nil)
		refreshATM()
	end)
	getRemote(GameConfig.RemoteNames.DebtChanged, "RemoteEvent").OnClientEvent:Connect(function()
		if UIController.IsATMVisible() then
			refreshATM()
		end
	end)
	for i, btn in ipairs(refs.ATMLoanButtons or {}) do
		local loanIdx = i
		btn.MouseButton1Click:Connect(function()
			local loans = lastATMState and lastATMState.loans
			local entry = loans and loans[loanIdx]
			if not entry then
				return
			end
			local fn = getRemote(GameConfig.RemoteNames.TakeLoan, "RemoteFunction")
			if not fn then
				return
			end
			local ok, res = pcall(function()
				return fn:InvokeServer(entry.id)
			end)
			if ok and typeof(res) == "table" then
				UIController.ShowToast(tostring(res.message))
				if typeof(res.state) == "table" then
					lastATMState = res.state
					UIController.RefreshATM(res.state)
				end
			else
				UIController.ShowToast("Loan failed")
			end
		end)
	end
	if refs.ATMRecoveryButton then
		refs.ATMRecoveryButton.MouseButton1Click:Connect(function()
			local fn = getRemote(GameConfig.RemoteNames.ClaimRecovery, "RemoteFunction")
			if not fn then
				return
			end
			local ok, res = pcall(function()
				return fn:InvokeServer()
			end)
			if ok and typeof(res) == "table" then
				if res.ok then
					UIController.ShowToast("Recovery grant: $" .. formatMoney(tonumber(res.result) or 0))
				else
					UIController.ShowToast(tostring(res.result))
				end
				if typeof(res.state) == "table" then
					lastATMState = res.state
					UIController.RefreshATM(res.state)
				end
			else
				UIController.ShowToast("Recovery failed")
			end
		end)
	end
	if refs.ATMCloseButton then
		refs.ATMCloseButton.MouseButton1Click:Connect(function()
			UIController.HideATM()
		end)
	end

	-- Warehouse upgrade: server owns level/cash/wins; client sends the bare
	-- call and renders the returned state.
	local function refreshWarehouse()
		local fn = getRemote(GameConfig.RemoteNames.GetWarehouseState, "RemoteFunction")
		if not fn then
			return
		end
		local ok, res = pcall(function()
			return fn:InvokeServer()
		end)
		if ok and typeof(res) == "table" and res.ok and typeof(res.state) == "table" then
			UIController.RefreshWarehouse(res.state)
		end
	end
	getRemote(GameConfig.RemoteNames.WarehouseOpened, "RemoteEvent").OnClientEvent:Connect(function()
		UIController.ShowWarehouse(nil)
		refreshWarehouse()
	end)
	if refs.WHUpgradeButton then
		refs.WHUpgradeButton.MouseButton1Click:Connect(function()
			local fn = getRemote(GameConfig.RemoteNames.UpgradeWarehouse, "RemoteFunction")
			if not fn then
				return
			end
			local ok, res = pcall(function()
				return fn:InvokeServer()
			end)
			if ok and typeof(res) == "table" then
				UIController.ShowToast(tostring(res.message))
				if typeof(res.state) == "table" then
					UIController.RefreshWarehouse(res.state)
				end
			else
				UIController.ShowToast("Upgrade failed")
			end
		end)
	end
	if refs.WHCloseButton then
		refs.WHCloseButton.MouseButton1Click:Connect(function()
			UIController.HideWarehouse()
		end)
	end
	local refreshWarehouseIfOpen = function()
		if UIController.IsWarehouseVisible() then
			refreshWarehouse()
		end
	end
	getRemote(GameConfig.RemoteNames.DisplayChanged, "RemoteEvent").OnClientEvent:Connect(function()
		refreshWarehouseIfOpen()
	end)
	getRemote(GameConfig.RemoteNames.InventoryChanged, "RemoteEvent").OnClientEvent:Connect(function()
		refreshWarehouseIfOpen()
	end)
	-- Local proximity check across ALL sessions (UX only; server validates).
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

-- Returns (unitIndex|nil, inRadius). Scans all sessions in order, replacing
-- the pick only on a strictly nearer center, so ties are deterministic.
function AuctionClient.NearestSession()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil, false
	end
	local best, bestD2 = nil, nil
	for idx = 1, SESSION_COUNT do
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
