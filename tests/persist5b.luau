-- Stage 5B: persistence tests TEST 1-26 (dev harness, NOT game code).
-- Uses REAL staged PlayerDataService/EconomyService/InventoryService/
-- PlayerStatsService/DebtService/AuctionService with a mock DataStore.
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

-- ============ clocks/scheduler ============
local vclock = 0
local fakeNow = 2000000
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
	inst.SetParent = nil
	return setmetatable(inst, {
		__newindex = function(t, k, v)
			if k == "Parent" and v ~= nil and type(v) == "table" and v._children ~= nil then
				table.insert(v._children, t)
			end
			rawset(t, k, v)
		end,
	})
end }
local nextRng = 777001
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

-- ============ mock DataStore ============
local storeData = {}
local storeFail = { get = false, set = false }
local setCalls = {}
local storeNameSeen = nil
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
local DataStoreServiceMock = {
	GetDataStore = function(_s, name)
		storeNameSeen = name
		return {
			GetAsync = function(_self, k)
				if storeFail.get then
					error("db down (get)")
				end
				return snapCopy(storeData[k])
			end,
			SetAsync = function(_self, k, v)
				if storeFail.set then
					error("db down (set)")
				end
				setCalls[k] = (setCalls[k] or 0) + 1
				storeData[k] = snapCopy(v)
			end,
		}
	end,
}

-- ============ mock players/services ============
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
-- Everyone starts at the ATM; recovery tests need proximity.
local function mkPlayer(name, id)
	local p = { Name = name, UserId = id, Parent = true, FindFirstChild = function(_s, _n)
		return nil
	end }
	playersById[id] = p
	setCharPos(p, 120, 2, 19.25)
	return p
end
local ATMBody = {
	ClassName = "Part",
	Position = v3(120, 2, 19.25),
	IsA = function(self, c)
		return c == "BasePart" or self.ClassName == c
	end,
	FindFirstChildOfClass = function(_s, _c)
		return { MaxActivationDistance = 10, Triggered = { Connect = function(_t, _fn) end } }
	end,
}
local ATMMock = {
	FindFirstChild = function(_s, n)
		if n == "Body" then
			return ATMBody
		end
		return nil
	end,
	FindFirstChildOfClass = function(_s, _c)
		return nil
	end,
}
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
game = {
	GetService = function(_s, name)
		if name == "Players" then
			return playersSvc
		elseif name == "ReplicatedStorage" then
			return { WaitForChild = function(_a, _b)
				return {}
			end }
		elseif name == "DataStoreService" then
			return DataStoreServiceMock
		end
		error("unexpected service " .. tostring(name))
	end,
	Workspace = {},
}

local GameConfig = require("./GameConfig")
local RealEconomyService = require("./EconomyService")
-- Mock players are tables, not Instances: unwrap reads to UserId (game code
-- is correct for real Instances; writers already use .UserId).
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
local PlayerDataService = require("./PlayerDataService")
local SA_AuctionService = require("./AuctionService")
local SA_DebtService2 = require("./DebtService")

check(storeNameSeen == "SA_M1_v1", "store name reused (SA_M1_v1)")

EconomyService.Init(nil)
InventoryService.Init(Remotes)
PlayerStatsService.Init({ InventoryService = InventoryService, Remotes = Remotes })
DebtService.Init({ EconomyService = EconomyService, PlayerStatsService = PlayerStatsService, Remotes = Remotes, ATMPrompt = ATMMock })
PlayerDataService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	PlayerStatsService = PlayerStatsService,
	DebtService = DebtService,
})
PlayerDataService.StartAutosave()

local function resetPlayerState(p)
	EconomyService.SetCash(p, GameConfig.StartingCash)
	InventoryService.RestoreItems(p, {})
	PlayerStatsService.RestoreWins(p, 0)
	DebtService.SetupPlayer(p)
	PlayerDataService.ClearPlayer(p)
end

local function goodItem(i)
	return {
		InstanceId = "k_" .. i,
		ItemId = "vintage_comic",
		Rarity = "Rare",
		Condition = 80,
		FinalValue = 500 + i,
		ModelKey = "VintageComic",
	}
