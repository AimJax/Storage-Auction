--!nonstrict
-- StorageAuction MVP — runtime player warehouses.
--
-- Clones the ONE Studio-authored WarehouseTemplate into the player's
-- assigned plot at runtime. Placement derives from the plot's
-- WarehouseOrigin marker (position AND yaw); no world-space assumptions.
-- Template stays hidden/non-interactive during Play; clones are per-player
-- under Workspace/SA_PlayerWarehouses (outside the Argon-managed map).
--
-- Warehouse record shape (future-persistent; plot index never saved):
--   { root, slots, level = 1, unlockedSlots, upgrades = {} }

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local WarehouseService = {}

local MapHandles = nil

-- [UserId] = { root = Model, slots = { [i] = Part }, level, unlockedSlots, upgrades }
local warehouses = {}
local folder = nil

local FOLDER_NAME = "SA_PlayerWarehouses"

-- Template visuals, recorded before hiding so clones restore them.
-- Keyed by stable relative instance path ("DisplaySlots/Slot_1#1"), so
-- future template hierarchy edits can only SKIP non-matching descendants,
-- never apply values to the wrong one. Class is re-checked on apply.
local templateVisuals = {}

-- Path of desc relative to root, with same-named siblings disambiguated
-- by occurrence index (Roblox allows duplicate sibling names).
local function relativePath(root, desc)
	local segments = {}
	local current = desc
	while current and current ~= root do
		local parent = current.Parent
		local occurrence = 1
		if parent then
			local count = 0
			for _, sibling in ipairs(parent:GetChildren()) do
				if sibling.Name == current.Name then
					count += 1
					if sibling == current then
						occurrence = count
					end
				end
			end
			if count < 2 then
				occurrence = 0 -- unique name: no suffix needed
			end
		end
		if occurrence > 0 then
			table.insert(segments, 1, current.Name .. "#" .. occurrence)
		else
			table.insert(segments, 1, current.Name)
		end
		current = parent
	end
	return table.concat(segments, "/")
end

local function recordVisuals(template)
	templateVisuals = {}
	for _, desc in ipairs(template:GetDescendants()) do
		local key = relativePath(template, desc)
		if desc:IsA("BasePart") then
			templateVisuals[key] = {
				class = "Part",
				transparency = desc.Transparency,
				collide = desc.CanCollide,
				touch = desc.CanTouch,
				query = desc.CanQuery,
			}
		elseif desc:IsA("SurfaceGui") or desc:IsA("BillboardGui") then
			templateVisuals[key] = { class = "Gui", guiEnabled = desc.Enabled }
		end
	end
end

local function restoreVisuals(clone)
	for _, desc in ipairs(clone:GetDescendants()) do
		local recorded = templateVisuals[relativePath(clone, desc)]
		if not recorded then
			continue -- new/renamed part: leave authored clone values alone
		end
		if desc:IsA("BasePart") and recorded.class == "Part" then
			desc.Transparency = recorded.transparency
			desc.CanCollide = recorded.collide
			desc.CanTouch = recorded.touch
			desc.CanQuery = recorded.query
		elseif (desc:IsA("SurfaceGui") or desc:IsA("BillboardGui")) and recorded.class == "Gui" then
			desc.Enabled = recorded.guiEnabled
		end
	end
end

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

local function collectSlots(root)
	local slotsFolder = root:FindFirstChild("DisplaySlots")
	local slots = {}
	if slotsFolder then
		for i = 1, GameConfig.DisplaySlotCount do
			local slot = slotsFolder:FindFirstChild("Slot_" .. i)
			if slot and slot:IsA("BasePart") then
				slots[i] = slot
			else
				break
			end
		end
	end
	return slots
end

function WarehouseService.Init(deps)
	MapHandles = deps.MapHandles

	folder = game.Workspace:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = game.Workspace
	end

	local template = MapHandles and MapHandles.WarehouseTemplate
	if template then
		hideTemplate(template)
	else
		warn("[SA] No WarehouseTemplate in map; runtime warehouses disabled (auctions unaffected).")
	end
end

function WarehouseService.IsAvailable()
	return MapHandles ~= nil and MapHandles.WarehouseTemplate ~= nil
end

-- Build (or return existing) runtime warehouse for this player on their plot.
function WarehouseService.BuildFor(player, plot)
	if not player or not plot then
		return nil
	end
	local existing = warehouses[player.UserId]
	if existing and existing.root.Parent ~= nil then
		return existing
	end
	local template = MapHandles and MapHandles.WarehouseTemplate
	if not template or not folder then
		return nil
	end
	local templateFloor = template:FindFirstChild("Floor")
	local floorTopCF = nil
	if templateFloor and templateFloor:IsA("BasePart") then
		floorTopCF = templateFloor.CFrame * CFrame.new(0, templateFloor.Size.Y / 2, 0)
	end
	local clone = template:Clone()
	clone.Name = "Player_" .. tostring(player.UserId)
	clone:SetAttribute("OwnerUserId", player.UserId)
	clone:SetAttribute("PlotIndex", plot.index)
	if floorTopCF then
		-- Rigid transform: template floor-top-center lands on plot origin.
		local place = plot.origin * floorTopCF:Inverse()
		clone:PivotTo(place * clone:GetPivot())
	else
		clone:PivotTo(CFrame.new(plot.originPos))
	end
	clone.Parent = folder
	restoreVisuals(clone)
	-- Ownership is shown ONLY on the plot roadside billboard (PlotService);
	-- warehouses carry no name signage (see ticket: rooftop sign removed).
	local entry = {
		root = clone,
		slots = collectSlots(clone),
		plotIndex = plot.index,
		level = 1,
		unlockedSlots = GameConfig.DisplaySlotCount,
		upgrades = {},
	}
	warehouses[player.UserId] = entry
	return entry
end

function WarehouseService.DestroyFor(player)
	if not player then
		return
	end
	local entry = warehouses[player.UserId]
	warehouses[player.UserId] = nil
	if entry and entry.root and entry.root.Parent ~= nil then
		entry.root:Destroy()
	elseif folder then
		local stale = folder:FindFirstChild("Player_" .. tostring(player.UserId))
		if stale then
			stale:Destroy()
		end
	end
end

function WarehouseService.GetWarehouse(player)
	if not player then
		return nil
	end
	local entry = warehouses[player.UserId]
	if entry and entry.root.Parent ~= nil then
		return entry
	end
	return nil
end

function WarehouseService.GetSlots(player)
	local entry = WarehouseService.GetWarehouse(player)
	if entry then
		return entry.slots
	end
	return nil
end

function WarehouseService.GetWarehouseRoot(player)
	local entry = WarehouseService.GetWarehouse(player)
	if entry then
		return entry.root
	end
	return nil
end

return WarehouseService
