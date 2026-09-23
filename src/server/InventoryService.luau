--!nonstrict
-- StorageAuction M1 — server-authoritative inventory.
-- Items are owned server-side. Client receives copies for display only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local RarityConfig = require(Shared.RarityConfig)
local ItemUtils = require(Shared.ItemUtils)

local InventoryService = {}

local inventories = {} -- [UserId] = { itemInstance, ... }
local remotesFolder = nil

-- Defensive cap: persistence ignores entries past this (bloat protection).
local MAX_PERSISTED_ITEMS = 500

function InventoryService.Init(remotes)
	remotesFolder = remotes
end

local function push(player)
	local list = inventories[player.UserId] or {}
	if remotesFolder then
		local ev = remotesFolder:FindFirstChild(GameConfig.RemoteNames.InventoryChanged)
		if ev then
			ev:FireClient(player, list)
		end
	end
end

function InventoryService.SetupPlayer(player)
	if inventories[player.UserId] == nil then
		inventories[player.UserId] = {}
	end
	task.defer(push, player)
end

function InventoryService.AddItem(player, itemInstance)
	local list = inventories[player.UserId]
	if not list then
		list = {}
		inventories[player.UserId] = list
	end
	table.insert(list, itemInstance)
	push(player)
	return itemInstance
end

function InventoryService.GetItems(player)
	local list = inventories[player.UserId] or {}
	-- Return a copy so callers can't mutate server state.
	local copy = {}
	for i, it in ipairs(list) do
		copy[i] = it
	end
	return copy
end

-- Removes by InstanceId. Returns removed item or nil.
function InventoryService.RemoveItem(player, instanceId)
	local list = inventories[player.UserId]
	if not list then
		return nil
	end
	for i, it in ipairs(list) do
		if it.InstanceId == instanceId then
			table.remove(list, i)
			push(player)
			return it
		end
	end
	return nil
end

function InventoryService.ClearPlayer(player)
	inventories[player.UserId] = nil
end

-- Validate + rebuild one persisted record. Never trusts shape: malformed
-- entries return nil (skipped). ConditionName is recomputed so display
-- always matches Condition even if the save predates it.
local nextRestoredSeq = 0
local function restoreRecord(raw)
	if typeof(raw) ~= "table" then
		return nil
	end
	local rarity = tostring(raw.Rarity or "Common")
	if not RarityConfig.Definitions[rarity] then
		rarity = "Common"
	end
	local condition = math.clamp(math.floor(tonumber(raw.Condition) or 50), 0, 100)
	nextRestoredSeq += 1
	local instanceId = raw.InstanceId
	if typeof(instanceId) ~= "string" or instanceId == "" then
		instanceId = "restored_" .. tostring(os.clock()):gsub("%.", "") .. "_" .. tostring(nextRestoredSeq)
	end
	local modifiers = raw.Modifiers
	if typeof(modifiers) ~= "table" then
		modifiers = {}
	end
	return {
		InstanceId = instanceId,
		ItemId = tostring(raw.ItemId or raw.Id or "unknown"),
		Name = tostring(raw.Name or "Unknown Item"),
		BaseValue = math.max(0, math.floor(tonumber(raw.BaseValue) or 0)),
		ModelKey = tostring(raw.ModelKey or ""),
		Rarity = rarity,
		Condition = condition,
		ConditionName = ItemUtils.ConditionName(condition),
		FinalValue = math.max(0, math.floor(tonumber(raw.FinalValue) or 0)),
		Modifiers = modifiers,
	}
end

-- Persistence support: data-only records, no Instance references.
function InventoryService.GetPersistData(player)
	local out = {}
	for _, item in ipairs(inventories[player.UserId] or {}) do
		table.insert(out, {
			InstanceId = item.InstanceId,
			ItemId = item.ItemId,
			Name = item.Name,
			BaseValue = item.BaseValue,
			ModelKey = item.ModelKey,
			Rarity = item.Rarity,
			Condition = item.Condition,
			ConditionName = item.ConditionName,
			FinalValue = item.FinalValue,
			Modifiers = item.Modifiers,
		})
		if #out >= MAX_PERSISTED_ITEMS then
			break
		end
	end
	return out
end

function InventoryService.LoadPersisted(player, data)
	local list = inventories[player.UserId]
	if not list then
		list = {}
		inventories[player.UserId] = list
	end
	if typeof(data) ~= "table" then
		return
	end
	for _, raw in ipairs(data) do
		if #list >= MAX_PERSISTED_ITEMS then
			break
		end
		local item = restoreRecord(raw)
		if item then
			table.insert(list, item)
		end
	end
	push(player)
end

return InventoryService
