--!nonstrict
-- StorageAuction M1 — client glue: remotes, bid/sell/open wiring.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local UIController = require(script.Parent.UIController)

local AuctionClient = {}

local player = Players.LocalPlayer
local remotes = nil
local snapshot = { state = "Waiting", timeLeft = 0, currentBid = 0, bidder = "", minIncrement = 25, winner = "" }
local cash = 0
local lastSeenBid = -1

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

function AuctionClient.Start()
	remotes = ReplicatedStorage:WaitForChild(GameConfig.RemotesFolderName)
	local refs = UIController.Build()
	UIController.UpdateStatus(snapshot, cash, player.Name)

	-- Server -> client streams
	getRemote(GameConfig.RemoteNames.AuctionState, "RemoteEvent").OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then
			return
		end
		local prevState = snapshot.state
		snapshot = data
		UIController.UpdateStatus(snapshot, cash, player.Name)
		-- Toast rival bids as they happen (not on every broadcast tick).
		if snapshot.state == "Bidding"
			and (snapshot.currentBid or 0) > lastSeenBid
			and (snapshot.bidder or "") ~= ""
			and snapshot.bidder ~= player.Name
		then
			UIController.ShowToast(snapshot.bidder .. " bid $" .. formatMoney(snapshot.currentBid))
		end
		lastSeenBid = snapshot.currentBid or 0
		if snapshot.state == "Sold" and prevState ~= "Sold" then
			lastSeenBid = -1 -- reset for next auction
			if snapshot.winner and snapshot.winner ~= "" then
				if snapshot.winner == player.Name then
					UIController.ShowToast("You won the unit for $" .. formatMoney(snapshot.currentBid) .. "!", 4)
				else
					UIController.ShowToast(snapshot.winner .. " won for $" .. formatMoney(snapshot.currentBid))
				end
			else
				UIController.ShowToast("No winner this round")
			end
		end
	end)
	getRemote(GameConfig.RemoteNames.CashChanged, "RemoteEvent").OnClientEvent:Connect(function(amount)
		cash = tonumber(amount) or 0
		UIController.UpdateStatus(snapshot, cash, player.Name)
	end)
	getRemote(GameConfig.RemoteNames.InventoryChanged, "RemoteEvent").OnClientEvent:Connect(function(items)
		if typeof(items) == "table" then
			UIController.UpdateInventory(items)
		end
	end)
	getRemote(GameConfig.RemoteNames.ItemRevealed, "RemoteEvent").OnClientEvent:Connect(function(item)
		if typeof(item) == "table" then
			UIController.ShowReveal(item)
		end
	end)
	getRemote(GameConfig.RemoteNames.Notify, "RemoteEvent").OnClientEvent:Connect(function(payload)
		if typeof(payload) == "table" then
			if payload.closeReveal then
				UIController.HideReveal()
			end
			UIController.ShowToast(tostring(payload.text))
		else
			UIController.ShowToast(tostring(payload))
		end
	end)

	-- Bid
	refs.BidButton.MouseButton1Click:Connect(function()
		local fn = getRemote(GameConfig.RemoteNames.PlaceBid, "RemoteFunction")
		if not fn then
			return
		end
		local amount = (snapshot.currentBid or 0) + (snapshot.minIncrement or GameConfig.MinBidIncrement)
		local ok, res = pcall(function()
			return fn:InvokeServer(amount)
		end)
		if ok and typeof(res) == "table" then
			if res.ok then
				lastSeenBid = amount -- don't toast our own bid back at ourselves
				UIController.ShowToast("Your bid: $" .. formatMoney(amount))
			else
				UIController.ShowToast(tostring(res.message))
			end
			if res.snapshot then
				snapshot = res.snapshot
				UIController.UpdateStatus(snapshot, cash, player.Name)
			end
		else
			UIController.ShowToast("Bid failed")
		end
	end)

	-- Sell / Keep (both auto-close the reveal panel)
	refs.SellButton.MouseButton1Click:Connect(function()
		local instanceId = UIController.GetRevealInstanceId()
		if not instanceId then
			return
		end
		local fn = getRemote(GameConfig.RemoteNames.SellItem, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer(instanceId)
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
		local fn = getRemote(GameConfig.RemoteNames.KeepItem, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer(instanceId)
		end)
		if ok and typeof(res) == "table" and res.ok then
			UIController.HideReveal()
			UIController.ShowToast("Kept! Find it in your Bag")
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Keep failed"
			UIController.ShowToast(msg)
		end
	end)

	-- Local proximity check for the BID button (UX only; server validates).
	-- Runs on a slow tick so movement updates without spamming anything.
	task.spawn(function()
		while true do
			task.wait(0.5)
			UIController.UpdateStatus(snapshot, cash, player.Name, AuctionClient.IsWithinBidRadius())
		end
	end)
end

-- Mirrors the server's XZ bid-radius check using the broadcast center.
-- Missing data/character counts as outside (button hidden, never a bid).
function AuctionClient.IsWithinBidRadius()
	local center = snapshot.bidCenter
	local radius = snapshot.bidRadius or GameConfig.BidRadius
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

return AuctionClient