end

-- ================= TEST 1: old Cash-only schema =================
do
	local P = mkPlayer("OldTimer", 301)
	storeData["player_301"] = { Cash = 777, SavedAt = 1000 }
	PlayerDataService.Load(P)
	check(EconomyService.GetCash(P.UserId) == 777, "T1 old Cash restored")
	check(PlayerStatsService.GetWins(P) == 0, "T1 wins default 0")
	check(DebtService.GetDebt(P.UserId) == 0, "T1 debt default 0")
	check(#InventoryService.GetItems(P) == 0, "T1 inventory default {}")
	check(PlayerDataService.IsLoaded(P), "T1 marked loaded")
end

-- ================= TEST 2-7: full round-trip =================
do
	local P = mkPlayer("RoundTrip", 302)
	EconomyService.SetCash(P, 4321)
	local items = { goodItem(1), goodItem(2), goodItem(3) }
	InventoryService.RestoreItems(P, items)
	PlayerStatsService.RestoreWins(P, 7)
	DebtService.RestorePlayer(P, { debt = 425, recoveryAvailableAt = fakeNow + 150 })
	PlayerDataService.Load(P) -- Load overwrites with store (empty) — instead Save first below
	-- NOTE: Load cleared runtime; rebuild then Save.
	EconomyService.SetCash(P, 4321)
	InventoryService.RestoreItems(P, items)
	PlayerStatsService.RestoreWins(P, 7)
	DebtService.RestorePlayer(P, { debt = 425, recoveryAvailableAt = fakeNow + 150 })
	PlayerDataService.Save(P)
	local saved = storeData["player_302"]
	check(saved ~= nil and saved.Cash == 4321, "T3 cash saved")
	check(saved.AuctionsWon == 7, "T5 wins saved")
	check(saved.Debt == 425, "T6 debt saved")
	check(saved.RecoveryAvailableAt == fakeNow + 150, "T7 cooldown saved")
	check(saved.SchemaVersion == GameConfig.PersistSchemaVersion and saved.SavedAt == fakeNow, "T2 version+timestamp")
	check(#saved.Inventory == 3 and saved.Inventory[2].FinalValue == 502, "T4 inventory saved")
	-- wipe runtime, reload from store
	EconomyService.SetCash(P, 0)
	InventoryService.RestoreItems(P, {})
	PlayerStatsService.RestoreWins(P, 0)
	DebtService.SetupPlayer(P)
	PlayerDataService.Load(P)
	check(EconomyService.GetCash(P.UserId) == 4321, "T3 cash restored")
	check(PlayerStatsService.GetWins(P) == 7, "T5 wins restored")
	check(DebtService.GetDebt(P.UserId) == 425, "T6 debt restored")
	local got = InventoryService.GetItems(P)
	check(#got == 3 and got[2].FinalValue == 502, "T4 items restored")
	check(got[1].Name == "Vintage Comic" and got[1].ConditionName ~= nil, "T4 derived display fields valid")
	check(PlayerDataService.IsLoaded(P), "T2 loaded flag")
end

-- ================= TEST 8: malformed entries skipped =================
do
	local P = mkPlayer("Messy", 303)
	storeData["player_303"] = {
		Cash = 100,
		Inventory = {
			{ InstanceId = "ok1", ItemId = "old_lamp", Rarity = "Common", Condition = 50, FinalValue = 30 },
			{ InstanceId = "", ItemId = "old_lamp", Rarity = "Common", Condition = 50, FinalValue = 30 },
			{ InstanceId = "bad-def", ItemId = "nope_missing", Rarity = "Common", Condition = 50, FinalValue = 30 },
			{ InstanceId = "bad-rar", ItemId = "old_lamp", Rarity = "Ultra", Condition = 50, FinalValue = 30 },
			"not-a-table",
			{ InstanceId = "dup", ItemId = "old_lamp", Rarity = "Common", Condition = 50, FinalValue = 30 },
			{ InstanceId = "dup", ItemId = "old_lamp", Rarity = "Common", Condition = 60, FinalValue = 40 },
			{ InstanceId = "clampme", ItemId = "gold_watch", Rarity = "Mythic", Condition = 9999, FinalValue = 99999999 },
		},
	}
	PlayerDataService.Load(P)
	local got = InventoryService.GetItems(P)
	check(#got == 3, "T8 malformed skipped, dupes collapsed (n=" .. #got .. ")")
	local clamped = nil
	for _, it in ipairs(got) do
		if it.InstanceId == "clampme" then
			clamped = it
		end
	end
	check(clamped ~= nil and clamped.Condition == 100 and clamped.FinalValue == 6000, "T8 numerics clamped")
end

-- ================= TEST 9: 500 cap =================
do
	local P = mkPlayer("Hoarder", 304)
	local big = {}
	for i = 1, 600 do
		table.insert(big, goodItem(i))
	end
	storeData["player_304"] = { Cash = 10, Inventory = big }
	PlayerDataService.Load(P)
	local got = InventoryService.GetItems(P)
	check(#got == 500, "T9 cap enforced (n=" .. #got .. ")")
	check(got[1].InstanceId == "k_1" and got[500].InstanceId == "k_500", "T9 first-valid-wins order")
end

-- ================= TEST 10/11: negative sanitized =================
do
	local P = mkPlayer("Neggy", 305)
	storeData["player_305"] = { Cash = -100, AuctionsWon = -3, Debt = -50, RecoveryAvailableAt = "soon" }
	PlayerDataService.Load(P)
	check(EconomyService.GetCash(P.UserId) == 1000, "T10/11 negative cash -> default")
	check(PlayerStatsService.GetWins(P) == 0, "T11 negative wins -> 0")
	check(DebtService.GetDebt(P.UserId) == 0, "T10 negative debt -> 0")
	local st = DebtService.GetPersistentState(P)
	check(st.recoveryAvailableAt == 0, "T10 bad timestamp -> 0")
end

-- ================= TEST 12: cooldown survives reconnect =================
do
	local P = mkPlayer("CooldownCarl", 306)
	PlayerDataService.Load(P)
	EconomyService.SetCash(P, 10)
	local ok1, _ = DebtService.ClaimRecovery(P)
	check(ok1, "T12 claim ok")
	PlayerDataService.Save(P)
	-- simulate reconnect: wipe runtime, reload
	DebtService.SetupPlayer(P)
	PlayerDataService.Load(P)
	EconomyService.SetCash(P, 10) -- broke again, cooldown still pending
	local ok2, msg2 = DebtService.ClaimRecovery(P)
	check(not ok2 and string.find(tostring(msg2), "cooldown") ~= nil, "T12 cooldown survives reconnect")
	check(DebtService.GetDebt(P.UserId) == 0, "T12 debt still 0")
end

-- ================= TEST 13/14: debt blocks loan + repayment =================
do
	local P = mkPlayer("DebtorDan", 307)
	EconomyService.SetCash(P, 500)
	PlayerDataService.Load(P)
	DebtService.TakeLoan(P, "A")
	PlayerDataService.Save(P)
	DebtService.SetupPlayer(P)
	EconomyService.SetCash(P, 500)
	PlayerDataService.Load(P)
	check(DebtService.GetDebt(P.UserId) == 300, "T13 debt restored")
	local okB, _ = DebtService.TakeLoan(P, "B")
	check(not okB, "T13 second loan still rejected after reconnect")
	local c0 = EconomyService.GetCash(P.UserId)
	local added, paid, rem = DebtService.ApplySaleProceeds(P, 400)
	check(added == 300 and paid == 100 and rem == 200, "T14 repayment from restored debt")
	check(EconomyService.GetCash(P.UserId) == c0 + 300, "T14 cash")
end

-- ================= TEST 15: kept item sells after reconnect =================
do
	local P = mkPlayer("KeeperKim", 308)
	storeData["player_308"] = {
		Cash = 200,
		Inventory = { { InstanceId = "keep1", ItemId = "retro_console", Rarity = "Epic", Condition = 90, FinalValue = 1500 } },
	}
	PlayerDataService.Load(P)
	local removed = InventoryService.RemoveItem(P, "keep1")
	check(removed ~= nil and removed.FinalValue == 1500 and removed.ConditionName ~= nil, "T15 item sellable, value+display intact")
end

-- ================= TEST 16: HR gate uses restored wins =================
do
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
	local function mkBox(id)
		return {
			_attrs = { ContainerId = id },
			FindFirstChildOfClass = function(_s, _c)
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
	local function mkUnit(bc, ids)
		local h = { Door = {}, Barrier = {}, Containers = {}, BidCenter = bc }
		for _, id in ipairs(ids) do
			h.Containers[id] = mkBox(id)
		end
		return h
	end
	local NPCBidderService = require("./NPCBidderService")
	local DisplayService = { OnItemRemoved = function() end }
	local AuctionService = SA_AuctionService
	local DebtService2 = SA_DebtService2
	DebtService2.Init({ EconomyService = EconomyService, PlayerStatsService = PlayerStatsService, Remotes = Remotes, ATMPrompt = nil })
	AuctionService.Init({
		EconomyService = EconomyService,
		InventoryService = InventoryService,
		NPCBidderService = NPCBidderService,
		MapBuilder = StubMapBuilder,
		MapHandles = {
			Units = {
				mkUnit({ X = 0, Y = 0, Z = 0 }, { "box_1", "box_2", "box_3" }),
				mkUnit({ X = 0, Y = 0, Z = 40 }, { "box_4", "box_5", "box_6" }),
				mkUnit({ X = 0, Y = 0, Z = 80 }, { "box_7", "box_8", "box_9" }),
			},
		},
		Remotes = Remotes,
		PlayerStatsService = PlayerStatsService,
		DisplayService = DisplayService,
		DebtService = DebtService2,
	})
	local P = mkPlayer("HighHope", 309)
	storeData["player_309"] = { Cash = 10000, AuctionsWon = 3 }
	PlayerDataService.Load(P)
	local function snap3()
		return AuctionService.GetSnapshot().auctions[3]
	end
	pumpUntil(function()
		return snap3().state == "Bidding"
	end)
	local s = snap3()
	local ok, msg = AuctionService.TryBid(3, P, s.currentBid + 50, false, nil)
	check(ok, "T16 restored wins open High Roller (" .. tostring(msg) .. ")")
end

-- ================= TEST 17/18: save-before-clear + removing =================
do
	local P = mkPlayer("Leaver", 310)
	EconomyService.SetCash(P, 2222)
	InventoryService.RestoreItems(P, { goodItem(9) })
	PlayerStatsService.RestoreWins(P, 4)
	DebtService.RestorePlayer(P, { debt = 130, recoveryAvailableAt = fakeNow + 50 })
	PlayerDataService.Load(P) -- store empty -> defaults; rebuild after
	EconomyService.SetCash(P, 2222)
	InventoryService.RestoreItems(P, { goodItem(9) })
	PlayerStatsService.RestoreWins(P, 4)
	DebtService.RestorePlayer(P, { debt = 130, recoveryAvailableAt = fakeNow + 50 })
	-- mirror init.server onPlayerRemoving EXACT order: Save, then clears
	PlayerDataService.Save(P)
	SA_AuctionService.ClearPlayer(P)
	PlayerStatsService.ClearPlayer(P)
	InventoryService.ClearPlayer(P)
	EconomyService.ClearPlayer(P)
	DebtService.ClearPlayer(P)
	PlayerDataService.ClearPlayer(P)
	local saved = storeData["player_310"]
	check(saved ~= nil and saved.Cash == 2222, "T17/18 cash snapshotted pre-clear")
	check(saved.AuctionsWon == 4 and saved.Debt == 130, "T17/18 wins+debt pre-clear")
	check(#saved.Inventory == 1 and saved.Inventory[1].FinalValue == 509, "T17/18 inventory pre-clear")
	check(saved.RecoveryAvailableAt == fakeNow + 50, "T17/18 cooldown pre-clear")
end

-- ================= TEST 19: BindToClose-style sweep =================
do
	local P = mkPlayer("ShutdownSue", 311)
	EconomyService.SetCash(P, 333)
	PlayerDataService.Load(P)
	EconomyService.SetCash(P, 333)
	for _, p in ipairs(playersSvc.GetPlayers()) do
		if PlayerDataService.IsLoaded(p) then
			PlayerDataService.Save(p)
		end
	end
	check(storeData["player_311"] ~= nil and storeData["player_311"].Cash == 333, "T19 shutdown sweep saves loaded")
end

-- ================= TEST 20: autosave only loaded =================
do
	for k, _ in pairs(setCalls) do
		setCalls[k] = nil
	end
	local P = mkPlayer("AutoAmy", 312)
	EconomyService.SetCash(P, 444)
	PlayerDataService.Load(P) -- loaded
	EconomyService.SetCash(P, 444)
	local Q = mkPlayer("GhostGus", 313)
	EconomyService.SetCash(Q, 555)
	PlayerDataService.Load(Q)
	EconomyService.SetCash(Q, 555)
	PlayerDataService.ClearPlayer(Q) -- unloaded afterwards
	pumpTo(vclock + 130) -- pass the 120s autosave tick
	pumpTo(vclock + 1)
	check((setCalls["player_312"] or 0) >= 1, "T20 autosave saved loaded player")
	check((setCalls["player_313"] or 0) == 0, "T20 autosave skipped unloaded player")
end

-- ================= TEST 21: DataStore failure =================
do
	storeFail.get = true
	local P = mkPlayer("OfflineOli", 314)
	PlayerDataService.Load(P) -- must not crash; session defaults
	check(EconomyService.GetCash(P.UserId) == GameConfig.StartingCash, "T21 get-failure falls back")
	check(PlayerDataService.IsLoaded(P), "T21 loaded flag even in fallback")
	storeFail.get = false
	storeFail.set = true
	EconomyService.SetCash(P, 999)
	PlayerDataService.Save(P) -- must not crash
	check(storeData["player_314"] == nil, "T21 set-failure writes nothing")
	storeFail.set = false
end

-- ================= TEST 22: unloaded never overwrites =================
do
	local P = mkPlayer("FreshFred", 315)
	storeData["player_315"] = { Cash = 2121, AuctionsWon = 2 }
	-- never Loaded (simulates a join that died mid-load)
	EconomyService.SetCash(P, 5)
	PlayerDataService.Save(P)
	check(storeData["player_315"].Cash == 2121 and storeData["player_315"].AuctionsWon == 2, "T22 unloaded save blocked")
end

-- ================= TEST 23: no plot fields =================
do
	local P = mkPlayer("PlotPat", 316)
	EconomyService.SetCash(P, 100)
	PlayerDataService.Load(P)
	EconomyService.SetCash(P, 100)
	PlayerDataService.Save(P)
	local saved = storeData["player_316"]
	local bad = false
	for k, _ in pairs(saved) do
		local lk = string.lower(tostring(k))
		if string.find(lk, "plot") then
			bad = true
		end
	end
	check(not bad, "T23 no plot fields in payload")
	local allowed = { Cash = true, Inventory = true, AuctionsWon = true, Debt = true, RecoveryAvailableAt = true, SavedAt = true, SchemaVersion = true, WarehouseLevel = true, DisplayAssignments = true }
	local strict = true
	for k, _ in pairs(saved) do
		if not allowed[k] then
			strict = false
		end
	end
	check(strict, "T23 payload keys exactly the schema")
end

check(#schedErrors == 0, "T26 no scheduler errors")
print(string.format("schedErrors=%d failures=%d", #schedErrors, failures))
if failures > 0 then
	print("PERSIST-5B TEST: FAILED")
else
	print("PERSIST-5B TEST: ALL PASS")
end
