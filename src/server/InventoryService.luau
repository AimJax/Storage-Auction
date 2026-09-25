--!nonstrict
-- StorageAuction M1 — server-authoritative inventory.
-- Items are owned server-side. Client receives copies for display only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local ItemUtils = require(Shared.ItemUtils)

local InventoryService = {}

local inventories = {} -- [UserId] = { itemInstance, ... }
local remotesFolder = nil

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
	-- No push here: PlayerDataService restores saved items (with its own
	-- push) and init.server pushes the final list on join, so clients never
	-- see a fake empty-inventory flash.
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
	-- Defensive copies (including Modifiers) so callers can never mutate
	-- server ownership records through a shared reference.
	local copy = {}
	for i, it in ipairs(list) do
		local mods = {}
		if typeof(it.Modifiers) == "table" then
			for k, v in pairs(it.Modifiers) do
				mods[k] = v
			end
		end
		copy[i] = {
			InstanceId = it.InstanceId,
			ItemId = it.ItemId,
			Name = it.Name,
			BaseValue = it.BaseValue,
			ModelKey = it.ModelKey,
			Rarity = it.Rarity,
			Condition = it.Condition,
			ConditionName = it.ConditionName,
			FinalValue = it.FinalValue,
			Modifiers = mods,
		}
	end
	return copy
end

function InventoryService.GetCount(player)
	if not player then
		return 0
	end
	return #(inventories[player.UserId] or {})
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

-- Restore persisted items (Stage 5B). Entries are validated through
-- ItemUtils.SanitizeItemData (unknown defs/rarities skipped, numerics
-- clamped); callers pass already-capped lists. Duplicate InstanceIds within
-- one restore are skipped (never duplicate items). Returns count restored.
function InventoryService.RestoreItems(player, entries)
	if not player or typeof(entries) ~= "table" then
		return 0
	end
	inventories[player.UserId] = {}
	local seen = {}
	local count = 0
	for _, entry in ipairs(entries) do
		local item = ItemUtils.SanitizeItemData(entry)
		if item and not seen[item.InstanceId] then
			seen[item.InstanceId] = true
			table.insert(inventories[player.UserId], item)
			count += 1
		end
	end
	push(player)
	return count
end

return InventoryService
