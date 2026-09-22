-- StorageAuction — ONE-TIME map migration (Studio command bar, Edit mode).
--
-- WHAT: builds the persistent, manually-editable map model
--       Workspace.StorageAuctionMap from the M1 prototype layout.
-- WHEN: exactly once, on a place that does not have the map yet.
-- HOW:
--   1. Open StorageAuction-place.rbxl in Roblox Studio (DO NOT press Play).
--   2. Make sure the Rojo plugin is NOT connected (avoid any sync surprise).
--   3. Copy-paste this ENTIRE file into the command bar (View → Command Bar).
--   4. Press Enter. Watch Output for "[SA] Map migration complete".
--   5. SAVE the place (Ctrl+S). The map now lives in the .rbxl permanently.
--   6. From now on, edit Workspace.StorageAuctionMap directly in Studio.
--
-- Ground assumption: the place Baseplate's top surface is at Y = 0 (Studio
-- default). If yours differs, select StorageAuctionMap after migration and
-- move it vertically so the Floor slab sits correctly, then Save.
--
-- SAFE: aborts without changing anything if StorageAuctionMap already exists.
-- This script is NOT part of Rojo sync (tools/ is unmapped) and NEVER runs
-- at game runtime.

local workspace = game:GetService("Workspace")

if workspace:FindFirstChild("StorageAuctionMap") then
	error("[SA] StorageAuctionMap already exists — migration not needed. Delete it first only if you intentionally want to regenerate.", 0)
end

local UNIT_CX, UNIT_CZ = 0, 40
local UNIT_W, UNIT_H, UNIT_D = 24, 12, 18
local WALL_T = 1
local FLOOR_RISE = 0.2
local GROUND_TOP = 0 -- Studio default Baseplate top; adjust map after if needed

local function part(props, parent)
	local p = Instance.new("Part")
	p.Anchored = true
	for k, v in pairs(props) do
		p[k] = v
	end
	p.Parent = parent
	return p
end

local function marker(name, size, pos, parent)
	return part({
		Name = name,
		Size = size,
		Position = pos,
		Transparency = 0.7, -- visible in Edit mode; forced to 1 at runtime
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
		Color = Color3.fromRGB(255, 200, 60),
		Material = Enum.Material.Neon,
	}, parent)
end

local cx, cz = UNIT_CX, UNIT_CZ
local floorTop = GROUND_TOP + FLOOR_RISE
local frontZ = cz - UNIT_D / 2
local backZ = cz + UNIT_D / 2
local roofTop = floorTop + UNIT_H + WALL_T

local map = Instance.new("Model")
map.Name = "StorageAuctionMap"

-- ---------- StorageUnit ----------
local unit = Instance.new("Model")
unit.Name = "StorageUnit"

part({ Name = "Floor", Size = Vector3.new(UNIT_W, WALL_T, UNIT_D),
	Position = Vector3.new(cx, floorTop - WALL_T / 2, cz),
	Color = Color3.fromRGB(120, 120, 120), Material = Enum.Material.Concrete }, unit)
part({ Name = "BackWall", Size = Vector3.new(UNIT_W, UNIT_H, WALL_T),
	Position = Vector3.new(cx, floorTop + UNIT_H / 2, backZ - WALL_T / 2),
	Color = Color3.fromRGB(150, 75, 60), Material = Enum.Material.CorrodedMetal }, unit)
part({ Name = "LeftWall", Size = Vector3.new(WALL_T, UNIT_H, UNIT_D),
	Position = Vector3.new(cx - UNIT_W / 2 + WALL_T / 2, floorTop + UNIT_H / 2, cz),
	Color = Color3.fromRGB(150, 75, 60), Material = Enum.Material.CorrodedMetal }, unit)
part({ Name = "RightWall", Size = Vector3.new(WALL_T, UNIT_H, UNIT_D),
	Position = Vector3.new(cx + UNIT_W / 2 - WALL_T / 2, floorTop + UNIT_H / 2, cz),
	Color = Color3.fromRGB(150, 75, 60), Material = Enum.Material.CorrodedMetal }, unit)
part({ Name = "Roof", Size = Vector3.new(UNIT_W, WALL_T, UNIT_D),
	Position = Vector3.new(cx, floorTop + UNIT_H + WALL_T / 2, cz),
	Color = Color3.fromRGB(80, 80, 85), Material = Enum.Material.Metal }, unit)
part({ Name = "Door", Size = Vector3.new(UNIT_W - 2 * WALL_T, UNIT_H, 0.6),
	Position = Vector3.new(cx, floorTop + UNIT_H / 2, frontZ),
	Color = Color3.fromRGB(180, 180, 190), Material = Enum.Material.Metal }, unit)
