--!nonstrict
-- StorageAuction M1 — server bootstrap.
-- Creates remotes, builds map, wires services, starts auction loop.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local EconomyService = require(script.EconomyService)
local InventoryService = require(script.InventoryService)
local NPCBidderService = require(script.NPCBidderService)
local AuctionService = require(script.AuctionService)
local MapBuilder = require(script.MapBuilder)
local PlayerDataService = require(script.PlayerDataService)
local DisplayService = require(script.DisplayService)
local PlayerStatsService = require(script.PlayerStatsService)
local PlotService = require(script.PlotService)
local WarehouseService = require(script.WarehouseService)
local DebtService = require(script.DebtService)

-- 1) Remotes (created at runtime so Studio needs zero manual setup).
local function ensureRemotes()
	local folder = ReplicatedStorage:FindFirstChild(GameConfig.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = GameConfig.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end
	local defs = {
		{ GameConfig.RemoteNames.AuctionState, "RemoteEvent" },
		{ GameConfig.RemoteNames.CashChanged, "RemoteEvent" },
		{ GameConfig.RemoteNames.ItemRevealed, "RemoteEvent" },
		{ GameConfig.RemoteNames.InventoryChanged, "RemoteEvent" },
		{ GameConfig.RemoteNames.Notify, "RemoteEvent" },
		{ GameConfig.RemoteNames.DisplayChanged, "RemoteEvent" },
		{ GameConfig.RemoteNames.StatsChanged, "RemoteEvent" },
		{ GameConfig.RemoteNames.PlaceBid, "RemoteFunction" },
		{ GameConfig.RemoteNames.OpenContainer, "RemoteFunction" },
		{ GameConfig.RemoteNames.KeepItem, "RemoteFunction" },
		{ GameConfig.RemoteNames.SellItem, "RemoteFunction" },
		{ GameConfig.RemoteNames.DisplayItem, "RemoteFunction" },
		{ GameConfig.RemoteNames.RemoveDisplay, "RemoteFunction" },
		{ GameConfig.RemoteNames.GetATMState, "RemoteFunction" },
		{ GameConfig.RemoteNames.TakeLoan, "RemoteFunction" },
		{ GameConfig.RemoteNames.ClaimRecovery, "RemoteFunction" },
		{ GameConfig.RemoteNames.ATMOpened, "RemoteEvent" },
		{ GameConfig.RemoteNames.DebtChanged, "RemoteEvent" },
	}
	for _, d in ipairs(defs) do
		if not folder:FindFirstChild(d[1]) then
			local inst = Instance.new(d[2])
			inst.Name = d[1]
			inst.Parent = folder
		end
	end
	return folder
end

local remotes = ensureRemotes()

-- 2) Services.
EconomyService.Init(remotes)
InventoryService.Init(remotes)
PlayerDataService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	PlayerStatsService = PlayerStatsService,
	DebtService = DebtService,
})
PlayerDataService.StartAutosave()

-- 3) Map.
-- 3) Map: Studio-authored. Errors clearly if StorageAuctionMap is missing
-- (run tools/BuildMapOnce.luau once in Studio, then Save the place).
local mapHandles = MapBuilder.GetHandles()

-- 4) Auction state machine.
AuctionService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	NPCBidderService = NPCBidderService,
	MapBuilder = MapBuilder,
	MapHandles = mapHandles,
	Remotes = remotes,
	PlayerStatsService = PlayerStatsService,
	DisplayService = DisplayService,
	DebtService = DebtService,
})

-- 4b) Runtime ATM loans/debt/recovery (no persistence in Stage 5A).
DebtService.Init({
	EconomyService = EconomyService,
	PlayerStatsService = PlayerStatsService,
	Remotes = remotes,
	ATMPrompt = mapHandles.ATM,
})

-- 5) Showroom displays + progression stats (depend on services above).
DisplayService.Init({
	InventoryService = InventoryService,
	WarehouseService = WarehouseService,
	Remotes = remotes,
})
PlayerStatsService.Init({
	InventoryService = InventoryService,
	Remotes = remotes,
})

-- 6) Server-local warehouse plots + runtime warehouses. Plots are claimed
-- manually via sign prompts (no auto-assignment); see PlotService.ClaimPlot.
PlotService.Init({
	MapHandles = mapHandles,
	Remotes = remotes,
	WarehouseService = WarehouseService,
})
WarehouseService.Init({
	MapHandles = mapHandles,
})

-- 7) Players.
local function onPlayerAdded(player)
	PlayerDataService.Load(player)
	DebtService.SetupPlayer(player)
	-- NOTE: no auto plot assignment. Players claim a plot manually at its
	-- sign ("Claim Plot", E). See PlotService.ClaimPlot.
	-- Send initial snapshot shortly after spawn so UI populates.
	task.delay(1, function()
		if player.Parent then
			local ev = remotes:FindFirstChild(GameConfig.RemoteNames.AuctionState)
			if ev then
				ev:FireClient(player, AuctionService.GetSnapshot())
			end
			local cashEv = remotes:FindFirstChild(GameConfig.RemoteNames.CashChanged)
			if cashEv then
				cashEv:FireClient(player, EconomyService.GetCash(player))
			end
			local invEv = remotes:FindFirstChild(GameConfig.RemoteNames.InventoryChanged)
			if invEv then
				invEv:FireClient(player, InventoryService.GetItems(player))
			end
			local dispEv = remotes:FindFirstChild(GameConfig.RemoteNames.DisplayChanged)
			if dispEv then
				dispEv:FireClient(player, DisplayService.GetDisplayState(player))
			end
			PlayerStatsService.Push(player)
		end
	end)
end

local function onPlayerRemoving(player)
	-- ORDER IS LOAD-BEARING: snapshot + save FIRST while every service still
	-- holds runtime state (debt, inventory, wins, cash), and only then clear.
	PlayerDataService.Save(player)
	PlotService.ReleasePlot(player)
	AuctionService.ClearPlayer(player)
	DisplayService.ClearPlayer(player)
	PlayerStatsService.ClearPlayer(player)
	InventoryService.ClearPlayer(player)
	EconomyService.ClearPlayer(player)
	DebtService.ClearPlayer(player)
	PlayerDataService.ClearPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

game:BindToClose(function()
	for _, p in ipairs(Players:GetPlayers()) do
		PlayerDataService.Save(p)
	end
end)

print("[SA] StorageAuction M1 server ready.")
