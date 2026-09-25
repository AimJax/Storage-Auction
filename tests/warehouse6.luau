-- Stage 6: warehouse progression tests (dev harness, NOT game code).
-- Uses REAL staged services with mocked Instances (incl. yaw CFrames).
-- Run from D:/Roblox/Temp/sa-econ.

local failures = 0
local function check(cond, label)
	if cond then
		print("PASS " .. label)
	else
		failures += 1
		print("FAIL " .. label)
	end
end

-- ============ Vector3 / CFrame (yaw-capable) ============
local function v3(x, y, z)
	return setmetatable({ X = x, Y = y, Z = z }, {
		__add = function(a, b)
			return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
		end,
		__sub = function(a, b)
			return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
		end,
		__mul = function(a, b)
			if typeof(b) == "number" then
				return v3(a.X * b, a.Y * b, a.Z * b)
			end
			return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
		end,
		__div = function(a, b)
			if typeof(b) == "number" then
				return v3(a.X / b, a.Y / b, a.Z / b)
			end
			return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
		end,
		__index = function(t, k)
			if k == "Magnitude" then
				return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
			elseif k == "Unit" then
				local m = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
				if m < 1e-9 then
					return v3(0, 0, 0)
				end
				return v3(t.X / m, t.Y / m, t.Z / m)
			end
			return rawget(t, k)
		end,
	})
