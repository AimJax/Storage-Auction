-- Stage 5A: debt/loan/recovery unit + integration tests (dev harness, NOT game).
-- Uses REAL staged DebtService/EconomyService/PlayerStatsService/AuctionService.
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

-- ============ deterministic RNG ============
local rngState = 60606
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

-- ============ virtual clock + scheduler; FAKE wall clock ============
local vclock = 0
local fakeNow = 1000000
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
	return { ClassName = c }
end }

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
-- Everyone starts at the ATM (120, 2, 19.25); specific tests move players.
local function mkPlayer(name, id)
	local p = { Name = name, UserId = id, FindFirstChild = function(_s, _n)
		return nil
	end }
	playersById[id] = p
	setCharPos(p, 120, 2, 19.25)
	return p
end
local P1 = mkPlayer("LoanLarry", 201)
local P2 = mkPlayer("MidMoe", 202)
local P3 = mkPlayer("RichRita", 203)
local P4 = mkPlayer("BrokeBob", 204)
local P5 = mkPlayer("LeaverLou", 205)
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
local fired = {} -- eventName -> list of {pl, payload}
local function mkRemote(name)
	return {
		IsA = function(_s, _c)
			return true
		end,
		FireAllClients = function(_s, _p) end,
		FireClient = function(_s, pl, a)
			fired[name] = fired[name] or {}
			table.insert(fired[name], { pl = pl, payload = a })
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

local GameConfig = require("./GameConfig")
local ItemUtils = require("./ItemUtils")
local RealEconomyService = require("./EconomyService")
-- Mock players are tables, not Instances, so typeof() doesn't return
-- "Instance" for them. Unwrap to UserId for reads; the real ledger,
-- guards, and DeductCash clamp are still fully exercised.
local EconomyService = setmetatable({
	GetCash = function(p)
		return RealEconomyService.GetCash(p.UserId)
	end,
}, { __index = RealEconomyService })
local function cashOf(p)
	return EconomyService.GetCash(p)
end
local UnitGeneratorService = require("./UnitGeneratorService")
local NPCBidderService = require("./NPCBidderService")
local AuctionService = require("./AuctionService")
local DebtService = require("./DebtService")

EconomyService.Init(nil)
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
local PlayerStatsService = require("./PlayerStatsService")
PlayerStatsService.Init({ InventoryService = InventoryService, Remotes = Remotes })
local DisplayService = { OnItemRemoved = function() end }

local function debtOf(p)
	return DebtService.GetDebt(p.UserId)
end

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

-- ATM prompt mock: captures the Triggered callback.
local atmPromptCb = nil
local ATMPrompt = {
	FindFirstChild = function(_s, _n)
		return nil
	end,
	FindFirstChildOfClass = function(_s, _c)
		return nil
	end,
}
local ATMBody = {
	ClassName = "Part",
	Position = v3(120, 2, 19.25),
	IsA = function(self, c)
		return c == "BasePart" or self.ClassName == c
	end,
	FindFirstChildOfClass = function(_s, _c)
		return {
			MaxActivationDistance = 10,
			Triggered = { Connect = function(_t, fn)
				atmPromptCb = fn
			end },
		}
	end,
}
ATMPrompt.FindFirstChild = function(_s, n)
	if n == "Body" then
		return ATMBody
	end
	return nil
end

EconomyService.SetCash(P1, 100)
EconomyService.SetCash(P2, 2000)
EconomyService.SetCash(P3, 10000)
EconomyService.SetCash(P4, 20)
EconomyService.SetCash(P5, 500)
DebtService.Init({
	EconomyService = EconomyService,
	PlayerStatsService = PlayerStatsService,
	Remotes = Remotes,
	ATMPrompt = ATMPrompt,
})
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
DebtService.SetupPlayer(P1)
DebtService.SetupPlayer(P2)
DebtService.SetupPlayer(P3)
DebtService.SetupPlayer(P4)
DebtService.SetupPlayer(P5)

local function snap(i)
	return AuctionService.GetSnapshot().auctions[i]
end

-- ================= TEST 1: Loan A =================
do
	local ok, msg = DebtService.TakeLoan(P1, "A")
	check(ok, "T1 Loan A accepted (" .. tostring(msg) .. ")")
	check(cashOf(P1) == 350, "T1 cash += 250")
	check(debtOf(P1) == 300, "T1 debt = 300")
end

-- ================= TEST 2/3: loan gates =================
do
	-- P2: cash 2000, 0 wins, empty inventory (networth 2000)
	local okB, _ = DebtService.TakeLoan(P2, "B")
	check(okB, "T2 Loan B via networth>=1500")
	-- reset P2 debt via full repayment through sales below; use fresh P6 for C gate
	local P6 = mkPlayer("GateGus", 206)
	EconomyService.SetCash(P6, 3000)
	DebtService.SetupPlayer(P6)
	local okC1, msgC1 = DebtService.TakeLoan(P6, "C")
	check(not okC1, "T3 Loan C rejected without wins/networth (" .. tostring(msgC1) .. ")")
	PlayerStatsService.RecordWin(P6)
	PlayerStatsService.RecordWin(P6)
	PlayerStatsService.RecordWin(P6)
	PlayerStatsService.RecordWin(P6)
	PlayerStatsService.RecordWin(P6)
	local okC2, _ = DebtService.TakeLoan(P6, "C")
	check(okC2 and debtOf(P6) == 1300, "T3 Loan C via 5 wins")
end

-- ================= TEST 4: one active loan =================
do
	local ok, msg = DebtService.TakeLoan(P1, "B")
	check(not ok, "T4 second loan rejected (" .. tostring(msg) .. ")")
	check(cashOf(P1) == 350, "T4 no duplicate credit")
	local okBad, _ = DebtService.TakeLoan(P1, "Z")
	check(not okBad, "T4 unknown loan id rejected")
end

-- ================= TEST 5/6/7: sale splits =================
do
	-- P1 debt 300: sell 400 -> pay 100, cash +300, debt 200
	local c0 = cashOf(P1)
	local added, paid, rem = DebtService.ApplySaleProceeds(P1, 400)
	check(added == 300 and paid == 100 and rem == 200, "T5 400/300 split")
	check(cashOf(P1) == c0 + 300 and debtOf(P1) == 200, "T5 balances")
	-- sell 400 with debt 50 -> pay 50, cash +350, debt 0 (no overpay)
	EconomyService.SetCash(P5, 500)
	DebtService.SetupPlayer(P5)
	-- give P5 debt 50: take A (debt 300) then repay down via sales
	DebtService.TakeLoan(P5, "A")
	DebtService.ApplySaleProceeds(P5, 800) -- pays 200 -> debt 100... need 50
	DebtService.ApplySaleProceeds(P5, 200) -- pays 50 -> debt 50
	check(debtOf(P5) == 50, "T6 setup debt=50")
	local c5 = cashOf(P5)
	local a6, p6, r6 = DebtService.ApplySaleProceeds(P5, 400)
	check(a6 == 350 and p6 == 50 and r6 == 0, "T6 small debt exact clear, no overpay")
	check(cashOf(P5) == c5 + 350, "T6 cash")
	-- no debt: full credit
	local c3 = cashOf(P3)
	local a7, p7, r7 = DebtService.ApplySaleProceeds(P3, 400)
	check(a7 == 400 and p7 == 0 and r7 == 0, "T7 no-debt full credit")
	check(cashOf(P3) == c3 + 400, "T7 cash")
	-- malformed/zero safe
	local a0, p0, r0 = DebtService.ApplySaleProceeds(P3, 0)
	check(a0 == 0 and p0 == 0, "T7b zero sale safe")
	local aN, pN, rN = DebtService.ApplySaleProceeds(P3, -50)
	check(aN == 0 and pN == 0, "T7c negative sale safe")
end

-- ================= TEST 8/9/10: recovery top-up =================
do
	local ok8, g8 = DebtService.ClaimRecovery(P4) -- cash 20
	check(ok8 and g8 == 105 and cashOf(P4) == 125, "T8 cash 20 -> grant 105 -> 125")
	EconomyService.SetCash(P4, 49)
	-- reset cooldown by advancing wall clock past it
	fakeNow += GameConfig.RecoveryCooldown + 1
	local ok9, g9 = DebtService.ClaimRecovery(P4)
	check(ok9 and g9 == 76 and cashOf(P4) == 125, "T9 cash 49 -> grant 76")
	EconomyService.SetCash(P4, 50)
	fakeNow += GameConfig.RecoveryCooldown + 1
	local ok10, _ = DebtService.ClaimRecovery(P4)
	check(not ok10, "T10 cash 50 rejected")
end

-- ================= TEST 11: recovery with debt =================
do
	-- P1 has debt 200, set cash low
	EconomyService.SetCash(P1, 10)
	fakeNow += GameConfig.RecoveryCooldown + 1
	local dBefore = debtOf(P1)
	local ok11, g11 = DebtService.ClaimRecovery(P1)
	check(ok11 and g11 == 115 and cashOf(P1) == 125, "T11 recovery tops cash with debt")
	check(debtOf(P1) == dBefore, "T11 debt unchanged by recovery")
end

-- ================= TEST 12: cooldown =================
do
	EconomyService.SetCash(P4, 10)
	local okA, _ = DebtService.ClaimRecovery(P4) -- last claim was long ago (fakeNow advanced) -> ok
	check(okA, "T12 fresh claim ok")
	local okB, msgB = DebtService.ClaimRecovery(P4) -- cash now 125 -> threshold reject (also cooling)
	-- force broke again without waiting: still cooling
	EconomyService.SetCash(P4, 10)
	local okC, msgC = DebtService.ClaimRecovery(P4)
	check(not okC and string.find(tostring(msgC), "cooldown") ~= nil, "T12 immediate re-claim cooling (" .. tostring(msgC) .. ")")
	fakeNow += GameConfig.RecoveryCooldown - 1
	EconomyService.SetCash(P4, 10)
	local okD, _ = DebtService.ClaimRecovery(P4)
	check(not okD, "T12 still cooling at 299s")
	fakeNow += 2
	EconomyService.SetCash(P4, 10)
	local okE, gE = DebtService.ClaimRecovery(P4)
	check(okE and cashOf(P4) == 125, "T12 eligible after 300s")
end

-- ================= TEST 13: lifecycle clear =================
do
	DebtService.ClearPlayer(P5)
	check(debtOf(P5) == 0, "T13 debt cleared on removal")
	DebtService.SetupPlayer(P5)
	check(debtOf(P5) == 0, "T13 fresh state on join")
end

-- ================= TEST 14/15: auction + bag sell integration =================
do
	-- Whale wins Budget, opens, sells pending with debt present.
	EconomyService.SetCash(P3, 100000)
	pumpUntil(function()
		return snap(1).state == "Bidding"
	end)
	AuctionService.TryBid(1, P3, 5000, false, nil)
	pumpUntil(function()
		return snap(1).state == "Rummaging"
	end, 800000)
	check(snap(1).winner == "RichRita", "T14 whale wins")
	-- give winner debt first
	DebtService.TakeLoan(P3, "A") -- debt 300 (P3: 0 wins? RecordWin? P3 has 0 wins, networth huge -> A open anyway)
	setCharPos(P3, 69, 2, -26) -- at box_1 for the range gate
	U1.Containers.box_1._promptCb(P3)
	local revealLog = fired[GameConfig.RemoteNames.ItemRevealed] or revealFires
	local item = revealLog[#revealLog].payload
	local gross = item.FinalValue
	local c0 = cashOf(P3)
	local okS, got = AuctionService.TrySellItem(1, P3, item.InstanceId)
	local expPay = math.min(math.floor(gross * 0.25), 300)
	check(okS and got == gross - expPay, "T14 pending sell splits via helper")
	check(cashOf(P3) == c0 + (gross - expPay), "T14 cash credited net")
	check(debtOf(P3) == 300 - expPay, "T14 debt reduced")
	-- Bag sell with remaining debt
	InventoryStore[P3.UserId] = { { InstanceId = "bag1", FinalValue = 200 } }
	local c1 = cashOf(P3)
	local d1 = debtOf(P3)
	local okB, gotB = AuctionService.TrySellItem(1, P3, "bag1")
	local expPayB = math.min(math.floor(200 * 0.25), d1)
	check(okB and gotB == 200 - expPayB, "T15 bag sell splits")
	check(cashOf(P3) == c1 + (200 - expPayB), "T15 cash")
end

-- ================= TEST: ATM prompt routing + state =================
do
	check(atmPromptCb ~= nil, "ATM prompt wired")
	fired.ATMOpened = nil
	atmPromptCb(P1)
	check(fired.ATMOpened ~= nil and fired.ATMOpened[1].pl == P1, "ATM prompt opens panel for triggerer")
	local st = DebtService.GetState(P2)
	check(st.cash ~= nil and st.debt ~= nil and #st.loans == 3 and st.recovery ~= nil, "ATM state shape")
	check(st.loans[1].id == "A" and st.loans[2].id == "B" and st.loans[3].id == "C", "ATM loan order")
end

check(#schedErrors == 0, "T20 no scheduler errors")
print(string.format("schedErrors=%d failures=%d", #schedErrors, failures))
if failures > 0 then
	print("DEBT-5A TEST: FAILED")
else
	print("DEBT-5A TEST: ALL PASS")
end
