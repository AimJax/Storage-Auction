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
local EconomyService = nil
local PlayerStatsService = nil
local InventoryService = nil
local PlayerDataService = nil
local AuctionService = nil
local DisplayService = nil
local Remotes = nil

-- [UserId] = { root = Model, slots = { [i] = Part }, level, unlockedSlots, upgrades }
-- plotIndex is session-local (never persisted); level lives in `levels` below
-- so progression survives plot release/reclaim within the session.
local warehouses = {}
-- Persistent progression (plot-independent). Restored on load, snapshotted
-- on save, never cleared on plot release.
local levels = {} -- [UserId] = level number
local folder = nil

local FOLDER_NAME = "SA_PlayerWarehouses"

-- Procedural overflow grid (template-local offsets) for display slots past
-- the physical markers. The template only authors 6 markers but Level 5
-- needs 36: rather than editing the map, extra cells continue a lattice
-- inside the warehouse floor bounds. Computed once from the template;
-- clones are rigid copies so offsets apply to every plot/yaw identically.
local gridOffsets = {} -- array of Vector3, template-local, slot 7, 8, ...

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

-- Physical markers: discover authored Slot_N parts dynamically (any count,
-- any gaps), sorted numerically for deterministic order. The six current
-- markers stay exactly where they are; the procedural overflow grid still
-- starts after the highest PHYSICAL slot found here.
local function collectSlots(root)
	local slotsFolder = root:FindFirstChild("DisplaySlots")
	local slots = {}
	if slotsFolder then
		local found = {}
		for _, child in ipairs(slotsFolder:GetChildren()) do
			local n = tonumber(string.match(child.Name, "^Slot_(%d+)$"))
			if n and n >= 1 and child:IsA("BasePart") then
				found[n] = child
			end
		end
		local order = {}
		for n, _ in pairs(found) do
			table.insert(order, n)
		end
		table.sort(order)
		local maxIndex = 0
		for _, n in ipairs(order) do
			slots[n] = found[n]
			maxIndex = n
		end
		return slots, maxIndex
	end
	return slots, 0
end

