--!nonstrict
-- StorageAuction M1 — map behavior over STUDIO-AUTHORED geometry.
--
-- OWNERSHIP RULE: Studio owns static world geometry. This module owns
-- behavior/state only. It NEVER creates map parts. It locates
--   Workspace.StorageAuctionMap
-- validates the required pieces, and drives door/barrier/prompts/bounds.
--
-- Expected hierarchy (see tools/BuildMapOnce.luau, the one-time migration
-- script that generated the initial layout):
--
--   Workspace
--   → StorageAuctionMap (Model)
--     → StorageUnit / StorageUnit2 / StorageUnit3 (Models, one per tier)
--         TierId attribute: "Budget" | "Standard" | "HighRoller" (REQUIRED)
--         Floor, LeftWall, RightWall, BackWall, Roof ( Parts, optional decor)
--         Door (Part, REQUIRED — visibility/collision driven)
--         Barrier (Part, REQUIRED — collision driven)
--         Sign (Part + SurfaceGui, optional)
--         Container_1..N (Parts, REQUIRED ≥1 — ContainerId attr, prompts)
--         UnitBounds (Part marker, optional — falls back to unit extents)
--         ReturnPoint (Part marker, REQUIRED — safety-eject destination)
--         BidCenter (Part marker, optional — falls back to shared one)
--     → AuctionArea (Model, optional container)
--         BidCenter (Part marker, REQUIRED — bid-radius center)
--         Mat (Part, optional)
--         Seats (Model, optional) → Chair_i (Model) → Seat + Post + Back
--     → SpawnLocation (optional — engine-owned; warned if absent)
--     → WarehouseTemplate (Model, optional — cloned per player at runtime;
--         warned if absent, warehouses/displays degrade gracefully)
--     → WarehouseDistrict (Model, discovered by PlotService itself)
--
-- Rojo does NOT manage Workspace (see default.project.json), so manual
-- Studio edits to this hierarchy are never overwritten by code sync.

local MapBuilder = {}

local MAP_NAME = "StorageAuctionMap"
local UNIT_NAME = "StorageUnit"
local AREA_NAME = "AuctionArea"
local SEATS_NAME = "Seats"

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local function failMissing(list)
	error(
		"[SA] Incomplete StorageAuctionMap — missing: "
			.. table.concat(list, ", ")
			.. ". Restore them in Studio (see tools/BuildMapOnce.luau), then Play again.",
		0
	)
end

