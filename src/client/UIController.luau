--!nonstrict
-- StorageAuction M1 — compact client UI (built in code, no Studio GUI needed).
-- Design: small corner pills + one contextual bid button + auto-fading toasts.
-- Nothing permanently covers the center or sides of the screen.
-- All status rendering is state-driven via UpdateStatus; stale text from a
-- previous auction is cleared on every state transition.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RarityConfig = require(Shared.RarityConfig)

local UIController = {}

local player = Players.LocalPlayer
local gui = nil
local refs = {}
local lastState = ""
local toastToken = 0

local TOAST_DURATION = 3.2

local function rarityColor(name)
	local def = RarityConfig.Definitions[name]
	if def then
		return def.Color
	end
	return Color3.new(1, 1, 1)
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

local function mk(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function pill(name, size, pos, textSize)
	local f = mk("Frame", {
		Name = name,
		Size = size,
		Position = pos,
		BackgroundColor3 = Color3.fromRGB(18, 18, 24),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
	local label = mk("TextLabel", {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = textSize,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, f)
	mk("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, f)
	return f, label
end

function UIController.Build()
	local pg = player:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("SA_UI")
	if old then
		old:Destroy()
	end
	gui = mk("ScreenGui", { Name = "SA_UI", ResetOnSpawn = false, IgnoreGuiInset = false }, pg)
	lastState = ""
	toastToken += 1

	-- Top-left: current bid + bidder. Top-center: state + countdown.
	-- Top-right: cash. All small pills.
	refs.BidFrame, refs.BidLabel = pill("BidPill",
		UDim2.new(0, 230, 0, 34), UDim2.new(0, 12, 0, 12), 14)
	refs.StateFrame, refs.StateLabel = pill("StatePill",
		UDim2.new(0, 210, 0, 34), UDim2.new(0.5, -105, 0, 12), 15)
	refs.CashFrame, refs.CashLabel = pill("CashPill",
		UDim2.new(0, 130, 0, 34), UDim2.new(1, -142, 0, 12), 15)
	refs.CashLabel.TextColor3 = Color3.fromRGB(255, 225, 130)

	-- Toast: temporary notification under the state pill, auto-hides.
	refs.ToastLabel = mk("TextLabel", {
		Name = "Toast",
		Size = UDim2.new(0, 340, 0, 28),
		Position = UDim2.new(0.5, -170, 0, 52),
		BackgroundColor3 = Color3.fromRGB(18, 18, 24),
		BackgroundTransparency = 0.25,
		Visible = false,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.Gotham,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, refs.ToastLabel)

	-- Contextual hint: small, bottom-center, only for states that need it.
	refs.HintLabel = mk("TextLabel", {
		Name = "Hint",
		Size = UDim2.new(0, 380, 0, 26),
		Position = UDim2.new(0.5, -190, 1, -64),
		BackgroundColor3 = Color3.fromRGB(18, 18, 24),
		BackgroundTransparency = 0.35,
		Visible = false,
		Text = "",
		TextColor3 = Color3.fromRGB(220, 220, 225),
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, refs.HintLabel)

	-- Bid button: lower-right, only during Bidding.
	refs.BidButton = mk("TextButton", {
		Name = "BidButton",
		Size = UDim2.new(0, 170, 0, 48),
		Position = UDim2.new(1, -186, 1, -128),
		BackgroundColor3 = Color3.fromRGB(40, 160, 70),
		Visible = false,
		Text = "BID",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 20,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, refs.BidButton)

	-- Inventory: small toggle button + compact popup panel (hidden by default).
	refs.BagButton = mk("TextButton", {
		Name = "BagButton",
		Size = UDim2.new(0, 104, 0, 32),
		Position = UDim2.new(1, -120, 1, -48),
		BackgroundColor3 = Color3.fromRGB(50, 55, 70),
		BackgroundTransparency = 0.15,
		Text = "Bag (0)",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.BagButton)

	local inv = mk("Frame", {
		Name = "Inventory",
		Size = UDim2.new(0, 240, 0, 250),
		Position = UDim2.new(1, -252, 1, -306),
		BackgroundColor3 = Color3.fromRGB(22, 22, 30),
		BackgroundTransparency = 0.1,
		Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, inv)
	mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		Text = "BAG",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
	}, inv)
	refs.InventoryList = mk("ScrollingFrame", {
		Size = UDim2.new(1, -12, 1, -36),
		Position = UDim2.new(0, 6, 0, 32),
		BackgroundTransparency = 1,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, inv)
	mk("UIListLayout", { Padding = UDim.new(0, 4) }, refs.InventoryList)
	refs.InventoryFrame = inv
	refs.BagButton.MouseButton1Click:Connect(function()
		refs.InventoryFrame.Visible = not refs.InventoryFrame.Visible
	end)

	-- Reveal panel: compact, centered. Auto-closes on Sell/Keep (see client).
	local reveal = mk("Frame", {
		Name = "Reveal",
		Size = UDim2.new(0, 250, 0, 225),
		Position = UDim2.new(0.5, -125, 0.5, -112),
		BackgroundColor3 = Color3.fromRGB(26, 26, 34),
		BackgroundTransparency = 0.05,
		Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, reveal)
	mk("UIStroke", { Color = Color3.fromRGB(90, 90, 110), Thickness = 1 }, reveal)
	mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = "YOU FOUND",
		TextColor3 = Color3.fromRGB(170, 170, 180),
		Font = Enum.Font.Gotham,
		TextSize = 12,
	}, reveal)
	refs.RevealName = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 30),
		Position = UDim2.new(0, 8, 0, 22),
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, reveal)
	refs.RevealRarity = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, 52),
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 15,
	}, reveal)
	refs.RevealDetail = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 48),
		Position = UDim2.new(0, 8, 0, 78),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Color3.fromRGB(225, 225, 230),
		Font = Enum.Font.Gotham,
		TextSize = 15,
	}, reveal)
	refs.SellButton = mk("TextButton", {
		Size = UDim2.new(0, 110, 0, 40),
		Position = UDim2.new(0, 12, 1, -52),
		BackgroundColor3 = Color3.fromRGB(190, 140, 30),
		Text = "SELL",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 17,
	}, reveal)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.SellButton)
	refs.KeepButton = mk("TextButton", {
		Size = UDim2.new(0, 110, 0, 40),
		Position = UDim2.new(1, -122, 1, -52),
		BackgroundColor3 = Color3.fromRGB(70, 110, 180),
		Text = "KEEP",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 17,
	}, reveal)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.KeepButton)
	refs.RevealFrame = reveal

	return refs