end
local function vadd(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
local function vsub(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
local function rotY(yaw, v)
	local c, s = math.cos(yaw), math.sin(yaw)
	return v3(c * v.X + s * v.Z, v.Y, -s * v.X + c * v.Z)
end
Vector3 = {
	new = function(x, y, z)
		if typeof(x) == "table" then
			return v3(x.X, x.Y, x.Z)
		end
		return v3(x or 0, y or 0, z or 0)
	end,
	zero = v3(0, 0, 0),
}
local CF = {}
local function cfIndex(t, k)
	if k == "Position" then
		return t.p
	end
	return CF[k]
end
CF.__index = cfIndex
local function cfNew(a, b, c)
	if a == nil then
		return setmetatable({ p = v3(0, 0, 0), yaw = 0 }, CF)
	elseif typeof(a) == "table" and b == nil then
		return setmetatable({ p = v3(a.X, a.Y, a.Z), yaw = 0 }, CF)
	end
	return setmetatable({ p = v3(a, b, c), yaw = 0 }, CF)
end
local function cfYaw(p, yaw)
	return setmetatable({ p = v3(p.X, p.Y, p.Z), yaw = yaw }, CF)
end
function CF.__mul(a, b)
	return setmetatable({ p = vadd(a.p, rotY(a.yaw, b.p)), yaw = a.yaw + b.yaw }, CF)
end
function CF:Inverse()
	return setmetatable({ p = rotY(-self.yaw, v3(-self.p.X, -self.p.Y, -self.p.Z)), yaw = -self.yaw }, CF)
end
CFrame = {
	new = cfNew,
	Angles = function(_, y, _)
		return setmetatable({ p = v3(0, 0, 0), yaw = y }, CF)
	end,
}
UDim = { new = function(a, b)
	return { Scale = a, Offset = b }
end }
UDim2 = {
	new = function(a, b, c, d)
		return { a, b, c, d }
	end,
	fromScale = function(a, b)
		return { a, 0, b, 0 }
	end,
	fromOffset = function(a, b)
		return { 0, a, 0, b }
	end,
}
Color3 = {
	new = function(r, g, b)
		return { R = r, G = g, B = b }
	end,
	fromRGB = function(r, g, b)
		return { R = r, G = g, B = b }
	end,
}
Enum = {
	Material = { SmoothPlastic = 1, Glass = 1, Metal = 1, Concrete = 1 },
	Font = { GothamBold = 1, Gotham = 1 },
	TextTruncate = { AtEnd = 1 },
	TextXAlignment = { Left = 1, Center = 1 },
	TextYAlignment = { Top = 1, Center = 1 },
}

-- ============ Instance mocks ============
local function attachChild(parent, child)
	parent._children = parent._children or {}
	table.insert(parent._children, child)
	rawset(child, "_parent", parent)
end
local function detachChild(child)
	local p = rawget(child, "_parent")
	if p and p._children then
		for i, c in ipairs(p._children) do
			if c == child then
				table.remove(p._children, i)
				break
			end
		end
	end
	rawset(child, "_parent", nil)
end
local function findChild(inst, name, recursive)
	for _, c in ipairs(inst._children or {}) do
		if c.Name == name then
			return c
		end
		if recursive then
			local f = findChild(c, name, true)
			if f then
				return f
			end
		end
	end
	return nil
end
local function findClass(inst, class, recursive)
	for _, c in ipairs(inst._children or {}) do
		if c.ClassName == class then
			return c
		end
		if recursive then
			local f = findClass(c, class, true)
			if f then
				return f
			end
		end
	end
	return nil
end
local function descendants(inst, out)
	out = out or {}
	for _, c in ipairs(inst._children or {}) do
		table.insert(out, c)
		descendants(c, out)
	end
	return out
end
local function isA(inst, class)
	if class == "BasePart" then
		return inst.ClassName == "Part" or inst.ClassName == "Seat" or inst.ClassName == "WedgePart"
	end
	return inst.ClassName == class
end
local function mkInst(class, name)
	local inst = {
		ClassName = class,
		Name = name or class,
		_children = {},
		_attrs = {},
		Destroyed = false,
	}
	local mt = {
		__index = function(t, k)
			if k == "Parent" then
				return rawget(t, "_parent")
			end
			return rawget(t, k)
		end,
		__newindex = function(t, k, v)
			if k == "Parent" then
				detachChild(t)
				if v ~= nil then
					attachChild(v, t)
				end
			else
				rawset(t, k, v)
			end
		end,
	}
	setmetatable(inst, mt)
	inst.IsA = function(self, c)
		return isA(self, c)
	end
	inst.FindFirstChild = function(self, n, rec)
		return findChild(self, n, rec)
	end
	inst.FindFirstChildOfClass = function(self, c)
		return findClass(self, c, false)
	end
	inst.GetChildren = function(self)
		return self._children or {}
	end
	inst.GetDescendants = function(self)
		return descendants(self)
	end
	inst.SetAttribute = function(self, k, v)
		self._attrs[k] = v
	end
	inst.GetAttribute = function(self, k)
		return self._attrs[k]
	end
	inst.Destroy = function(self)
		self.Destroyed = true
		detachChild(self)
	end
	inst.Clone = function(self)
		local function deep(src)
			local c = mkInst(src.ClassName, src.Name)
			for k, v in pairs(src) do
				if k ~= "_children" and k ~= "_parent" and k ~= "_pivot" and type(v) ~= "function" then
					if k == "Position" or k == "Size" then
						rawset(c, k, v3(v.X, v.Y, v.Z))
					elseif k == "CFrame" then
						rawset(c, k, cfYaw(v.p, v.yaw))
					elseif type(v) == "table" and (v.X ~= nil) then
						rawset(c, k, v3(v.X, v.Y, v.Z))
					else
						rawset(c, k, v)
					end
				end
			end
			if src._attrs then
				for k, v in pairs(src._attrs) do
					c._attrs[k] = v
				end
			end
			for _, ch in ipairs(src._children or {}) do
				deep(ch).Parent = c
			end
			return c
		end
		local c = deep(self)
		if self._pivot then
			c._pivot = cfYaw(self._pivot.p, self._pivot.yaw)
		end
		return c
	end
	inst.GetPivot = function(self)
		return self._pivot or cfNew(0, 0, 0)
	end
	inst.PivotTo = function(self, cf)
		local old = self:GetPivot()
		local delta = cf * old:Inverse()
		for _, d in ipairs(descendants(self)) do
			if d.Position then
				d.Position = (delta * cfNew(d.Position)).p
				d.CFrame = cfNew(d.Position)
			end
		end
		self._pivot = cfYaw(cf.p, cf.yaw)
	end
	if class == "ProximityPrompt" then
		inst.Triggered = { Connect = function(_, fn)
			inst._cb = fn
		end }
	end
	return inst
end
Instance = { new = function(c)
	return mkInst(c, c)
end }

local function mkPart(name, x, y, z, sx, sy, sz)
	local p = mkInst("Part", name)
	p.Position = v3(x, y, z)
	p.CFrame = cfNew(x, y, z)
	p.Size = v3(sx or 3, sy or 3, sz or 3)
	p.Transparency = 0
	p.CanCollide = true
	p.CanTouch = true
	p.CanQuery = true
	p.Anchored = true
	return p
end

-- ============ clocks/scheduler ============
local vclock = 0
local fakeNow = 3000000
local realOsTime = os.time
os = {
	clock = function()
		return vclock
	end,
	time = function(...)
		if select("#", ...) == 0 then
			return fakeNow
		end
		return realOsTime(...)
	end,
	difftime = function(a, b)
		return a - b
	end,
}
local runqueue = {}
task = {}
task.spawn = function(fn, ...)
	local args = { ... }
	table.insert(runqueue, { co = coroutine.create(function()
		fn(table.unpack(args))
	end), at = 0 })
end
task.wait = function(t)
	t = tonumber(t) or 0
	local co = coroutine.running()
	assert(co ~= nil, "task.wait on main thread")
	table.insert(runqueue, { co = co, at = vclock + t })
	coroutine.yield()
end
task.delay = function(t, fn, ...)
	local args = { ... }
	task.spawn(function()
		task.wait(t)
		fn(table.unpack(args))
	end)
end
task.defer = function(fn, ...)
	local args = { ... }
	task.spawn(function()
		fn(table.unpack(args))
	end)
end
local schedErrors = {}
local function pumpTo(target)
	while true do
		local nextAt = nil
		for _, item in ipairs(runqueue) do
			if coroutine.status(item.co) ~= "dead" then
				if nextAt == nil or item.at < nextAt then
					nextAt = item.at
				end
			end
		end
		if nextAt == nil or nextAt > target then
			vclock = target
			return
		end
		vclock = nextAt
		local i = 1
		while i <= #runqueue do
			if runqueue[i].at <= vclock then
				local item = table.remove(runqueue, i)
				if coroutine.status(item.co) ~= "dead" then
					local ok, err = coroutine.resume(item.co)
					if not ok then
						table.insert(schedErrors, tostring(err))
					end
				end
			else
				i += 1
			end
		end
	end
end
local function pumpUntil(cond, limit)
	limit = limit or 800000
	while not cond() and vclock < limit do
		pumpTo(vclock + 0.5)
	end
	return cond()
end

warn = function(...) end
debug = { traceback = function(e)
	return tostring(e)
end }
local nextRng = 424242
Random = { new = function(_s)
	return {
		NextNumber = function(_self, a, b)
			nextRng = (nextRng * 1103515245 + 12345) % 2147483648
			local r = nextRng / 2147483648
			if a == nil then
				return r
			end
			return a + r * (b - a)
		end,
		NextInteger = function(_self, a, b)
			nextRng = (nextRng * 1103515245 + 12345) % 2147483648
			return a + (nextRng % (b - a + 1))
		end,
	}
end }

-- ============ DataStore mock ============
local storeData = {}
local setCalls = {}
local storeFail = { get = false, set = false }
local function snapCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local c = {}
	for k, val in pairs(v) do
		c[k] = snapCopy(val)
	end
	return c
end
local DataStoreMock = {
	GetDataStore = function(_s, _name)
		return {
			GetAsync = function(_self, k)
				if storeFail.get then
					error("db down")
				end
				return snapCopy(storeData[k])
			end,
			SetAsync = function(_self, k, v)
				if storeFail.set then
					error("db down")
				end
				setCalls[k] = (setCalls[k] or 0) + 1
				storeData[k] = snapCopy(v)
			end,
		}
	end,
}

-- ============ players/remotes/game ============
local playersById = {}
local function setCharPos(p, x, y, z)
	p.Character = {
		HumanoidRootPart = { Position = v3(x, y, z) },
		FindFirstChild = function(self, n)
			if n == "HumanoidRootPart" then
				return self.HumanoidRootPart
			end
			return nil
		end,
	}
end
local function mkPlayer(name, id)
	local p = { Name = name, UserId = id, Parent = true, FindFirstChild = function(_s, _n)
		return nil
	end }
	playersById[id] = p
	return p
end
local playersSvc = {
	PlayerRemoving = { Connect = function(_s, _fn) end },
	GetPlayers = function()
		local list = {}
		for _, p in pairs(playersById) do
			table.insert(list, p)
		end
		return list
	end,
	GetPlayerByUserId = function(_s, id)
		return playersById[id]
	end,
}
local firedEvents = {}
local function mkRemote()
	return {
		IsA = function(_s, _c)
			return true
		end,
		FireAllClients = function(_s, _p) end,
		FireClient = function(_s, pl, a)
			table.insert(firedEvents, { pl = pl, payload = a })
		end,
		OnServerInvoke = nil,
	}
end
local remoteReg = {}
local Remotes = {
	FindFirstChild = function(_s, n)
		if not remoteReg[n] then
			remoteReg[n] = mkRemote(n)
		end
		return remoteReg[n]
	end,
}

-- Template: floor 52x40 + back wall + 6 markers (3x2 grid).
local function buildTemplate()
	local t = mkInst("Model", "WarehouseTemplate")
	t._pivot = cfNew(0, 0, -120)
	local floor = mkPart("Floor", 0, -0.3, -120, 52, 1, 40)
	floor.Parent = t
	local back = mkPart("BackWall", 0, 9, -139, 52, 18, 1)
	back.Parent = t
	local ds = mkInst("Model", "DisplaySlots")
	ds.Parent = t
	local xs = { -14, 0, 14 }
	local zs = { -123, -117 }
	local n = 0
	for _, z in ipairs(zs) do
		for _, x in ipairs(xs) do
			n += 1
			local s = mkPart("Slot_" .. n, x, 0.3, z, 3, 0.2, 3)
			s.Parent = ds
		end
	end
	return t
end
local template = buildTemplate()

-- District: Plot_01 (identity) + Plot_02 (90-degree yaw).
local function buildPlot(name, ox, oz, yaw)
	local m = mkInst("Model", name)
	local origin = mkPart("WarehouseOrigin", ox, 0.2, oz, 1, 1, 1)
	origin.CFrame = cfYaw(origin.Position, yaw)
	origin.Parent = m
	local sign = mkInst("Model", "PlotSign")
	sign.Parent = m
	local board = mkPart("Board", ox - 30, 5.4, oz - 25, 6, 2.5, 0.5)
	board.Parent = sign
	local label = mkInst("TextLabel", "TextLabel")
	label.Text = "AVAILABLE"
	label.Parent = board
	m._pivot = cfNew(ox, 0, oz)
	return m
end
local district = mkInst("Model", "WarehouseDistrict")
buildPlot("Plot_01", 230, 36, 0).Parent = district
buildPlot("Plot_02", 330, 36, math.pi / 2).Parent = district
local mapMock = mkInst("Model", "StorageAuctionMap")
district.Parent = mapMock
template.Parent = mapMock
local workspaceMock = mkInst("Workspace", "Workspace")
mapMock.Parent = workspaceMock

game = {
	GetService = function(_s, name)
		if name == "Players" then
			return playersSvc
		elseif name == "ReplicatedStorage" then
			return { WaitForChild = function(_a, _b)
				return {}
			end }
		elseif name == "DataStoreService" then
			return DataStoreMock
		end
		error("unexpected service " .. tostring(name))
	end,
	Workspace = workspaceMock,
}

-- ============ real modules ============
local GameConfig = require("./GameConfig")
local RealEconomyService = require("./EconomyService")
local EconomyService = setmetatable({
	GetCash = function(p)
		local id = if typeof(p) == "table" then p.UserId else p
		return RealEconomyService.GetCash(id)
	end,
	CanAfford = function(p, amount)
		local id = if typeof(p) == "table" then p.UserId else p
		return RealEconomyService.GetCash(id) >= (amount or 0)
	end,
}, { __index = RealEconomyService })
local InventoryService = require("./InventoryService")
local PlayerStatsService = require("./PlayerStatsService")
local RealDebtService = require("./DebtService")
local DebtService = setmetatable({
	GetPersistentState = function(p)
		local id = if typeof(p) == "table" then p.UserId else p
		return RealDebtService.GetPersistentState(id)
	end,
	GetDebt = function(p)
		local id = if typeof(p) == "table" then p.UserId else p
		return RealDebtService.GetDebt(id)
	end,
}, { __index = RealDebtService })
local WarehouseService = require("./WarehouseService")
local DisplayService = require("./DisplayService")
local PlotService = require("./PlotService")
local PlayerDataService = require("./PlayerDataService")
local NPCBidderService = require("./NPCBidderService")
local AuctionService = require("./AuctionService")

EconomyService.Init(nil)
InventoryService.Init(Remotes)
PlayerStatsService.Init({ InventoryService = InventoryService, Remotes = Remotes })
DebtService.Init({ EconomyService = EconomyService, PlayerStatsService = PlayerStatsService, Remotes = Remotes, ATMPrompt = nil })
WarehouseService.Init({ MapHandles = { WarehouseTemplate = template }, EconomyService = EconomyService, PlayerStatsService = PlayerStatsService, InventoryService = InventoryService, Remotes = Remotes })
DisplayService.Init({ InventoryService = InventoryService, WarehouseService = WarehouseService, Remotes = Remotes })
PlotService.Init({ MapHandles = {}, Remotes = Remotes, WarehouseService = WarehouseService, DisplayService = DisplayService })
PlayerDataService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	PlayerStatsService = PlayerStatsService,
	DebtService = DebtService,
	WarehouseService = WarehouseService,
	DisplayService = DisplayService,
})
PlayerDataService.StartAutosave()

