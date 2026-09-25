--!nonstrict
-- StorageAuction — server bootstrap.
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
local RemoteGuardService = require(script.RemoteGuardService)

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
		{ GameConfig.RemoteNames.GetWarehouseState, "RemoteFunction" },
		{ GameConfig.RemoteNames.UpgradeWarehouse, "RemoteFunction" },
		{ GameConfig.RemoteNames.WarehouseOpened, "RemoteEvent" },
		{ GameConfig.RemoteNames.GetATMState, "RemoteFunction" },
		{ GameConfig.RemoteNames.TakeLoan, "RemoteFunction" },
		{ GameConfig.RemoteNames.ClaimRecovery, "RemoteFunction" },
		{ GameConfig.RemoteNames.ATMOpened, "RemoteEvent" },
		{ GameConfig.RemoteNames.DebtChanged, "RemoteEvent" },
	}
	for _, d in ipairs(defs) do
		local existing = folder:FindFirstChild(d[1])
		-- Validate CLASS as well as name: a stale wrong-class instance
		-- under SA_Remotes would otherwise break invokes silently.
		if existing and not existing:IsA(d[2]) then
			warn("[SA] Replacing wrong-class remote '" .. d[1] .. "' (expected " .. d[2] .. ").")
			existing:Destroy()
			existing = nil
		end
		if not existing then
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
	WarehouseService = WarehouseService,
	DisplayService = DisplayService,
})
PlayerDataService.StartAutosave()

-- 3) Map: Studio-authored. Errors clearly if StorageAuctionMap is missing
-- (restore map/StorageAuctionMap from version control with Argon SERVER
-- sync, then Save the place).
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
	WarehouseService = WarehouseService,
	PlayerDataService = PlayerDataService,
	RemoteGuardService = RemoteGuardService,
})

-- 4b) ATM loans/debt/recovery (runtime state, persisted via PlayerDataService).
DebtService.Init({
	EconomyService = EconomyService,
	PlayerStatsService = PlayerStatsService,
	PlayerDataService = PlayerDataService,
	RemoteGuardService = RemoteGuardService,
	Remotes = remotes,
	ATMPrompt = mapHandles.ATM,
})

-- 5) Showroom displays + progression stats (depend on services above).
DisplayService.Init({
	InventoryService = InventoryService,
	WarehouseService = WarehouseService,
	PlayerDataService = PlayerDataService,
	RemoteGuardService = RemoteGuardService,
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
	DisplayService = DisplayService,
	PlayerDataService = PlayerDataService,
})
WarehouseService.Init({
	MapHandles = mapHandles,
	EconomyService = EconomyService,
	PlayerStatsService = PlayerStatsService,
	InventoryService = InventoryService,
	PlayerDataService = PlayerDataService,
	AuctionService = AuctionService,
	DisplayService = DisplayService,
	Remotes = remotes,
})

-- 7) Players. Single deterministic owner of player initialization: one
-- Load per join (guarded against duplicate PlayerAdded races), then the
-- delayed full-state push. Debt/inventory/stats setup all happens inside
-- PlayerDataService.Load — never reset afterwards.
local bootstrapped = {}
-- Per-user lifecycle serialization: PlayerRemoving and BindToClose share ONE
-- durable-save path per player so two overlapping saves can never snapshot
-- stale (pre-pending-resolution) state. Per-player only — different players
-- still save in parallel. Bounded waits: shutdown never hangs.
local lifecycleBusy = {} -- [UserId] = true while a durable save is in flight
local lifecycleDone = {} -- [UserId] = true once durably saved (skip repeats)
local function acquireLifecycle(userId)
	local deadline = os.clock() + 5
	while lifecycleBusy[userId] and os.clock() < deadline do
		task.wait(0.1)
	end
	lifecycleBusy[userId] = true
end
local function releaseLifecycle(userId)
	lifecycleBusy[userId] = nil
end
-- The ONLY durable-save path: resolve pending Sell/Keep value exactly once
-- (idempotent — second call finds nothing pending), then snapshot + save.
-- Returns after THIS player's save attempt completes.
local function savePlayerDurably(player)
	if not player then
		return false
	end
	local id = player.UserId
	if lifecycleDone[id] then
		return true -- already durably saved; never a stale second save
	end
	acquireLifecycle(id)
	if lifecycleDone[id] then
		-- Lost the race while waiting: the winner already saved post-resolve
		-- state, so there is nothing stale left to write.
		releaseLifecycle(id)
		return true
	end
	AuctionService.ResolvePendingForPlayer(player)
	PlayerDataService.Save(player)
	lifecycleDone[id] = true
	releaseLifecycle(id)
	return true
end
local function onPlayerAdded(player)
	if not player then
		return
	end
	if bootstrapped[player.UserId] then
		return -- duplicate join event: state already initializing/initialized
	end
	bootstrapped[player.UserId] = true
	lifecycleDone[player.UserId] = nil -- fresh join may save again later
	PlayerDataService.Load(player)
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
	if not player then
		return
	end
	bootstrapped[player.UserId] = nil
	-- ORDER IS LOAD-BEARING: resolve pending durable value, then snapshot +
	-- save FIRST while every service still holds runtime state (debt,
	-- inventory, wins, cash, level, displays), and only then clear. The
	-- shared durable path serializes with any concurrent BindToClose save.
	savePlayerDurably(player)
	PlotService.ReleasePlot(player)
	AuctionService.ClearPlayer(player)
	DisplayService.ClearPlayer(player)
	PlayerStatsService.ClearPlayer(player)
	InventoryService.ClearPlayer(player)
	EconomyService.ClearPlayer(player)
	DebtService.ClearPlayer(player)
	WarehouseService.ClearPlayer(player)
	RemoteGuardService.ClearPlayer(player)
	PlayerDataService.ClearPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

game:BindToClose(function()
	-- Bounded parallel saves through the SAME durable path as PlayerRemoving
	-- (pending resolve + snapshot + save, per-player serialized). Skips
	-- players already durably saved and anyone unsafe to save. Runtime
	-- services are NOT cleared here — a concurrent PlayerRemoving still
	-- needs them after its own coordinated save.
	local pending = 0
	for _, p in ipairs(Players:GetPlayers()) do
		if PlayerDataService.IsLoaded(p) and PlayerDataService.IsSaveAllowed(p) then
			pending += 1
			task.spawn(function(pl)
				savePlayerDurably(pl)
				pending -= 1
			end, p)
		end
	end
	local deadline = os.clock() + 8
	while pending > 0 and os.clock() < deadline do
		task.wait(0.2)
	end
end)

print("[SA] StorageAuction server ready.")
