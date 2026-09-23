--!nonstrict
-- StorageAuction MVP — player-owned showroom displays.
--
-- Each player owns their logical AND physical display state:
--
--   Workspace/SA_PlayerShowrooms/Player_<UserId>/  (runtime clone per player)
--     Floor, BackWall, LeftWall, RightWall, Sign (cloned template geometry)
--     DisplaySlots/Slot_1..6                       (this player's slot parts)
--       + Slot_N proxy Part (rarity-colored, labeled, server data only)
--
-- The Studio-authored Workspace.StorageAuctionMap.PlayerShowroom is the
-- editable TEMPLATE ONLY: hidden at runtime, never written to, never used
-- for proxies. Runtime clones live outside the Argon-managed map tree so
-- two-way sync can never fight them.
--
-- Rules enforced here, never trusted from the client:
--   slot 1..slotCount, ownership via InventoryService lookup,
--   one item per slot, one slot per item (per player), replace clears the
--   old proxy, selling a displayed item auto-clears its display (no ghosts).
-- No player can ever touch another player's assignments or proxies.

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
-- [UserId] = { root = Model, slots = { [slotIndex] = Part } }
local showrooms = {}
-- [UserId] = plotIndex (0-based; offset = index * PLOT_SPACING on +X)
local plotByUser = {}
local freedPlots = {}
local nextPlotIndex = 0

local PLOT_SPACING = 24
local SHOWROOMS_FOLDER_NAME = "SA_PlayerShowrooms"

local showroomsFolder = nil

-- Forward declaration: defined below buildProxy's callers need it at runtime
-- (getShowroom re-render). Assigned before any call happens (post-Init).
local buildProxyIn

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

local function slotCount()
	local count = GameConfig.DisplaySlotCount
	if MapHandles and MapHandles.ShowroomSlots then
		count = math.min(count, #MapHandles.ShowroomSlots)
	end
	return count
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

-- Template visuals, recorded before hiding so clones can restore them.
-- Positional list parallel to GetDescendants() order; clones are structural
-- copies, so a pairwise walk restores 1:1 (mismatches are skipped).
local templateVisuals = {}

local function recordVisuals(template)
	templateVisuals = {}
	for _, desc in ipairs(template:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(templateVisuals, {
				transparency = desc.Transparency,
				collide = desc.CanCollide,
				touch = desc.CanTouch,
				query = desc.CanQuery,
			})
		elseif desc:IsA("SurfaceGui") or desc:IsA("BillboardGui") then
			table.insert(templateVisuals, { guiEnabled = desc.Enabled })
		else
			table.insert(templateVisuals, {})
		end
	end
end

local function restoreVisuals(clone)
	local cloneDescs = clone:GetDescendants()
	for i, recorded in ipairs(templateVisuals) do
		local desc = cloneDescs[i]
		if not desc then
			break
		end
		if desc:IsA("BasePart") and recorded.transparency ~= nil then
			desc.Transparency = recorded.transparency
			desc.CanCollide = recorded.collide
			desc.CanTouch = recorded.touch
			desc.CanQuery = recorded.query
		elseif (desc:IsA("SurfaceGui") or desc:IsA("BillboardGui")) and recorded.guiEnabled ~= nil then
			desc.Enabled = recorded.guiEnabled
		end
	end
end

-- Hide the authored template at runtime (place file untouched; this only
-- affects the live session). Clones carry the visuals from here on.
local function hideTemplate(template)
	if not template then
		return
	end
	recordVisuals(template)
	for _, desc in ipairs(template:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Transparency = 1
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
		elseif desc:IsA("SurfaceGui") or desc:IsA("BillboardGui") then
			desc.Enabled = false
		end
	end
end

local function claimPlot(player)
	local existing = plotByUser[player.UserId]
	if existing ~= nil then
		return existing
	end
	local index = table.remove(freedPlots)
	if index == nil then
		index = nextPlotIndex
		nextPlotIndex += 1
	end
	plotByUser[player.UserId] = index
	return index
end

-- Returns (and lazily builds) this player's runtime showroom, or nil when
-- no template exists in the map.
local function getShowroom(player)
	local existing = showrooms[player.UserId]
	if existing and existing.root.Parent ~= nil then
		return existing
	end
	local template = MapHandles and MapHandles.ShowroomTemplate
	if not template then
		return nil
	end
	if not showroomsFolder then
		return nil
	end
	local plotIndex = claimPlot(player)
	local clone = template:Clone()
	clone.Name = "Player_" .. tostring(player.UserId)
	clone:SetAttribute("OwnerUserId", player.UserId)
	clone:PivotTo(template:GetPivot() + Vector3.new(plotIndex * PLOT_SPACING, 0, 0))
	clone.Parent = showroomsFolder
	restoreVisuals(clone)
	local slotsFolder = clone:FindFirstChild("DisplaySlots")
	local slots = {}
	if slotsFolder then
		for i = 1, slotCount() do
			local slot = slotsFolder:FindFirstChild("Slot_" .. i)
			if slot and slot:IsA("BasePart") then
				slots[i] = slot
			else
				break
			end
		end
	end
	local entry = { root = clone, slots = slots }
	showrooms[player.UserId] = entry
	-- Re-render surviving assignments (e.g. showroom rebuilt out-of-band;
	-- records outlive the folder here, proxies do not).
	local playerSlots = assignments[player.UserId]
	if playerSlots then
		for slotIndex, item in pairs(playerSlots) do
			if entry.slots[slotIndex] then
				buildProxyIn(entry, player.UserId, slotIndex, item)
			end
		end
	end
	return entry
end

local function destroyProxy(userId, slotIndex)
	local entry = showrooms[userId]
	local root = if entry then entry.root else nil
	if not root or root.Parent == nil then
		-- Fall back to a direct lookup so stale proxies can never linger.
		if showroomsFolder then
			root = showroomsFolder:FindFirstChild("Player_" .. tostring(userId))
		end
	end
	if not root then
		return
	end
	local old = root:FindFirstChild("Slot_" .. tostring(slotIndex) .. "_Display", true)
	if old then
		old:Destroy()
	end
end

buildProxyIn = function(entry, userId, slotIndex, item)
	destroyProxy(userId, slotIndex)
	local slot = entry and entry.slots[slotIndex]
	if not slot then
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
	proxy.Position = slot.Position + Vector3.new(0, 0.1 + size / 2 + 1.2, 0)
	proxy.Color = rarityColor(item.Rarity)
	proxy.Material = Enum.Material.Glass
	proxy.Parent = entry.root

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

local function buildProxy(player, slotIndex, item)
	local entry = getShowroom(player)
	if not entry then
		return nil
	end
	return buildProxyIn(entry, player.UserId, slotIndex, item)
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

	showroomsFolder = game.Workspace:FindFirstChild(SHOWROOMS_FOLDER_NAME)
	if not showroomsFolder then
		showroomsFolder = Instance.new("Folder")
		showroomsFolder.Name = SHOWROOMS_FOLDER_NAME
		showroomsFolder.Parent = game.Workspace
	end

	-- Legacy cleanup: clones supersede the old shared folder entirely.
	local legacy = game.Workspace:FindFirstChild("SA_Displays")
	if legacy then
		legacy:Destroy()
	end

	if MapHandles and MapHandles.ShowroomTemplate then
		hideTemplate(MapHandles.ShowroomTemplate)
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
	return MapHandles ~= nil and MapHandles.ShowroomTemplate ~= nil
end

-- Assign an OWNED item to one of the CALLER's slots. Touches nothing
-- belonging to any other player. Replaces the caller's own occupant.
function DisplayService.AssignDisplay(player, instanceId, slotIndex)
	if not DisplayService.IsAvailable() then
		return false, "Showroom is not available."
	end
	slotIndex = math.floor(tonumber(slotIndex) or 0)
	if slotIndex < 1 or slotIndex > slotCount() then
		return false, "Invalid slot (1-" .. slotCount() .. ")."
	end
	if typeof(instanceId) ~= "string" or instanceId == "" then
		return false, "Invalid item."
	end
	local item = ownsItem(player, instanceId)
	if not item then
		return false, "You don't own that item."
	end
	local entry = getShowroom(player)
	if not entry or not entry.slots[slotIndex] then
		return false, "That slot does not exist."
	end
	-- One item cannot occupy multiple slots: clear its old slot first.
	local oldSlot = findSlotWithItem(player.UserId, instanceId)
	if oldSlot and oldSlot ~= slotIndex then
		local playerSlots = assignments[player.UserId]
		if playerSlots then
			playerSlots[oldSlot] = nil
		end
		destroyProxy(player.UserId, oldSlot)
	end
	local playerSlots = assignments[player.UserId]
	if not playerSlots then
		playerSlots = {}
		assignments[player.UserId] = playerSlots
	end
	playerSlots[slotIndex] = item
	buildProxy(player, slotIndex, item)
	pushDisplayState(player)
	return true, item
end

-- Remove whichever of the CALLER's displays holds this InstanceId.
function DisplayService.RemoveDisplay(player, instanceId)
	local slotIndex = findSlotWithItem(player.UserId, instanceId)
	if not slotIndex then
		return false, "That item is not on display."
	end
	local playerSlots = assignments[player.UserId]
	if playerSlots then
		playerSlots[slotIndex] = nil
	end
	destroyProxy(player.UserId, slotIndex)
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
	destroyProxy(player.UserId, slotIndex)
	pushDisplayState(player)
end

-- Snapshot for UI: the CALLER's per-slot occupant info (server data only).
function DisplayService.GetDisplayState(player)
	local state = { slots = {} }
	local playerSlots = assignments[player.UserId] or {}
	for i = 1, slotCount() do
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

-- Leaving removes ONLY this player's showroom, proxies, plot and records.
function DisplayService.ClearPlayer(player)
	if not player then
		return
	end
	assignments[player.UserId] = nil
	local entry = showrooms[player.UserId]
	showrooms[player.UserId] = nil
	if entry and entry.root and entry.root.Parent ~= nil then
		entry.root:Destroy()
	elseif showroomsFolder then
		local stale = showroomsFolder:FindFirstChild("Player_" .. tostring(player.UserId))
		if stale then
			stale:Destroy()
		end
	end
	local plotIndex = plotByUser[player.UserId]
	plotByUser[player.UserId] = nil
	if plotIndex ~= nil then
		table.insert(freedPlots, plotIndex)
	end
end

return DisplayService