local P = mkPlayer("WhTest", 401)
local function cashOf(p)
	return EconomyService.GetCash(p)
end
local function fakeItem(i, value)
	return { InstanceId = "w_" .. i, ItemId = "old_lamp", Name = "Old Lamp", BaseValue = 40, ModelKey = "OldLamp", Rarity = "Common", Condition = 50, ConditionName = "Used", FinalValue = value or 100, Modifiers = {} }
end

-- ================= TEST 1/2: defaults =================
do
	check(WarehouseService.GetLevel(P) == 1, "T1 new player level 1")
	local st = WarehouseService.GetWarehouseState(P)
	check(st.storageCapacity == 25 and st.displaySlots == 6 and st.maxLevel == 5, "T1 L1 capacity/slots")
	check(st.hasWarehouse == false and st.canUpgrade == false, "T1 no warehouse yet")
	storeData["player_401"] = { Cash = 500 }
	PlayerDataService.Load(P)
	check(WarehouseService.GetLevel(P) == 1, "T2 old schema loads level 1")
	local st2 = WarehouseService.GetWarehouseState(P)
	check(st2.displaySlots == 6, "T2 displays default empty")
end

-- ================= claim plot (upgrades + displays need a warehouse) =================
local function claimAs(p, idx)
	return PlotService.ClaimPlot(p, idx)
