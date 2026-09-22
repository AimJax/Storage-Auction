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
--     → AuctionArea (Model, optional container)
--         BidCenter (Part marker, REQUIRED — bid-radius center)
--         Mat (Part, optional)
--         Seats (Model, optional) → Chair_i (Model) → Seat + Post + Back
--     → SpawnLocation (optional — engine-owned; warned if absent)
--
-- Rojo does NOT manage Workspace (see default.project.json), so manual
-- Studio edits to this hierarchy are never overwritten by code sync.

local MapBuilder = {}

local MAP_NAME = "StorageAuctionMap"
local UNIT_NAME = "StorageUnit"
local AREA_NAME = "AuctionArea"
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

-- Locate + validate the Studio-authored map. Errors clearly on missing
-- REQUIRED pieces (never silently rebuilds). Returns opaque handles.
function MapBuilder.GetHandles()
	local workspace = game.Workspace
	local map = workspace:WaitForChild(MAP_NAME, 15)
	if not map then
		failMissing({ "Workspace." .. MAP_NAME .. " (run tools/BuildMapOnce.luau once, then Save the place)" })
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

	local unitPath = MAP_NAME .. "." .. UNIT_NAME
	local unit = req(map, UNIT_NAME, unitPath)
	local door = req(unit, "Door", unitPath .. ".Door")
	local barrier = req(unit, "Barrier", unitPath .. ".Barrier")
	local floorPart = req(unit, "Floor", unitPath .. ".Floor")
	local returnPoint = req(unit, "ReturnPoint", unitPath .. ".ReturnPoint")

	local area = map:FindFirstChild(AREA_NAME)
	local bidCenter = req(area, "BidCenter", MAP_NAME .. "." .. AREA_NAME .. ".BidCenter")

	-- Containers: discover every Container_* part (freely repositionable).
	local containers = {}
	if unit then
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
	end
	local containerCount = 0
	for _ in pairs(containers) do
		containerCount += 1
	end
	if containerCount == 0 then
		table.insert(missing, unitPath .. ".Container_1 (at least one Container_* part)")
	end

	if #missing > 0 then
		failMissing(missing)
	end

	-- Type-check the required instances (a Model renamed to Door helps nobody).
	local typeErrors = {}
	if not door:IsA("BasePart") then
		table.insert(typeErrors, unitPath .. ".Door must be a Part")
	end
	if not barrier:IsA("BasePart") then
		table.insert(typeErrors, unitPath .. ".Barrier must be a Part")
	end
	if not floorPart:IsA("BasePart") then
		table.insert(typeErrors, unitPath .. ".Floor must be a Part")
	end
	if not bidCenter:IsA("BasePart") then
		table.insert(typeErrors, MAP_NAME .. "." .. AREA_NAME .. ".BidCenter must be a Part")
	end
	if not returnPoint:IsA("BasePart") then
		table.insert(typeErrors, unitPath .. ".ReturnPoint must be a Part")
	end
	if #typeErrors > 0 then
		failMissing(typeErrors)
	end

	-- Optional pieces: use when present, ignore when absent.
	local unitBounds = unit:FindFirstChild("UnitBounds")
	if unitBounds and not unitBounds:IsA("BasePart") then
		unitBounds = nil
	end
	if map:FindFirstChild("SpawnLocation") == nil
		and workspace:FindFirstChildOfClass("SpawnLocation") == nil
	then
		warn("[SA] No SpawnLocation found; players may spawn at the origin. Add one under " .. MAP_NAME .. ".")
	end

	-- Runtime stealth for markers + prompt setup (state itself comes later).
	stealthMarker(unitBounds)
	stealthMarker(bidCenter)
	stealthMarker(returnPoint)
	local index = 0
	for _, box in pairs(containers) do
		index += 1
		standardPrompt(box, index)
	end

	local floorTop = floorPart.Position.Y + floorPart.Size.Y / 2
	local center: Vector3
	local boundHalf: Vector3
	if unitBounds then
		center = unitBounds.Position
		boundHalf = unitBounds.Size / 2
	else
		local cf, size = unit:GetBoundingBox()
		center = cf.Position
		boundHalf = size / 2
	end

	return {
		Map = map,
		Unit = unit,
		Door = door,
		Barrier = barrier,
		Containers = containers,
		UnitCenter = Vector3.new(center.X, floorTop, center.Z),
		BoundHalf = boundHalf,
		FloorTop = floorTop,
		BidCenter = bidCenter.Position,
		ReturnCFrame = returnPoint.CFrame,
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
	if handles and handles.Barrier and handles.Barrier.Parent ~= nil then
		handles.Barrier.CanCollide = blocked
	end
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
