--!nonstrict
-- StorageAuction M1 — builds the physical prototype map at runtime.
-- Creates 1 storage unit + N containers + spawn, so no manual Studio
-- building is required. Returns handles the AuctionService drives.
--
-- Ground rule: exactly ONE exterior ground surface (the world's Baseplate).
-- The unit has its own interior floor slab whose top sits FLOOR_RISE studs
-- above the exterior ground — a real vertical separation, so no Z-fighting.
-- All Y positions derive from the detected ground top; nothing hard-codes
-- absolute heights except the unit's XZ location.
--
-- Door rule (M1 simple): the door only appears/disappears. No swing, no
-- animation. Closed = visible + colliding. Open = invisible + non-colliding.
--
-- Access philosophy: players walk freely. Nobody is routinely teleported;
-- MovePlayerOutsideIfInside is a safety fallback used only right before the
-- unit closes for the next auction.
--
-- Layout (studs): unit centered at (0, *, 40), opening faces -Z (spawn side).

local MapBuilder = {}

local UNIT_CX, UNIT_CZ = 0, 40
local UNIT_W, UNIT_H, UNIT_D = 24, 12, 18
local WALL_T = 1
local FLOOR_RISE = 0.2 -- interior floor top above exterior ground (no coplanar faces)
local RETURN_OFFSET_FRONT = 7

local containerColors = {
	Color3.fromRGB(170, 120, 70),
	Color3.fromRGB(100, 140, 180),
	Color3.fromRGB(140, 110, 160),
}

local function makePart(props, parent)
	local p = Instance.new("Part")
	p.Anchored = true
	for k, v in pairs(props) do
		p[k] = v
	end
	p.Parent = parent
	return p
end

-- Returns the Y of the existing ground surface under the unit, or nil.
local function detectGroundTop()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local legacy = game.Workspace:FindFirstChild("SA_Baseplate")
	if legacy then
		params.FilterDescendantsInstances = { legacy }
	end
	local origin = Vector3.new(UNIT_CX, 200, UNIT_CZ)
	local result = game.Workspace:Raycast(origin, Vector3.new(0, -600, 0), params)
	if result then
		return result.Position.Y
	end
	return nil
end

local function ensureGround()
	local workspace = game.Workspace
	local legacy = workspace:FindFirstChild("SA_Baseplate")
	local groundTop = detectGroundTop()
	if groundTop ~= nil then
		-- Real ground exists: remove our legacy plane so surfaces never overlap.
		if legacy then
			legacy:Destroy()
		end
		return groundTop
	end
	if legacy and legacy:IsA("BasePart") then
		-- No other ground, but our plane from an earlier run exists: reuse it.
		return legacy.Position.Y + legacy.Size.Y / 2
	end
	-- No ground at all: create exactly one clean plane, top at y = 0.
	local ground = makePart({
		Name = "SA_Baseplate",
		Size = Vector3.new(256, 2, 256),
		Position = Vector3.new(0, -1, 20),
		Color = Color3.fromRGB(80, 120, 80),
		Material = Enum.Material.Grass,
	}, workspace)
	ground.Locked = true
	return 0
end

local function ensureSpawn(groundTop)
	local workspace = game.Workspace
	local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
	if spawn then
		-- Keep the place's spawn, but make sure it rests on the ground.
		spawn.Position = Vector3.new(spawn.Position.X, groundTop + 3, spawn.Position.Z)
		return spawn
	end
	spawn = Instance.new("SpawnLocation")
	spawn.Anchored = true
	spawn.Size = Vector3.new(6, 1, 6)
	spawn.Position = Vector3.new(0, groundTop + 3, -6)
	spawn.Neutral = true
	spawn.AllowTeamChangeOnTouch = false
	spawn.Duration = 0
	spawn.Parent = workspace
	return spawn
end

function MapBuilder.Build(numContainers)
	local workspace = game.Workspace

	-- Remove previous unit BEFORE ground detection so its roof/walls can
	-- never be mistaken for the ground surface by the raycast.
	local old = workspace:FindFirstChild("SA_Unit")
	if old then
		old:Destroy()
	end

	local groundTop = ensureGround()
	ensureSpawn(groundTop)

	local unit = Instance.new("Model")
	unit.Name = "SA_Unit"

	local cx, cz = UNIT_CX, UNIT_CZ
	local floorTop = groundTop + FLOOR_RISE -- interior walking surface
	local frontZ = cz - UNIT_D / 2
	local backZ = cz + UNIT_D / 2
	local roofTop = floorTop + UNIT_H + WALL_T

	-- Interior floor slab: top face FLOOR_RISE above exterior ground.
	makePart({
		Name = "Floor",
		Size = Vector3.new(UNIT_W, WALL_T, UNIT_D),
		Position = Vector3.new(cx, floorTop - WALL_T / 2, cz),
		Color = Color3.fromRGB(120, 120, 120),
		Material = Enum.Material.Concrete,
	}, unit)

	-- Walls stand ON the interior floor (no gaps underneath), outer faces
	-- flush with the slab edges.
	makePart({
		Name = "BackWall",
		Size = Vector3.new(UNIT_W, UNIT_H, WALL_T),
		Position = Vector3.new(cx, floorTop + UNIT_H / 2, backZ - WALL_T / 2),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	makePart({
		Name = "LeftWall",
		Size = Vector3.new(WALL_T, UNIT_H, UNIT_D),
		Position = Vector3.new(cx - UNIT_W / 2 + WALL_T / 2, floorTop + UNIT_H / 2, cz),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	makePart({
		Name = "RightWall",
		Size = Vector3.new(WALL_T, UNIT_H, UNIT_D),
		Position = Vector3.new(cx + UNIT_W / 2 - WALL_T / 2, floorTop + UNIT_H / 2, cz),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	-- Roof rests on the walls, flush footprint.
	makePart({
		Name = "Roof",
		Size = Vector3.new(UNIT_W, WALL_T, UNIT_D),
		Position = Vector3.new(cx, floorTop + UNIT_H + WALL_T / 2, cz),
		Color = Color3.fromRGB(80, 80, 85),
		Material = Enum.Material.Metal,
	}, unit)

	-- Front door: fills the opening. Only shown/hidden, never animated.
	-- (A proper rolling shutter can replace this later.)
	local door = makePart({
		Name = "Door",
		Size = Vector3.new(UNIT_W - 2 * WALL_T, UNIT_H, 0.6),
		Position = Vector3.new(cx, floorTop + UNIT_H / 2, frontZ),
		Color = Color3.fromRGB(180, 180, 190),
		Material = Enum.Material.Metal,
	}, unit)
	door:SetAttribute("IsDoor", true)

	-- Invisible barrier used ONLY while players must look but not enter
	-- (Inspection/Bidding). Never active during Rummaging.
	local barrier = makePart({
		Name = "Barrier",
		Size = Vector3.new(UNIT_W - 2 * WALL_T, UNIT_H, 0.5),
		Position = Vector3.new(cx, floorTop + UNIT_H / 2, frontZ),
		Transparency = 1,
		CanCollide = true,
		CanQuery = false,
	}, unit)

	-- Physical sign board sitting on the roof, front edge. World-space
	-- SurfaceGui on the -Z face: obeys the world, never renders through
	-- geometry, never fights the screen-space HUD.
	local sign = makePart({
		Name = "Sign",
		Size = Vector3.new(18, 2.5, 0.6),
		Position = Vector3.new(cx, roofTop + 1.3, frontZ),
		Color = Color3.fromRGB(40, 40, 45),
	}, unit)
	do
		local surface = Instance.new("SurfaceGui")
		surface.Face = Enum.NormalId.Back -- -Z: faces approaching players
		surface.CanvasSize = Vector2.new(600, 84)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
		label.BorderSizePixel = 0
		label.Text = "STORAGE — UNIT 1"
		label.TextScaled = true
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.GothamBold
		label.Parent = surface
		surface.Parent = sign
	end

	-- Containers: centered row toward the back, clearly visible from the front.
	local containers = {}
	for i = 1, (numContainers or 3) do
		local xOff = (i - 2) * 6 -- -6, 0, +6
		local box = makePart({
			Name = "Container_" .. i,
			Size = Vector3.new(4, 4, 4),
			Position = Vector3.new(cx + xOff, floorTop + 2, cz + 2),
			Color = containerColors[((i - 1) % #containerColors) + 1],
			Material = Enum.Material.WoodPlanks,
		}, unit)
		box:SetAttribute("ContainerId", "box_" .. i)
		box:SetAttribute("Opened", false)

		local prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = "Storage Box " .. i
		prompt.ActionText = "Open"
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Enabled = false
		prompt.Parent = box

		containers["box_" .. i] = box
	end

	-- Safe return spot: several studs in front of the door, facing the unit.
	-- Used ONLY as a safety fallback, never during normal play.
	local outsidePos = Vector3.new(cx, floorTop + 4, frontZ - RETURN_OFFSET_FRONT)
	local outsideFace = Vector3.new(cx, floorTop + 2, frontZ)

	unit.Parent = workspace

	return {
		Unit = unit,
		Door = door,
		Barrier = barrier,
		Containers = containers,
		UnitCenter = Vector3.new(cx, floorTop, cz),
		FloorTop = floorTop,
		RoofTop = roofTop,
		FrontZ = frontZ,
		ReturnCFrame = CFrame.lookAt(outsidePos, outsideFace),
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

-- True when the player's character root is physically inside the unit volume
-- (with a small vertical tolerance). False for missing characters — safe.
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
	return math.abs(pos.X - center.X) <= UNIT_W / 2
		and math.abs(pos.Z - center.Z) <= UNIT_D / 2
		and pos.Y >= handles.FloorTop - 3
		and pos.Y <= handles.RoofTop + 3
end

-- Safety fallback only: moves the player outside if (and only if) they are
-- still inside when the unit must close. Never touches players outside.
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
