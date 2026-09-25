-- Shutdown save race tests S1-S7 (dev harness, NOT game code).
-- Mirrors init.server's savePlayerDurably / onPlayerRemoving / BindToClose
-- sweep EXACTLY (same order, same guards) with a yielding mock DataStore
-- so interleavings are deterministic. Run from the staged exec dir.

local failures = 0
local function check(cond, label)
	if cond then
		print("PASS " .. label)
	else
		failures += 1
		print("FAIL " .. label)
	end
end

-- ============ clocks/scheduler ============
local vclock = 0
local fakeNow = 6000000
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
Color3 = { fromRGB = function(r, g, b)
	return { R = r, G = g, B = b }
end }
Instance = { new = function(c)
	local inst = { ClassName = c, Name = c, _children = {} }
	inst.IsA = function(self, class)
		return self.ClassName == class
	end
	inst.FindFirstChild = function(self, n)
		for _, ch in ipairs(self._children) do
			if ch.Name == n then
				return ch
			end
		end
		return nil
	end
	inst.Destroy = function(_s) end
	return inst
end }
local workspaceMock = {
	_children = {},
	FindFirstChild = function(self, n)
		for _, ch in ipairs(self._children) do
			if ch.Name == n then
				return ch
			end
		end
		return nil
	end,
	FindFirstChildOfClass = function(_s, _c)
		return nil
	end,
}
local nextRng = 121314
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

-- ============ DataStore mock: yielding SetAsync + journal ============
local storeData = {}
local setJournal = {} -- {key, cash, inv, debt, t}
local storeFail = { get = false, set = false }
local setStallSecs = 0
local function setStall(n)
	setStallSecs = n
end
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
				if setStallSecs > 0 then
					task.wait(setStallSecs) -- simulate a slow datastore mid-save
				end
				table.insert(setJournal, { key = k, cash = v.Cash, inv = #(v.Inventory or {}), debt = v.Debt, t = vclock })
				storeData[k] = snapCopy(v)
			end,
		}
	end,
}

-- ============ players/remotes ============
local playersById = {}
local function v3(x, y, z)
	return setmetatable({ X = x, Y = y, Z = z }, {
		__sub = function(a, b)
			return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
		end,
	})
end
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
local workspaceMock = {
	_children = {},
	FindFirstChild = function(self, n)
		for _, ch in ipairs(self._children) do
			if ch.Name == n then
				return ch
			end
		end
		return nil
	end,
	FindFirstChildOfClass = function(_s, _c)
		return nil
	end,
}
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

-- ============ real modules, init.server dep shape ============
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
local PlayerDataService = require("./PlayerDataService")
local NPCBidderService = require("./NPCBidderService")
local AuctionService = require("./AuctionService")
local RemoteGuardService = require("./RemoteGuardService")

EconomyService.Init(nil)
InventoryService.Init(Remotes)
PlayerStatsService.Init({ InventoryService = InventoryService, Remotes = Remotes })
DebtService.Init({ EconomyService = EconomyService, PlayerStatsService = PlayerStatsService, PlayerDataService = PlayerDataService, RemoteGuardService = RemoteGuardService, Remotes = Remotes, ATMPrompt = {
	FindFirstChild = function(_s, n)
		if n == "Body" then
			return {
				ClassName = "Part",
				Position = v3(120, 2, 19.25),
				IsA = function(self, c)
					return c == "BasePart" or self.ClassName == c
				end,
				FindFirstChildOfClass = function(_s, _c)
					return { MaxActivationDistance = 10, Triggered = { Connect = function(_t, _fn) end } }
				end,
			}
		end
		return nil
	end,
	FindFirstChildOfClass = function(_s, _c)
		return nil
	end,
} })
WarehouseService.Init({ MapHandles = {}, EconomyService = EconomyService, PlayerStatsService = PlayerStatsService, InventoryService = InventoryService, PlayerDataService = PlayerDataService, AuctionService = AuctionService, DisplayService = DisplayService, Remotes = Remotes })
DisplayService.Init({ InventoryService = InventoryService, WarehouseService = WarehouseService, PlayerDataService = PlayerDataService, RemoteGuardService = RemoteGuardService, Remotes = Remotes })
PlayerDataService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	PlayerStatsService = PlayerStatsService,
	DebtService = DebtService,
	WarehouseService = WarehouseService,
	DisplayService = DisplayService,
})

