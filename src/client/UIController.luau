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
local lastInspectionKey = nil
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
	lastInspectionKey = nil
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

	-- Inspection clues: real visible items + visible/hidden counts. Shown ONLY
	-- during Inspection AND inside the auction radius. Names/conditions only
	-- — never values, never hidden item identities.
	local insp = mk("Frame", {
		Name = "Inspection",
		Size = UDim2.new(0, 250, 0, 150),
		Position = UDim2.new(1, -262, 0, 52),
		BackgroundColor3 = Color3.fromRGB(18, 18, 24),
		BackgroundTransparency = 0.25,
		Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, insp)
	mk("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = "VISIBLE CONTENTS",
		TextColor3 = Color3.fromRGB(255, 225, 130),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
	}, insp)
	refs.InspectionRows = {}
	for i = 1, 4 do
		local row = mk("TextLabel", {
			Size = UDim2.new(1, -16, 0, 20),
			Position = UDim2.new(0, 8, 0, 24 + (i - 1) * 20),
			BackgroundTransparency = 1,
			Text = "",
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.Gotham,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, insp)
		refs.InspectionRows[i] = row
	end
	refs.InspectionFooter = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 20),
		Position = UDim2.new(0, 8, 0, 106),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Color3.fromRGB(170, 170, 180),
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, insp)
	refs.InspectionFrame = insp

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
	refs.StatsLabel = mk("TextLabel", {
		Size = UDim2.new(1, -12, 0, 18),
		Position = UDim2.new(0, 6, 0, 28),
		BackgroundTransparency = 1,
		Text = "Collection $0 · Won 0",
		TextColor3 = Color3.fromRGB(255, 225, 130),
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, inv)
	refs.PremiumLabel = mk("TextLabel", {
		Size = UDim2.new(1, -12, 0, 16),
		Position = UDim2.new(0, 6, 0, 46),
		BackgroundTransparency = 1,
		Text = "PREMIUM: LOCKED",
		TextColor3 = Color3.fromRGB(150, 150, 160),
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, inv)
	refs.InventoryList = mk("ScrollingFrame", {
		Size = UDim2.new(1, -12, 1, -68),
		Position = UDim2.new(0, 6, 0, 64),
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

	-- Item detail popup (from Bag row click): DISPLAY / SELL / CLOSE.
	local itemPanel = mk("Frame", {
		Name = "ItemPanel",
		Size = UDim2.new(0, 230, 0, 220),
		Position = UDim2.new(0.5, -115, 0.5, -110),
		BackgroundColor3 = Color3.fromRGB(26, 26, 34),
		BackgroundTransparency = 0.05,
		Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, itemPanel)
	mk("UIStroke", { Color = Color3.fromRGB(90, 90, 110), Thickness = 1 }, itemPanel)
	refs.ItemName = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 26), Position = UDim2.new(0, 8, 0, 6),
		BackgroundTransparency = 1, Text = "", Font = Enum.Font.GothamBold,
		TextSize = 15, TextTruncate = Enum.TextTruncate.AtEnd,
	}, itemPanel)
	refs.ItemRarity = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 20), Position = UDim2.new(0, 8, 0, 32),
		BackgroundTransparency = 1, Text = "", Font = Enum.Font.GothamBold, TextSize = 13,
	}, itemPanel)
	refs.ItemDetail = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 40), Position = UDim2.new(0, 8, 0, 54),
		BackgroundTransparency = 1, Text = "", TextColor3 = Color3.fromRGB(225, 225, 230),
		Font = Enum.Font.Gotham, TextSize = 13, TextWrapped = true,
	}, itemPanel)
	refs.ItemDisplayBtn = mk("TextButton", {
		Size = UDim2.new(0, 102, 0, 36), Position = UDim2.new(0, 10, 0, 100),
		BackgroundColor3 = Color3.fromRGB(70, 110, 180), Text = "DISPLAY",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 14,
	}, itemPanel)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.ItemDisplayBtn)
	refs.ItemSellBtn = mk("TextButton", {
		Size = UDim2.new(0, 102, 0, 36), Position = UDim2.new(1, -112, 0, 100),
		BackgroundColor3 = Color3.fromRGB(190, 140, 30), Text = "SELL",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 14,
	}, itemPanel)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.ItemSellBtn)
	refs.ItemCloseBtn = mk("TextButton", {
		Size = UDim2.new(1, -20, 0, 30), Position = UDim2.new(0, 10, 1, -40),
		BackgroundColor3 = Color3.fromRGB(60, 60, 70), Text = "CLOSE",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 13,
	}, itemPanel)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.ItemCloseBtn)
	refs.ItemPanel = itemPanel

	-- Slot picker popup: level-aware slot buttons in a scroll list + REMOVE
	-- DISPLAY + CLOSE. Button count follows displayState.slotCount (server
	-- warehouse level); no hardcoded slot assumptions client-side.
	local slotPanel = mk("Frame", {
		Name = "SlotPanel",
		Size = UDim2.new(0, 230, 0, 300),
		Position = UDim2.new(0.5, -115, 0.5, -150),
		BackgroundColor3 = Color3.fromRGB(26, 26, 34),
		BackgroundTransparency = 0.05,
		Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, slotPanel)
	mk("UIStroke", { Color = Color3.fromRGB(90, 90, 110), Thickness = 1 }, slotPanel)
	mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1,
		Text = "DISPLAY IN SLOT", TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold, TextSize = 13,
	}, slotPanel)
	refs.SlotScroll = mk("ScrollingFrame", {
		Name = "SlotScroll",
		Size = UDim2.new(1, -16, 0, 188),
		Position = UDim2.new(0, 8, 0, 26),
		BackgroundTransparency = 1,
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(0, 0, 0, 0),
	}, slotPanel)
	refs.SlotButtons = {}
	refs.SlotButtonCount = 0
	refs.SlotRemoveBtn = mk("TextButton", {
		Size = UDim2.new(1, -16, 0, 28), Position = UDim2.new(0, 8, 0, 218),
		BackgroundColor3 = Color3.fromRGB(140, 60, 60), Text = "REMOVE DISPLAY",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 12,
	}, slotPanel)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, refs.SlotRemoveBtn)
	refs.SlotCloseBtn = mk("TextButton", {
		Size = UDim2.new(1, -16, 0, 26), Position = UDim2.new(0, 8, 0, 250),
		BackgroundColor3 = Color3.fromRGB(60, 60, 70), Text = "CLOSE",
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 12,
	}, slotPanel)
	mk("UICorner", { CornerRadius = UDim.new(0, 6) }, refs.SlotCloseBtn)
	refs.SlotPanel = slotPanel

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

	-- ATM panel: compact, center, hidden by default. Cash + debt + fixed
	-- loan offers + recovery. Buttons only send IDs/actions; the server
	-- validates everything and returns fresh state for re-render.
	local atm = mk("Frame", {
		Name = "ATM",
		Size = UDim2.new(0, 280, 0, 330),
		Position = UDim2.new(0.5, -140, 0.5, -165),
		BackgroundColor3 = Color3.fromRGB(22, 22, 30),
		BackgroundTransparency = 0.05,
		Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, atm)
	mk("UIStroke", { Color = Color3.fromRGB(40, 200, 130), Thickness = 1 }, atm)
	mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "AUCTION ATM",
		TextColor3 = Color3.fromRGB(120, 230, 170),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
	}, atm)
	refs.ATMCashLabel = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 20),
		Position = UDim2.new(0, 8, 0, 28),
		BackgroundTransparency = 1,
		Text = "Cash: $0",
		TextColor3 = Color3.fromRGB(255, 225, 130),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, atm)
	refs.ATMDebtLabel = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 20),
		Position = UDim2.new(0, 8, 0, 48),
		BackgroundTransparency = 1,
		Text = "Debt: $0",
		TextColor3 = Color3.fromRGB(255, 150, 150),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, atm)
	refs.ATMLoanButtons = {}
	refs.ATMLoanLabels = {}
	for i = 1, 3 do
		local y = 70 + (i - 1) * 52
		local btn = mk("TextButton", {
			Size = UDim2.new(0, 120, 0, 30),
			Position = UDim2.new(0, 8, 0, y),
			BackgroundColor3 = Color3.fromRGB(40, 130, 85),
			Text = "LOAN",
			TextColor3 = Color3.new(1, 1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
		}, atm)
		mk("UICorner", { CornerRadius = UDim.new(0, 8) }, btn)
		refs.ATMLoanButtons[i] = btn
		refs.ATMLoanLabels[i] = mk("TextLabel", {
			Size = UDim2.new(1, -136, 0, 30),
			Position = UDim2.new(0, 132, 0, y),
			BackgroundTransparency = 1,
			Text = "",
			TextColor3 = Color3.fromRGB(200, 200, 205),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, atm)
	end
	refs.ATMRecoveryButton = mk("TextButton", {
		Size = UDim2.new(0, 120, 0, 30),
		Position = UDim2.new(0, 8, 0, 226),
		BackgroundColor3 = Color3.fromRGB(70, 110, 180),
		Text = "RECOVER",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
	}, atm)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.ATMRecoveryButton)
	refs.ATMRecoveryLabel = mk("TextLabel", {
		Size = UDim2.new(1, -136, 0, 30),
		Position = UDim2.new(0, 132, 0, 226),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Color3.fromRGB(200, 200, 205),
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, atm)
	refs.ATMCloseButton = mk("TextButton", {
		Size = UDim2.new(1, -16, 0, 32),
		Position = UDim2.new(0, 8, 0, 288),
		BackgroundColor3 = Color3.fromRGB(50, 55, 70),
		Text = "CLOSE",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
	}, atm)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.ATMCloseButton)
	refs.ATMFrame = atm

	-- Warehouse upgrade panel: compact, centered-left, hidden by default.
	-- Shows current level/capacity/slots + next-level cost/requirements.
	local wh = mk("Frame", {
		Name = "Warehouse",
		Size = UDim2.new(0, 280, 0, 300),
		Position = UDim2.new(0.5, -140, 0.5, -150),
		BackgroundColor3 = Color3.fromRGB(22, 22, 30),
		BackgroundTransparency = 0.05,
		Visible = false,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, wh)
	mk("UIStroke", { Color = Color3.fromRGB(90, 140, 220), Thickness = 1 }, wh)
	mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "WAREHOUSE",
		TextColor3 = Color3.fromRGB(150, 190, 255),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
	}, wh)
	refs.WHLevelLabel = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 20),
		Position = UDim2.new(0, 8, 0, 28),
		BackgroundTransparency = 1,
		Text = "Level 1",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, wh)
	refs.WHStatsLabel = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 40),
		Position = UDim2.new(0, 8, 0, 50),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Color3.fromRGB(200, 200, 205),
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, wh)
	refs.WHNextLabel = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 100),
		Position = UDim2.new(0, 8, 0, 94),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Color3.fromRGB(200, 200, 205),
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
	}, wh)
	refs.WHUpgradeButton = mk("TextButton", {
		Size = UDim2.new(1, -16, 0, 36),
		Position = UDim2.new(0, 8, 0, 200),
		BackgroundColor3 = Color3.fromRGB(40, 130, 85),
		Text = "UPGRADE",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
	}, wh)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.WHUpgradeButton)
	refs.WHReasonLabel = mk("TextLabel", {
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.new(0, 8, 0, 238),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Color3.fromRGB(255, 170, 150),
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, wh)
	refs.WHCloseButton = mk("TextButton", {
		Size = UDim2.new(1, -16, 0, 30),
		Position = UDim2.new(0, 8, 0, 262),
		BackgroundColor3 = Color3.fromRGB(50, 55, 70),
		Text = "CLOSE",
		TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
	}, wh)
	mk("UICorner", { CornerRadius = UDim.new(0, 8) }, refs.WHCloseButton)
	refs.WHFrame = wh

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
		-- NOTE: the reveal panel is NEVER auto-hidden here. It closes only
		-- on Sell/Keep success, server closeReveal, or explicit resolution,
		-- so walking between units or out of radius cannot strand a decision.
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
		local tierName = tostring(snapshot.tierDisplayName or "")
		local timeText = tostring(snapshot.timeLeft or 0) .. "s"
		refs.StateLabel.Text = if tierName ~= ""
			then tierName .. " · " .. string.upper(state) .. " · " .. timeText
			else string.upper(state) .. " · " .. timeText
	end
	if refs.BidLabel then
		local function tag(name, kind)
			if kind == "NPC" and name ~= "" then
				return name .. " (NPC)"
			end
			return name
		end
		if state == "Sold" or state == "Rummaging" then
			local w = snapshot.winner
			if w and w ~= "" then
				refs.BidLabel.Text = "Won by " .. tag(w, snapshot.winnerType) .. " · $" .. formatMoney(snapshot.currentBid or 0)
			else
				refs.BidLabel.Text = "No winner"
			end
		elseif state == "Bidding" then
			local who = snapshot.bidder
			if who == nil or who == "" then
				-- No bids yet: show the true opening bid (internal CurrentBid
				-- sits one increment below it by design).
				who = "no bids"
				refs.BidLabel.Text = "$" .. formatMoney(snapshot.startingBid or snapshot.currentBid or 0) .. " · " .. who
			else
				who = tag(who, snapshot.bidderType)
				refs.BidLabel.Text = "$" .. formatMoney(snapshot.currentBid or 0) .. " · " .. who
			end
		elseif state == "Inspection" then
			refs.BidLabel.Text = "Starts at $" .. formatMoney(snapshot.startingBid or snapshot.currentBid or 0)
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
		local tierReq = snapshot.tierRequirement
		local reqSuffix = if tierReq ~= nil and tierReq ~= "" then " (" .. tostring(tierReq) .. ")" else ""
		if not showAuction then
			setHint(nil)
		elseif state == "Inspection" then
			setHint("Inspect the unit before bidding begins" .. reqSuffix)
		elseif state == "Bidding" then
			setHint("Outbid your rivals to win the unit" .. reqSuffix)
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

	-- Inspection clues refresh on state entry, payload change, or radius
	-- crossing (walk out hides, walk back in restores — same payload).
	local inspKey = state .. (showAuction and "|in" or "|out")
	if state == "Inspection" and snapshot.inspection then
		local insp = snapshot.inspection
		inspKey ..= "|" .. tostring(insp.visibleCount or 0) .. "|" .. tostring(insp.hiddenCount or 0)
		local first = insp.clues and insp.clues[1]
		if first then
			inspKey ..= "|" .. tostring(first.name)
		end
	end
	if inspKey ~= lastInspectionKey then
		lastInspectionKey = inspKey
		local payload = nil
		if state == "Inspection" and showAuction and snapshot.inspection then
			payload = snapshot.inspection
		end
		UIController.UpdateInspection(payload)
	end
end

local function plural(n, one, many)
	if tonumber(n) == 1 then
		return "1 " .. one
	end
	return tostring(tonumber(n) or 0) .. " " .. many
end

-- ATM panel render. `state` is the server GetATMState payload (or nil to
-- just hide). Loan buttons show locked reasons; recovery shows grant or
-- cooldown/eligibility. Pure render — all decisions are server-side.
function UIController.ShowATM(state)
	if not refs.ATMFrame then
		return
	end
	refs.ATMFrame.Visible = true
	if state then
		UIController.RefreshATM(state)
	end
end

function UIController.HideATM()
	if refs.ATMFrame then
		refs.ATMFrame.Visible = false
	end
end

function UIController.IsATMVisible()
	return refs.ATMFrame and refs.ATMFrame.Visible or false
end

-- Warehouse upgrade panel. Pure render of the server GetWarehouseState
-- payload; upgrade decisions stay server-side.
function UIController.ShowWarehouse(state)
	if not refs.WHFrame then
		return
	end
	refs.WHFrame.Visible = true
	if state then
		UIController.RefreshWarehouse(state)
	end
end

function UIController.HideWarehouse()
	if refs.WHFrame then
		refs.WHFrame.Visible = false
	end
end

function UIController.IsWarehouseVisible()
	return refs.WHFrame and refs.WHFrame.Visible or false
end

function UIController.RefreshWarehouse(state)
	if not refs.WHFrame or typeof(state) ~= "table" then
		return
	end
	local level = tonumber(state.level) or 1
	refs.WHLevelLabel.Text = string.format("Level %d / %d", level, tonumber(state.maxLevel) or level)
	refs.WHStatsLabel.Text = string.format("Storage: %d / %d\nDisplay slots: %d",
		tonumber(state.inventoryCount) or 0, tonumber(state.storageCapacity) or 0,
		tonumber(state.displaySlots) or 0)
	local next = state.next
	if typeof(next) == "table" then
		refs.WHNextLabel.Text = string.format("Next: Lv %d\nCost: $%s\nWins: %d\nStorage: %d · Slots: %d",
			tonumber(next.level) or 0, formatMoney(next.cost or 0), tonumber(next.minWins) or 0,
			tonumber(next.capacity) or 0, tonumber(next.slots) or 0)
	else
		refs.WHNextLabel.Text = "Max level reached."
	end
	local can = state.canUpgrade == true
	if refs.WHUpgradeButton then
		refs.WHUpgradeButton.Active = can
		refs.WHUpgradeButton.AutoButtonColor = can
		refs.WHUpgradeButton.BackgroundColor3 = if can
			then Color3.fromRGB(40, 130, 85)
			else Color3.fromRGB(70, 70, 80)
	end
	if refs.WHReasonLabel then
		refs.WHReasonLabel.Text = if can then "" else tostring(state.reason or "")
	end
end

function UIController.RefreshATM(state)
	if not refs.ATMFrame or typeof(state) ~= "table" then
		return
	end
	refs.ATMCashLabel.Text = "Cash: $" .. formatMoney(state.cash or 0)
	refs.ATMDebtLabel.Text = "Debt: $" .. formatMoney(state.debt or 0)
	for i, loan in ipairs(state.loans or {}) do
		local btn = (refs.ATMLoanButtons or {})[i]
		local lab = (refs.ATMLoanLabels or {})[i]
		if btn then
			btn.Text = string.format("LOAN %s: $%s", tostring(loan.id), formatMoney(loan.borrow or 0))
			btn.Active = loan.eligible ~= false
			btn.AutoButtonColor = loan.eligible ~= false
			btn.BackgroundColor3 = if loan.eligible ~= false
				then Color3.fromRGB(40, 130, 85)
				else Color3.fromRGB(70, 70, 80)
		end
		if lab then
			if loan.eligible ~= false then
				lab.Text = string.format("repay $%s", formatMoney(loan.repay or 0))
			else
				lab.Text = tostring(loan.reason or "Locked")
			end
		end
	end
	local rec = state.recovery or {}
	if refs.ATMRecoveryButton then
		refs.ATMRecoveryButton.Active = rec.eligible == true
		refs.ATMRecoveryButton.AutoButtonColor = rec.eligible == true
		refs.ATMRecoveryButton.BackgroundColor3 = if rec.eligible == true
			then Color3.fromRGB(70, 110, 180)
			else Color3.fromRGB(70, 70, 80)
	end
	if refs.ATMRecoveryLabel then
		if rec.eligible == true then
			refs.ATMRecoveryLabel.Text = string.format("grant $%s", formatMoney(rec.grant or 0))
		else
			refs.ATMRecoveryLabel.Text = tostring(rec.reason or "")
		end
	end
end

function UIController.UpdateInspection(inspection)
	if not refs.InspectionFrame then
		return
	end
	if not inspection then
		refs.InspectionFrame.Visible = false
		return
	end
	refs.InspectionFrame.Visible = true
	local clues = inspection.clues or {}
	for i, row in ipairs(refs.InspectionRows or {}) do
		local clue = clues[i]
		if clue then
			row.Text = string.format("%s (%s)", tostring(clue.name), tostring(clue.condition or "?"))
			row.TextColor3 = rarityColor(clue.rarity)
		else
			row.Text = ""
		end
	end
	refs.InspectionFooter.Text = string.format("%s · %s",
		plural(inspection.visibleCount, "visible item", "visible items"),
		plural(inspection.hiddenCount, "hidden item", "hidden items"))
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
		"%s · %d%%  ·  Value $%s",
		tostring(item.ConditionName or item.Condition),
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

function UIController.UpdateInventory(items, onSelect)
	if refs.BagButton then
		refs.BagButton.Text = "Bag (" .. tostring(#items) .. ")"
	end
	if not refs.InventoryList then
		return
	end
	for _, child in ipairs(refs.InventoryList:GetChildren()) do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for _, item in ipairs(items) do
		local label = Instance.new("TextButton")
		label.Size = UDim2.new(1, -4, 0, 40)
		label.BackgroundColor3 = Color3.fromRGB(36, 36, 48)
		label.TextColor3 = rarityColor(item.Rarity)
		label.Font = Enum.Font.Gotham
		label.TextSize = 12
		label.TextWrapped = true
		label.AutoButtonColor = true
		label.Text = string.format("%s [%s] %d%% $%s", item.Name, tostring(item.Rarity), tonumber(item.Condition) or 0, formatMoney(tonumber(item.FinalValue) or 0))
		label.Parent = refs.InventoryList
		mk("UICorner", { CornerRadius = UDim.new(0, 4) }, label)
		if onSelect then
			local copy = item
			label.MouseButton1Click:Connect(function()
				onSelect(copy)
			end)
		end
	end
end

function UIController.UpdateStats(stats)
	if not stats then
		return
	end
	if refs.StatsLabel then
		refs.StatsLabel.Text = string.format("Collection $%s · Won %d",
			formatMoney(tonumber(stats.collectionValue) or 0), tonumber(stats.auctionsWon) or 0)
	end
	if refs.PremiumLabel then
		if stats.premiumUnlocked then
			refs.PremiumLabel.Text = "PREMIUM AUCTIONS: UNLOCKED"
			refs.PremiumLabel.TextColor3 = Color3.fromRGB(120, 230, 130)
		else
			refs.PremiumLabel.Text = string.format("PREMIUM: LOCKED (%d wins or $%s)",
				tonumber(stats.winsRequired) or 5, formatMoney(tonumber(stats.valueRequired) or 5000))
			refs.PremiumLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
		end
	end
end

local selectedItem = nil

function UIController.SetSelectedItem(item)
	selectedItem = item
	if not refs.ItemPanel then
		return
	end
	if not item then
		refs.ItemPanel.Visible = false
		return
	end
	refs.ItemPanel.Visible = true
	refs.ItemName.Text = item.Name
	refs.ItemName.TextColor3 = rarityColor(item.Rarity)
	refs.ItemRarity.Text = string.upper(tostring(item.Rarity))
	refs.ItemRarity.TextColor3 = rarityColor(item.Rarity)
	refs.ItemDetail.Text = string.format("Condition %d%%  ·  Value $%s",
		tonumber(item.Condition) or 0, formatMoney(tonumber(item.FinalValue) or 0))
	refs.ItemPanel:SetAttribute("InstanceId", item.InstanceId)
end

function UIController.GetSelectedItemId()
	if refs.ItemPanel then
		return refs.ItemPanel:GetAttribute("InstanceId")
	end
	return nil
end

function UIController.HideItemPanel()
	selectedItem = nil
	if refs.ItemPanel then
		refs.ItemPanel.Visible = false
		refs.ItemPanel:SetAttribute("InstanceId", nil)
	end
end

function UIController.ShowSlotPicker(displayState)
	if not refs.SlotPanel then
		return
	end
	refs.SlotPanel.Visible = true
	UIController.RefreshSlotPicker(displayState)
end

function UIController.HideSlotPicker()
	if refs.SlotPanel then
		refs.SlotPanel.Visible = false
	end
end

function UIController.IsSlotPickerVisible()
	return refs.SlotPanel and refs.SlotPanel.Visible or false
end

function UIController.RefreshSlotPicker(displayState)
	if not refs.SlotButtons or not refs.SlotScroll then
		return
	end
	local count = math.clamp(math.floor(tonumber(displayState and displayState.slotCount) or 6), 1, 64)
	if count ~= refs.SlotButtonCount then
		for _, child in ipairs(refs.SlotScroll:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		refs.SlotButtons = {}
		for i = 1, count do
			local btn = mk("TextButton", {
				Size = UDim2.new(1, -8, 0, 28),
				Position = UDim2.new(0, 4, 0, (i - 1) * 32),
				BackgroundColor3 = Color3.fromRGB(40, 40, 52),
				Text = i .. ": (empty)",
				TextColor3 = Color3.new(1, 1, 1),
				Font = Enum.Font.Gotham, TextSize = 12,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, refs.SlotScroll)
			mk("UICorner", { CornerRadius = UDim.new(0, 6) }, btn)
			refs.SlotButtons[i] = btn
		end
		refs.SlotScroll.CanvasSize = UDim2.new(0, 0, 0, count * 32)
		refs.SlotButtonCount = count
		UIController.RewireSlotButtons()
	end
	local slots = (displayState and displayState.slots) or {}
	for i, btn in ipairs(refs.SlotButtons) do
		local occupant = slots[i]
		if occupant then
			btn.Text = i .. ": " .. tostring(occupant.name)
		else
			btn.Text = i .. ": (empty)"
		end
	end
end

-- Rebind per-button click handlers after a rebuild. AuctionClient registers
-- its handler factory here so dynamic buttons behave like the old static ones.
local slotClickFactory = nil
function UIController.SetSlotClickFactory(fn)
	slotClickFactory = fn
	UIController.RewireSlotButtons()
end

function UIController.RewireSlotButtons()
	if not slotClickFactory then
		return
	end
	for i, btn in ipairs(refs.SlotButtons or {}) do
		slotClickFactory(btn, i)
	end
end

return UIController
