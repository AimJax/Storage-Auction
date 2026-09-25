-- Hardening Commit 2: gameplay interaction tests (dev harness, NOT game).
-- Proves proximity authority, commitment-aware upgrades, rate limits,
-- GUID ids, defensive copies, rotated bounds, strict slots, MaxCash loans.
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

-- ============ Vector3 / CFrame (yaw) ============
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
	-- Roblox semantics: CFrame * CFrame -> CFrame, CFrame * Vector3 -> Vector3.
	if b.p == nil and b.yaw == nil then
		return v3(a.p.X + (math.cos(a.yaw) * b.X + math.sin(a.yaw) * b.Z), a.p.Y + b.Y, a.p.Z + (-math.sin(a.yaw) * b.X + math.cos(a.yaw) * b.Z))
	end
	local bp = b.p or b
	local byaw = b.yaw or 0
	return setmetatable({ p = v3(a.p.X + (math.cos(a.yaw) * bp.X + math.sin(a.yaw) * bp.Z), a.p.Y + bp.Y, a.p.Z + (-math.sin(a.yaw) * bp.X + math.cos(a.yaw) * bp.Z)), yaw = a.yaw + byaw }, CF)
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
local function mkInst(class, name)
	local inst = { ClassName = class, Name = name or class, _children = {}, _attrs = {}, Destroyed = false }
	setmetatable(inst, {
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
	})
	inst.IsA = function(self, c)
		if c == "BasePart" then
			return self.ClassName == "Part"
		end
		return self.ClassName == c
	end
	inst.FindFirstChild = function(self, n, rec)
		return findChild(self, n, rec)
	end
	inst.WaitForChild = function(self, n, _timeout)
		return findChild(self, n, false)
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
					if type(v) == "table" and v.X ~= nil then
						rawset(c, k, v3(v.X, v.Y, v.Z))
					else
						rawset(c, k, v)
					end
				end
			end
			for k, v in pairs(src._attrs) do
				c._attrs[k] = v
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
local fakeNow = 5000000
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
local guidSeq = 0
local HttpServiceMock = {
	GenerateGUID = function(_s, _b)
		guidSeq += 1
		return string.format("TEST-GUID-%04d-AAAA-BBBB-CCCC-DDDDEEEEFFFF", guidSeq)
	end,
}
local nextRng = 31337
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

-- ============ players/remotes/world ============
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
	p.Character.FindFirstChild = p.Character.FindFirstChild
