--!nonstrict
-- StorageAuction MVP — server-authoritative display assignments.
--
-- Tracks, per player, which owned inventory item (by InstanceId) sits in
-- each of the 6 showroom slots, and builds a small physical proxy on the
-- Studio-authored slot part (rarity-colored, labeled with server data).
--
-- Rules enforced here, never trusted from the client:
--   slot 1..DisplaySlotCount, ownership via InventoryService lookup,
--   one item per slot, one slot per item, replace clears the old proxy,
--   selling a displayed item auto-clears its display (no ghosts).
--
-- MVP scope note: the physical area is ONE shared showroom, so slot visuals
-- are global (slot -> assignment). Assignment records are per player so a
-- future per-player-showroom milestone can reuse them unchanged.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local RarityConfig = require(Shared.RarityConfig)

local DisplayService = {}

local InventoryService = nil
local MapHandles = nil
local Remotes = nil

-- [UserId] = { [slotIndex] = itemInstance (server copy at assign time) }
local assignments = {}
local displaysFolder = nil

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

local function slotPart(slotIndex)
	if not MapHandles or not MapHandles.ShowroomSlots then
		return nil
	end
	return MapHandles.ShowroomSlots[slotIndex]
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

local function pushAllDisplays()
	if not Remotes then
		return
	end
	local Players = game:GetService("Players")
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.DisplayChanged)
	if not ev then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		ev:FireClient(player, DisplayService.GetDisplayState(player))
	end
end

local function destroyProxy(slotIndex)
	if not displaysFolder then
		return
	end
	local old = displaysFolder:FindFirstChild("Slot_" .. tostring(slotIndex))
	if old then
		old:Destroy()
	end
end

local function buildProxy(player, slotIndex, item)
	destroyProxy(slotIndex)
	local slot = slotPart(slotIndex)
	if not slot or not displaysFolder then
		return nil
	end
	local scale = rarityScale(item.Rarity)
	local size = 2 * scale
	local proxy = Instance.new("Part")
	proxy.Name = "Slot_" .. tostring(slotIndex)
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanTouch = false
	proxy.CanQuery = false
	proxy.Size = Vector3.new(size, size, size)
	proxy.Position = slot.Position + Vector3.new(0, 0.1 + size / 2 + 1.2, 0)
	proxy.Color = rarityColor(item.Rarity)
	proxy.Material = Enum.Material.SmoothPlastic
	proxy.Parent = displaysFolder

	local billboard = Instance.new("BillboardGui")
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
	for slotIndex, item in pairs(playerSlots) do
		if item.InstanceId == instanceId then
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
	MapHandles = deps.MapHandles
	Remotes = deps.Remotes

	displaysFolder = game.Workspace:FindFirstChild("SA_Displays")
	if not displaysFolder then
		displaysFolder = Instance.new("Folder")
		displaysFolder.Name = "SA_Displays"
		displaysFolder.Parent = game.Workspace
	end

	local displayItem = Remotes:FindFirstChild(GameConfig.RemoteNames.DisplayItem)
	if displayItem and displayItem:IsA("RemoteFunction") then
		displayItem.OnServerInvoke = function(player, instanceId, slotIndex)
			local ok, result = DisplayService.AssignDisplay(player, instanceId, slotIndex)
			return { ok = ok, result = result }
		end
	end
	local removeDisplay = Remotes:FindFirstChild(GameConfig.RemoteNames.RemoveDisplay)
	if removeDisplay and removeDisplay:IsA("RemoteFunction") then
		removeDisplay.OnServerInvoke = function(player, instanceId)
			local ok, result = DisplayService.RemoveDisplay(player, instanceId)
			return { ok = ok, result = result }
		end
	end
end

function DisplayService.IsAvailable()
	return MapHandles ~= nil and MapHandles.ShowroomSlots ~= nil and #MapHandles.ShowroomSlots > 0
end

-- Assign an OWNED item to a slot. Replaces any occupant (own or other's).
function DisplayService.AssignDisplay(player, instanceId, slotIndex)
	if not DisplayService.IsAvailable() then
		return false, "Showroom is not available."
	end
	slotIndex = math.floor(tonumber(slotIndex) or 0)
	if slotIndex < 1 or slotIndex > GameConfig.DisplaySlotCount then
		return false, "Invalid slot (1-" .. GameConfig.DisplaySlotCount .. ")."
	end
	if typeof(instanceId) ~= "string" or instanceId == "" then
		return false, "Invalid item."
	end
	if slotPart(slotIndex) == nil then
		return false, "That slot does not exist."
	end
	local item = ownsItem(player, instanceId)
	if not item then
		return false, "You don't own that item."
	end
	-- One item cannot occupy multiple slots: clear its old slot first.
	local oldSlot = findSlotWithItem(player.UserId, instanceId)
	if oldSlot and oldSlot ~= slotIndex then
		local playerSlots = assignments[player.UserId]
		if playerSlots then
			playerSlots[oldSlot] = nil
		end
		destroyProxy(oldSlot)
	end
	local playerSlots = assignments[player.UserId]
	if not playerSlots then
		playerSlots = {}
		assignments[player.UserId] = playerSlots
	end
	-- MVP shared showroom: slots are global. Clear any other owner's record
	-- for this slot so no stale assignment survives a replace.
	for userId, otherSlots in pairs(assignments) do
		if userId ~= player.UserId and otherSlots[slotIndex] ~= nil then
			otherSlots[slotIndex] = nil
		end
	end
	playerSlots[slotIndex] = item
	buildProxy(player, slotIndex, item)
	pushAllDisplays()
	return true, item
end

-- Remove whichever display holds this InstanceId (no-op success if none).
function DisplayService.RemoveDisplay(player, instanceId)
	local slotIndex = findSlotWithItem(player.UserId, instanceId)
	if not slotIndex then
		return false, "That item is not on display."
	end
	local playerSlots = assignments[player.UserId]
	if playerSlots then
		playerSlots[slotIndex] = nil
	end
	destroyProxy(slotIndex)
	pushAllDisplays()
	return true, slotIndex
end

-- Called after an inventory removal (sell). Clears any display of the item
-- so a ghost proxy of an unowned item can never persist.
function DisplayService.OnItemRemoved(player, instanceId)
	local slotIndex = findSlotWithItem(player.UserId, instanceId)
	if not slotIndex then
		return
	end
	local playerSlots = assignments[player.UserId]
	if playerSlots then
		playerSlots[slotIndex] = nil
	end
	destroyProxy(slotIndex)
	pushAllDisplays()
end

-- Snapshot for UI: per-slot occupant info (server data only).
function DisplayService.GetDisplayState(player)
	local state = { slots = {} }
	local count = GameConfig.DisplaySlotCount
	if MapHandles and MapHandles.ShowroomSlots then
		count = math.min(count, #MapHandles.ShowroomSlots)
	end
	local playerSlots = assignments[player.UserId] or {}
	for i = 1, count do
		local item = playerSlots[i]
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

function DisplayService.ClearPlayer(player)
	if not player then
		return
	end
	local playerSlots = assignments[player.UserId]
	if playerSlots then
		for slotIndex, _ in pairs(playerSlots) do
			destroyProxy(slotIndex)
		end
	end
	assignments[player.UserId] = nil
end

return DisplayService
