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
-- Local auction-radius flag (UX only; the server validates every bid).
-- Auction toasts/hints follow it; Sell/Keep feedback always shows.
local inRadius = true
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

function AuctionClient.Start()
	remotes = ReplicatedStorage:WaitForChild(GameConfig.RemotesFolderName)
	local refs = UIController.Build()
	local debtState = { remaining = 0, total = 0, loanId = "" }
	local playerStats = nil
	local function refresh()
		UIController.UpdateStatus(snapshot, cash, player.Name, inRadius)
		UIController.SetRecoverVisible(cash < GameConfig.RecoveryCashThreshold)
	end
	refresh()

	-- Server -> client streams
	getRemote(GameConfig.RemoteNames.AuctionState, "RemoteEvent").OnClientEvent:Connect(function(data)
		if typeof(data) ~= "table" then
			return
		end
		local prevState = snapshot.state
		snapshot = data
		refresh()
		-- Toast rival bids as they happen (not on every broadcast tick).
		-- Auction toasts only make sense inside the radius.
		if inRadius
			and snapshot.state == "Bidding"
			and (snapshot.currentBid or 0) > lastSeenBid
			and (snapshot.bidder or "") ~= ""
			and snapshot.bidder ~= player.Name
		then
			UIController.ShowToast(snapshot.bidder .. " bid $" .. formatMoney(snapshot.currentBid))
		end
		lastSeenBid = snapshot.currentBid or 0
		if snapshot.state == "Sold" and prevState ~= "Sold" then
			lastSeenBid = -1 -- reset for next auction
			if inRadius then
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
		end
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
	getRemote(GameConfig.RemoteNames.ItemRevealed, "RemoteEvent").OnClientEvent:Connect(function(item)
		if typeof(item) == "table" then
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
			playerStats = stats
			UIController.UpdateStats(stats)
			if UIController.IsLoanVisible() then
				UIController.RefreshLoan(debtState, GameConfig.LoanProducts, playerStats)
			end
		end
	end)
	getRemote(GameConfig.RemoteNames.DebtChanged, "RemoteEvent").OnClientEvent:Connect(function(debt)
		if typeof(debt) == "table" then
			debtState = debt
			if UIController.IsLoanVisible() then
				UIController.RefreshLoan(debtState, GameConfig.LoanProducts, playerStats)
			end
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

	-- Bid
	refs.BidButton.MouseButton1Click:Connect(function()
		local fn = getRemote(GameConfig.RemoteNames.PlaceBid, "RemoteFunction")
		if not fn then
			return
		end
		local amount = (snapshot.currentBid or 0) + (snapshot.minIncrement or 25)
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
				refresh()
			end
		else
			UIController.ShowToast("Bid failed")
		end
	end)

	-- Sell / Keep (both auto-close the reveal panel).
	-- Sell results carry the debt breakdown: { cashGain, debtPaid, ... }.
	local function toastSale(res)
		local sale = res.result
		if typeof(sale) == "table" then
			local gained = tonumber(sale.cashGain) or 0
			local paid = tonumber(sale.debtPaid) or 0
			if paid > 0 then
				UIController.ShowToast(string.format("Sold $%s · loan -$%s · you +$%s",
					formatMoney(gained + paid), formatMoney(paid), formatMoney(gained)), 4)
			else
				UIController.ShowToast("Sold for $" .. formatMoney(gained) .. "!")
			end
		else
			UIController.ShowToast("Sold for $" .. formatMoney(sale) .. "!")
		end
	end
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
			toastSale(res)
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
			return fn:InvokeServer(instanceId)
		end)
		if ok and typeof(res) == "table" and res.ok then
			UIController.HideItemPanel()
			UIController.HideSlotPicker()
			toastSale(res)
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

	-- ATM kiosk: client-side prompt opens the loan menu (opening UI needs
	-- no server trust; every money action below is a validated RemoteFunction).
	task.spawn(function()
		local ok, map = pcall(function()
			return game.Workspace:WaitForChild("StorageAuctionMap", 10)
		end)
		if not ok or not map then
			return
		end
		local atm = map:FindFirstChild("ATM", true)
		local prompt = atm and atm:FindFirstChild("ATMPrompt", true)
		if prompt and prompt:IsA("ProximityPrompt") then
			prompt.Triggered:Connect(function()
				UIController.ShowLoanMenu(debtState, GameConfig.LoanProducts, playerStats)
			end)
		end
	end)

	-- Loan menu actions (all server-validated).
	for i, btn in ipairs(refs.LoanProductBtns) do
		local products = GameConfig.LoanProducts
		local product = products and products[i]
		local productId = product and product.Id
		local productAmount = product and product.Amount
		local productRepay = product and product.Repay
		btn.MouseButton1Click:Connect(function()
			if not productId then
				return
			end
			local fn = getRemote(GameConfig.RemoteNames.TakeLoan, "RemoteFunction")
			local ok, res = pcall(function()
				return fn:InvokeServer(productId)
			end)
			if ok and typeof(res) == "table" and res.ok then
				UIController.ShowToast(string.format("Borrowed $%s · repay $%s",
					formatMoney(productAmount), formatMoney(productRepay)))
			else
				local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Loan failed"
				UIController.ShowToast(msg)
			end
		end)
	end
	refs.LoanPayBtn.MouseButton1Click:Connect(function()
		local fn = getRemote(GameConfig.RemoteNames.PayDebt, "RemoteFunction")
		local amount = tonumber(refs.LoanPayBox and refs.LoanPayBox.Text or nil)
		local ok, res = pcall(function()
			return fn:InvokeServer(amount)
		end)
		if ok and typeof(res) == "table" and res.ok then
			local d = res.result or {}
			UIController.ShowToast("Debt remaining: $" .. formatMoney(tonumber(d.remaining) or 0))
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Pay failed"
			UIController.ShowToast(msg)
		end
	end)
	refs.LoanPayFullBtn.MouseButton1Click:Connect(function()
		local fn = getRemote(GameConfig.RemoteNames.PayDebt, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer(nil)
		end)
		if ok and typeof(res) == "table" and res.ok then
			UIController.ShowToast("Debt cleared!")
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Pay failed"
			UIController.ShowToast(msg)
		end
	end)
	refs.LoanCloseBtn.MouseButton1Click:Connect(function()
		UIController.HideLoanMenu()
	end)

	-- Bankruptcy recovery (server validates everything; button is UX only).
	refs.RecoverButton.MouseButton1Click:Connect(function()
		local fn = getRemote(GameConfig.RemoteNames.ClaimRecovery, "RemoteFunction")
		local ok, res = pcall(function()
			return fn:InvokeServer()
		end)
		if ok and typeof(res) == "table" and res.ok then
			UIController.ShowToast("Recovery grant: +$" .. formatMoney(tonumber(res.result) or 0))
		else
			local msg = if (ok and typeof(res) == "table") then tostring(res.result) else "Recovery failed"
			UIController.ShowToast(msg)
		end
	end)
	-- Local proximity check for the auction HUD (UX only; server validates).
	-- Runs on a slow tick so entering/leaving the radius updates immediately
	-- without spamming anything.
	task.spawn(function()
		while true do
			task.wait(0.5)
			inRadius = AuctionClient.IsWithinBidRadius()
			refresh()
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