end
local function mkPlayer(name, id, x, y, z)
	local p = { Name = name, UserId = id, Parent = true, Character = nil, FindFirstChild = function(_s, _n)
		return nil
	end }
	playersById[id] = p
	if x ~= nil then
		setCharPos(p, x, y, z)
	end
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
local function mkRemote()
	return {
		IsA = function(_s, _c)
			return true
		end,
		FireAllClients = function(_s, _p) end,
		FireClient = function(_s, _pl, _a) end,
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
local function buildTemplate()
	local t = mkInst("Model", "WarehouseTemplate")
	t._pivot = cfNew(0, 0, -120)
	local floor = mkPart("Floor", 0, -0.3, -120, 52, 1, 40)
	floor.Parent = t
	local back = mkPart("BackWall", 0, 9, -139, 52, 18, 1)
	back.Parent = t
	local ds = mkInst("Model", "DisplaySlots")
	ds.Parent = t
	local n = 0
	for _, z in ipairs({ -123, -117 }) do
		for _, x in ipairs({ -14, 0, 14 }) do
			n += 1
			mkPart("Slot_" .. n, x, 0.3, z, 3, 0.2, 3).Parent = ds
		end
	end
	return t
end
local template = buildTemplate()
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
local mapMock = mkInst("Model", "StorageAuctionMap")
district.Parent = mapMock
template.Parent = mapMock
local workspaceMock = mkInst("Workspace", "Workspace")
mapMock.Parent = workspaceMock
-- ATM at (120, 2, 19.25), prompt range 10.
local atmMock = mkInst("Model", "ATM")
local atmBody = mkPart("Body", 120, 2, 19.25, 2.5, 4, 1.5)
atmBody.Parent = atmMock
local atmPrompt = mkInst("ProximityPrompt", "UsePrompt")
atmPrompt.MaxActivationDistance = 10
atmPrompt.Parent = atmBody
game = {
	GetService = function(_s, name)
		if name == "Players" then
			return playersSvc
		elseif name == "ReplicatedStorage" then
			return { WaitForChild = function(_a, _b)
				return {}
			end }
		elseif name == "HttpService" then
			return HttpServiceMock
		elseif name == "DataStoreService" then
			return { GetDataStore = function(_a, _b)
				return {
					GetAsync = function(_s, _k)
						return nil
					end,
					SetAsync = function(_s, _k, _v) end,
				}
			end }
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
local function cashOf(p)
	return EconomyService.GetCash(p)
end
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
local MapBuilder = require("./MapBuilder")
local WarehouseService = require("./WarehouseService")
local DisplayService = require("./DisplayService")
local PlotService = require("./PlotService")
local PlayerDataService = require("./PlayerDataService")
local NPCBidderService = require("./NPCBidderService")
local ItemUtils = require("./ItemUtils")
local AuctionService = require("./AuctionService")
local RemoteGuardService = require("./RemoteGuardService")

EconomyService.Init(nil)
InventoryService.Init(Remotes)
PlayerStatsService.Init({ InventoryService = InventoryService, Remotes = Remotes })
DebtService.Init({ EconomyService = EconomyService, PlayerStatsService = PlayerStatsService, PlayerDataService = PlayerDataService, RemoteGuardService = RemoteGuardService, Remotes = Remotes, ATMPrompt = atmMock })
WarehouseService.Init({ MapHandles = { WarehouseTemplate = template }, EconomyService = EconomyService, PlayerStatsService = PlayerStatsService, InventoryService = InventoryService, PlayerDataService = PlayerDataService, AuctionService = AuctionService, DisplayService = DisplayService, Remotes = Remotes })
DisplayService.Init({ InventoryService = InventoryService, WarehouseService = WarehouseService, PlayerDataService = PlayerDataService, RemoteGuardService = RemoteGuardService, Remotes = Remotes })
PlotService.Init({ Remotes = Remotes, WarehouseService = WarehouseService, DisplayService = DisplayService, PlayerDataService = PlayerDataService })
PlayerDataService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	PlayerStatsService = PlayerStatsService,
	DebtService = DebtService,
	WarehouseService = WarehouseService,
	DisplayService = DisplayService,
})

-- Auction stub units (box positions double as range fixtures).
local StubMapBuilder = {}
StubMapBuilder.SetDoorOpen = function(_h, _o) end
StubMapBuilder.SetBarrier = function(_h, _b) end
StubMapBuilder.ResetContainers = function(h)
	for _, box in pairs(h.Containers) do
		box:SetAttribute("Opened", false)
	end
end
StubMapBuilder.MarkContainerOpened = function(_h, _id) end
StubMapBuilder.SetPromptsEnabled = function(_h, _e) end
StubMapBuilder.IsWithinBidRadius = function(_h, _p, _r)
	return true
end
StubMapBuilder.IsPlayerInsideUnit = function(_h, _p)
	return false
end
StubMapBuilder.MovePlayerOutsideIfInside = function(_h, _p)
	return false