end
do
	local plot = claimAs(P, 1)
	check(plot ~= nil and WarehouseService.GetWarehouse(P) ~= nil, "claim works")
	local term = WarehouseService.GetWarehouseRoot(P):FindFirstChild("UpgradeTerminal")
	check(term ~= nil, "upgrade terminal built")
	local prompt = term and term:FindFirstChildOfClass("ProximityPrompt")
	check(prompt ~= nil, "upgrade prompt present")
	-- stand at the terminal for the ownership + range gate
	local tp = term.Position
	P.Character = {
		HumanoidRootPart = { Position = { X = tp.X, Y = tp.Y, Z = tp.Z } },
		FindFirstChild = function(self, n)
			if n == "HumanoidRootPart" then
				return self.HumanoidRootPart
			end
			return nil
		end,
	}
	firedEvents = {}
	prompt._cb(P)
	local sawOpen = false
	for _, e in ipairs(firedEvents) do
		if e.pl == P then
			sawOpen = true
		end
	end
	check(sawOpen, "terminal prompt opens UI")
end

-- ================= TEST 3-7: upgrades =================
do
	local termPos = WarehouseService.GetWarehouseRoot(P):FindFirstChild("UpgradeTerminal").Position
	setCharPos(P, termPos.X, termPos.Y, termPos.Z) -- at own terminal for range gate
	EconomyService.SetCash(P, 10000)
	PlayerStatsService.RestoreWins(P, 3)
	local ok3, msg3 = WarehouseService.UpgradeWarehouse(P)
	check(ok3, "T3 L1->L2 (" .. tostring(msg3) .. ")")
	check(WarehouseService.GetLevel(P) == 2, "T3 level 2")
	check(cashOf(P) == 7500, "T7 cash deducted exactly once")
	local st = WarehouseService.GetWarehouseState(P)
	check(st.storageCapacity == 50 and st.displaySlots == 10, "T3 new caps")
	EconomyService.SetCash(P, 100)
	PlayerStatsService.RestoreWins(P, 10)
	local ok4, msg4 = WarehouseService.UpgradeWarehouse(P)
	check(not ok4 and cashOf(P) == 100 and WarehouseService.GetLevel(P) == 2, "T4 insufficient cash rejected (" .. tostring(msg4) .. ")")
	check(string.find(tostring(msg4), "cash"), "T4 reason names cash")
	PlayerStatsService.RestoreWins(P, 0)
	EconomyService.SetCash(P, 100000)
	local ok5, msg5 = WarehouseService.UpgradeWarehouse(P)
	check(not ok5, "T5 insufficient wins rejected (" .. tostring(msg5) .. ")")
	WarehouseService.RestoreLevel(P, 5)
	local ok6, msg6 = WarehouseService.UpgradeWarehouse(P)
	check(not ok6 and tostring(msg6) == "MAX LEVEL", "T6 max rejected")
	WarehouseService.RestoreLevel(P, 2)