-- Level definitions + per-player level. Unknown/empty levels default to 1.
local function levelDef(level)
	local defs = GameConfig.WarehouseLevels
	return defs[math.clamp(math.floor(tonumber(level) or 1), 1, #defs)]
end

function WarehouseService.GetLevel(player)
	if not player then
		return 1
	end
	local n = math.clamp(math.floor(tonumber(levels[player.UserId]) or 1), 1, #GameConfig.WarehouseLevels)
	return n
end

function WarehouseService.RestoreLevel(player, level)
	if not player then
		return 1
	end
	local n = math.clamp(math.floor(tonumber(level) or 1), 1, #GameConfig.WarehouseLevels)
	levels[player.UserId] = n
	local entry = warehouses[player.UserId]
	if entry then
		entry.level = n
		entry.unlockedSlots = levelDef(n).DisplaySlots
	end
	return n
end

function WarehouseService.GetStorageCapacity(player)
	return levelDef(WarehouseService.GetLevel(player)).StorageCapacity
end

function WarehouseService.GetDisplaySlotCount(player)
	return levelDef(WarehouseService.GetLevel(player)).DisplaySlots
end

local function setTerminalLabel(root, level)
	if not root then
		return
	end
	local term = root:FindFirstChild("UpgradeTerminal")
	local gui = term and term:FindFirstChildOfClass("BillboardGui")
	local label = gui and gui:FindFirstChildOfClass("TextLabel")
	if label then
		label.Text = "WAREHOUSE LV " .. tostring(level)
	end
	local prompt = term and term:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.ObjectText = "Warehouse Upgrade (Lv " .. tostring(level) .. ")"
	end
end

-- Build the overflow lattice once from the template: 7x6 cells clipped to
-- the floor bounds (margins included), skipping cells near physical markers.
-- All math in template-local space (pivot-relative), so one list serves
-- every clone regardless of plot position or yaw.
local function computeGridOffsets(template)
	gridOffsets = {}
	local slotsFolder = template:FindFirstChild("DisplaySlots")
	local floor = template:FindFirstChild("Floor")
	if not slotsFolder or not floor or not floor:IsA("BasePart") then
		return
	end
	local pivot = template:GetPivot()
	local function toLocal(worldPos)
		return (pivot:Inverse() * CFrame.new(worldPos)).Position
	end
	local physical = {}
	for _, child in ipairs(slotsFolder:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(physical, toLocal(child.Position))
		end
	end
	if #physical == 0 then
		return
	end
	local floorLocal = toLocal(floor.Position)
	local hx, hz = floor.Size.X / 2 - 2.5, floor.Size.Z / 2 - 2.5
	local slotY = physical[1].Y
	local nx, nz = 7, 6
	for r = 0, nz - 1 do
		for c = 0, nx - 1 do
			local x = floorLocal.X - hx + (2 * hx) * (c / (nx - 1))
			local z = floorLocal.Z - hz + (2 * hz) * (r / (nz - 1))
			local clear = true
			for _, p in ipairs(physical) do
				local dx, dz = x - p.X, z - p.Z
				if dx * dx + dz * dz < 2.5 * 2.5 then
					clear = false
					break
				end
			end
			if clear then
				table.insert(gridOffsets, Vector3.new(x, slotY, z))
				if #gridOffsets >= 64 then
					return
				end
			end
		end
	end
end

-- World position anchor for display slot `index` (1-based): physical marker
-- when present, else the procedural grid cell. Nil when the index exceeds
-- everything available (caller rejects gracefully).
function WarehouseService.GetSlotPosition(player, index)
	index = math.floor(tonumber(index) or 0)
	if index < 1 then
		return nil
	end
	local entry = WarehouseService.GetWarehouse(player)
	if not entry then
		return nil
	end
	local physical = entry.slots[index]
	if physical then
		return physical.Position
	end
	local cell = gridOffsets[index - (entry.physicalSlots or 0)]
	if not cell then
		return nil
	end
	local root = entry.root
	if not root then
		return nil
	end
	return (root:GetPivot() * CFrame.new(cell)).Position
end

function WarehouseService.GetMaxSlotIndex(player)
	local entry = WarehouseService.GetWarehouse(player)
	local physical = 0
	if entry then
		physical = entry.physicalSlots or 0
	end
	return physical + #gridOffsets
end

local function setLevel(player, level)
	local n = math.clamp(math.floor(tonumber(level) or 1), 1, #GameConfig.WarehouseLevels)
	levels[player.UserId] = n
	local entry = warehouses[player.UserId]
	if entry then
		entry.level = n
		entry.unlockedSlots = levelDef(n).DisplaySlots
		setTerminalLabel(entry.root, n)
	end
	return n
end

-- Upgrade terminal: small runtime kiosk inside the clone (no map edits),
-- placed toward the open side relative to the back wall. Carries the level
-- billboard + the Upgrade prompt (wired by the caller via GetTerminalPrompt
-- or directly at build).
local function createTerminal(clone, level)
	local floor = clone:FindFirstChild("Floor")
	local back = clone:FindFirstChild("BackWall")
	if not floor or not floor:IsA("BasePart") then
		return nil
	end
	local dir = Vector3.new(0, 0, 1)
	if back and back:IsA("BasePart") then
		local away = floor.Position - back.Position
		away = Vector3.new(away.X, 0, away.Z)
		if away.Magnitude > 0.01 then
			dir = away.Unit
		end
	end
	local floorTop = floor.Position.Y + floor.Size.Y / 2
	local pos = floor.Position + dir * 15 + Vector3.new(0, floorTop - floor.Position.Y + 1.5, 0)
	local term = Instance.new("Part")
	term.Name = "UpgradeTerminal"
	term.Anchored = true
	term.CanCollide = false
	term.CanTouch = false
	term.CanQuery = false
	term.Size = Vector3.new(2, 3, 1)
	term.Position = pos
	term.Color = Color3.fromRGB(40, 120, 200)
	term.Material = Enum.Material.SmoothPlastic
	term.Parent = clone
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromOffset(200, 50)
	billboard.StudsOffset = Vector3.new(0, 2.4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 60
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	label.BackgroundTransparency = 0.25
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.Text = "WAREHOUSE LV " .. tostring(level)
	label.Parent = billboard
	billboard.Parent = term
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "UpgradePrompt"
	prompt.ObjectText = "Warehouse Upgrade (Lv " .. tostring(level) .. ")"
	prompt.ActionText = "Upgrade"
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = term
	prompt.Triggered:Connect(function(player)
		-- Only the warehouse owner may open their own upgrade UI, and only
		-- from near their terminal. Anyone else gets a targeted message.
		local entry = warehouses[player.UserId]
		local mine = entry and entry.root and term.Parent == entry.root
		if not mine then
			local ev = Remotes and Remotes:FindFirstChild(GameConfig.RemoteNames.Notify)
			if ev then
				ev:FireClient(player, "This upgrade terminal belongs to another player.")
			end
			return
		end
		if not WarehouseService.IsNearTerminal(player) then
			return
		end
		local ev = Remotes and Remotes:FindFirstChild(GameConfig.RemoteNames.WarehouseOpened)
		if ev then
			ev:FireClient(player)
		end
	end)
	return term
end

-- Range gate shared by the terminal prompt and the UpgradeWarehouse remote:
-- caller must stand within the prompt's own MaxActivationDistance (+2).
function WarehouseService.IsNearTerminal(player)
	if not player then
		return false
	end
	local entry = warehouses[player.UserId]
	if not entry or not entry.root or entry.root.Parent == nil then
		return false
	end
	local term = entry.root:FindFirstChild("UpgradeTerminal")
	if not term or not term:IsA("BasePart") then
		return false
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local prompt = term:FindFirstChildOfClass("ProximityPrompt")
	local maxDist = 10
	if prompt then
		maxDist = tonumber(prompt.MaxActivationDistance) or 10
	end
	maxDist += 2
	local delta = root.Position - term.Position
	return delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z <= maxDist * maxDist
end

function WarehouseService.Init(deps)
	MapHandles = deps.MapHandles
	EconomyService = deps.EconomyService
	PlayerStatsService = deps.PlayerStatsService
	InventoryService = deps.InventoryService
	PlayerDataService = deps.PlayerDataService
	AuctionService = deps.AuctionService
	DisplayService = deps.DisplayService
	Remotes = deps.Remotes

	folder = game.Workspace:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = game.Workspace
	end

	local template = MapHandles and MapHandles.WarehouseTemplate
	if template then
		hideTemplate(template)
		computeGridOffsets(template)
	else
		warn("[SA] No WarehouseTemplate in map; runtime warehouses disabled (auctions unaffected).")
	end

	local getState = Remotes and Remotes:FindFirstChild(GameConfig.RemoteNames.GetWarehouseState)
	if getState and getState:IsA("RemoteFunction") then
		getState.OnServerInvoke = function(player)
			return { ok = true, state = WarehouseService.GetWarehouseState(player) }
		end
	end
	local upgrade = Remotes and Remotes:FindFirstChild(GameConfig.RemoteNames.UpgradeWarehouse)
	if upgrade and upgrade:IsA("RemoteFunction") then
		upgrade.OnServerInvoke = function(player)
			local ok, msg = WarehouseService.UpgradeWarehouse(player)
			return { ok = ok, message = msg, state = WarehouseService.GetWarehouseState(player) }
		end
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
	local level = WarehouseService.GetLevel(player)
	local foundSlots, physicalCount = collectSlots(clone)
	local entry = {
		root = clone,
		slots = foundSlots,
		physicalSlots = physicalCount,
		plotIndex = plot.index,
		level = level,
		unlockedSlots = levelDef(level).DisplaySlots,
		upgrades = {},
	}
	warehouses[player.UserId] = entry
	-- Upgrade kiosk (runtime part, no map edits) + level marker.
	createTerminal(clone, level)
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

-- Actual PLAYER LEAVE cleanup (after save): destroy any lingering runtime
-- warehouse and clear the per-user level cache. Plot release (DestroyFor)
-- deliberately keeps the level: releasing/reclaiming in-session must not
-- lose progression; only real lifecycle cleanup clears it.
function WarehouseService.ClearPlayer(player)
	if not player then
		return
	end
	WarehouseService.DestroyFor(player)
	levels[player.UserId] = nil
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

-- Full upgrade-panel state for one player (server-computed, safe to render).
function WarehouseService.GetWarehouseState(player)
	local defs = GameConfig.WarehouseLevels
	local level = WarehouseService.GetLevel(player)
	local def = levelDef(level)
	local inventoryCount = 0
	if InventoryService and player then
		inventoryCount = #InventoryService.GetItems(player)
	end
	local state = {
		level = level,
		maxLevel = #defs,
		storageCapacity = def.StorageCapacity,
		inventoryCount = inventoryCount,
		displaySlots = def.DisplaySlots,
		hasWarehouse = WarehouseService.GetWarehouse(player) ~= nil,
		next = nil,
		canUpgrade = false,
		reason = nil,
	}
	local next = defs[level + 1]
	if not next then
		state.reason = "MAX LEVEL"
		return state
	end
	state.next = {
		level = level + 1,
		cost = next.UpgradeCost,
		minWins = next.MinWins,
		capacity = next.StorageCapacity,
		slots = next.DisplaySlots,
	}
	if state.hasWarehouse then
		local wins = (PlayerStatsService and player) and PlayerStatsService.GetWins(player) or 0
		local cash = (EconomyService and player) and EconomyService.GetCash(player) or 0
		if wins < (tonumber(next.MinWins) or 0) then
			state.reason = string.format("Requires %d auction wins (you have %d).", next.MinWins, wins)
		elseif cash < (tonumber(next.UpgradeCost) or 0) then
			state.reason = string.format("Requires $%d cash.", next.UpgradeCost)
		else
			state.canUpgrade = true
		end
	else
		state.reason = "Claim a warehouse plot first."
	end
	return state
end

-- Server-authoritative upgrade. Client sends nothing but the call.
-- Validates warehouse ownership, level ladder, wins, and cash; deducts via
-- normal EconomyService (debt never intercepts, never auto-repays).
-- Server-authoritative upgrade. Client sends nothing but the call.
-- Validates warehouse ownership, terminal proximity, level ladder, wins,
-- and SPENDABLE cash (cash minus active auction leading commitments, so an
-- upgrade can never starve a bid the player is currently winning). Deducts
-- via normal EconomyService (debt never intercepts, never auto-repays).
-- Refreshes display proxies so the new slot count applies immediately.
function WarehouseService.UpgradeWarehouse(player)
	if not player then
		return false, "Invalid player."
	end
	if PlayerDataService and not PlayerDataService.IsLoaded(player) then
		return false, PlayerDataService.NotReadyMessage()
	end
	local entry = WarehouseService.GetWarehouse(player)
	if not entry then
		return false, "Claim a warehouse plot first."
	end
	if not WarehouseService.IsNearTerminal(player) then
		return false, "Move closer to your upgrade terminal."
	end
	local defs = GameConfig.WarehouseLevels
	local level = WarehouseService.GetLevel(player)
	local next = defs[level + 1]
	if not next then
		return false, "MAX LEVEL"
	end
	local wins = (PlayerStatsService and PlayerStatsService.GetWins(player)) or 0
	if wins < (tonumber(next.MinWins) or 0) then
		return false, string.format("Requires %d auction wins (you have %d).", next.MinWins, wins)
	end
	local cost = tonumber(next.UpgradeCost) or 0
	local committed = 0
	if AuctionService and AuctionService.GetLeadingCommitment then
		committed = AuctionService.GetLeadingCommitment(player) or 0
	end
	local spendable = (EconomyService and EconomyService.GetCash(player) or 0) - committed
	if spendable < cost then
		if committed > 0 then
			return false, string.format("Requires $%d spendable cash ($%d tied in leading bids).", cost, committed)
		end
		return false, string.format("Requires $%d cash.", cost)
	end
	if cost > 0 then
		if not EconomyService.DeductCash(player, cost) then
			return false, string.format("Requires $%d cash.", cost)
		end
	end
	setLevel(player, level + 1)
	if DisplayService and DisplayService.RefreshProxies then
		DisplayService.RefreshProxies(player)
	end
	return true, string.format("Warehouse upgraded to Lv %d (%d slots, %d storage).",
		level + 1, defs[level + 1].DisplaySlots, defs[level + 1].StorageCapacity)
end

return WarehouseService