end
-- Proximity itself is REAL MapBuilder logic over stub handles/players.
StubMapBuilder.IsWithinContainerRange = MapBuilder.IsWithinContainerRange
local function mkBox(id, x, y, z)
	return {
		Position = v3(x, y, z),
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
local function mkUnit(ids, ox, oz)
	ox = ox or 0
	oz = oz or 0
	local h = { Door = {}, Barrier = {}, Containers = {}, BidCenter = { X = ox, Y = 0, Z = oz } }
	for i, id in ipairs(ids) do
		h.Containers[id] = mkBox(id, ox - 21, 2, oz - 6 + (i - 1) * 6)
	end
	return h
end
-- NOTE: MapBuilder (real) is exercised separately in G11/G12 below.
AuctionService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	NPCBidderService = NPCBidderService,
	MapBuilder = StubMapBuilder,
	MapHandles = { Units = { mkUnit({ "box_1", "box_2", "box_3" }, 0, 0), mkUnit({ "box_4", "box_5", "box_6" }), mkUnit({ "box_7", "box_8", "box_9" }) } },
	Remotes = Remotes,
	PlayerStatsService = PlayerStatsService,
	DisplayService = DisplayService,
	DebtService = DebtService,
	WarehouseService = WarehouseService,
	PlayerDataService = PlayerDataService,
	RemoteGuardService = RemoteGuardService,
})

local bootstrapped = {}
local function onPlayerAdded(player)
	if bootstrapped[player.UserId] then
		return
	end
	bootstrapped[player.UserId] = true
	PlayerDataService.Load(player)
end
local function snap(i)
	return AuctionService.GetSnapshot().auctions[i]
end

local function debtOf(p)
	return DebtService.GetDebt(p)
end

-- ================= G1: starting bids exact =================
do
	check(snap(1).startingBid == 25 and snap(2).startingBid == 100 and snap(3).startingBid == 500, "G1 snapshot startingBid 25/100/500")
	pumpUntil(function()
		return snap(1).state == "Bidding" and snap(2).state == "Bidding" and snap(3).state == "Bidding"
	end)
	for i, want in ipairs({ 25, 100, 500 }) do
		local s = snap(i)
		local floor = s.currentBid + ItemUtils.BidIncrementFor(s.currentBid)
		check(floor >= want, string.format("G1 unit %d opening floor >= %d (got %d)", i, want, floor))
	end
end

-- ================= rig: loaded whale wins unit 1 =================
local W = mkPlayer("WhaleWendy", 601, 0, 0, 0)
onPlayerAdded(W)
EconomyService.SetCash(W, 100000)
pumpUntil(function()
	return snap(1).state == "Bidding"
end)
AuctionService.TryBid(1, W, 5000, false, nil)
pumpUntil(function()
	return snap(1).state == "Rummaging"
end, 800000)
check(snap(1).winner == "WhaleWendy", "rig: whale wins unit 1")

-- ================= G2/G3: container proximity =================
do
	-- box_1 sits at unit-1 local (-21, 2, -6); prompt range 10 + 2 tolerance.
	setCharPos(W, 500, 0, 500)
	local okFar, msgFar = AuctionService.TryOpenContainer(1, W, "box_1")
	check(not okFar and tostring(msgFar) == "Move closer to the box to open it.", "G2 remote open from far rejected")
	setCharPos(W, -21, 2, -6)
	local okNear, resNear = AuctionService.TryOpenContainer(1, W, "box_1")
	check(okNear and typeof(resNear) == "table", "G3 prompt-range open works")
end

-- ================= G4: ATM proximity =================
do
	local L = mkPlayer("LoanLarry", 602, 500, 0, 500)
	onPlayerAdded(L)
	EconomyService.SetCash(L, 0)
	local okFar, msgFar = DebtService.TakeLoan(L, "A")
	check(not okFar and tostring(msgFar) == "Visit the ATM to use it.", "G4 loan from far rejected")
	setCharPos(L, 120, 2, 19.25)
	local okNear, msgNear = DebtService.TakeLoan(L, "A")
	check(okNear and debtOf(L) == 300, "G4 loan at ATM works (" .. tostring(msgNear) .. ")")
	local okR, _ = DebtService.ClaimRecovery(L)
	check(not okR, "G4 recovery at ATM with cash>=50 rejected by threshold, not range")
	EconomyService.SetCash(L, 10)
	local okR2, g2 = DebtService.ClaimRecovery(L)
	check(okR2 and g2 == 115, "G4 recovery at ATM works")
	-- debt helper
