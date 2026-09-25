--!nonstrict
-- StorageAuction Stage 5B — durable progression/economy persistence.
-- Same SA_M1_v1 store, extended backward-compatible schema:
--   { Cash, Inventory, AuctionsWon, Debt, RecoveryAvailableAt, SavedAt, SchemaVersion }
-- Wrapped in pcall so Studio playtests WITHOUT DataStore API access still work.
-- Enable "Enable Studio Access to API Services" in Game Settings for real saves.
--
-- Load order (no half-loaded state): raw data -> sanitize/defaults ->
-- Economy Cash -> Inventory items -> Stats wins -> Debt/cooldown -> push all
-- to client -> mark loaded. Save snapshots BEFORE any ClearPlayer runs
-- (init.server calls Save first); unloaded players are never saved.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local ItemUtils = require(Shared.ItemUtils)

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
local PlayerStatsServiceRef = nil
local DebtServiceRef = nil
local WarehouseServiceRef = nil
local DisplayServiceRef = nil

local loaded = {} -- [UserId] = true once fully loaded (or session fallback)
local saveAllowed = {} -- [UserId] = true only when remote data is safe to overwrite

function PlayerDataService.Init(deps)
	EconomyServiceRef = deps.EconomyService
	InventoryServiceRef = deps.InventoryService
	PlayerStatsServiceRef = deps.PlayerStatsService
	DebtServiceRef = deps.DebtService
	WarehouseServiceRef = deps.WarehouseService
	DisplayServiceRef = deps.DisplayService
end

function PlayerDataService.IsLoaded(player)
	return player ~= nil and loaded[player.UserId] == true
end

-- Save gate: autosave / leave / shutdown must skip players whose load never
-- produced trustworthy state, so a failed load can never overwrite remote
-- data with defaults.
function PlayerDataService.IsSaveAllowed(player)
	return player ~= nil and saveAllowed[player.UserId] == true
end

-- Gameplay gate message shared by all server-mutating player actions.
function PlayerDataService.NotReadyMessage()
	return "Player data is still loading."
end

local function sanitizeNumber(value, default, min, max)
	local n = math.floor(tonumber(value) or default)
	if n < min then
		n = min
	end
	if max ~= nil and n > max then
		n = max
	end
	return n
end

-- Cash: absent OR negative/corrupt records fall back to starting cash (never
-- zero a player on a corrupt row); oversized values clamp to MaxCash.
local function sanitizeCash(value)
	local n = tonumber(value)
	if n == nil or n < 0 then
		return GameConfig.StartingCash
	end
	return math.clamp(math.floor(n), 0, GameConfig.MaxCash)
end