part({ Name = "Barrier", Size = Vector3.new(UNIT_W - 2 * WALL_T, UNIT_H, 0.5),
	Position = Vector3.new(cx, floorTop + UNIT_H / 2, frontZ),
	Transparency = 1, CanCollide = true, CanQuery = false, CanTouch = false }, unit)

local sign = part({ Name = "Sign", Size = Vector3.new(18, 2.5, 0.6),
	Position = Vector3.new(cx, roofTop + 1.3, frontZ),
	Color = Color3.fromRGB(40, 40, 45) }, unit)
do
	local surface = Instance.new("SurfaceGui")
	surface.Face = Enum.NormalId.Back
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

local boxColors = {
	Color3.fromRGB(170, 120, 70),
	Color3.fromRGB(100, 140, 180),
	Color3.fromRGB(140, 110, 160),
}
for i = 1, 3 do
	local box = part({ Name = "Container_" .. i, Size = Vector3.new(4, 4, 4),
		Position = Vector3.new(cx + (i - 2) * 6, floorTop + 2, cz + 2),
		Color = boxColors[i], Material = Enum.Material.WoodPlanks }, unit)
	box:SetAttribute("ContainerId", "box_" .. i)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = "Storage Box " .. i
	prompt.ActionText = "Open"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = box
end

marker("UnitBounds", Vector3.new(UNIT_W, UNIT_H + 2, UNIT_D),
	Vector3.new(cx, floorTop + (UNIT_H + 2) / 2, cz), unit)
local returnPoint = marker("ReturnPoint", Vector3.new(1, 1, 1),
	Vector3.new(cx, floorTop + 4, frontZ - 7), unit)
returnPoint.CFrame = CFrame.lookAt(
	Vector3.new(cx, floorTop + 4, frontZ - 7),
	Vector3.new(cx, floorTop + 2, frontZ))

unit.Parent = map

-- ---------- AuctionArea ----------
local area = Instance.new("Model")
area.Name = "AuctionArea"

marker("BidCenter", Vector3.new(1, 1, 1),
	Vector3.new(cx, floorTop, frontZ - 10), area)
part({ Name = "Mat", Size = Vector3.new(20, 0.1, 12),
	Position = Vector3.new(cx, GROUND_TOP + 0.05, frontZ - 10),
	Color = Color3.fromRGB(55, 55, 65), Material = Enum.Material.SmoothPlastic }, area)

local seats = Instance.new("Model")
seats.Name = "Seats"
for i, xOff in ipairs({ -7, -4, 4, 7 }) do
	local chair = Instance.new("Model")
	chair.Name = "Chair_" .. i
	local gx, gz = cx + xOff, frontZ - 18
	part({ Name = "Post", Size = Vector3.new(1, 1.5, 1),
		Position = Vector3.new(gx, GROUND_TOP + 0.75, gz),
		Color = Color3.fromRGB(60, 60, 68), Material = Enum.Material.Metal }, chair)
	local seat = Instance.new("Seat")
	seat.Name = "Seat"
	seat.Anchored = true
	seat.Size = Vector3.new(2.5, 0.6, 2.5)
	seat.Position = Vector3.new(gx, GROUND_TOP + 1.8, gz)
	seat.Color = Color3.fromRGB(70, 80, 100)
	seat.Material = Enum.Material.SmoothPlastic
	seat.Parent = chair
	part({ Name = "Back", Size = Vector3.new(2.5, 2.2, 0.5),
		Position = Vector3.new(gx, GROUND_TOP + 3.1, gz - 1.25),
		Color = Color3.fromRGB(70, 80, 100), Material = Enum.Material.SmoothPlastic }, chair)
	chair.Parent = seats
end
seats.Parent = area
area.Parent = map

-- ---------- SpawnLocation (reuse the place's, else create) ----------
local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
if spawn and not spawn:IsDescendantOf(map) then
	spawn.Parent = map
else
	spawn = Instance.new("SpawnLocation")
	spawn.Parent = map
end
spawn.Anchored = true
spawn.Size = Vector3.new(6, 1, 6)
spawn.Position = Vector3.new(0, GROUND_TOP + 3, -6)
spawn.Neutral = true
spawn.AllowTeamChangeOnTouch = false
spawn.Duration = 0

map.Parent = workspace

print("[SA] Map migration complete: Workspace.StorageAuctionMap created.")
print("[SA] NEXT: SAVE the place (Ctrl+S), then Play with Rojo serving + connected.")