-- Defensive fix-ups for marker parts: never visible/colliding in Play.
-- (Edit-time visibility is the user's choice; runtime forces stealth.)
local function stealthMarker(part)
	if not part then
		return
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Transparency = 1
end

local function standardPrompt(box, index)
	local prompt = box:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = "Storage Box " .. tostring(index)
		prompt.ActionText = "Open"
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = box
	end
	prompt.Enabled = false
	return prompt
end

-- Locate + validate the Studio-authored map. Errors clearly on missing
-- REQUIRED pieces (never silently rebuilds). Returns opaque handles.
function MapBuilder.GetHandles()
	local workspace = game.Workspace
	local map = workspace:WaitForChild(MAP_NAME, 15)
	if not map then
		failMissing({ "Workspace." .. MAP_NAME .. " (run tools/BuildMapOnce.luau once, then Save the place)" })
	end

	-- LEGACY MIGRATION ONLY: destroy a stale PlayerShowroom left in old
	-- places (Argon keepUnknowns can preserve it). Exact name match; never
	-- touches WarehouseDistrict, WarehouseTemplate, StorageUnit, AuctionArea.
	local legacyShowroom = map:FindFirstChild("PlayerShowroom")
	if legacyShowroom then
		warn("[SA] Removing legacy PlayerShowroom remnant (superseded by warehouses).")
		legacyShowroom:Destroy()
	end

	local missing = {}
	local function req(parent, name, path)
		if not parent then
			table.insert(missing, path)
			return nil
		end
		local inst = parent:FindFirstChild(name)
		if not inst then
			table.insert(missing, path)
		end
		return inst
	end

	-- Auction units: every direct Model child carrying a TierId attribute
	-- naming a GameConfig tier (e.g. StorageUnit/Budget, StorageUnit2/
	-- Standard, StorageUnit3/HighRoller). Tier identity comes from parts,
	-- never hard-coded coordinates.
	local tierIds = {}
	if GameConfig.AuctionTierOrder then
		for _, id in ipairs(GameConfig.AuctionTierOrder) do
			tierIds[id] = true
		end
	end
	local unitModels = {} -- { { tierId, model } }
	for _, child in ipairs(map:GetChildren()) do
		if child:IsA("Model") then
			local tierId = child:GetAttribute("TierId")
			if typeof(tierId) == "string" and tierIds[tierId] then
				table.insert(unitModels, { tierId = tierId, model = child })
			end
		end
	end
	if #unitModels == 0 then
		failMissing({ MAP_NAME .. ".<StorageUnit> (at least one Model with a TierId attribute)" })
	end

	local area = map:FindFirstChild(AREA_NAME)
	local sharedBidCenter = area and area:FindFirstChild("BidCenter") or nil

	local function buildUnitHandles(unit, unitPath)
		local door = req(unit, "Door", unitPath .. ".Door")
		local barrier = req(unit, "Barrier", unitPath .. ".Barrier")
		local floorPart = req(unit, "Floor", unitPath .. ".Floor")
		local returnPoint = req(unit, "ReturnPoint", unitPath .. ".ReturnPoint")

		-- Per-unit BidCenter if authored, else the shared auction-area one.
		local bidCenter = unit:FindFirstChild("BidCenter")
		if bidCenter and not bidCenter:IsA("BasePart") then
			bidCenter = nil
		end
		if not bidCenter then
			bidCenter = sharedBidCenter
		end
		if not bidCenter then
			table.insert(missing, unitPath .. ".BidCenter (or shared " .. MAP_NAME .. "." .. AREA_NAME .. ".BidCenter)")
		end

		-- Containers: discover every Container_* part (freely repositionable).
		local containers = {}
		for _, child in ipairs(unit:GetChildren()) do
			if child:IsA("BasePart") and string.match(child.Name, "^Container_") then
				local id = child:GetAttribute("ContainerId")
				if typeof(id) ~= "string" or id == "" then
					id = child.Name
					child:SetAttribute("ContainerId", id)
				end
				containers[id] = child
			end
		end
		local containerCount = 0
		for _ in pairs(containers) do
			containerCount += 1
		end
		if containerCount == 0 then
			table.insert(missing, unitPath .. ".Container_1 (at least one Container_* part)")
		end
		return {
			Unit = unit,
			Door = door,
			Barrier = barrier,
			Floor = floorPart,
			ReturnPoint = returnPoint,
			BidCenterPart = bidCenter,
			Containers = containers,
		}
	end

	local units = {} -- [TierId] = per-unit handles
	for _, entry in ipairs(unitModels) do
		units[entry.tierId] = buildUnitHandles(entry.model, MAP_NAME .. "." .. entry.model.Name)
	end

	if #missing > 0 then
		failMissing(missing)
	end

	-- Type-check the required instances (a Model renamed to Door helps nobody).
	local typeErrors = {}
	for tierId, uh in pairs(units) do
		local prefix = MAP_NAME .. ".<?>[" .. tierId .. "]."
		if not uh.Door:IsA("BasePart") then
			table.insert(typeErrors, prefix .. "Door must be a Part")
		end
		if not uh.Barrier:IsA("BasePart") then
			table.insert(typeErrors, prefix .. "Barrier must be a Part")
		end
		if not uh.Floor:IsA("BasePart") then
			table.insert(typeErrors, prefix .. "Floor must be a Part")
		end
		if not uh.BidCenterPart:IsA("BasePart") then
			table.insert(typeErrors, prefix .. "BidCenter must be a Part")
		end
		if not uh.ReturnPoint:IsA("BasePart") then
			table.insert(typeErrors, prefix .. "ReturnPoint must be a Part")
		end
	end
	if #typeErrors > 0 then
		failMissing(typeErrors)
	end

	-- Optional pieces: use when present, ignore when absent.
	for tierId, uh in pairs(units) do
		local unitBounds = uh.Unit:FindFirstChild("UnitBounds")
		if unitBounds and not unitBounds:IsA("BasePart") then
			unitBounds = nil
		end
		uh.UnitBounds = unitBounds

		-- Runtime stealth for markers + prompt setup (state itself comes later).
		stealthMarker(unitBounds)
		stealthMarker(uh.BidCenterPart)
		stealthMarker(uh.ReturnPoint)
		-- The barrier must start invisible even before the first state reset.
		-- (Collision itself is driven by SetBarrier during state transitions.)
		if uh.Barrier then
			uh.Barrier.Transparency = 1
			uh.Barrier.CanTouch = false
			uh.Barrier.CanQuery = false
		end
		local index = 0
		for _, box in pairs(uh.Containers) do
			index += 1
			standardPrompt(box, index)
		end

		local floorTop = uh.Floor.Position.Y + uh.Floor.Size.Y / 2
		local center: Vector3
		local boundHalf: Vector3
		if unitBounds then
			center = unitBounds.Position
			boundHalf = unitBounds.Size / 2
		else
			local cf, size = uh.Unit:GetBoundingBox()
			center = cf.Position
			boundHalf = size / 2
		end
		uh.UnitCenter = Vector3.new(center.X, floorTop, center.Z)
		uh.BoundHalf = boundHalf
		uh.FloorTop = floorTop
		uh.BidCenter = uh.BidCenterPart.Position
		uh.ReturnCFrame = uh.ReturnPoint.CFrame
		-- Spatial sanity: markers must belong to their own unit. A stale
		-- translation-script offset shows up here immediately (warn, not
		-- fatal — the auction still runs on whatever is authored).
		local function xzDistance(a, b)
			local dx, dz = a.X - b.X, a.Z - b.Z
			return math.sqrt(dx * dx + dz * dz)
		end
		do
			local d = xzDistance(uh.UnitCenter, uh.BidCenterPart.Position)
			if d > 50 then
				warn(string.format("[SA] %s BidCenter is %.1f studs from unit center — map marker likely misplaced.",
					uh.Unit.Name, d))
			end
			local rp = uh.ReturnPoint.Position
			local dr = xzDistance(uh.UnitCenter, rp)
			if dr > 50 then
				warn(string.format("[SA] %s ReturnPoint is %.1f studs from unit center — map marker likely misplaced.",
					uh.Unit.Name, dr))
			end
		end
	end
	-- Warehouse template (optional): cloned per player by WarehouseService.
	-- Absence only disables warehouses/displays; the auction loop runs on.
	local warehouseTemplate = map:FindFirstChild("WarehouseTemplate")
	if warehouseTemplate and not warehouseTemplate:IsA("Model") then
		warehouseTemplate = nil
	end
	if warehouseTemplate == nil then
		warn("[SA] No WarehouseTemplate in map; warehouses/displays disabled until the map provides one.")
	end
	if map:FindFirstChild("SpawnLocation") == nil
		and workspace:FindFirstChildOfClass("SpawnLocation") == nil
	then
		warn("[SA] No SpawnLocation found; players may spawn at the origin. Add one under " .. MAP_NAME .. ".")
	end

	return {
		Map = map,
		Units = units, -- [TierId] = per-unit handles (Door/Barrier/Containers/...)
		WarehouseTemplate = warehouseTemplate, -- Model or nil
	}
end

-- M1 door behavior: appear/disappear only.
function MapBuilder.SetDoorOpen(handles, open)
	local door = handles and handles.Door
	if not door or door.Parent == nil then
		return
	end
	if open then
		door.Transparency = 1
		door.CanCollide = false
	else
		door.Transparency = 0
		door.CanCollide = true
	end
end

function MapBuilder.SetBarrier(handles, blocked)
	if not handles or not handles.Barrier or handles.Barrier.Parent == nil then
		return
	end
	-- The barrier is a collision volume ONLY. It must never be visible,
	-- regardless of what the authored map file says (Argon does not even
	-- serialize Transparency for it). Only collision is state-driven.
	handles.Barrier.Transparency = 1
	handles.Barrier.CanTouch = false
	handles.Barrier.CanQuery = false
	handles.Barrier.CanCollide = blocked
end

function MapBuilder.ResetContainers(handles)
	if not handles then
		return
	end
	for _, box in pairs(handles.Containers) do
		box:SetAttribute("Opened", false)
		box.Transparency = 0
		local prompt = box:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Enabled = false
		end
	end
end

function MapBuilder.MarkContainerOpened(handles, containerId)
	if not handles then
		return
	end
	local box = handles.Containers[containerId]
	if not box then
		return
	end
	box:SetAttribute("Opened", true)
	box.Transparency = 0.55
	local prompt = box:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = false
	end
end

function MapBuilder.SetPromptsEnabled(handles, enabled)
	if not handles then
		return
	end
	for _, box in pairs(handles.Containers) do
		if box:GetAttribute("Opened") == true then
			continue -- opened boxes stay shut
		end
		local prompt = box:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Enabled = enabled
		end
	end
end

-- XZ distance check against the physical BidCenter part. Y is ignored so
-- jumping/seating never matters.
function MapBuilder.IsWithinBidRadius(handles, player, radius)
	if not handles or not handles.BidCenter or not player then
		return false
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local dx = root.Position.X - handles.BidCenter.X
	local dz = root.Position.Z - handles.BidCenter.Z
	return (dx * dx + dz * dz) <= radius * radius
end

-- Inside test against the UnitBounds marker (or unit extents fallback),
-- derived from live part positions — move the unit in Studio and this follows.
function MapBuilder.IsPlayerInsideUnit(handles, player)
	if not handles or not player then
		return false
	end
	local char = player.Character
	if not char then
		return false
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local pos = root.Position
	local center = handles.UnitCenter
	local half = handles.BoundHalf
	return math.abs(pos.X - center.X) <= half.X
		and math.abs(pos.Z - center.Z) <= half.Z
		and pos.Y >= handles.FloorTop - 3
		and pos.Y <= handles.FloorTop + half.Y * 2 + 3
end

-- Safety fallback only: moves the player to the physical ReturnPoint part
-- if (and only if) they are still inside when the unit must close.
-- Returns true when a move happened.
function MapBuilder.MovePlayerOutsideIfInside(handles, player)
	if not MapBuilder.IsPlayerInsideUnit(handles, player) then
		return false
	end
	if not handles or not handles.ReturnCFrame then
		return false
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	pcall(function()
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end)
	root.CFrame = handles.ReturnCFrame
	return true
end

return MapBuilder
