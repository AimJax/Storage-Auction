--!nonstrict
-- StorageAuction MVP — display slot assignments inside player warehouses.
--
-- Tracks, per player, which owned inventory item (by InstanceId) sits in
-- each display slot, and builds a small physical proxy on that player's
-- runtime warehouse slot (rarity-colored, labeled with server data).
-- Plot allocation and warehouse instances belong to PlotService /
-- WarehouseService; this service never touches them.
--
-- Rules enforced here, never trusted from the client:
--   slot 1..DisplaySlotCount, ownership via InventoryService lookup,
--   one item per slot, one slot per item (per player), replace clears the
--   old proxy, selling a displayed item auto-clears its display (no ghosts).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local RarityConfig = require(Shared.RarityConfig)

local DisplayService = {}

local InventoryService = nil
local WarehouseService = nil
local PlayerDataService = nil
local RemoteGuardService = nil
local Remotes = nil

-- [UserId] = { [slotIndex] = InstanceId }. Identity only — item fields are
-- always resolved live from InventoryService so restores and sales can never
-- desync into stale copies or ghost proxies.
local assignments = {}

local function rarityColor(rarity)
	local def = RarityConfig.Definitions[rarity]
	if def then
		return def.Color
	end
	return Color3.new(1, 1, 1)
end

local function rarityScale(rarity)
	local order = RarityConfig.Order
	for i, name in ipairs(order) do
		if name == rarity then
			return 1 + (i - 1) * 0.12
		end
	end
	return 1
end

local function pushDisplayState(player)
	if not Remotes then
		return
	end
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.DisplayChanged)
	if ev then
		ev:FireClient(player, DisplayService.GetDisplayState(player))
	end
end

local function destroyProxy(player, slotIndex)
	local root = WarehouseService and WarehouseService.GetWarehouseRoot(player)
	if not root then
		return
	end
	local old = root:FindFirstChild("Slot_" .. tostring(slotIndex) .. "_Display", true)
	if old then
		old:Destroy()
	end
end