end

-- ================= TEST 8: capacity =================
do
	check(WarehouseService.GetStorageCapacity(P) == 50, "T8 L2 capacity 50")
	WarehouseService.RestoreLevel(P, 1)
	check(WarehouseService.GetStorageCapacity(P) == 25, "T8 L1 capacity 25")
end

-- ================= TEST 9-11/13: keep gate =================
do
	-- mini auction rig for rummage + pending
	local MapBuilderStub = {}
	MapBuilderStub.SetDoorOpen = function(_h, _o) end
	MapBuilderStub.SetBarrier = function(_h, _b) end
	MapBuilderStub.ResetContainers = function(h)
		for _, box in pairs(h.Containers) do
			box:SetAttribute("Opened", false)
		end
	end
	MapBuilderStub.MarkContainerOpened = function(_h, _id) end
	MapBuilderStub.SetPromptsEnabled = function(_h, _e) end
	MapBuilderStub.IsWithinBidRadius = function(_h, _p, _r)
		return true
	end
	MapBuilderStub.IsPlayerInsideUnit = function(_h, _p)
		return false
	end
	MapBuilderStub.MovePlayerOutsideIfInside = function(_h, _p)
		return false
	end
	local function mkBox(id, x, y, z)
		return {
			Position = v3(x or 0, y or 2, z or 0),
			_attrs = {},
			FindFirstChildOfClass = function(self, c)
				if c == "ProximityPrompt" then
					if not self._prompt then
						self._prompt = { MaxActivationDistance = 10, Enabled = false, Triggered = { Connect = function(_t, _fn) end } }
					end
					return self._prompt
				end
				return nil
			end,
			GetAttribute = function(self, k)
				return self._attrs[k]
			end,
			SetAttribute = function(self, k, v)
				self._attrs[k] = v
			end,
		}
	end
	local function mkUnit(ids)
		local h = { Door = {}, Barrier = {}, Containers = {}, BidCenter = { X = 0, Y = 0, Z = 0 } }
		local i = 0
		for _, id in ipairs(ids) do
			i += 1
			h.Containers[id] = mkBox(id, -21, 2, -6 + (i - 1) * 6)
		end
		return h
	end
	local MapBuilderReal = require("./MapBuilder")
	MapBuilderStub.IsWithinContainerRange = MapBuilderReal.IsWithinContainerRange
	AuctionService.Init({
		EconomyService = EconomyService,
		InventoryService = InventoryService,
		NPCBidderService = NPCBidderService,
		MapBuilder = MapBuilderStub,
		MapHandles = { Units = { mkUnit({ "box_1", "box_2", "box_3" }), mkUnit({ "box_4", "box_5", "box_6" }), mkUnit({ "box_7", "box_8", "box_9" }) } },
		Remotes = Remotes,
		PlayerStatsService = PlayerStatsService,
		DisplayService = DisplayService,
		DebtService = DebtService,
		WarehouseService = WarehouseService,
	})
	local function snap1()
		return AuctionService.GetSnapshot().auctions[1]
	end
	EconomyService.SetCash(P, 100000)
	-- plant 24 items (L1 cap 25)
	for i = 1, 24 do
		InventoryService.AddItem(P, fakeItem(i))
	end
	pumpUntil(function()
		return snap1().state == "Bidding"
	end)
	AuctionService.TryBid(1, P, 5000, false, nil)
	pumpUntil(function()
		return snap1().state == "Rummaging"
	end, 800000)
	check(snap1().winner == "WhTest", "rig: whale wins")
	setCharPos(P, -21, 2, -6) -- at box_1 for the range gate
	AuctionService.TryOpenContainer(1, P, "box_1")
	local ok9, _ = AuctionService.TryKeepItem(1, P, nil)
	check(ok9, "T9 Keep at 24/25 succeeds")
	-- back to 25 via another keep? open box_2 (pending was consumed)
	setCharPos(P, -21, 2, 0) -- at box_2 for the range gate
	AuctionService.TryOpenContainer(1, P, "box_2")
	local ok10, msg10 = AuctionService.TryKeepItem(1, P, nil)
	check(not ok10 and string.find(tostring(msg10), "full") ~= nil, "T10 Keep at 25/25 rejected (" .. tostring(msg10) .. ")")
	-- pending still active: sell works
	local ok11, got11 = AuctionService.TrySellItem(1, P, nil)
	check(ok11 and got11 > 0, "T11 Sell works when full")
	-- now 24/25 again... sell removed pending (not inventory). Inventory still 25. Sell a bag item:
	local bagId = InventoryService.GetItems(P)[1].InstanceId
	AuctionService.TrySellItem(1, P, bagId)
	check(InventoryService.GetCount(P) == 24, "T13 setup count 24")
