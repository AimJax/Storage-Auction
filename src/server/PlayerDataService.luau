--!nonstrict
-- StorageAuction M1 — minimal persistence (Cash + kept items).
-- Wrapped in pcall so Studio playtests WITHOUT DataStore API access still work.
-- Enable "Enable Studio Access to API Services" in Game Settings for real saves.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local PlayerDataService = {}

local STORE_NAME = "SA_M1_v1"
local store = nil
local ok, err = pcall(function()
	store = DataStoreService:GetDataStore(STORE_NAME)
end)
if not ok then
	warn("[SA] DataStore unavailable, using session-only data: " .. tostring(err))
	store = nil
end

local EconomyServiceRef = nil
local InventoryServiceRef = nil
local DebtServiceRef = nil
local PlayerStatsServiceRef = nil

function PlayerDataService.Init(economyService, inventoryService, debtService, statsService)
	EconomyServiceRef = economyService
	InventoryServiceRef = inventoryService
	DebtServiceRef = debtService
	PlayerStatsServiceRef = statsService
end

function PlayerDataService.Load(player)
	local startCash = GameConfig.StartingCash
	if not store then
		EconomyServiceRef.SetupPlayer(player, startCash)
		InventoryServiceRef.SetupPlayer(player)
		return
	end
	local data = nil
	local success, result = pcall(function()
		return store:GetAsync("player_" .. player.UserId)
	end)
	if success then
		data = result
	else
		warn("[SA] Load failed for " .. player.Name .. ": " .. tostring(result))
	end
	-- 1) Economy first (everything else may read cash).
	if typeof(data) == "table" and typeof(data.Cash) == "number" then
		EconomyServiceRef.SetupPlayer(player, math.clamp(math.floor(data.Cash), 0, GameConfig.MaxCash))
	else
		EconomyServiceRef.SetupPlayer(player, startCash)
	end
	-- 2) Inventory before anything that computes NetWorth.
	InventoryServiceRef.SetupPlayer(player)
	if InventoryServiceRef.LoadPersisted then
		InventoryServiceRef.LoadPersisted(player, typeof(data) == "table" and data.Inventory or nil)
	end
	-- 3) Stats (wins gate access/loans).
	if PlayerStatsServiceRef and PlayerStatsServiceRef.LoadPersisted then
		PlayerStatsServiceRef.LoadPersisted(player, data)
	end
	-- 4) Debt + recovery timestamp (never blocks play when absent).
	if DebtServiceRef then
		DebtServiceRef.LoadPersisted(player, data)
	end
	if GameConfig.DebugAuction then
		print(string.format("[SA] Loaded player data cash=%d wins=%d inventoryCount=%d recoveryAt=%s",
			EconomyServiceRef.GetCash(player),
			(PlayerStatsServiceRef and PlayerStatsServiceRef.GetWins(player)) or 0,
			#(InventoryServiceRef.GetItems(player)),
			tostring(typeof(data) == "table" and data.RecoveryAvailableAt or 0)))
	end
end

function PlayerDataService.Save(player)
	if not store then
		return
	end
	local cash = 0
	if EconomyServiceRef then
		cash = EconomyServiceRef.GetCash(player)
	end
	local debtData = { DebtRemaining = 0, DebtTotal = 0, LoanId = "" }
	if DebtServiceRef then
		debtData = DebtServiceRef.GetPersistData(player)
	end
	local statsData = { AuctionsWon = 0 }
	if PlayerStatsServiceRef and PlayerStatsServiceRef.GetPersistData then
		statsData = PlayerStatsServiceRef.GetPersistData(player)
	end
	local inventoryData = {}
	if InventoryServiceRef and InventoryServiceRef.GetPersistData then
		inventoryData = InventoryServiceRef.GetPersistData(player)
	end
	local success, result = pcall(function()
		store:SetAsync("player_" .. player.UserId, {
			Cash = cash,
			DebtRemaining = debtData.DebtRemaining,
			DebtTotal = debtData.DebtTotal,
			LoanId = debtData.LoanId,
			RecoveryAvailableAt = debtData.RecoveryAvailableAt,
			AuctionsWon = statsData.AuctionsWon,
			Inventory = inventoryData,
			SavedAt = os.time(),
		})
	end)
	if not success then
		warn("[SA] Save failed for " .. player.Name .. ": " .. tostring(result))
	end
end

return PlayerDataService
