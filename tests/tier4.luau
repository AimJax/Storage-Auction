-- Stage 4: tier functional tests TEST 1-20 (dev harness, NOT game code).
-- Uses REAL staged modules. Run from D:/Roblox/Temp/sa-econ.

local failures = 0
local function check(cond, label)
	if cond then
		print("PASS " .. label)
	else
		failures += 1
		print("FAIL " .. label)
	end
end

local rngState = 515151
local function nextRand()
	rngState = (rngState * 1103515245 + 12345) % 2147483648
	return rngState / 2147483648
end
Random = { new = function(_s)
	return {
		NextNumber = function(_self, a, b)
			local r = nextRand()
			if a == nil then
				return r
			end
			return a + r * (b - a)
		end,
		NextInteger = function(_self, a, b)
			return a + math.floor(nextRand() * (b - a + 1))
		end,
	}
end }

local vclock = 0
local realOsTime = os.time
os = {
	clock = function()
		return vclock
	end,
	time = function(...)
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
	table.insert(runqueue, {
		co = coroutine.create(function()
			fn(table.unpack(args))
		end),
		at = 0,
	})
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

warn = function(...) end
debug = { traceback = function(e)
	return tostring(e)
end }
Color3 = { fromRGB = function(r, g, b)
	return { R = r, G = g, B = b }
end }
Instance = { new = function(c)
	return { ClassName = c }
end }

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
	local p = { Name = name, UserId = id, FindFirstChild = function(_s, _n)
		return nil
	end }
	playersById[id] = p
	return p
end
local P1 = mkPlayer("WhaleOne", 101) -- rich + wins (HR eligible)
local P2 = mkPlayer("PoorPete", 102) -- cash 100 (Budget only)
local P3 = mkPlayer("MidMoe", 103) -- cash 3000, no wins (Standard yes, HR no)
local P4 = mkPlayer("RichRita", 104) -- cash 3000 + 3 wins (HR eligible)
local P5 = mkPlayer("CommitCarl", 105) -- cash 10000 + 3 wins (commitment probe)
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

local broadcasts = {}
local revealFires = {}
local function mkRemote(name)
	return {
		IsA = function(_s, _c)
			return true
		end,
		FireAllClients = function(_s, payload)
			if name == "AuctionState" then
				table.insert(broadcasts, payload)
			end
		end,
		FireClient = function(_s, pl, a, b)
			if name == "ItemRevealed" then
				table.insert(revealFires, { player = pl, item = a, unitIndex = b })
			end
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
game = {
	GetService = function(_s, name)
		if name == "Players" then
			return playersSvc
		elseif name == "ReplicatedStorage" then
			return { WaitForChild = function(_a, _b)
				return {}
			end }
		end
		error("unexpected service " .. tostring(name))
	end,
	Workspace = {},
}

local function mkBox(id, x, y, z)
	local box = {
		Position = v3(x or 0, y or 2, z or 0),
		_attrs = { ContainerId = id, Opened = false },
		Transparency = 0,
		_promptCb = nil,
		FindFirstChildOfClass = function(self, _c)
			if _c == "ProximityPrompt" then
				if not self._prompt then
					local b = self
					self._prompt = { MaxActivationDistance = 10, Enabled = false, Triggered = { Connect = function(_t, fn)
						b._promptCb = fn
					end } }
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
	return box
end
local function mkUnit(name, bc, ids)
	local h = { UnitName = name, Door = {}, Barrier = {}, Containers = {}, BidCenter = bc, UnitCenter = { X = 0, Y = 0, Z = 0 }, ReturnCFrame = {} }
	for i, id in ipairs(ids) do
		h.Containers[id] = mkBox(id, bc.X - 21, 2, bc.Z - 6 + (i - 1) * 6)
	end
	return h
end
local U1 = mkUnit("StorageUnit", { X = 90, Y = 0, Z = -20 }, { "box_1", "box_2", "box_3" })
local U2 = mkUnit("StorageUnit2", { X = 90, Y = 0, Z = 20 }, { "box_4", "box_5", "box_6" })
local U3 = mkUnit("StorageUnit3", { X = 90, Y = 0, Z = 60 }, { "box_7", "box_8", "box_9" })
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
local MapBuilderReal = require("./MapBuilder")
StubMapBuilder.IsWithinContainerRange = MapBuilderReal.IsWithinContainerRange

local GameConfig = require("./GameConfig")
local ItemUtils = require("./ItemUtils")
local RealEconomyService = require("./EconomyService")
local EconomyService = setmetatable({
	GetCash = function(p)
		return RealEconomyService.GetCash(p.UserId)
	end,
}, { __index = RealEconomyService })
local UnitGeneratorService = require("./UnitGeneratorService")
local NPCBidderService = require("./NPCBidderService")
local AuctionService = require("./AuctionService")
local DebtService = require("./DebtService")

RealEconomyService.Init(nil)
RealEconomyService.SetCash(P1, 100000)
RealEconomyService.SetCash(P2, 100)
RealEconomyService.SetCash(P3, 3000)
RealEconomyService.SetCash(P4, 3000)
RealEconomyService.SetCash(P5, 10000)

local InventoryStore = {}
local InventoryService = {
	AddItem = function(p, item)
		InventoryStore[p.UserId] = InventoryStore[p.UserId] or {}
		table.insert(InventoryStore[p.UserId], item)
		return item
	end,
	RemoveItem = function(p, id)
		local list = InventoryStore[p.UserId] or {}
		for i, it in ipairs(list) do
			if it.InstanceId == id then
				table.remove(list, i)
				return it
			end
		end
		return nil
	end,
	GetItems = function(p)
		return InventoryStore[p.UserId] or {}
	end,
}
-- REAL PlayerStatsService: session wins + collection value drive HR gate.
local PlayerStatsService = require("./PlayerStatsService")
PlayerStatsService.Init({ InventoryService = InventoryService, Remotes = Remotes })
local DisplayService = { OnItemRemoved = function() end }

local genTiers = {}
local lastUnits = {}
local createTier = {} -- bidder table -> tierId (gen->create is same-tick atomic)
local genTierTag = nil
local npcBids = { [1] = 0, [2] = 0, [3] = 0 }
local RealGen = UnitGeneratorService.GenerateUnit
UnitGeneratorService.GenerateUnit = function(rng, ids, tier)
	local u = RealGen(rng, ids, tier)
	genTiers[u.TierId or "?"] = (genTiers[u.TierId or "?"] or 0) + 1
	genTierTag = u.TierId
	lastUnits[(tier and tier.TierId) or "?"] = u
	return u
end
local RealTick = NPCBidderService.Tick
NPCBidderService.Tick = function(bidders, t, cur, bidderName, lastBid, humans, tleft, highHuman, tryBidFn, mult)
	return RealTick(bidders, t, cur, bidderName, lastBid, humans, tleft, highHuman, function(name, amount)
		local ok = tryBidFn(name, amount)
		if ok then
			local tierId = createTier[bidders]
			local idx = if tierId == "Standard" then 2 elseif tierId == "HighRoller" then 3 else 1
			npcBids[idx] += 1
		end
		return ok
	end, mult)
end
local createCalls = {}
local RealCreate = NPCBidderService.CreateBidders
NPCBidderService.CreateBidders = function(defs, vis, hid, hiddenBaseline, budgetMult)
	local b = RealCreate(defs, vis, hid, hiddenBaseline, budgetMult)
	table.insert(createCalls, b)
	createTier[b] = genTierTag
	return b
end
local RealTryBid = AuctionService.TryBid
AuctionService.TryBid = function(unitIndex, p, amount, isNPC, name)
	-- NOTE: NPC bids travel the internal tryBid path and never pass through
	-- here; NPC presence is counted in the Tick wrapper above instead.
	return RealTryBid(unitIndex, p, amount, isNPC, name)
end

AuctionService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	NPCBidderService = NPCBidderService,
	MapBuilder = StubMapBuilder,
	MapHandles = { Units = { U1, U2, U3 } },
	Remotes = Remotes,
	PlayerStatsService = PlayerStatsService,
	DisplayService = DisplayService,
	DebtService = DebtService,
})
DebtService.Init({
	EconomyService = EconomyService,
	PlayerStatsService = PlayerStatsService,
	Remotes = Remotes,
	ATMPrompt = nil,
})
-- Qualify HR-eligible players via REAL session stats (no persistence).
PlayerStatsService.RecordWin(P1)
PlayerStatsService.RecordWin(P1)
PlayerStatsService.RecordWin(P1)
PlayerStatsService.RecordWin(P4)
PlayerStatsService.RecordWin(P4)
PlayerStatsService.RecordWin(P4)
PlayerStatsService.RecordWin(P5)
PlayerStatsService.RecordWin(P5)
PlayerStatsService.RecordWin(P5)

local function snap(i)
	return AuctionService.GetSnapshot().auctions[i]
end
local function pumpUntil(cond, limit)
	limit = limit or 800000
	while not cond() and vclock < limit do
		pumpTo(vclock + 0.5)
	end
	return cond()
end

-- ================= TEST 1: tier mapping =================
do
	check(snap(1).tierId == "Budget" and snap(2).tierId == "Standard" and snap(3).tierId == "HighRoller", "T1 Unit1=Budget Unit2=Standard Unit3=HighRoller")
	check(snap(1).tierDisplayName == "BUDGET" and snap(3).tierDisplayName == "HIGH ROLLER", "T1 display names")
end

-- ================= TEST 2: concurrency with tiers =================
do
	local seen = { [1] = {}, [2] = {}, [3] = {} }
	pumpUntil(function()
		for i = 1, 3 do
			seen[i][snap(i).state] = true
		end
		return seen[1].Bidding and seen[2].Bidding and seen[3].Bidding
	end, 400000)
	check(seen[1].Bidding and seen[2].Bidding and seen[3].Bidding, "T2 all 3 reach Bidding independently")
end

-- ================= TESTs 3/4/5: starting bids =================
local function startingBidOf(i)
	return GameConfig.Tiers[(if i == 1 then "Budget" elseif i == 2 then "Standard" else "HighRoller")].StartingBid
end
for i = 1, 3 do
	pumpUntil(function()
		return snap(i).state == "Bidding"
	end)
	local want = startingBidOf(i)
	-- NPCs may have already raised the price; the floor must simply never
	-- drop below the tier StartingBid.
	local okLow, msgLow = AuctionService.TryBid(i, P1, want - 1, false, nil)
	-- NPCs may have raised the price (commas in big numbers); the floor must
	-- simply never drop below the tier StartingBid.
	local floor = tonumber(string.match(string.gsub(tostring(msgLow), ",", ""), "at least %$(%d+)")) or -1
	check(not okLow and floor >= want, string.format("T%d below-%d rejected (floor $%d)", i + 2, want, floor))
end
check(startingBidOf(1) == 25 and startingBidOf(2) == 100 and startingBidOf(3) == 500, "T3/4/5 starting bids 25/100/500")

-- ================= TESTs 6/7/8/9: eligibility =================
do
	-- Bid at the first observed tick of a FRESH Budget auction, before NPCs
	-- can move the price beyond a poor player's wallet.
	local last1 = snap(1).state
	local ok6, msg6 = false, "no fresh auction observed"
	local guard = 0
	while guard < 20000 do
		pumpTo(vclock + 0.5)
		guard += 1
		if snap(1).state ~= last1 then
			last1 = snap(1).state
			if last1 == "Bidding" then
				ok6, msg6 = AuctionService.TryBid(1, P2, snap(1).currentBid + ItemUtils.BidIncrementFor(snap(1).currentBid), false, nil)
				break
			end
		end
	end
	check(ok6, "T6 poor player CAN bid Budget (" .. tostring(msg6) .. ")")
	pumpUntil(function()
		return snap(1).state == "Bidding" and snap(2).state == "Bidding" and snap(3).state == "Bidding"
	end)
	-- T7: poor rejected from Standard with exact message
	local ok7, msg7 = AuctionService.TryBid(2, P2, snap(2).currentBid + ItemUtils.BidIncrementFor(snap(2).currentBid), false, nil)
	check(not ok7 and msg7 == "Standard auction requires $300 Cash.", "T7 poor rejected from Standard: " .. tostring(msg7))
	-- T8a: poor rejected from HighRoller
	local ok8a, msg8a = AuctionService.TryBid(3, P2, snap(3).currentBid + ItemUtils.BidIncrementFor(snap(3).currentBid), false, nil)
	check(not ok8a and msg8a == "High Roller requires $2,500 Cash and 3 wins or $5,000 net worth.", "T8 poor rejected from HR")
	-- T8b: cash-rich but no wins/networth rejected from HR
	local ok8b, msg8b = AuctionService.TryBid(3, P3, snap(3).currentBid + ItemUtils.BidIncrementFor(snap(3).currentBid), false, nil)
	check(not ok8b and msg8b == "High Roller requires $2,500 Cash and 3 wins or $5,000 net worth.", "T8b unqualified-rich rejected from HR")
	-- T9: qualified (cash+wins) accepted on HR
	local ok9, msg9 = AuctionService.TryBid(3, P4, snap(3).currentBid + ItemUtils.BidIncrementFor(snap(3).currentBid), false, nil)
	check(ok9, "T9 qualified player CAN bid HR (" .. tostring(msg9) .. ")")
	-- T9b: net-worth path (cash 3000 + kept loot, zero wins)
	InventoryStore[P3.UserId] = { { InstanceId = "x", FinalValue = 6000 } }
	local ok9b, _ = AuctionService.TryBid(3, P3, snap(3).currentBid + ItemUtils.BidIncrementFor(snap(3).currentBid), false, nil)
	check(ok9b, "T9b net-worth path qualifies for HR")
	InventoryStore[P3.UserId] = {}
end

-- ================= TESTs 10-13: generator consumption (fast stats) =================
do
	local rng = Random.new()
	local ruin = { Budget = 0, Standard = 0, HighRoller = 0 }
	local jack = { Budget = 0, Standard = 0, HighRoller = 0 }
	local means = { Budget = 0, Standard = 0, HighRoller = 0 }
	local tagBad = 0
	for _, tierId in ipairs({ "Budget", "Standard", "HighRoller" }) do
		local tier = {}
		for k, v in pairs(GameConfig.Tiers[tierId]) do
			tier[k] = v
		end
		tier.TierId = tierId
		local sum = 0
		for _ = 1, 2000 do
			local u = UnitGeneratorService.GenerateUnit(rng, { "box_1", "box_2", "box_3" }, tier)
			sum += u.TrueTotalValue
			if u.Quality == "Jackpot" then
				jack[tierId] += 1
			end
			if u.Quality == "Trash" or u.Quality == "Low" then
				ruin[tierId] += 1
			end
			if u.TierId ~= tierId then
				tagBad += 1
			end
		end
		means[tierId] = sum / 2000
	end
	check(tagBad == 0, "tier tags on generated loot")
	check(jack.Budget < jack.Standard and jack.Standard < jack.HighRoller, string.format("T10-12 Jackpot counts follow tier weights (B=%d S=%d H=%d)", jack.Budget, jack.Standard, jack.HighRoller))
	check(means.Budget < means.Standard and means.Standard < means.HighRoller, string.format("T13 means ordered (%.0f < %.0f < %.0f)", means.Budget, means.Standard, means.HighRoller))
end

-- ================= TEST 14: clues map to real items =================
-- Clues travel on broadcasts (GetSnapshot carries state, not clue payloads
-- — same as pre-tier). Compare the latest Inspection broadcast per unit.
do
	local latest = { [1] = nil, [2] = nil, [3] = nil }
	local function inspCount2()
		local n = 0
		for _, b in ipairs(broadcasts) do
			if b.inspection and b.unitIndex == 2 then
				n += 1
			end
		end
		return n
	end
	-- Wait for a NEW Inspection broadcast on unit 2; no generation can occur
	-- mid-Inspection, so lastUnits.Standard is exactly that auction's loot.
	local baseInsp = inspCount2()
	pumpUntil(function()
		return snap(2).state == "Inspection" and inspCount2() > baseInsp
	end)
	for _, b in ipairs(broadcasts) do
		if b.inspection and (b.unitIndex == 1 or b.unitIndex == 2 or b.unitIndex == 3) then
			latest[b.unitIndex] = b
		end
	end
	local u = lastUnits.Standard
	local s = latest[2]
	check(u ~= nil and s ~= nil and s.inspection ~= nil, "T14 inspection data present")
	local map = {}
	for _, it in ipairs(u.VisibleItems) do
		map[it.Name .. "|" .. it.Rarity .. "|" .. it.ConditionName] = true
	end
	local allReal = true
	for _, c in ipairs(s.inspection.clues) do
		if not map[c.name .. "|" .. c.rarity .. "|" .. c.condition] then
			allReal = false
		end
	end
	check(allReal and #s.inspection.clues == #u.VisibleItems, "T14 every clue is a real generated item")
end

-- ================= TEST 15: hidden secrecy =================
do
	local bad = 0
	local function scan(t, depth)
		if depth > 4 or type(t) ~= "table" then
			return
		end
		for k, v in pairs(t) do
			if k == "FinalValue" or k == "BaseValue" or k == "InstanceId" or k == "TrueTotalValue" then
				bad += 1
			end
			if type(v) == "table" then
				scan(v, depth + 1)
			end
		end
	end
	for _, b in ipairs(broadcasts) do
		if b.inspection then
			scan(b.inspection, 0)
		end
	end
	check(bad == 0, "T15 no hidden values in client payloads")
end

-- ================= TEST 16: NPC isolation =================
do
	local distinct = true
	local seen = {}
	local tiersSeen = {}
	for _, b in ipairs(createCalls) do
		if seen[b] then
			distinct = false
		end
		seen[b] = true
		tiersSeen[createTier[b]] = true
	end
	check(distinct, "T16 fresh NPC table per auction")
	check(tiersSeen.Budget and tiersSeen.Standard and tiersSeen.HighRoller, "T16 NPC sets instantiated for all 3 tiers")
end

-- ================= TEST 17: anti-snipe isolated =================
do
	pumpUntil(function()
		return snap(2).state == "Bidding" and snap(2).timeLeft < GameConfig.AntiSnipeWindow
	end)
	local t1, t3 = snap(1).timeLeft, snap(3).timeLeft
	local s = snap(2)
	local ok, _ = AuctionService.TryBid(2, P4, s.currentBid + ItemUtils.BidIncrementFor(s.currentBid), false, nil)
	if not ok then
		ok, _ = AuctionService.TryBid(2, P1, snap(2).currentBid + ItemUtils.BidIncrementFor(snap(2).currentBid), false, nil)
	end
	check(ok, "T17 late bid accepted")
	check(snap(2).timeLeft >= GameConfig.AntiSnipeExtension - 1, "T17 sniped session extended")
	check(math.abs(snap(1).timeLeft - t1) < 2.5 and math.abs(snap(3).timeLeft - t3) < 2.5, "T17 other timers unchanged")
end

-- ================= TEST 18: 3-way commitment =================
do
	pumpUntil(function()
		return snap(1).state == "Bidding" and snap(2).state == "Bidding" and snap(3).state == "Bidding"
	end, 800000)
	local i1 = ItemUtils.BidIncrementFor(snap(1).currentBid)
	local ok1, _ = AuctionService.TryBid(1, P5, snap(1).currentBid + i1, false, nil)
	local L1 = if ok1 then snap(1).currentBid else -1
	local i2 = ItemUtils.BidIncrementFor(snap(2).currentBid)
	local ok2, _ = AuctionService.TryBid(2, P5, snap(2).currentBid + i2, false, nil)
	local L2 = if ok2 then snap(2).currentBid else -1
	check(ok1 and ok2, "T18 P5 leads Units 1+2")
	local headroom = 10000 - L1 - L2
	local min3 = snap(3).currentBid + ItemUtils.BidIncrementFor(snap(3).currentBid)
	local okOver, msgOver = AuctionService.TryBid(3, P5, math.max(min3, headroom + 1), false, nil)
	check(not okOver and string.find(tostring(msgOver), "Not enough Cash") ~= nil, "T18 over-commit rejected (eligibility passed, commitment blocked)")
	if headroom >= min3 then
		local okE, _ = AuctionService.TryBid(3, P5, headroom, false, nil)
		check(okE, "T18 exact headroom accepted")
	end
end

-- ================= TEST 19: sell/keep unchanged =================
do
	pumpUntil(function()
		return snap(1).state == "Bidding"
	end)
	AuctionService.TryBid(1, P1, 5000, false, nil)
	pumpUntil(function()
		return snap(1).state == "Rummaging"
	end, 800000)
	check(snap(1).winner == "WhaleOne", "T19 whale wins Budget")
	setCharPos(P1, 69, 2, -26) -- at box_1 for the range gate
	U1.Containers.box_1._promptCb(P1)
	local id = revealFires[#revealFires].item.InstanceId
	local cashBefore = EconomyService.GetCash(P1)
	local okS, pay = AuctionService.TrySellItem(1, P1, id)
	check(okS and EconomyService.GetCash(P1) == cashBefore + pay, "T19 sell pays out")
	U1.Containers.box_2._promptCb(P1)
	local id2 = revealFires[#revealFires].item.InstanceId
	local okK, _ = AuctionService.TryKeepItem(1, P1, id2)
	check(okK and #(InventoryStore[P1.UserId] or {}) >= 1, "T19 keep lands in inventory")
end

-- ================= NPC presence on HighRoller =================
do
	pumpTo(vclock + 400)
	check(npcBids[3] > 0, "HR NPCs place bids (filler present, n=" .. npcBids[3] .. ")")
	check(npcBids[1] > 0 and npcBids[2] > 0, "NPCs present on all tiers")
end

check(#schedErrors == 0, "T20 no scheduler errors")
print(string.format("broadcasts=%d genCalls(tierTagged=%d) createCalls=%d reveals=%d schedErrors=%d failures=%d",
	#broadcasts, (genTiers.Budget or 0) + (genTiers.Standard or 0) + (genTiers.HighRoller or 0), #createCalls, #revealFires, #schedErrors, failures))
if failures > 0 then
	print("TIER TEST: FAILED")
else
	print("TIER TEST: ALL PASS")
end
