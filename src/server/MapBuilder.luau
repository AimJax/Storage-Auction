--!nonstrict
-- StorageAuction M1 — builds the physical prototype map at runtime.
-- Creates 1 storage unit + N containers + spawn, so no manual Studio
-- building is required. Returns handles the AuctionService drives.
--
-- Layout (studs):
--   Spawn at (0, 5, 0). Unit centered at (0, 0, 40), opening faces -Z (spawn).

local MapBuilder = {}

local UNIT_CENTER = Vector3.new(0, 0, 40)
local UNIT_W, UNIT_H, UNIT_D = 24, 12, 18
local WALL_T = 1

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

function MapBuilder.Build(numContainers)
	-- Baseplate + spawn (only if the place doesn't already have them).
	local workspace = game.Workspace
	if not workspace:FindFirstChildOfClass("SpawnLocation") then
		local spawn = Instance.new("SpawnLocation")
		spawn.Anchored = true
		spawn.Size = Vector3.new(6, 1, 6)
		spawn.Position = Vector3.new(0, 3, 0)
		spawn.Neutral = true
		spawn.AllowTeamChangeOnTouch = false
		spawn.Duration = 0
		spawn.Parent = workspace
	end
	if not workspace:FindFirstChild("SA_Baseplate") then
		makePart({
			Name = "SA_Baseplate",
			Size = Vector3.new(200, 2, 200),
			Position = Vector3.new(0, -1, 20),
			Color = Color3.fromRGB(90, 140, 90),
			Material = Enum.Material.Grass,
		}, workspace)
	end

	-- Remove previous unit on rebuild.
	local old = workspace:FindFirstChild("SA_Unit")
	if old then
		old:Destroy()
	end

	local unit = Instance.new("Model")
	unit.Name = "SA_Unit"

	local cx, _, cz = UNIT_CENTER.X, UNIT_CENTER.Y, UNIT_CENTER.Z
	local floorY = 1

	-- Floor
	makePart({
		Name = "Floor",
		Size = Vector3.new(UNIT_W, WALL_T, UNIT_D),
		Position = Vector3.new(cx, floorY - 0.5, cz),
		Color = Color3.fromRGB(120, 120, 120),
		Material = Enum.Material.Concrete,
	}, unit)

	-- Walls: back (+Z), left, right. Front (-Z) is the openable door side.
	makePart({
		Name = "BackWall",
		Size = Vector3.new(UNIT_W, UNIT_H, WALL_T),
		Position = Vector3.new(cx, floorY + UNIT_H / 2, cz + UNIT_D / 2),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	makePart({
		Name = "LeftWall",
		Size = Vector3.new(WALL_T, UNIT_H, UNIT_D),
		Position = Vector3.new(cx - UNIT_W / 2, floorY + UNIT_H / 2, cz),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	makePart({
		Name = "RightWall",
		Size = Vector3.new(WALL_T, UNIT_H, UNIT_D),
		Position = Vector3.new(cx + UNIT_W / 2, floorY + UNIT_H / 2, cz),
		Color = Color3.fromRGB(150, 75, 60),
		Material = Enum.Material.CorrodedMetal,
	}, unit)
	-- Roof
	makePart({
		Name = "Roof",
		Size = Vector3.new(UNIT_W + 2, WALL_T, UNIT_D + 2),
		Position = Vector3.new(cx, floorY + UNIT_H + 0.5, cz),
		Color = Color3.fromRGB(80, 80, 85),
		Material = Enum.Material.Metal,
	}, unit)

	-- Door (front, slides/fades on inspection). Stored for AuctionService.
	local door = makePart({
		Name = "Door",
		Size = Vector3.new(UNIT_W - 2, UNIT_H - 1, 0.6),
		Position = Vector3.new(cx, floorY + (UNIT_H - 1) / 2, cz - UNIT_D / 2),
		Color = Color3.fromRGB(180, 180, 190),
		Material = Enum.Material.Metal,
	}, unit)
	door:SetAttribute("IsDoor", true)

	-- Invisible barrier: blocks entry during inspection/bidding, removed in rummage.
	local barrier = makePart({
		Name = "Barrier",
		Size = Vector3.new(UNIT_W - 2, UNIT_H - 1, 0.5),
		Position = door.Position,
		Transparency = 1,
		CanCollide = true,
		CanQuery = false,
	}, unit)

	-- Sign
	do
		local sign = makePart({
			Name = "Sign",
			Size = Vector3.new(14, 3, 0.5),
			Position = Vector3.new(cx, floorY + UNIT_H + 2.5, cz - UNIT_D / 2),
			Color = Color3.fromRGB(40, 40, 45),
		}, unit)
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromScale(1, 1)
		gui.AlwaysOnTop = true
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = "STORAGE AUCTION — UNIT 1"
		label.TextScaled = true
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.GothamBold
		label.Parent = gui
		gui.Parent = sign
	end

	-- Containers (visible during inspection, openable in rummage).
	local containers = {}
	for i = 1, (numContainers or 3) do
		local xOff = (i - 2) * 6 -- -6, 0, +6
		local box = makePart({
			Name = "Container_" .. i,
			Size = Vector3.new(4, 4, 4),
			Position = Vector3.new(cx + xOff, floorY + 2, cz + 2),
			Color = containerColors[((i - 1) % #containerColors) + 1],
			Material = Enum.Material.WoodPlanks,
		}, unit)
		box:SetAttribute("ContainerId", "box_" .. i)
		box:SetAttribute("Opened", false)

		local prompt = Instance.new("ProximityPrompt")
		prompt.ObjectText = "Storage Box " .. i
		prompt.ActionText = "Open"
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = box

		containers["box_" .. i] = box
	end

	unit.Parent = workspace

	return {
		Unit = unit,
		Door = door,
		Barrier = barrier,
		Containers = containers,
		UnitCenter = Vector3.new(cx, floorY, cz),
	}
end

function MapBuilder.SetDoorOpen(handles, open)
	local door = handles and handles.Door
	if not door then
		return
	end
	if open then
		door.Transparency = 0.85
		door.CanCollide = false
	else
		door.Transparency = 0
		door.CanCollide = true
	end
end

function MapBuilder.SetBarrier(handles, blocked)
	if handles and handles.Barrier then
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

function MapBuilder.SetPromptsEnabled(handles, enabled)
	if not handles then
		return
	end
	for _, box in pairs(handles.Containers) do
		local prompt = box:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Enabled = enabled
		end
	end
end

return MapBuilder
