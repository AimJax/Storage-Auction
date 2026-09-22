--!nonstrict
-- StorageAuction M1 — builds the physical prototype map at runtime.
-- Creates 1 storage unit + N containers + spawn, so no manual Studio
-- building is required. Returns handles the AuctionService drives.
--
-- Ground rule: exactly ONE ground surface. If the place already has a
-- Baseplate (or any ground under the unit), we reuse it. Our legacy
-- SA_Baseplate is removed when real ground exists, and only created when
-- the place has no ground at all (e.g. empty Rojo-built place).
--
-- Layout (studs, Y relative to detected ground top):
--   Unit centered at (0, *, 40), opening faces -Z (toward spawn).
--   WinnerReturnPosition sits ~7 studs in front of the door, facing the unit.

local MapBuilder = {}

local UNIT_CX, UNIT_CZ = 0, 40
local UNIT_W, UNIT_H, UNIT_D = 24, 12, 18
local WALL_T = 1
local DOOR_W, DOOR_H, DOOR_T = 22, 10, 0.6
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
	local gy = groundTop -- shorthand: ground surface Y
	local frontZ = cz - UNIT_D / 2
	local backZ = cz + UNIT_D / 2

	-- Floor slab: top face flush with the ground (no step, no overlap).
	makePart({
		Name = "Floor",
		Size = Vector3.new(UNIT_W, WALL_T, UNIT_D),
		Position = Vector3.new(cx, gy - WALL_T / 2, cz),
		Color = Color3.fromRGB(120, 120, 120),
		Material = Enum.Material.Concrete,
	}, unit)

	-- Walls sit ON the floor (bottoms at gy), outer faces flush with slab edges.
	makePart({
		Name = "BackWall",
		Size = Vector3.new(UNIT_W, UNIT_H, WALL_T),
		Position = Vector3.new(cx, gy + UNIT_H / 2, backZ - WALL_T / 2),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	makePart({
		Name = "LeftWall",
		Size = Vector3.new(WALL_T, UNIT_H, UNIT_D),
		Position = Vector3.new(cx - UNIT_W / 2 + WALL_T / 2, gy + UNIT_H / 2, cz),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	makePart({
		Name = "RightWall",
		Size = Vector3.new(WALL_T, UNIT_H, UNIT_D),
		Position = Vector3.new(cx + UNIT_W / 2 - WALL_T / 2, gy + UNIT_H / 2, cz),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	-- Roof rests on the walls (bottom at gy + H), flush footprint.
	makePart({
		Name = "Roof",
		Size = Vector3.new(UNIT_W, WALL_T, UNIT_D),
		Position = Vector3.new(cx, gy + UNIT_H + WALL_T / 2, cz),
		Color = Color3.fromRGB(80, 80, 85),
		Material = Enum.Material.Metal,
	}, unit)

	-- Lintel / sign board above the front opening (opening height = H - 2).
	local lintel = makePart({
		Name = "SignBoard",
		Size = Vector3.new(UNIT_W, 2, WALL_T),
		Position = Vector3.new(cx, gy + UNIT_H - 1, frontZ),
		Color = Color3.fromRGB(40, 40, 45),
	}, unit)
	do
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(400, 60)
		gui.AlwaysOnTop = false
		gui.MaxDistance = 120
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = "STORAGE AUCTION — UNIT 1"
		label.TextScaled = true
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.GothamBold
		label.Parent = gui
		gui.Parent = lintel
	end

	-- Swing door on a left-edge hinge. Closed: fills the opening below the
	-- lintel. Open: rotated ~100 degrees outward toward approaching players.
	local doorClosedPos = Vector3.new(cx, gy + DOOR_H / 2, frontZ)
	local door = makePart({
		Name = "Door",
		Size = Vector3.new(DOOR_W, DOOR_H, DOOR_T),
		Position = doorClosedPos,
		Color = Color3.fromRGB(180, 180, 190),
		Material = Enum.Material.Metal,
	}, unit)
	door:SetAttribute("IsDoor", true)
	local hingePos = Vector3.new(cx - DOOR_W / 2, gy + DOOR_H / 2, frontZ)
	local doorOffset = Vector3.new(DOOR_W / 2, 0, 0) -- hinge -> door center
	door:SetAttribute("DoorOpen", false)

	-- Invisible barrier in the opening: blocks entry while the door is open.
	local barrier = makePart({
		Name = "Barrier",
		Size = Vector3.new(DOOR_W, DOOR_H, 0.5),
		Position = doorClosedPos,
		Transparency = 1,
		CanCollide = true,
		CanQuery = false,
	}, unit)

	-- Containers: centered row toward the back, clearly visible from the front.
	local containers = {}
	for i = 1, (numContainers or 3) do
		local xOff = (i - 2) * 6 -- -6, 0, +6
		local box = makePart({
			Name = "Container_" .. i,
			Size = Vector3.new(4, 4, 4),
			Position = Vector3.new(cx + xOff, gy + 2, cz + 2),
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

	-- Winner spots. Inside: clear of boxes/walls, facing the boxes.
	-- Outside: several studs in front of the door, facing the unit.
	local insidePos = Vector3.new(cx, gy + 4, frontZ + 4)
	local insideFace = Vector3.new(cx, gy + 4, cz + 2)
	local outsidePos = Vector3.new(cx, gy + 4, frontZ - RETURN_OFFSET_FRONT)
	local outsideFace = Vector3.new(cx, gy + 3, frontZ)

	unit.Parent = workspace

	return {
		Unit = unit,
		Door = door,
		DoorHinge = hingePos,
		DoorOffset = doorOffset,
		DoorAnimToken = 0,
		Barrier = barrier,
		Containers = containers,
		UnitCenter = Vector3.new(cx, gy, cz),
		WinnerInsideCFrame = CFrame.lookAt(insidePos, insideFace),
		WinnerReturnCFrame = CFrame.lookAt(outsidePos, outsideFace),
	}
end

-- Swing-door animation. Runs a short lerp; newer calls cancel older ones.
local function animateDoor(handles, open)
	local door = handles and handles.Door
	if not door or door.Parent == nil then
		return
	end
	handles.DoorAnimToken += 1
	local token = handles.DoorAnimToken
	local hingeCF = CFrame.new(handles.DoorHinge)
	local fromOpen = door:GetAttribute("DoorOpen") == true
	door:SetAttribute("DoorOpen", open)
	if open then
		door.CanCollide = false -- never block players while swinging
	end
	task.spawn(function()
		local steps = 18
		local from = if fromOpen then math.rad(100) else 0
		local to = if open then math.rad(100) else 0
		for i = 1, steps do
			if token ~= handles.DoorAnimToken then
				return -- superseded
			end
			local t = i / steps
			local angle = from + (to - from) * t
			if door.Parent ~= nil then
				door.CFrame = hingeCF * CFrame.Angles(0, angle, 0) * CFrame.new(handles.DoorOffset)
			end
			task.wait(0.035)
		end
		if door.Parent ~= nil then
			door.CanCollide = not open
		end
	end)
end

function MapBuilder.SetDoorOpen(handles, open)
	if not handles or not handles.Door then
		return
	end
	if (handles.Door:GetAttribute("DoorOpen") == true) == (open == true) then
		-- Already in the requested state; still enforce collision flags.
		handles.Door.CanCollide = not open
		return
	end
	animateDoor(handles, open == true)
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

-- Teleports any player to a CFrame with full nil-safety. Returns true if the
-- character's root was moved. Never errors on missing/dead characters.
local function teleportPlayerTo(player, cf)
	if not player then
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
	pcall(function()
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end)
	root.CFrame = cf
	return true
end

function MapBuilder.TeleportWinnerInside(handles, player)
	if not handles or not handles.WinnerInsideCFrame then
		return false
	end
	return teleportPlayerTo(player, handles.WinnerInsideCFrame)
end

-- Safe return spot in front of the unit. Safe to call when the winner left,
-- died, or has no character: it simply does nothing and returns false.
function MapBuilder.TeleportPlayerOutside(handles, player)
	if not handles or not handles.WinnerReturnCFrame then
		return false
	end
	return teleportPlayerTo(player, handles.WinnerReturnCFrame)
end

return MapBuilder
