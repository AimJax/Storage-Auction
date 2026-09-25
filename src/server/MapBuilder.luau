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
--     → StorageUnit (Model)
--         Floor, LeftWall, RightWall, BackWall, Roof ( Parts, optional decor)
--         Door (Part, REQUIRED — visibility/collision driven)
--         Barrier (Part, REQUIRED — collision driven)
--         Sign (Part + SurfaceGui, optional)
--         Container_1..N (Parts, REQUIRED ≥1 — ContainerId attr, prompts)
--         UnitBounds (Part marker, optional — falls back to unit extents)
--         ReturnPoint (Part marker, REQUIRED — safety-eject destination)
--     → StorageUnit2 (Model)
--         Same required structure as StorageUnit, validated identically
--         (see getUnitHandles). ContainerIds must be unique across units
--         (box_4+), so pregenerated loot never collides.
--     → StorageUnit3 (Model)
--         Same required structure as StorageUnit (ContainerIds box_7+).
--     → AuctionArea (Model, optional container)
--         BidCenter (Part marker, REQUIRED — bid-radius center for Unit 1)
--         Mat (Part, optional)
--         Seats (Model, optional) → Chair_i (Model) → Seat + Post + Back
--     → AuctionArea2 (Model, optional container)
--         BidCenter (Part marker, REQUIRED — bid-radius center for Unit 2)
--         ... same optional structure as AuctionArea, translated near Unit 2.
--     → AuctionArea3 (Model, optional container)
--         BidCenter (Part marker, REQUIRED — bid-radius center for Unit 3)
--         ... same optional structure as AuctionArea, translated near Unit 3.
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
-- Physical auction units: faithful duplicates at nearby offsets. All units
-- are REQUIRED; a stale place missing one fails clearly (re-sync the map
-- from the filesystem with Argon SERVER priority, then Play again).
local UNIT2_NAME = "StorageUnit2"
local AREA2_NAME = "AuctionArea2"
local UNIT3_NAME = "StorageUnit3"
local AREA3_NAME = "AuctionArea3"
local SEATS_NAME = "Seats"

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