-- Backward-compatible record sanitize: old Cash-only rows (or partial rows)
-- load safely; malformed values clamp/default instead of crashing. Never
-- wipes valid data for absent newer fields.
local function sanitizeRecord(raw)
	if typeof(raw) ~= "table" then
		raw = {}
	end
	local inventory = {}
	if typeof(raw.Inventory) == "table" then
		local limit = tonumber(GameConfig.PersistInventoryLimit) or 500
		for _, entry in ipairs(raw.Inventory) do
			if #inventory >= limit then
				break -- deterministic: first valid entries win
			end
			local item = ItemUtils.SanitizeItemData(entry)
			if item then
				table.insert(inventory, item)
			end
		end
		if typeof(raw.Inventory) == "table" and #raw.Inventory > limit and GameConfig.DebugAuction then
			warn(string.format("[SA] Inventory capped at %d items on load.", limit))
		end
	end
	return {
		Cash = sanitizeCash(raw.Cash),
		Inventory = inventory,
		AuctionsWon = sanitizeNumber(raw.AuctionsWon, 0, 0, nil),
		Debt = sanitizeNumber(raw.Debt, 0, 0, nil),
		RecoveryAvailableAt = sanitizeNumber(raw.RecoveryAvailableAt, 0, 0, nil),
		-- Stage 6: warehouse level clamps to the configured ladder (default 1);
		-- display assignments restore against inventory + level afterwards.
		WarehouseLevel = sanitizeNumber(raw.WarehouseLevel, 1, 1, #GameConfig.WarehouseLevels),
		DisplayAssignments = if typeof(raw.DisplayAssignments) == "table" then raw.DisplayAssignments else {},
		SchemaVersion = tonumber(raw.SchemaVersion) or 0,
	}
end

function PlayerDataService.Load(player)
	local startCash = GameConfig.StartingCash
	-- Silent container setup first: no pushes until final state is known,
	-- so clients never see a fake StartingCash/empty-inventory flash.
	EconomyServiceRef.SetupPlayer(player, startCash, true)
	InventoryServiceRef.SetupPlayer(player)
	if DebtServiceRef then
		DebtServiceRef.SetupPlayer(player)
	end
	loaded[player.UserId] = false
	saveAllowed[player.UserId] = false
	if not store then
		-- Session fallback: playable now, never persisted.
		PlayerDataService.finishLoad(player, sanitizeRecord(nil))
		return
	end
	local data = nil
	local loadOk = false
	local success, result = pcall(function()
		return store:GetAsync("player_" .. player.UserId)
	end)
	if success then
		data = result
		loadOk = true
	else
		warn("[SA] Load failed for " .. player.Name .. ": " .. tostring(result))
	end
	if not loadOk then
		-- Failed load: playable session fallback, but SaveAllowed stays
		-- false so later saves can never overwrite remote data with defaults.
		PlayerDataService.finishLoad(player, sanitizeRecord(nil))
		return
	end
	saveAllowed[player.UserId] = true
	PlayerDataService.finishLoad(player, sanitizeRecord(data))
end

-- Shared finalization for every load outcome: restore in deterministic
-- order, push final state once, then mark ready. Never half-loaded.
function PlayerDataService.finishLoad(player, clean)
	-- Deterministic restore order; every push keeps the client consistent.
	-- Over-cap grandfathered inventories restore intact (only NEW keeps gate).
	EconomyServiceRef.SetCash(player, clean.Cash)
	InventoryServiceRef.RestoreItems(player, clean.Inventory)
	if PlayerStatsServiceRef then
		PlayerStatsServiceRef.RestoreWins(player, clean.AuctionsWon)
	end
	if WarehouseServiceRef then
		WarehouseServiceRef.RestoreLevel(player, clean.WarehouseLevel)
	end
	if DebtServiceRef then
		DebtServiceRef.RestorePlayer(player, {
			debt = clean.Debt,
			recoveryAvailableAt = clean.RecoveryAvailableAt,
		})
	end
	if DisplayServiceRef then
		DisplayServiceRef.RestoreAssignments(player, clean.DisplayAssignments)
	end
	if PlayerStatsServiceRef then
		PlayerStatsServiceRef.Push(player)
	end
	loaded[player.UserId] = true
end

-- Snapshot current runtime state into a sanitized, storable record.
-- Explicitly EXCLUDES: plot assignment, auction/bid/loot/NPC state, pendings.
local function snapshot(player)
	local cash = 0
	if EconomyServiceRef then
		cash = EconomyServiceRef.GetCash(player)
	end
	local inventory = {}
	if InventoryServiceRef then
		local limit = tonumber(GameConfig.PersistInventoryLimit) or 500
		for _, item in ipairs(InventoryServiceRef.GetItems(player)) do
			if #inventory >= limit then
				break
			end
			local entry = ItemUtils.SerializeItem(item)
			if entry then
				table.insert(inventory, entry)
			end
		end
	end
	local wins = 0
	if PlayerStatsServiceRef then
		wins = PlayerStatsServiceRef.GetWins(player)
	end
	local debtState = { debt = 0, recoveryAvailableAt = 0 }
	if DebtServiceRef then
		debtState = DebtServiceRef.GetPersistentState(player)
	end
	local warehouseLevel = 1
	if WarehouseServiceRef then
		warehouseLevel = WarehouseServiceRef.GetLevel(player)
	end
	local displayAssignments = {}
	if DisplayServiceRef then
		displayAssignments = DisplayServiceRef.GetPersistentAssignments(player)
	end
	return {
		Cash = sanitizeNumber(cash, 0, 0, GameConfig.MaxCash),
		Inventory = inventory,
		AuctionsWon = sanitizeNumber(wins, 0, 0, nil),
		Debt = sanitizeNumber(debtState.debt, 0, 0, nil),
		RecoveryAvailableAt = sanitizeNumber(debtState.recoveryAvailableAt, 0, 0, nil),
		WarehouseLevel = sanitizeNumber(warehouseLevel, 1, 1, #GameConfig.WarehouseLevels),
		DisplayAssignments = displayAssignments,
		SavedAt = os.time(),
		SchemaVersion = tonumber(GameConfig.PersistSchemaVersion) or 2,
	}
end

function PlayerDataService.Save(player)
	if not store then
		return
	end
	if not player or loaded[player.UserId] ~= true then
		-- Never overwrite remote data with defaults for unloaded players.
		return
	end
	if saveAllowed[player.UserId] ~= true then
		-- Load failed or store unavailable: session is playable but must
		-- never persist. Explicit (not silent) so logs show the reason.
		warn("[SA] Save skipped for " .. player.Name .. " (load did not produce saveable state).")
		return
	end
	-- Snapshot BEFORE any yield so retries store one consistent record.
	local record = snapshot(player)
	local success, result = nil, nil
	for attempt = 1, 3 do
		success, result = pcall(function()
			store:SetAsync("player_" .. player.UserId, record)
		end)
		if success then
			break
		end
		if attempt < 3 then
			task.wait(0.5 * attempt) -- bounded backoff, no infinite loops
		end
	end
	if not success then
		warn("[SA] Save failed for " .. player.Name .. ": " .. tostring(result))
	end
end

function PlayerDataService.ClearPlayer(player)
	if player then
		loaded[player.UserId] = nil
		saveAllowed[player.UserId] = nil
	end
end

-- Conservative autosave: loaded players only, same guarded Save path.
-- Started once from init.server.
function PlayerDataService.StartAutosave()
	local interval = tonumber(GameConfig.PersistAutosaveInterval) or 120
	if interval <= 0 then
		return
	end
	task.spawn(function()
		while true do
			task.wait(interval)
			for _, player in ipairs(Players:GetPlayers()) do
				if loaded[player.UserId] == true then
					PlayerDataService.Save(player)
				end
			end
		end
	end)
end

return PlayerDataService
