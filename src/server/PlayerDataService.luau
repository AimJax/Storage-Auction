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

function PlayerDataService.Init(economyService, inventoryService)
	EconomyServiceRef = economyService
	InventoryServiceRef = inventoryService
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
	if typeof(data) == "table" and typeof(data.Cash) == "number" then
		EconomyServiceRef.SetupPlayer(player, math.clamp(math.floor(data.Cash), 0, GameConfig.MaxCash))
	else
		EconomyServiceRef.SetupPlayer(player, startCash)
	end
	InventoryServiceRef.SetupPlayer(player)
	-- M1: kept items are session-only; Cash persists. Full collection
	-- persistence comes in a later milestone.
end

function PlayerDataService.Save(player)
	if not store then
		return
	end
	local cash = 0
	if EconomyServiceRef then
		cash = EconomyServiceRef.GetCash(player)
	end
	local success, result = pcall(function()
		store:SetAsync("player_" .. player.UserId, {
			Cash = cash,
			SavedAt = os.time(),
		})
	end)
	if not success then
		warn("[SA] Save failed for " .. player.Name .. ": " .. tostring(result))
	end
end

return PlayerDataService