local function buildProxy(player, slotIndex, item)
	destroyProxy(player, slotIndex)
	local pos = WarehouseService and WarehouseService.GetSlotPosition(player, slotIndex)
	if not pos then
		return nil
	end
	local root = WarehouseService.GetWarehouseRoot(player)
	if not root then
		return nil
	end
	local scale = rarityScale(item.Rarity)
	local size = 2 * scale
	local proxy = Instance.new("Part")
	proxy.Name = "Slot_" .. tostring(slotIndex) .. "_Display"
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanTouch = false
	proxy.CanQuery = false
	proxy.Size = Vector3.new(size, size, size)
	proxy.Position = pos + Vector3.new(0, 0.1 + size / 2 + 1.2, 0)
	proxy.Color = rarityColor(item.Rarity)
	proxy.Material = Enum.Material.Glass
	proxy.Parent = root

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(220, 90)
	billboard.StudsOffset = Vector3.new(0, size / 2 + 1.4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 60
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	label.BackgroundTransparency = 0.25
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextWrapped = true
	label.Text = string.format("%s\n%s\n$%d", item.Name, string.upper(tostring(item.Rarity)), tonumber(item.FinalValue) or 0)
	label.Parent = billboard
	billboard.Parent = proxy
	return proxy
end

local function findSlotWithItem(userId, instanceId)
	local playerSlots = assignments[userId]
	if not playerSlots then
		return nil
	end
	for slotIndex, storedId in pairs(playerSlots) do
		if storedId == instanceId then
			return slotIndex
		end
	end
	return nil
end

local function ownsItem(player, instanceId)
	for _, item in ipairs(InventoryService.GetItems(player)) do
		if item.InstanceId == instanceId then
			return item
		end
	end
	return nil
end

function DisplayService.Init(deps)
	InventoryService = deps.InventoryService
	WarehouseService = deps.WarehouseService
	PlayerDataService = deps.PlayerDataService
	RemoteGuardService = deps.RemoteGuardService
	Remotes = deps.Remotes

	local displayItem = Remotes:FindFirstChild(GameConfig.RemoteNames.DisplayItem)
	if displayItem and displayItem:IsA("RemoteFunction") then
		displayItem.OnServerInvoke = function(player, instanceId, slotIndex)
			if RemoteGuardService and not RemoteGuardService.Check(player, "DisplayItem") then
				return { ok = false, result = "Too fast. Try again." }
			end
			local ok, result = DisplayService.AssignDisplay(player, instanceId, slotIndex)
			return { ok = ok, result = result }
		end
	end
	local removeDisplay = Remotes:FindFirstChild(GameConfig.RemoteNames.RemoveDisplay)
	if removeDisplay and removeDisplay:IsA("RemoteFunction") then
		removeDisplay.OnServerInvoke = function(player, instanceId)
			if RemoteGuardService and not RemoteGuardService.Check(player, "RemoveDisplay") then
				return { ok = false, result = "Too fast. Try again." }
			end
			local ok, result = DisplayService.RemoveDisplay(player, instanceId)
			return { ok = ok, result = result }
		end
	end
end

function DisplayService.IsAvailable()
	return WarehouseService ~= nil
end

-- Assign an OWNED item to one of the CALLER's warehouse slots. Touches
-- nothing belonging to any other player. Replaces the caller's own occupant.
-- Slot range follows the player's warehouse level (not a hardcoded count).
function DisplayService.AssignDisplay(player, instanceId, slotIndex)
	if PlayerDataService and not PlayerDataService.IsLoaded(player) then
		return false, PlayerDataService.NotReadyMessage()
	end
	slotIndex = math.floor(tonumber(slotIndex) or 0)
	local maxSlots = WarehouseService and WarehouseService.GetDisplaySlotCount(player) or GameConfig.DisplaySlotCount
	if slotIndex < 1 or slotIndex > maxSlots then
		return false, "Invalid slot (1-" .. maxSlots .. ")."
	end
	if typeof(instanceId) ~= "string" or instanceId == "" then
		return false, "Invalid item."
	end
	local item = ownsItem(player, instanceId)
	if not item then
		return false, "You don't own that item."
	end
	local pos = WarehouseService and WarehouseService.GetSlotPosition(player, slotIndex)
	if not pos then
		return false, "No warehouse plot available in this server."
	end
	-- One item cannot occupy multiple slots: clear its old slot first.
	local oldSlot = findSlotWithItem(player.UserId, instanceId)
	if oldSlot and oldSlot ~= slotIndex then
		local playerSlots = assignments[player.UserId]
		if playerSlots then
			playerSlots[oldSlot] = nil
		end
		destroyProxy(player, oldSlot)
	end
	local playerSlots = assignments[player.UserId]
	if not playerSlots then
		playerSlots = {}
		assignments[player.UserId] = playerSlots
	end
	playerSlots[slotIndex] = instanceId
	buildProxy(player, slotIndex, item)
	pushDisplayState(player)
	return true, item
end

-- Remove whichever of the CALLER's displays holds this InstanceId.
function DisplayService.RemoveDisplay(player, instanceId)
	if PlayerDataService and not PlayerDataService.IsLoaded(player) then
		return false, PlayerDataService.NotReadyMessage()
	end
	local slotIndex = findSlotWithItem(player.UserId, instanceId)
	if not slotIndex then
		return false, "That item is not on display."
	end
	local playerSlots = assignments[player.UserId]
	if playerSlots then
		playerSlots[slotIndex] = nil
	end
	destroyProxy(player, slotIndex)
	pushDisplayState(player)
	return true, slotIndex
end

-- Called after an inventory removal (sell). Clears ONLY the seller's display
-- of the item so a ghost proxy of an unowned item can never persist.
function DisplayService.OnItemRemoved(player, instanceId)
	local slotIndex = findSlotWithItem(player.UserId, instanceId)
	if not slotIndex then
		return
	end
	local playerSlots = assignments[player.UserId]
	if playerSlots then
		playerSlots[slotIndex] = nil
	end
	destroyProxy(player, slotIndex)
	pushDisplayState(player)
end

-- Snapshot for UI: the CALLER's per-slot occupant info (server data only),
-- plus level/slot metadata so the client picker needs no hardcoded counts.
function DisplayService.GetDisplayState(player)
	local maxSlots = WarehouseService and WarehouseService.GetDisplaySlotCount(player) or GameConfig.DisplaySlotCount
	local level = WarehouseService and WarehouseService.GetLevel(player) or 1
	local state = { slots = {}, slotCount = maxSlots, level = level }
	local playerSlots = assignments[player.UserId] or {}
	for i = 1, maxSlots do
		local storedId = playerSlots[i]
		local item = if typeof(storedId) == "string" then ownsItem(player, storedId) else nil
		if item then
			state.slots[i] = {
				instanceId = item.InstanceId,
				name = item.Name,
				rarity = item.Rarity,
				value = item.FinalValue,
			}
		else
			state.slots[i] = nil
		end
	end
	return state
end

-- Sanitized persistent form: { [slot] = InstanceId }. No models, positions,
-- or plot references — data only.
function DisplayService.GetPersistentAssignments(player)
	local out = {}
	if not player then
		return out
	end
	for slotIndex, storedId in pairs(assignments[player.UserId] or {}) do
		if typeof(slotIndex) == "number" and typeof(storedId) == "string" then
			out[slotIndex] = storedId
		end
	end
	return out
end

-- Restore persisted assignments (Stage 6): keep only integer slots within
-- the player's level allowance, string ids present in the restored
-- inventory, and no id twice. Proxies rebuild only when a warehouse exists
-- (plot claim refreshes them separately). Returns count kept.
function DisplayService.RestoreAssignments(player, map)
	if not player then
		return 0
	end
	assignments[player.UserId] = {}
	if typeof(map) ~= "table" then
		return 0
	end
	local maxSlots = WarehouseService and WarehouseService.GetDisplaySlotCount(player) or GameConfig.DisplaySlotCount
	local owned = {}
	for _, item in ipairs(InventoryService.GetItems(player)) do
		owned[item.InstanceId] = true
	end
	local kept = {}
	local count = 0
	for rawSlot, instanceId in pairs(map) do
		local numSlot = tonumber(rawSlot)
		-- Strictly integer slot indices only (1.5 must not become 1).
		if numSlot == nil or math.floor(numSlot) ~= numSlot then
			continue
		end
		local slotIndex = numSlot
		if slotIndex >= 1 and slotIndex <= maxSlots
			and typeof(instanceId) == "string"
			and owned[instanceId] and not kept[instanceId]
		then
			kept[instanceId] = true
			assignments[player.UserId][slotIndex] = instanceId
			count += 1
		end
	end
	DisplayService.RefreshProxies(player)
	pushDisplayState(player)
	return count
end

-- Rebuild every display proxy from stored assignments (plot claim, level
-- change). Missing warehouse/items resolve to no proxy, never an error.
function DisplayService.RefreshProxies(player)
	if not player then
		return
	end
	local playerSlots = assignments[player.UserId] or {}
	for slotIndex, storedId in pairs(playerSlots) do
		local item = ownsItem(player, storedId)
		if item then
			buildProxy(player, slotIndex, item)
		else
			destroyProxy(player, slotIndex)
		end
	end
	pushDisplayState(player)
end

-- Records only; the warehouse itself is destroyed by PlotService.ReleasePlot.
function DisplayService.ClearPlayer(player)
	if player then
		assignments[player.UserId] = nil
	end
end

return DisplayService