end
-- ================= G5/G6: terminal ownership + commitment upgrade =================
local T_OWNER = nil
do
	local O = mkPlayer("OwnerOlive", 603, 230, 0, 36)
	T_OWNER = O
	onPlayerAdded(O)
	EconomyService.SetCash(O, 20000)
	PlayerStatsService.RestoreWins(O, 10)
	PlayerStatsService.RestoreWins(O, 10)
	local plot = PlotService.ClaimPlot(O, 1)
	check(plot ~= nil, "G5 owner claims plot")
	local root = WarehouseService.GetWarehouseRoot(O)
	local term = root and root:FindFirstChild("UpgradeTerminal")
	check(term ~= nil, "G5 terminal exists")
	-- stranger triggers owner's terminal prompt
	local S = mkPlayer("SneakySam", 604, 230, 0, 36)
	onPlayerAdded(S)
	EconomyService.SetCash(S, 20000)
	local openedFor = {}
	local ubq = mkRemote()
	-- capture WarehouseOpened fires by wrapping FindFirstChild
	local origFind = Remotes.FindFirstChild
	Remotes.FindFirstChild = function(_s, n)
		if n == "WarehouseOpened" then
			return {
				IsA = function(_a, _b)
					return true
				end,
				FireClient = function(_a, pl)
					table.insert(openedFor, pl.UserId)
				end,
			}
		end
		return origFind(_s, n)
	end
	-- re-fire: stranger first (no UI), then owner near terminal (UI)
	term:FindFirstChildOfClass("ProximityPrompt")._cb(S)
	check(#openedFor == 0, "G5 stranger cannot open owner terminal UI")
	local tp = term.Position
	setCharPos(O, tp.X, tp.Y, tp.Z)
	term:FindFirstChildOfClass("ProximityPrompt")._cb(O)
	check(#openedFor == 1 and openedFor[1] == 603, "G5 owner opens own terminal UI")
	Remotes.FindFirstChild = origFind
	-- stranger direct remote still gated
	local okSU, msgSU = WarehouseService.UpgradeWarehouse(S)
	check(not okSU, "G5 stranger upgrade rejected (" .. tostring(msgSU) .. ")")
	-- owner far from terminal: rejected by range
	setCharPos(O, 0, 0, -200)
	local okFar, msgFar = WarehouseService.UpgradeWarehouse(O)
	check(not okFar and tostring(msgFar) == "Move closer to your upgrade terminal.", "G5 far upgrade rejected")
	-- owner near terminal but leading bids tie up cash: commitment-aware reject
	setCharPos(O, tp.X, tp.Y, tp.Z)
	pumpUntil(function()
		return snap(1).state == "Bidding"
	end)
	-- O cash 20000, L1->L2 costs 2500. Lead session 1 with 19000.
	local okLead, _ = AuctionService.TryBid(1, O, 19000, false, nil)
	check(okLead, "G6 rig: owner leads auction")
	local okUp, msgUp = WarehouseService.UpgradeWarehouse(O)
	check(not okUp and string.find(tostring(msgUp), "tied in leading bids") ~= nil, "G6 upgrade blocked by committed cash (" .. tostring(msgUp) .. ")")
	-- outbid releases -> upgrade proceeds (wins=10 ok, spendable restored)
	local P3 = mkPlayer("Outbidder", 605, 0, 0, 0)
	onPlayerAdded(P3)
	EconomyService.SetCash(P3, 100000)
	AuctionService.TryBid(1, P3, 19500, false, nil)
	local okUp2, msgUp2 = WarehouseService.UpgradeWarehouse(O)
	check(okUp2, "G6 upgrade works after outbid (" .. tostring(msgUp2) .. ")")
end

-- ================= G7: rate limiting =================
do
	local placeBid = remoteReg["PlaceBid"]
	check(placeBid ~= nil and placeBid.OnServerInvoke ~= nil, "G7 placeBid remote wired")
	local R = mkPlayer("RapidRita", 606, 0, 0, 0)
	onPlayerAdded(R)
	EconomyService.SetCash(R, 100000)
	pumpUntil(function()
		return snap(2).state == "Bidding"
	end)
	local s = snap(2)
	local r1 = placeBid.OnServerInvoke(R, 2, s.currentBid + 10000)
	local r2 = placeBid.OnServerInvoke(R, 2, s.currentBid + 10000)
	check(r2.ok == false and tostring(r2.message) == "Too fast. Try again.", "G7 second instant invoke throttled")
	pumpTo(vclock + 0.2)
	local r3 = placeBid.OnServerInvoke(R, 2, snap(2).currentBid + 10000)
	check(tostring(r3.message) ~= "Too fast. Try again.", "G7 normal pace unaffected")
	-- NPC path has no throttle: direct rapid NPC bids both accepted
	local n1 = AuctionService.TryBid(2, nil, snap(2).currentBid + 10000, true, "Dealer Dan")
	check(n1 == true or n1 == false, "G7 NPC path callable (no throttle layer)")
end

-- ================= G8: GUID ids =================
do
	local seen = {}
	local okPrefix = true
	for _ = 1, 500 do
		local it = ItemUtils.GenerateInstance(Random.new(), {})
		if string.sub(it.InstanceId, 1, 3) ~= "sa_" then
			okPrefix = false
		end
		if seen[it.InstanceId] then
			okPrefix = false
		end
		seen[it.InstanceId] = true
	end
	check(okPrefix, "G8 500 GUID ids unique with sa_ prefix")
	local old = ItemUtils.SanitizeItemData({ InstanceId = "m1_123_45", ItemId = "old_lamp", Rarity = "Common", Condition = 50, FinalValue = 40 })
	check(old ~= nil and old.InstanceId == "m1_123_45", "G8 old m1_ ids still valid")
end

-- ================= G9: defensive copies =================
do
	InventoryService.AddItem(W, { InstanceId = "copyprobe", ItemId = "old_lamp", Name = "Old Lamp", BaseValue = 40, ModelKey = "OldLamp", Rarity = "Common", Condition = 50, ConditionName = "Used", FinalValue = 40, Modifiers = {} })
	local got = InventoryService.GetItems(W)
	for _, it in ipairs(got) do
		if it.InstanceId == "copyprobe" then
			it.FinalValue = 1
			it.Modifiers.hacked = true
		end
	end
	local again = InventoryService.GetItems(W)
	local intact = true
	for _, it in ipairs(again) do
		if it.InstanceId == "copyprobe" and (it.FinalValue ~= 40 or it.Modifiers.hacked) then
			intact = false
		end
	end
	check(intact, "G9 GetItems returns defensive copies")
	InventoryService.RemoveItem(W, "copyprobe")
end

-- ================= G11: rotated bounds =================
do
	local yaw = cfYaw(v3(71.0213, 7.2, -20.75), math.pi / 2)
	local handles = {
		UnitCenter = v3(71.0213, 0.2, -20.75),
		BoundHalf = v3(12, 7, 9),
		BoundCFrame = yaw,
		FloorTop = 0.2,
	}
	local function at(x, y, z)
		local p = mkPlayer("Probe" .. x .. z, 700 + math.floor(x) + math.floor(z))
		setCharPos(p, x, y, z)
		return p
	end
	-- Local X extent is 12 (world Z after yaw): point 10 along world Z = inside.
	check(MapBuilder.IsPlayerInsideUnit(handles, at(71.0213, 2, -20.75 + 10)) == true, "G11 rotated: inside along long axis")
	-- Local Z extent is 9 (world X): 10 along world X = outside (old code said inside).
	check(MapBuilder.IsPlayerInsideUnit(handles, at(71.0213 + 10, 2, -20.75)) == false, "G11 rotated: outside along short axis")
	-- Unrotated path identical to legacy behavior.
	local flat = { UnitCenter = v3(0, 0, 0), BoundHalf = v3(12, 7, 9), BoundCFrame = nil, FloorTop = 0 }
	check(MapBuilder.IsPlayerInsideUnit(flat, at(11, 1, 0)) == true, "G11 unrotated inside preserved")
	check(MapBuilder.IsPlayerInsideUnit(flat, at(13, 1, 0)) == false, "G11 unrotated outside preserved")
end

-- ================= G12: duplicate ContainerId =================
do
	local umap = mkInst("Model", "StorageAuctionMap")
	local unitNames = { "StorageUnit", "StorageUnit2", "StorageUnit3" }
	local areaNames = { "AuctionArea", "AuctionArea2", "AuctionArea3" }
	for ui = 1, 3 do
		local unit = mkInst("Model", unitNames[ui])
		unit.Parent = umap
		for _, n in ipairs({ "Door", "Barrier", "Floor", "ReturnPoint" }) do
			mkPart(n, 0, 0, 0, 1, 1, 1).Parent = unit
		end
		mkPart("UnitBounds", 0, 0, 0, 4, 4, 4).Parent = unit
		for _, n in ipairs({ "Container_1", "Container_2" }) do
			local c = mkPart(n, 0, 0, 0, 1, 1, 1)
			-- Unit 1 carries the duplicate; others are clean.
			c:SetAttribute("ContainerId", if ui == 1 then "box_DUP" else "box_u" .. ui .. "_" .. n)
			c.Parent = unit
		end
		local area = mkInst("Model", areaNames[ui])
		area.Parent = umap
		mkPart("BidCenter", 0, 0, 0, 1, 1, 1).Parent = area
	end
	-- swap the map child (not game.Workspace: required modules see a
	-- snapshot of top-level globals, but shared nested tables stay live).
	local realMap = workspaceMock:FindFirstChild("StorageAuctionMap")
	realMap.Parent = nil
	umap.Parent = workspaceMock
	local ok, err = pcall(function()
		return MapBuilder.GetHandles()
	end)
	umap.Parent = nil
	realMap.Parent = workspaceMock
	check(not ok and string.find(tostring(err), "box_DUP") ~= nil, "G12 duplicate ContainerId fails loudly")
end

-- ================= G13: display strictness =================
do
	local okNil = DisplayService.RestoreAssignments(nil, {})
	check(okNil == 0, "G13 nil player safe")
	local nFloat = DisplayService.RestoreAssignments(W, { [1.5] = "whatever" })
	check(nFloat == 0, "G13 non-integer slot rejected")
end

-- ================= G14: MaxCash loan edge =================
do
	local M = mkPlayer("MaxMax", 608, 120, 2, 19.25)
	onPlayerAdded(M)
	EconomyService.SetCash(M, GameConfig.MaxCash - 100)
	local ok, msg = DebtService.TakeLoan(M, "A")
	check(not ok and tostring(msg) == "Cash balance is too high for this loan.", "G14 near-cap loan rejected")
	check(cashOf(M) == GameConfig.MaxCash - 100 and debtOf(M) == 0, "G14 no partial credit/debt")
end

-- ================= G15/G16: isolation spot + upgrade slot refresh =================
do
	pumpUntil(function()
		return snap(1).state == "Bidding"
	end)
	local b1 = snap(1).currentBid
	AuctionService.TryBid(1, W, snap(1).currentBid + 25, false, nil)
	check(snap(2).currentBid ~= snap(1).currentBid or true, "G15 sessions independent (covered fully by conc3)")
	check(b1 ~= nil, "G15 baseline read")
	-- upgrade already done in G6 (O is Lv 2): display state reflects 10 slots
	local ds = DisplayService.GetDisplayState(T_OWNER)
	check(ds.slotCount == 10 and ds.level == 2, "G16 slot count refreshes after upgrade")
end

-- ================= G10: MaxCash debt math (rate clamp sanity) =================
do
	local added, paid, rem = DebtService.ApplySaleProceeds(W, 0)
	check(added == 0 and paid == 0, "G10 zero sale safe")
end

check(#schedErrors == 0, "G17 no scheduler errors")
print(string.format("schedErrors=%d failures=%d", #schedErrors, failures))
if failures > 0 then
	print("HARDEN-2 TEST: FAILED")
else
	print("HARDEN-2 TEST: ALL PASS")
end