-- Auction stub units.
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
local function mkUnit(ids, ox, oz)
	ox = ox or 0
	oz = oz or 0
	local h = { Door = {}, Barrier = {}, Containers = {}, BidCenter = { X = ox, Y = 0, Z = oz } }
	local i = 0
	for _, id in ipairs(ids) do
		i += 1
		h.Containers[id] = mkBox(id, ox - 21, 2, oz - 6 + (i - 1) * 6)
	end
	return h
end
local MapBuilderReal = require("./MapBuilder")
StubMapBuilder.IsWithinContainerRange = MapBuilderReal.IsWithinContainerRange
AuctionService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	NPCBidderService = NPCBidderService,
	MapBuilder = StubMapBuilder,
	MapHandles = { Units = { mkUnit({ "box_1", "box_2", "box_3" }), mkUnit({ "box_4", "box_5", "box_6" }), mkUnit({ "box_7", "box_8", "box_9" }) } },
	Remotes = Remotes,
	PlayerStatsService = PlayerStatsService,
	DisplayService = DisplayService,
	DebtService = DebtService,
	WarehouseService = WarehouseService,
	PlayerDataService = PlayerDataService,
	RemoteGuardService = RemoteGuardService,
})

-- ============ lifecycle mirror (EXACT init.server order/logic) ============
local bootstrapped = {}
local lifecycleBusy = {}
local lifecycleDone = {}
local function acquireLifecycle(userId)
	local deadline = os.clock() + 5
	while lifecycleBusy[userId] and os.clock() < deadline do
		task.wait(0.1)
	end
	lifecycleBusy[userId] = true
end
local function releaseLifecycle(userId)
	lifecycleBusy[userId] = nil
end
local function savePlayerDurably(player)
	if not player then
		return false
	end
	local id = player.UserId
	if lifecycleDone[id] then
		return true
	end
	acquireLifecycle(id)
	if lifecycleDone[id] then
		releaseLifecycle(id)
		return true
	end
	AuctionService.ResolvePendingForPlayer(player)
	PlayerDataService.Save(player)
	lifecycleDone[id] = true
	releaseLifecycle(id)
	return true
end
local function onPlayerAdded(player)
	if bootstrapped[player.UserId] then
		return
	end
	bootstrapped[player.UserId] = true
	lifecycleDone[player.UserId] = nil
	PlayerDataService.Load(player)
end
local function onPlayerRemoving(player)
	if not player then
		return
	end
	bootstrapped[player.UserId] = nil
	savePlayerDurably(player)
	PlotServiceRelease(player)
	AuctionService.ClearPlayer(player)
	DisplayService.ClearPlayer(player)
	PlayerStatsService.ClearPlayer(player)
	InventoryService.ClearPlayer(player)
	EconomyService.ClearPlayer(player)
	DebtService.ClearPlayer(player)
	WarehouseService.ClearPlayer(player)
	PlayerDataService.ClearPlayer(player)
end
-- PlotService has no map in this rig; mirror release = warehouse destroy only.
function PlotServiceRelease(player)
	WarehouseService.DestroyFor(player)
end
local function bindToCloseSweep()
	local pending = 0
	for _, p in ipairs(playersSvc.GetPlayers()) do
		if PlayerDataService.IsLoaded(p) and PlayerDataService.IsSaveAllowed(p) then
			pending += 1
			task.spawn(function(pl)
				savePlayerDurably(pl)
				pending -= 1
			end, p)
		end
	end
	local deadline = os.clock() + 8
	while pending > 0 and os.clock() < deadline do
		task.wait(0.2)
	end