-- Per-unit discovery + validation + runtime stealth. Shared by every
-- physical auction unit so all units behave identically.
-- Appends to the caller's shared `missing` list (reported once afterwards).
-- Returns the per-unit handles table consumed by ALL behavior functions
-- below, or nil when required pieces are absent (caller fails clearly).
local function getUnitHandles(map, unitName, areaName, req, missing)
	local unitPath = MAP_NAME .. "." .. unitName
	local areaPath = MAP_NAME .. "." .. areaName
	local unit = req(map, unitName, unitPath)
	local door = req(unit, "Door", unitPath .. ".Door")
	local barrier = req(unit, "Barrier", unitPath .. ".Barrier")
	local floorPart = req(unit, "Floor", unitPath .. ".Floor")
	local returnPoint = req(unit, "ReturnPoint", unitPath .. ".ReturnPoint")

	local area = map:FindFirstChild(areaName)
	local bidCenter = req(area, "BidCenter", areaPath .. ".BidCenter")

	-- Containers: discover every Container_* part (freely repositionable).
	-- Duplicate ContainerIds fail loudly instead of silently overwriting a box.
	local containers = {}
	if unit then
		local parts = {}
		for _, child in ipairs(unit:GetChildren()) do
			if child:IsA("BasePart") and string.match(child.Name, "^Container_") then
				table.insert(parts, child)
			end
		end
		table.sort(parts, function(a, b) return a.Name < b.Name end)
		for _, child in ipairs(parts) do
			local id = child:GetAttribute("ContainerId")
			if typeof(id) ~= "string" or id == "" then
				id = child.Name
				child:SetAttribute("ContainerId", id)
			end
			if containers[id] ~= nil then
				table.insert(missing, unitPath .. "." .. child.Name
					.. " reuses ContainerId '" .. id .. "' (ids must be unique per unit)")
			else
				containers[id] = child
			end
		end
	end
	local containerCount = 0
	for _ in pairs(containers) do
		containerCount += 1
	end
	if containerCount == 0 then
		table.insert(missing, unitPath .. ".Container_1 (at least one Container_* part)")
	end

	-- Type-check the required instances (a Model renamed to Door helps
	-- nobody). Only check what was found; absences are already listed.
	if door and not door:IsA("BasePart") then
		table.insert(missing, unitPath .. ".Door must be a Part")
		door = nil
	end
	if barrier and not barrier:IsA("BasePart") then
		table.insert(missing, unitPath .. ".Barrier must be a Part")
		barrier = nil
	end
	if floorPart and not floorPart:IsA("BasePart") then
		table.insert(missing, unitPath .. ".Floor must be a Part")
		floorPart = nil
	end
	if bidCenter and not bidCenter:IsA("BasePart") then
		table.insert(missing, areaPath .. ".BidCenter must be a Part")
		bidCenter = nil
	end
	if returnPoint and not returnPoint:IsA("BasePart") then
		table.insert(missing, unitPath .. ".ReturnPoint must be a Part")
		returnPoint = nil
	end
	if door == nil or barrier == nil or floorPart == nil
		or bidCenter == nil or returnPoint == nil or containerCount == 0
	then
		return nil -- caller reports `missing`; never half-build a unit
	end

	-- Optional pieces: use when present, ignore when absent.
	local unitBounds = unit:FindFirstChild("UnitBounds")
	if unitBounds and not unitBounds:IsA("BasePart") then
		unitBounds = nil
	end

	-- Runtime stealth for markers + prompt setup (state itself comes later).
	stealthMarker(unitBounds)
	stealthMarker(bidCenter)
	stealthMarker(returnPoint)
	-- The barrier must start invisible even before the first state reset.
	-- (Collision itself is driven by SetBarrier during state transitions.)
	barrier.Transparency = 1
	barrier.CanTouch = false
	barrier.CanQuery = false
	local index = 0
	-- Deterministic order (sorted by part name): prompt ObjectText numbering
	-- must not depend on pairs() iteration order.
	local promptBoxes = {}
	for _, box in pairs(containers) do
		table.insert(promptBoxes, box)
	end
	table.sort(promptBoxes, function(a, b) return a.Name < b.Name end)
	for _, box in ipairs(promptBoxes) do
		index += 1
		standardPrompt(box, index)
	end

	local floorTop = floorPart.Position.Y + floorPart.Size.Y / 2
	local center: Vector3
	local boundHalf: Vector3
	local boundCFrame: CFrame? = nil
	if unitBounds then
		-- Preserve orientation: rotated bounds test in object-local space so
		-- a yawed marker keeps its true footprint (unrotated units behave
		-- exactly as before).
		boundCFrame = unitBounds.CFrame
		center = unitBounds.Position
		boundHalf = unitBounds.Size / 2
	else
		local cf, size = unit:GetBoundingBox()
		boundCFrame = cf
		center = cf.Position
		boundHalf = size / 2
	end
	local unitCenter = Vector3.new(center.X, floorTop, center.Z)

	-- Spatial sanity: every gameplay marker must sit near its own unit.
	-- Catches copy/paste offset mistakes (e.g. a BidCenter left at Unit 1).
	local function checkNearby(label, pos)
		local dx = pos.X - unitCenter.X
		local dz = pos.Z - unitCenter.Z
		if dx * dx + dz * dz > 50 * 50 then
			warn(string.format("[SA] %s.%s is %.0f studs from its unit center — check the map offset.",
				unitName, label, math.sqrt(dx * dx + dz * dz)))
		end
	end
	checkNearby("Door", door.Position)
	checkNearby("Barrier", barrier.Position)
	checkNearby("BidCenter", bidCenter.Position)
	checkNearby("ReturnPoint", returnPoint.Position)
	for id, box in pairs(containers) do
		checkNearby("Container " .. tostring(id), box.Position)
	end

	return {
		UnitName = unitName,
		Unit = unit,
		Door = door,
		Barrier = barrier,
		Containers = containers,
		UnitCenter = unitCenter,
		BoundHalf = boundHalf,
		BoundCFrame = boundCFrame, -- object-space inside test (rotation-safe)
		FloorTop = floorTop,
		BidCenter = bidCenter.Position,
		ReturnCFrame = returnPoint.CFrame,
	}