end

-- ================= TEST 12: grandfathered =================
do
	local G = mkPlayer("Grandpa", 402)
	local big = {}
	for i = 1, 40 do
		table.insert(big, { InstanceId = "g_" .. i, ItemId = "old_lamp", Rarity = "Common", Condition = 50, FinalValue = 60 })
	end
	storeData["player_402"] = { Cash = 100, Inventory = big, WarehouseLevel = 1 }
	PlayerDataService.Load(G)
	check(InventoryService.GetCount(G) == 40, "T12 40-item L1 inventory intact")
end

-- ================= TEST 14: slots follow level =================
do
	for lvl, want in pairs({ [1] = 6, [3] = 16, [5] = 36 }) do
		WarehouseService.RestoreLevel(P, lvl)
		local st = WarehouseService.GetWarehouseState(P)
		check(st.displaySlots == want, "T14 level " .. lvl .. " slots " .. want)
	end
	WarehouseService.RestoreLevel(P, 1)
end

-- ================= TEST 15/16: display persist + reconnect =================
do
	WarehouseService.RestoreLevel(P, 2)
	local items = InventoryService.GetItems(P)
	local okA, _ = DisplayService.AssignDisplay(P, items[1].InstanceId, 3)
	local okB, _ = DisplayService.AssignDisplay(P, items[2].InstanceId, 9)
	check(okA and okB, "T15 assignments placed (incl. overflow slot 9)")
	local snap = DisplayService.GetPersistentAssignments(P)
	check(snap[3] == items[1].InstanceId and snap[9] == items[2].InstanceId, "T15 assignments persist as id map")
	PlayerDataService.Save(P)
	local saved = storeData["player_401"]
	check(saved.WarehouseLevel == 2, "T16 level saved")
	check(saved.DisplayAssignments[3] == items[1].InstanceId, "T16 assignments saved")
	-- wipe runtime, reload
	DisplayService.ClearPlayer(P)
	WarehouseService.RestoreLevel(P, 1)
	PlayerDataService.Load(P)
	check(WarehouseService.GetLevel(P) == 2, "T16 level restored")
	local back = DisplayService.GetPersistentAssignments(P)
	check(back[3] == items[1].InstanceId and back[9] == items[2].InstanceId, "T16 assignments restored")
