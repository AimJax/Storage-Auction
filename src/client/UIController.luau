--!nonstrict
-- StorageAuction M1 — client UI (built in code, no manual Studio GUI needed).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RarityConfig = require(Shared.RarityConfig)

local UIController = {}

local player = Players.LocalPlayer
local gui = nil
local refs = {}

local function rarityColor(name)
	local def = RarityConfig.Definitions[name]
	if def then
		return def.Color
	end
	return Color3.new(1, 1, 1)
end

local function mk(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

function UIController.Build()
	local pg = player:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("SA_UI")
	if old then
		old:Destroy()
	end
	gui = mk("ScreenGui", { Name = "SA_UI", ResetOnSpawn = false, IgnoreGuiInset = false }, pg)

	-- Top status bar
	local top = mk("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, 110),
		BackgroundColor3 = Color3.fromRGB(25, 25, 30),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
	}, gui)
	local layout = mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 12), HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center }, top)
	mk("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, top)

	refs.StateLabel = mk("TextLabel", { Name = "State", Size = UDim2.new(0, 220, 1, 0), BackgroundTransparency = 1, Text = "Waiting...", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 22 }, top)
	refs.CountdownLabel = mk("TextLabel", { Name = "Countdown", Size = UDim2.new(0, 80, 1, 0), BackgroundTransparency = 1, Text = "", TextColor3 = Color3.new(1, 0.9, 0.4), Font = Enum.Font.GothamBold, TextSize = 28 }, top)
	refs.BidLabel = mk("TextLabel", { Name = "Bid", Size = UDim2.new(0, 220, 1, 0), BackgroundTransparency = 1, Text = "Bid: $0", TextColor3 = Color3.new(0.6, 1, 0.6), Font = Enum.Font.GothamBold, TextSize = 20 }, top)
	refs.CashLabel = mk("TextLabel", { Name = "Cash", Size = UDim2.new(0, 180, 1, 0), BackgroundTransparency = 1, Text = "Cash: $0", TextColor3 = Color3.new(1, 1, 0.5), Font = Enum.Font.GothamBold, TextSize = 20 }, top)
	refs.BidButton = mk("TextButton", { Name = "BidButton", Size = UDim2.new(0, 150, 0, 60), BackgroundColor3 = Color3.fromRGB(40, 160, 70), Text = "BID", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 24 }, top)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.BidButton)

	-- Message line under top bar
	refs.MessageLabel = mk("TextLabel", {
		Name = "Message",
		Size = UDim2.new(1, -20, 0, 30),
		Position = UDim2.new(0, 10, 0, 115),
		BackgroundTransparency = 0.4,
		BackgroundColor3 = Color3.fromRGB(20, 20, 25),
		Text = "Welcome to Storage Auction!",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.Gotham,
		TextSize = 16,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, refs.MessageLabel)

	-- Reveal panel (center)
	local reveal = mk("Frame", {
		Name = "Reveal",
		Size = UDim2.new(0, 340, 0, 300),
		Position = UDim2.new(0.5, -170, 0.5, -150),
		BackgroundColor3 = Color3.fromRGB(30, 30, 38),
		Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, reveal)
	mk("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }, reveal)
	refs.RevealTitle = mk("TextLabel", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Text = "You found...", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 18 }, reveal)
	refs.RevealName = mk("TextLabel", { Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 0, 40), BackgroundTransparency = 1, Text = "", Font = Enum.Font.GothamBold, TextSize = 24 }, reveal)
	refs.RevealDetail = mk("TextLabel", { Size = UDim2.new(1, -20, 0, 100), Position = UDim2.new(0, 10, 0, 90), BackgroundTransparency = 1, Text = "", TextColor3 = Color3.new(0.9, 0.9, 0.9), Font = Enum.Font.Gotham, TextSize = 18, TextWrapped = true }, reveal)
	refs.SellButton = mk("TextButton", { Size = UDim2.new(0.45, 0, 0, 50), Position = UDim2.new(0.03, 0, 1, -110), BackgroundColor3 = Color3.fromRGB(200, 150, 30), Text = "SELL", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 20 }, reveal)
	refs.KeepButton = mk("TextButton", { Size = UDim2.new(0.45, 0, 0, 50), Position = UDim2.new(0.52, 0, 1, -110), BackgroundColor3 = Color3.fromRGB(70, 110, 180), Text = "KEEP", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 20 }, reveal)
	refs.CloseReveal = mk("TextButton", { Size = UDim2.new(1, -20, 0, 32), Position = UDim2.new(0, 10, 1, -44), BackgroundColor3 = Color3.fromRGB(60, 60, 70), Text = "Close", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 14 }, reveal)
	refs.RevealFrame = reveal

	-- Inventory panel (right side)
	local inv = mk("Frame", {
		Name = "Inventory",
		Size = UDim2.new(0, 260, 0, 300),
		Position = UDim2.new(1, -270, 0.5, -150),
		BackgroundColor3 = Color3.fromRGB(25, 25, 32),
		BackgroundTransparency = 0.15,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, inv)
	mk("TextLabel", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Text = "INVENTORY", TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 16 }, inv)
	refs.InventoryList = mk("ScrollingFrame", {
		Size = UDim2.new(1, -10, 1, -40),
		Position = UDim2.new(0, 5, 0, 35),
		BackgroundTransparency = 1,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, inv)
	mk("UIListLayout", { Padding = UDim.new(0, 4) }, refs.InventoryList)
	refs.InventoryFrame = inv

	-- Hint bar (bottom)
	refs.HintLabel = mk("TextLabel", {
		Size = UDim2.new(1, -20, 0, 30),
		Position = UDim2.new(0, 10, 1, -40),
		BackgroundTransparency = 0.5,
		BackgroundColor3 = Color3.fromRGB(20, 20, 25),
		Text = "Walk to the unit. During Bidding press BID. Winner opens boxes with E.",
		TextColor3 = Color3.new(0.85, 0.85, 0.85),
		Font = Enum.Font.Gotham,
		TextSize = 14,
	}, gui)

	return refs
end

function UIController.GetRefs()
	return refs
end

function UIController.ShowMessage(text)
	if refs.MessageLabel then
		refs.MessageLabel.Text = text
	end
end

function UIController.UpdateStatus(snapshot, cash)
	if refs.StateLabel then
		local extra = ""
		if snapshot.winner and snapshot.winner ~= "" and (snapshot.state == "Sold" or snapshot.state == "Rummaging") then
			extra = " | Winner: " .. snapshot.winner
		end
		refs.StateLabel.Text = snapshot.state .. extra
	end
	if refs.CountdownLabel then
		refs.CountdownLabel.Text = tostring(snapshot.timeLeft or 0) .. "s"
	end
	if refs.BidLabel then
		local who = snapshot.bidder
		if who == nil or who == "" then
			who = "no bids"
		end
		refs.BidLabel.Text = string.format("Bid: $%d (%s)", snapshot.currentBid or 0, who)
	end
	if refs.CashLabel and cash ~= nil then
		refs.CashLabel.Text = "Cash: $" .. tostring(cash)
	end
	if refs.BidButton then
		refs.BidButton.Text = string.format("BID $%d", (snapshot.currentBid or 0) + (snapshot.minIncrement or 25))
		refs.BidButton.Visible = (snapshot.state == "Bidding")
	end
	if refs.HintLabel then
		if snapshot.state == "Inspection" then
			refs.HintLabel.Text = "INSPECTION: look at the boxes, get ready to bid!"
		elseif snapshot.state == "Bidding" then
			refs.HintLabel.Text = "BIDDING: press BID to outbid!"
		elseif snapshot.state == "Rummaging" then
			if snapshot.winner == player.Name then
				refs.HintLabel.Text = "YOU WON! Enter the unit and press E on each box."
			else
				refs.HintLabel.Text = "Winner is rummaging: " .. tostring(snapshot.winner)
			end
		end
	end
end

function UIController.ShowReveal(item)
	if not refs.RevealFrame then
		return
	end
	refs.RevealFrame.Visible = true
	refs.RevealName.Text = item.Name
	refs.RevealName.TextColor3 = rarityColor(item.Rarity)
	refs.RevealDetail.Text = string.format(
		"Rarity: %s\nCondition: %d%%\nValue: $%d",
		tostring(item.Rarity), tonumber(item.Condition) or 0, tonumber(item.FinalValue) or 0
	)
	refs.RevealFrame:SetAttribute("InstanceId", item.InstanceId)
end

function UIController.HideReveal()
	if refs.RevealFrame then
		refs.RevealFrame.Visible = false
	end
end

function UIController.GetRevealInstanceId()
	if refs.RevealFrame then
		return refs.RevealFrame:GetAttribute("InstanceId")
	end
	return nil
end

function UIController.UpdateInventory(items)
	if not refs.InventoryList then
		return
	end
	for _, child in ipairs(refs.InventoryList:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for _, item in ipairs(items) do
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -4, 0, 44)
		label.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
		label.TextColor3 = rarityColor(item.Rarity)
		label.Font = Enum.Font.Gotham
		label.TextSize = 13
		label.TextWrapped = true
		label.Text = string.format("%s [%s] %d%% $%d", item.Name, tostring(item.Rarity), tonumber(item.Condition) or 0, tonumber(item.FinalValue) or 0)
		label.Parent = refs.InventoryList
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, label)
	end
end

return UIController