end

function UIController.GetRefs()
	return refs
end

-- Temporary toast notification. Replaces the old permanent message strip.
function UIController.ShowToast(text, duration)
	if not refs.ToastLabel then
		return
	end
	toastToken += 1
	local token = toastToken
	refs.ToastLabel.Text = text
	refs.ToastLabel.Visible = true
	task.delay(duration or TOAST_DURATION, function()
		if token == toastToken and refs.ToastLabel then
			refs.ToastLabel.Visible = false
		end
	end)
end

function UIController.HideToast()
	toastToken += 1
	if refs.ToastLabel then
		refs.ToastLabel.Visible = false
	end
end

local function setHint(text)
	if not refs.HintLabel then
		return
	end
	if text and text ~= "" then
		refs.HintLabel.Text = text
		refs.HintLabel.Visible = true
	else
		refs.HintLabel.Visible = false
	end
end

-- State-driven status. On every state transition: winner text cleared unless
-- relevant, bid button hidden unless Bidding, hint contextual, reveal closed
-- when leaving Rummaging, toast cleared so nothing goes stale.
-- bidAllowed (from the local proximity check) gates the BID button during
-- Bidding; nil counts as allowed so the button works before the first check.
-- Outside the auction radius the whole auction HUD (bid pill, state pill,
-- bid button, hint, toasts) hides; Cash, Bag, inventory and reveal never hide.
function UIController.UpdateStatus(snapshot, cash, localPlayerName, bidAllowed)
	local state = snapshot.state or "Waiting"
	local transitioned = state ~= lastState
	lastState = state
	local canBid = bidAllowed ~= false
	local showAuction = canBid

	if transitioned then
		UIController.HideToast()
		if state ~= "Rummaging" then
			UIController.HideReveal()
		end
	end

	if not showAuction then
		UIController.HideToast()
	end
	if refs.BidFrame then
		refs.BidFrame.Visible = showAuction
	end
	if refs.StateFrame then
		refs.StateFrame.Visible = showAuction
	end

	if refs.StateLabel then
		refs.StateLabel.Text = string.upper(state) .. " · " .. tostring(snapshot.timeLeft or 0) .. "s"
	end
	if refs.BidLabel then
		if state == "Sold" or state == "Rummaging" then
			local w = snapshot.winner
			if w and w ~= "" then
				refs.BidLabel.Text = "Won by " .. w .. " · $" .. formatMoney(snapshot.currentBid or 0)
			else
				refs.BidLabel.Text = "No winner"
			end
		elseif state == "Bidding" then
			local who = snapshot.bidder
			if who == nil or who == "" then
				who = "no bids"
			end
			refs.BidLabel.Text = "$" .. formatMoney(snapshot.currentBid or 0) .. " · " .. who
		elseif state == "Inspection" then
			refs.BidLabel.Text = "Starts at $" .. formatMoney(snapshot.currentBid or 0)
		else
			refs.BidLabel.Text = "Next auction soon"
		end
	end
	if refs.CashLabel and cash ~= nil then
		refs.CashLabel.Text = "$" .. formatMoney(cash)
	end
	if refs.BidButton then
		local isBidding = state == "Bidding"
		refs.BidButton.Visible = isBidding and canBid
		if isBidding then
			refs.BidButton.Text = "BID $" .. formatMoney((snapshot.currentBid or 0) + (snapshot.minIncrement or 25))
		end
	end

	if transitioned or state == "Rummaging" or state == "Bidding" then
		if not showAuction then
			setHint(nil)
		elseif state == "Inspection" then
			setHint("Inspect the unit before bidding begins")
		elseif state == "Bidding" then
			setHint("Outbid your rivals to win the unit")
		elseif state == "Rummaging" then
			if snapshot.winner == localPlayerName then
				setHint("You won! Walk in and press E on each box")
			else
				setHint("Winner is rummaging: " .. tostring(snapshot.winner or ""))
			end
		else
			setHint(nil)
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
	refs.RevealRarity.Text = string.upper(tostring(item.Rarity))
	refs.RevealRarity.TextColor3 = rarityColor(item.Rarity)
	refs.RevealDetail.Text = string.format(
		"Condition %d%%  ·  Value $%s",
		tonumber(item.Condition) or 0,
		formatMoney(tonumber(item.FinalValue) or 0)
	)
	refs.RevealFrame:SetAttribute("InstanceId", item.InstanceId)
end

function UIController.HideReveal()
	if refs.RevealFrame then
		refs.RevealFrame.Visible = false
		refs.RevealFrame:SetAttribute("InstanceId", nil)
	end
end

function UIController.GetRevealInstanceId()
	if refs.RevealFrame then
		return refs.RevealFrame:GetAttribute("InstanceId")
	end
	return nil
end

function UIController.UpdateInventory(items)
	if refs.BagButton then
		refs.BagButton.Text = "Bag (" .. tostring(#items) .. ")"
	end
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
		label.Size = UDim2.new(1, -4, 0, 40)
		label.BackgroundColor3 = Color3.fromRGB(36, 36, 48)
		label.TextColor3 = rarityColor(item.Rarity)
		label.Font = Enum.Font.Gotham
		label.TextSize = 12
		label.TextWrapped = true
		label.Text = string.format("%s [%s] %d%% $%s", item.Name, tostring(item.Rarity), tonumber(item.Condition) or 0, formatMoney(tonumber(item.FinalValue) or 0))
		label.Parent = refs.InventoryList
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, label)
	end
end

return UIController