end

-- ================= TEST 17: different (yawed) plot =================
do
	local before = {}
	for _, d in ipairs(WarehouseService.GetWarehouseRoot(P):GetDescendants()) do
		if string.find(d.Name or "", "_Display") then
			table.insert(before, { d.Name, d.Position.X, d.Position.Z })
		end
	end
	PlotService.ReleasePlot(P)
	check(WarehouseService.GetWarehouse(P) == nil, "T23 clone destroyed on leave")
	check(PlotService.GetPlot(P) == nil, "T24 plot freed")
	local Q = mkPlayer("PlotTwo", 403)
	EconomyService.SetCash(Q, 100)
	PlayerDataService.Load(Q)
	local claimed = claimAs(Q, 1)
	check(claimed ~= nil, "T24 plot reclaimable")
	PlotService.ReleasePlot(Q)
	local plot2 = claimAs(P, 2) -- 90-degree yaw plot
	check(plot2 ~= nil, "T17 claim yawed plot")
	local after = {}
	for _, d in ipairs(WarehouseService.GetWarehouseRoot(P):GetDescendants()) do
		if string.find(d.Name or "", "_Display") then
			table.insert(after, { d.Name, d.Position.X, d.Position.Z })
		end
	end
	check(#after == #before and #after > 0, "T17 proxies rebuilt on different plot")
	local moved = false
	for _, b in ipairs(before) do
		for _, a in ipairs(after) do
			if a[1] == b[1] and (math.abs(a[2] - b[2]) > 0.01 or math.abs(a[3] - b[3]) > 0.01) then
				moved = true
			end
		end
	end
	check(moved, "T17 proxy positions follow new plot")
end

-- ================= TEST 18/19/20: sanitize =================
do
	InventoryService.RestoreItems(P, { fakeItem(900), fakeItem(901) })
	local n18 = DisplayService.RestoreAssignments(P, { [99] = fakeItem(900).InstanceId, [0] = fakeItem(901).InstanceId, ["x"] = fakeItem(900).InstanceId })
	check(n18 == 0, "T18 invalid slots dropped")
	local n19 = DisplayService.RestoreAssignments(P, { [2] = "ghost_missing_id" })
	check(n19 == 0, "T19 missing-item assignment dropped")
	local id = fakeItem(900).InstanceId
	local n20 = DisplayService.RestoreAssignments(P, { [1] = id, [2] = id })
	local kept = DisplayService.GetPersistentAssignments(P)
	local cnt = 0
	for _, _ in pairs(kept) do
		cnt += 1
	end
	check(cnt == 1, "T20 duplicate id collapsed")
end

-- ================= TEST 21/22: sell/remove display =================
do
	InventoryService.RestoreItems(P, { fakeItem(910), fakeItem(911) })
	local items = InventoryService.GetItems(P)
	DisplayService.AssignDisplay(P, items[1].InstanceId, 1)
	DisplayService.AssignDisplay(P, items[2].InstanceId, 2)
	AuctionService.TrySellItem(1, P, items[1].InstanceId) -- bag-sell path
	local after = DisplayService.GetPersistentAssignments(P)
	check(after[1] == nil and after[2] == items[2].InstanceId, "T21 sold display cleared")
	local root = WarehouseService.GetWarehouseRoot(P)
	local ghost = root and root:FindFirstChild("Slot_1_Display", true)
	check(ghost == nil, "T21 proxy destroyed")
	local okR, _ = DisplayService.RemoveDisplay(P, items[2].InstanceId)
	check(okR, "T22 remove ok")
	check(#InventoryService.GetItems(P) == 1, "T22 inventory preserved (sold item already gone)")
	check(DisplayService.GetPersistentAssignments(P)[2] == nil, "T22 assignment cleared")
end

-- ================= TEST 23/25: payload has no plot =================
do
	PlayerDataService.Save(P)
	local saved = storeData["player_401"]
	local bad = false
	for k, _ in pairs(saved) do
		local lk = string.lower(tostring(k))
		if string.find(lk, "plot") or string.find(lk, "position") or string.find(lk, "world") then
			bad = true
		end
	end
	check(not bad, "T23/25 no plot identity in payload")
end

-- ================= TEST 26/27: autosave + BindToClose =================
do
	for k, _ in pairs(setCalls) do
		setCalls[k] = nil
	end
	pumpTo(vclock + 130)
	pumpTo(vclock + 1)
	check((setCalls["player_401"] or 0) >= 1, "T26 autosave includes warehouse fields")
	check(storeData["player_401"].WarehouseLevel ~= nil and storeData["player_401"].DisplayAssignments ~= nil, "T26 autosaved record has new fields")
	for _, p in ipairs(playersSvc.GetPlayers()) do
		if PlayerDataService.IsLoaded(p) then
			PlayerDataService.Save(p)
		end
	end
	check(storeData["player_401"].WarehouseLevel ~= nil, "T27 shutdown sweep includes level")
end

check(#schedErrors == 0, "T32 no scheduler errors")
print(string.format("schedErrors=%d failures=%d", #schedErrors, failures))
if failures > 0 then
	print("WAREHOUSE-6 TEST: FAILED")
else
	print("WAREHOUSE-6 TEST: ALL PASS")
end
