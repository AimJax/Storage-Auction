--!nonstrict
-- StorageAuction M1 — server-authoritative inventory.
-- Items are owned server-side. Client receives copies for display only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

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

return InventoryService