end

-- Locate + validate the Studio-authored map. Errors clearly on missing
-- REQUIRED pieces (never silently rebuilds). Returns map-level handles plus
-- the per-unit tables AuctionService rotates between:
--   { Map, WarehouseTemplate, Units = { [1], [2] } }
function MapBuilder.GetHandles()
	local workspace = game.Workspace
	local map = workspace:WaitForChild(MAP_NAME, 15)
	if not map then
		failMissing({ "Workspace." .. MAP_NAME .. " (run tools/BuildMapOnce.luau once, then Save the place)" })
	end

	-- LEGACY MIGRATION ONLY: destroy a stale PlayerShowroom left in old
	-- places (Argon keepUnknowns can preserve it). Exact name match; never
	-- touches WarehouseDistrict, WarehouseTemplate, StorageUnit(2), AuctionArea(2).
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

	-- Every physical unit validates through the same builder: identical
	-- structure, identical behavior. Absences accumulate in `missing`.
	-- Generic table: adding a unit is one line, no special cases.
	local unitDefs = {
		{ UNIT_NAME, AREA_NAME },
		{ UNIT2_NAME, AREA2_NAME },
		{ UNIT3_NAME, AREA3_NAME },
	}
	local units = {}
	for i, def in ipairs(unitDefs) do
		units[i] = getUnitHandles(map, def[1], def[2], req, missing)
	end

	if #missing > 0 then
		failMissing(missing)
	end
	for i, _ in ipairs(unitDefs) do
		if units[i] == nil then
			failMissing({ MAP_NAME .. ".StorageUnit + StorageUnit2 + StorageUnit3 (all auction units are required)" })
		end
	end

	-- Optional pieces: use when present, ignore when absent.
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

	-- ATM (optional): single "ATM" Model with a ProximityPrompt. Absence only
	-- disables loans/recovery UI; auctions and sales run on.
	local atm = map:FindFirstChild("ATM")
	if atm and not atm:IsA("Model") then
		atm = nil
	end
	if atm == nil then
		warn("[SA] No ATM in map; loans/recovery disabled until the map provides one.")
	end

	return {
		Map = map,
		WarehouseTemplate = warehouseTemplate, -- Model or nil
		ATM = atm, -- Model or nil
		-- Per-unit handles; AuctionService runs one session per unit.
		Units = units, -- [1] StorageUnit, [2] StorageUnit2, [3] StorageUnit3
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

-- Authoritative container range: player root must be within the box's own
-- ProximityPrompt.MaxActivationDistance (+2 stud tolerance) in 3D. The
-- physical prompt path and the OpenContainer remote share this gate, so a
-- remote invocation from across the map rejects while prompt use is unchanged.
function MapBuilder.IsWithinContainerRange(handles, player, containerId)
	if not handles or not handles.Containers or not player then
		return false
	end
	local box = handles.Containers[containerId]
	if not box then
		return false
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local prompt = box:FindFirstChildOfClass("ProximityPrompt")
	local maxDist = 10
	if prompt then
		maxDist = tonumber(prompt.MaxActivationDistance) or 10
	end
	maxDist += 2
	local delta = root.Position - box.Position
	return delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z <= maxDist * maxDist
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
-- Object-local test: rotated markers keep their true footprint. Unrotated
-- markers behave exactly as the old axis-aligned test.
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
	if handles.BoundCFrame then
		local localPos = handles.BoundCFrame:Inverse() * pos
		return math.abs(localPos.X) <= half.X
			and math.abs(localPos.Z) <= half.Z
			and pos.Y >= handles.FloorTop - 3
			and pos.Y <= handles.FloorTop + half.Y * 2 + 3
	end
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