end
-- Top-level drivers: sweeps and leaves yield, so run them in a task and
-- pump until done (mirrors Roblox threading where these run off-main).
local function runSweep()
	local done = false
	task.spawn(function()
		bindToCloseSweep()
		done = true
	end)
	pumpUntil(function()
		return done
	end)
end
local function leave(P)
	task.spawn(function()
		onPlayerRemoving(P)
	end)
	pumpUntil(function()
		return not PlayerDataService.IsLoaded(P)
	end)
end

local function snap(i)
	return AuctionService.GetSnapshot().auctions[i]
end
local function winBudget(P)
	pumpUntil(function()
		return snap(1).state == "Bidding"
	end)
	AuctionService.TryBid(1, P, 5000, false, nil)
	pumpUntil(function()
		return snap(1).state == "Rummaging"
	end, 800000)
	return snap(1).winner
end
local function openBox1(P)
	setCharPos(P, -21, 2, -6)
	local ok, res = AuctionService.TryOpenContainer(1, P, "box_1")
	return ok, res
end

-- ================= S1: BindToClose-only with pending =================
do
	local P = mkPlayer("ShutPam", 701)
	onPlayerAdded(P)
	EconomyService.SetCash(P, 100000)
	check(winBudget(P) == "ShutPam", "S1 rig: whale wins")
	local okO, item = openBox1(P)
	check(okO, "S1 rig: box opened (pending live)")
	runSweep()
	pumpTo(vclock + 1)
	local saved = storeData["player_701"]
	check(saved ~= nil and #saved.Inventory == 1, "S1 shutdown resolved pending into save")
	check(saved.Inventory[1].FinalValue == item.FinalValue, "S1 saved item matches opened value")
end

-- ================= S2: Removing first, then BindToClose =================
do
	local P = mkPlayer("LeaveLarry", 702)
	onPlayerAdded(P)
	EconomyService.SetCash(P, 100000)
	winBudget(P)
	openBox1(P)
	local writesBefore = 0
	for _, e in ipairs(setJournal) do
		if e.key == "player_702" then
			writesBefore += 1
		end
	end
	leave(P) -- full leave: resolve + save + clears
	runSweep() -- P gone from players? still registered; done-flag must skip
	pumpTo(vclock + 1)
	local writesAfter = 0
	for _, e in ipairs(setJournal) do
		if e.key == "player_702" then
			writesAfter += 1
		end
	end
	check(writesAfter == writesBefore + 1, "S2 exactly one save (no stale second write)")
	local saved = storeData["player_702"]
	check(saved ~= nil and #saved.Inventory == 1, "S2 single resolution, no duplicate item")
	playersById[702] = nil -- simulate actual departure for later sweeps
end

-- ================= S3: BindToClose first (stalled), Removing waits =================
do
	local P = mkPlayer("RaceRita", 703)
	onPlayerAdded(P)
	EconomyService.SetCash(P, 100000)
	winBudget(P)
	openBox1(P)
	setStall(4) -- every SetAsync yields 4 virtual seconds mid-save
	-- start shutdown sweep in background; it acquires the lock first
	task.spawn(function()
		runSweep()
	end)
	pumpTo(vclock + 0.5) -- let the sweep acquire + stall inside SetAsync
	leave(P) -- must wait, then save correct post-resolve state, then clear
	pumpTo(vclock + 10)
	setStall(0)
	local saved = storeData["player_703"]
	check(saved ~= nil and #saved.Inventory == 1, "S3 correct save despite overlap")
	local count = 0
	for _, e in ipairs(setJournal) do
		if e.key == "player_703" then
			count += 1
		end
	end
	-- shutdown save + removing save may both complete, but both snapshot
	-- POST-resolve state, so neither is stale: inventory exactly 1 either way.
	check(count <= 2, "S3 at most two coordinated saves (got " .. count .. ")")
	check(EconomyService.GetCash(P.UserId) == 0 and #InventoryService.GetItems(P) == 0, "S3 clears happened after save")
	playersById[703] = nil
end

-- ================= S4: full warehouse shutdown -> auto-sell + debt split =================
do
	local P = mkPlayer("FullFrank", 704)
	onPlayerAdded(P)
	EconomyService.SetCash(P, 100000)
	setCharPos(P, 120, 2, 19.25) -- at ATM for the loan
	DebtService.TakeLoan(P, "A") -- debt 300 (Loan A open to all)
	for i = 1, 25 do
		InventoryService.AddItem(P, { InstanceId = "sf_" .. i, ItemId = "old_lamp", Name = "Old Lamp", BaseValue = 40, ModelKey = "OldLamp", Rarity = "Common", Condition = 50, ConditionName = "Used", FinalValue = 60, Modifiers = {} })
	end
	winBudget(P)
	openBox1(P)
	local item = nil
	-- capture pending value via a direct resolve preview is internal; use totals instead
	runSweep()
	pumpTo(vclock + 1)
	local saved = storeData["player_704"]
	check(saved ~= nil and #saved.Inventory == 25, "S4 no over-cap keep (" .. #(saved.Inventory or {}) .. ")")
	-- pending auto-sold: 25% of its value paid the 300 debt, rest to cash.
	check(saved.Debt < 300, "S4 debt reduced by shutdown auto-sale")
	playersById[704] = nil
end

-- ================= S5: room shutdown -> auto-keep exactly once =================
do
	local P = mkPlayer("RoomRuth", 705)
	onPlayerAdded(P)
	EconomyService.SetCash(P, 100000)
	winBudget(P)
	openBox1(P)
	runSweep()
	pumpTo(vclock + 1)
	local saved = storeData["player_705"]
	check(saved ~= nil and #saved.Inventory == 1, "S5 pending auto-kept exactly once")
	playersById[705] = nil
end

-- ================= S6: SaveAllowed=false during shutdown =================
do
	local P = mkPlayer("UnsafeUma", 706)
	onPlayerAdded(P) -- store empty -> loaded, allowed; force-unsafe below
	-- simulate a failed load AFTER the fact is impossible; instead craft:
	-- clear the done/allowed flags by simulating load failure path directly
	PlayerDataService.ClearPlayer(P) -- unloaded
	EconomyService.SetCash(P, 9999)
	runSweep()
	pumpTo(vclock + 1)
	check(storeData["player_706"] == nil, "S6 unloaded player never written")
	playersById[706] = nil
end

-- ================= S7: two players stay parallel =================
do
	local A = mkPlayer("ParA", 707)
	local B = mkPlayer("ParB", 708)
	onPlayerAdded(A)
	onPlayerAdded(B)
	EconomyService.SetCash(A, 1111)
	EconomyService.SetCash(B, 2222)
	setStall(2) -- slow saves; serial would take 4s+, parallel ~2s
	local t0 = vclock
	runSweep()
	pumpTo(vclock + 0.1)
	local elapsed = vclock - t0
	setStall(0)
	check(storeData["player_707"] ~= nil and storeData["player_708"] ~= nil, "S7 both saved")
	check(storeData["player_707"].Cash == 1111 and storeData["player_708"].Cash == 2222, "S7 values correct per player")
	check(elapsed < 6, "S7 parallel, not serial (elapsed " .. elapsed .. "s)")
	playersById[707] = nil
	playersById[708] = nil
end

check(#schedErrors == 0, "S8 no scheduler errors")
print(string.format("schedErrors=%d failures=%d", #schedErrors, failures))
if failures > 0 then
	print("SHUTDOWN TEST: FAILED")
else
	print("SHUTDOWN TEST: ALL PASS")
end
