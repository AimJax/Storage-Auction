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
local inventory = {}

local function getRemote(name, className)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = remotes:WaitForChild(name, 10)
	end
	return r
end

function AuctionClient.Start()
	remotes = ReplicatedStorage:WaitForChild(GameConfig.RemotesFolderName)
	local refs = UIController.Build()
	UIController.UpdateStatus(snapshot, cash)

	-- Server -> client streams
	getRemote(GameConfig.RemoteNames.AuctionState, "RemoteEvent").OnClientEvent:Connect(function(data)
		if typeof(data) == "table" then
			snapshot = data
			UIController.UpdateStatus(snapshot, cash)
			if snapshot.state == "Sold" and snapshot.winner and snapshot.winner ~= "" then
				if snapshot.winner == player.Name then
					UIController.ShowMessage("YOU WON for $" .. tostring(snapshot.currentBid) .. "! Go rummage the unit!")
				else
					UIController.ShowMessage(snapshot.winner .. " won for $" .. tostring(snapshot.currentBid) .. ". Next auction soon.")
				end
			end
		end
	end)
	getRemote(GameConfig.RemoteNames.CashChanged, "RemoteEvent").OnClientEvent:Connect(function(amount)
		cash = tonumber(amount) or 0
		UIController.UpdateStatus(snapshot, cash)
	end)
	getRemote(GameConfig.RemoteNames.InventoryChanged, "RemoteEvent").OnClientEvent:Connect(function(items)
		if typeof(items) == "table" then
			inventory = items
			UIController.UpdateInventory(inventory)
		end
	end)
	getRemote(GameConfig.RemoteNames.ItemRevealed, "RemoteEvent").OnClientEvent:Connect(function(item)
		if typeof(item) == "table" then
			UIController.ShowReveal(item)
			UIController.ShowMessage("Found: " .. tostring(item.Name) .. " — Sell or Keep?")
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
			UIController.ShowMessage(tostring(res.message))
			if res.snapshot then
				snapshot = res.snapshot
				UIController.UpdateStatus(snapshot, cash)
			end
		else
			UIController.ShowMessage("Bid failed.")
		end
	end)

	-- Sell / Keep / Close
	refs.SellButton.MouseButton1Click:Connect(function()
		local instanceId = UIController.GetRevealInstanceId()
		if not instanceId then
			return
		end
		local fn = getRemote(GameConfig.RemoteNames.SellItem, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer(instanceId)
		end)
		if ok and typeof(res) == "table" and res.ok then
			UIController.ShowMessage("Sold for $" .. tostring(res.result) .. "!")
			UIController.HideReveal()
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Sell failed."
			UIController.ShowMessage(msg)
		end
	end)
	refs.KeepButton.MouseButton1Click:Connect(function()
		UIController.ShowMessage("Kept! (stays in your inventory panel)")
		UIController.HideReveal()
	end)
	refs.CloseReveal.MouseButton1Click:Connect(function()
		UIController.HideReveal()
	end)
end

return AuctionClient
