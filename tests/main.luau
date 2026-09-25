-- Deterministic economy sim over REAL f9f0a30 modules (virtual time).
-- Usage: lune run main.luau [solo|duo] [N]
-- NOTE: plain global assignments (shared _ENV); rawset(_G) is invisible here.

-- ============ deterministic RNG ============
local rngState = 20260924
local function nextRand()
	rngState = (rngState * 1103515245 + 12345) % 2147483648
	return rngState / 2147483648
end
local FakeRng = {}
FakeRng.__index = FakeRng
function FakeRng:NextNumber(a, b)
	local r = nextRand()
	if a == nil then
		return r
	end
	return a + r * (b - a)
end
function FakeRng:NextInteger(a, b)
	return a + math.floor(nextRand() * (b - a + 1))
end
Random = { new = function(_seed)
	return setmetatable({}, FakeRng)
end }

-- ============ virtual clock (shadow read-only os) ============
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
local schedulerErrors = {}
task = {}
task.spawn = function(fn, ...)
	local args = { ... }
	local co = coroutine.create(function()
		fn(table.unpack(args))
	end)
	table.insert(runqueue, { co = co, at = 0 })
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
local function pumpTo(target)
	while true do
		-- find next due
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
						table.insert(schedulerErrors, tostring(err))
					end
				end
			else
				i += 1
			end
		end
	end
end

-- ============ misc globals ============
warn = function(...)
	print("[WARN]", ...)
end
debug = {
	traceback = function(err)
		return tostring(err)
	end,
}
Color3 = {
	fromRGB = function(r, g, b)
		return { R = r, G = g, B = b }
	end,
	new = function(r, g, b)
		return { R = r or 0, G = g or 0, B = b or 0 }
	end,
}

-- ============ service stubs (thin, behavior-preserving) ============
local balances = {}
local EconomyService = {
	GetCash = function(p)
		return balances[p.UserId] or 0
	end,
	DeductCash = function(p, amount)
		local cur = balances[p.UserId] or 0
		if cur < amount then
			return false
		end
		balances[p.UserId] = cur - amount
		return true
	end,
	AddCash = function(p, amount)
		balances[p.UserId] = (balances[p.UserId] or 0) + amount
		return true
	end,
}
local InventoryService = {
	GetItems = function(_p)
		return {}
	end,
	AddItem = function(_p, item)
		return item
	end,
	RemoveItem = function(_p, _id)
		return nil
	end,
}
local hrQualified = {}
local PlayerStatsService = {
	RecordWin = function(_p)
	end,
	Push = function(_p)
	end,
	GetWins = function(_p)
		return 0
	end,
	-- Econ sim: progression-qualified identities for HR measurement runs.
	GetStats = function(p)
		return { auctionsWon = hrQualified[p.UserId] and 5 or 0, collectionValue = 0 }
	end,
}
local DisplayService = {
	OnItemRemoved = function(_p, _id)
	end,
}
local MapBuilder = {
	SetDoorOpen = function(_h, _o)
	end,
	SetBarrier = function(_h, _b)
	end,
	ResetContainers = function(_h)
	end,
	SetPromptsEnabled = function(_h, _e)
	end,
	MarkContainerOpened = function(_h, _id)
	end,
	IsWithinBidRadius = function(_h, _p, _r)
		return true
	end,
	MovePlayerOutsideIfInside = function(_h, _p)
		return false
	end,
}
local function makeBox()
	return {
		FindFirstChildOfClass = function(_self, _class)
			return nil
		end,
	}
end
local function mkUnitHandles(bc, ids)
	local containers = {}
	for _, id in ipairs(ids) do
		containers[id] = makeBox()
	end
	return {
		Door = {},
		Barrier = {},
		Containers = containers,
		BidCenter = bc,
	}
end
local MapHandles = {
	Units = {
		mkUnitHandles({ X = 0, Y = 0, Z = 0 }, { "box_1", "box_2", "box_3" }),
		mkUnitHandles({ X = 90, Y = 0, Z = 40 }, { "box_4", "box_5", "box_6" }),
		mkUnitHandles({ X = 90, Y = 0, Z = 80 }, { "box_7", "box_8", "box_9" }),
	},
}
local Remotes = {
	FindFirstChild = function(_self, _name)
		return {
			IsA = function(_s, _c)
				return true
			end,
			FireAllClients = function(_s, _p)
			end,
			FireClient = function(_s, _pl, _p)
			end,
		}
	end,
}
local playersById = {}
local playersSvc = {
	PlayerRemoving = { Connect = function(_s, _fn) end },
	GetPlayers = function()
		local list = {}
		for _, p in pairs(playersById) do
			table.insert(list, p)
		end
		return list
	end,
	GetPlayerByUserId = function(_self, id)
		return playersById[id]
	end,
}
game = {
	GetService = function(_self, name)
		if name == "Players" then
			return playersSvc
		elseif name == "ReplicatedStorage" then
			return {
				WaitForChild = function(_s, _n)
					return {}
				end,
			}
		end
		error("unexpected service: " .. tostring(name))
	end,
	Workspace = {},
}

-- ============ load REAL modules ============
local GameConfig = require("./GameConfig")
local ItemUtils = require("./ItemUtils")
local UnitGeneratorService = require("./UnitGeneratorService")
local NPCBidderService = require("./NPCBidderService")
local AuctionService = require("./AuctionService")
local DebtService = require("./DebtService")
DebtService.Init({
	EconomyService = EconomyService,
	PlayerStatsService = PlayerStatsService,
	Remotes = Remotes,
	ATMPrompt = nil,
})

-- ============ recorders (wrap real functions, call through) ============
-- Session-routed metric slots: the MEASUREd session routes to AU, every
-- other session shares the spare slot. Declared up here so the wrappers
-- below capture these locals (not globals).
local MEASURE = 1
local MEASURE_IDS = { [1] = { box_1 = true, box_2 = true, box_3 = true },
	[2] = { box_4 = true, box_5 = true, box_6 = true },
	[3] = { box_7 = true, box_8 = true, box_9 = true } }
local function freshSlot()
	return { trueValue = 0, quality = "", visible = 0, hidden = 0, visibleSum = 0,
		npcInfo = {}, seriousMax = 0, bids = {}, bidCount = 0, recorded = false }
end
local AU, AU2 = freshSlot(), freshSlot()
local pendingTag = 1
local function slotForIds(ids)
	-- Measured session routes to AU; every other session shares the spare slot.
	for _, id in ipairs(ids) do
		if not MEASURE_IDS[MEASURE][id] then
			return AU2, 2
		end
	end
	return AU, 1
end
local RealGenerate = UnitGeneratorService.GenerateUnit
UnitGeneratorService.GenerateUnit = function(rng, ids, tier)
	local u = RealGenerate(rng, ids, tier)
	local slot, tag = slotForIds(ids)
	pendingTag = tag
	slot.trueValue = u.TrueTotalValue
	slot.quality = u.Quality
	slot.visible = #u.VisibleItems
	slot.hidden = #u.HiddenItems
	local vsum = 0
	for _, it in ipairs(u.VisibleItems) do
		vsum += tonumber(it.FinalValue) or 0
	end
	slot.visibleSum = vsum
	return u
end
local RealCreate = NPCBidderService.CreateBidders
local tickSlot = {} -- bidder table -> metric slot (1 or 2)
NPCBidderService.CreateBidders = function(defs, vis, hid, hiddenBaseline, budgetMult)
	local b = RealCreate(defs, vis, hid, hiddenBaseline, budgetMult)
	local slot = if pendingTag == 2 then AU2 else AU
	tickSlot[b] = slot
	slot.npcInfo = {}
	local seriousMax = 0
	for _, x in ipairs(b) do
		slot.npcInfo[x.Name] = {
			est = x.EstimatedValue,
			maxBid = x.MaxBid,
			budget = x.Budget,
			interested = x.Interested,
		}
		if x.Interested and x.MaxBid > seriousMax then
			seriousMax = x.MaxBid
		end
	end
	slot.seriousMax = seriousMax
	return b
end
local RealTick = NPCBidderService.Tick
NPCBidderService.Tick = function(bidders, t, cur, bidderName, lastBid, humans, tleft, highHuman, tryBidFn, mult)
	return RealTick(bidders, t, cur, bidderName, lastBid, humans, tleft, highHuman, function(name, amount)
		local ok = tryBidFn(name, amount)
		if ok then
			local slot = tickSlot[bidders] or AU
			slot.bidCount += 1
			table.insert(slot.bids, { who = name, npc = true, amount = amount })
		end
		return ok
	end, mult)
end
local RealTryBid = AuctionService.TryBid
AuctionService.TryBid = function(unitIndex, p, amount, isNPC, name)
	local ok, msg = RealTryBid(unitIndex, p, amount, isNPC, name)
	if ok then
		local slot = if tonumber(unitIndex) == MEASURE then AU else AU2
		slot.bidCount += 1
		table.insert(slot.bids, {
			who = if isNPC then name else p.Name,
			npc = isNPC == true,
			amount = amount,
		})
	end
	return ok, msg
end

AuctionService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	NPCBidderService = NPCBidderService,
	MapBuilder = MapBuilder,
	MapHandles = MapHandles,
	Remotes = Remotes,
	PlayerStatsService = PlayerStatsService,
	DisplayService = DisplayService,
	DebtService = DebtService,
})

-- ============ human agents ============
local function makeHuman(userId, name, noiseSeed)
	local h = { Name = name, UserId = userId, maxVal = 0 }
	playersById[userId] = h
	task.spawn(function()
		while true do
			task.wait(0.4 + nextRand() * 0.8)
			local snap = AuctionService.GetSnapshot().auctions[MEASURE]
			if snap.state == "Bidding" and snap.bidder ~= name then
				local inc = ItemUtils.BidIncrementFor(snap.currentBid)
				local amount = snap.currentBid + inc
				if amount <= h.maxVal and amount <= (balances[userId] or 0) then
					AuctionService.TryBid(MEASURE, h, amount, false, nil)
				end
			end
		end
	end)
	return h
end

-- Human willingness (documented assumption): reasons from the SAME visible
-- clues as NPCs (appraised with error) plus a per-hidden-box guess, jittered.
-- Humans do NOT know true value. Distinct draws per human.
local function rollHumanMax(visibleSum, hiddenCount)
	local appraised = visibleSum * (0.7 + nextRand() * 0.6)
	local guess = hiddenCount * 150 * (0.25 + nextRand() * 1.0)
	-- Humans demand margin like anyone else: haircut the willingness.
	return math.floor((appraised + guess) * 0.75 * (0.8 + nextRand() * 0.3))
end

-- ============ metrics ============
-- MEASURE selects the tier session under measurement (assigned below).
local results = { trueVals = {}, winBids = {}, ratios = {}, margins = {}, ests = {}, maxBids = {}, npcReach = {}, humanRatios = {}, humanMargins = {} }
local buckets = { lt25 = 0, b2540 = 0, b4065 = 0, b6590 = 0, b90110 = 0, gt110 = 0 }
local npcWins, humanWins, noBids, totalBids = 0, 0, 0, 0
local extremes = {}
local invariantFails = {}

local function pct(sorted, q)
	if #sorted == 0 then
		return 0
	end
	local idx = math.clamp(math.ceil(q * #sorted), 1, #sorted)
	return sorted[idx]
end

local function runScenario(mode, n, cashStart)
	local humans = {}
	if mode == "solo" then
		humans = { makeHuman(1, "Tester") }
	else
		humans = { makeHuman(1, "TesterA"), makeHuman(2, "TesterB") }
	end
	local done = 0
	local inBidding = false
	local bidStart = 0
	while done < n do
		pumpTo(vclock + 0.5)
		local snap = AuctionService.GetSnapshot().auctions[MEASURE]
		if snap.state == "Bidding" and not inBidding then
			inBidding = true
			bidStart = vclock
			-- fresh bankroll + fresh clue-based willingness per auction
			for _, h in ipairs(humans) do
				balances[h.UserId] = cashStart
				h.maxVal = rollHumanMax(AU.visibleSum or 0, AU.hidden or 0)
			end
			AU.bids = {}
			AU.bidCount = 0
		elseif snap.state ~= "Bidding" and inBidding then
			inBidding = false
		end
		if snap.state == "Sold" and not AU.recorded then
			AU.recorded = true
			done += 1
			local tv = AU.trueValue
			local wb = snap.currentBid
			local w = snap.winner or ""
			table.insert(results.trueVals, tv)
			table.insert(results.winBids, wb)
			-- Mechanism metric: strongest serious NPC maxBid vs true value.
			table.insert(results.npcReach, if tv > 0 then (AU.seriousMax or 0) / tv else 0)
			local ratio = if tv > 0 then wb / tv else 0
			table.insert(results.ratios, ratio)
			table.insert(results.margins, tv - wb)
			for _, b in ipairs(AU.bids) do
				if b.npc then
					local info = AU.npcInfo[b.who]
					if info then
						if b.amount > info.maxBid then
							table.insert(invariantFails, string.format("NPC %s bid %d > maxBid %d", b.who, b.amount, info.maxBid))
						end
						if b.amount > info.budget then
							table.insert(invariantFails, string.format("NPC %s bid %d > budget %d", b.who, b.amount, info.budget))
						end
					end
				end
			end
			-- self-outbid check on accepted-bid log
			for i = 2, #AU.bids do
				if AU.bids[i].who == AU.bids[i - 1].who then
					table.insert(invariantFails, string.format("self-outbid by %s at %d", AU.bids[i].who, AU.bids[i].amount))
				end
			end
			for _, info in pairs(AU.npcInfo) do
				table.insert(results.ests, info.est)
				table.insert(results.maxBids, info.maxBid)
			end
			if ratio < 0.25 then
				buckets.lt25 += 1
			elseif ratio < 0.40 then
				buckets.b2540 += 1
			elseif ratio < 0.65 then
				buckets.b4065 += 1
			elseif ratio < 0.90 then
				buckets.b6590 += 1
			elseif ratio <= 1.10 then
				buckets.b90110 += 1
			else
				buckets.gt110 += 1
			end
			local isNPCWinner = false
			for name, _ in pairs(AU.npcInfo) do
				if name == w then
					isNPCWinner = true
				end
			end
			if w == "" then
				noBids += 1
			elseif isNPCWinner then
				npcWins += 1
			else
				humanWins += 1
				table.insert(results.humanRatios, ratio)
				table.insert(results.humanMargins, tv - wb)
			end
			totalBids += AU.bidCount
			local key = string.format("q=%s tv=%d wb=%d vis=%d winner=%s", AU.quality, tv, wb, AU.visible, w)
			if extremes.cheapest == nil or tv < extremes.cheapest.tv then
				extremes.cheapest = { tv = tv, wb = wb, key = key }
			end
			if extremes.priciest == nil or tv > extremes.priciest.tv then
				extremes.priciest = { tv = tv, wb = wb, key = key }
			end
			local margin = tv - wb
			if extremes.bargain == nil or margin > extremes.bargain.margin then
				extremes.bargain = { tv = tv, wb = wb, margin = margin, key = key }
			end
			if extremes.overpay == nil or margin < extremes.overpay.margin then
				extremes.overpay = { tv = tv, wb = wb, margin = margin, key = key }
			end
		end
		if snap.state ~= "Sold" then
			AU.recorded = false
		end
		if vclock > 1000000 then
			print("TIMEOUT")
			break
		end
	end
	playersById = {}
end

local function summarize(name)
	local function sorted(t)
		local c = {}
		for _, v in ipairs(t) do
			table.insert(c, v)
		end
		table.sort(c)
		return c
	end
	local function mean(t)
		if #t == 0 then
			return 0
		end
		local s = 0
		for _, v in ipairs(t) do
			s += v
		end
		return s / #t
	end
	local tv, wb, ra, mg = sorted(results.trueVals), sorted(results.winBids), sorted(results.ratios), sorted(results.margins)
	local hr, hm = sorted(results.humanRatios), sorted(results.humanMargins)
	local nr = sorted(results.npcReach)
	print("===== " .. name .. " =====")
	print(string.format("trueValue: n=%d min=%d P10=%d P25=%d P50=%d P75=%d P90=%d P95=%d P99=%d max=%d mean=%.0f",
		#tv, pct(tv, 0), pct(tv, 0.10), pct(tv, 0.25), pct(tv, 0.5), pct(tv, 0.75), pct(tv, 0.9), pct(tv, 0.95), pct(tv, 0.99), pct(tv, 1), mean(tv)))
	print(string.format("winBid: min=%d P10=%d P25=%d P50=%d P75=%d P90=%d P95=%d max=%d mean=%.0f",
		pct(wb, 0), pct(wb, 0.10), pct(wb, 0.25), pct(wb, 0.5), pct(wb, 0.75), pct(wb, 0.9), pct(wb, 0.95), pct(wb, 1), mean(wb)))
	print(string.format("ratio win/true: P10=%.2f P25=%.2f P50=%.2f P75=%.2f P90=%.2f mean=%.2f",
		pct(ra, 0.10), pct(ra, 0.25), pct(ra, 0.5), pct(ra, 0.75), pct(ra, 0.9), mean(ra)))
	print(string.format("margin mean=%.0f P10=%.0f P90=%.0f", mean(mg), pct(mg, 0.10), pct(mg, 0.90)))
	print(string.format("HUMAN wins=%d ratio P50=%.2f P25=%.2f P75=%.2f marginMean=%.0f", #hr, pct(hr, 0.5), pct(hr, 0.25), pct(hr, 0.75), mean(hm)))
	print(string.format("buckets: <25%%=%d 25-40%%=%d 40-65%%=%d 65-90%%=%d 90-110%%=%d >110%%=%d",
		buckets.lt25, buckets.b2540, buckets.b4065, buckets.b6590, buckets.b90110, buckets.gt110))
	print(string.format("winners: human=%d npc=%d none=%d avgBids=%.1f", humanWins, npcWins, noBids, totalBids / math.max(1, (humanWins + npcWins + noBids))))
	local es, mb = sorted(results.ests), sorted(results.maxBids)
	print(string.format("npcEst: P50=%d P90=%d max=%d mean=%.0f", pct(es, 0.5), pct(es, 0.9), pct(es, 1), mean(es)))
	print(string.format("npcMax: P50=%d P90=%d max=%d mean=%.0f", pct(mb, 0.5), pct(mb, 0.9), pct(mb, 1), mean(mb)))
	print(string.format("npcReach seriousMax/true: P10=%.2f P25=%.2f P50=%.2f P75=%.2f P90=%.2f mean=%.2f",
		pct(nr, 0.10), pct(nr, 0.25), pct(nr, 0.5), pct(nr, 0.75), pct(nr, 0.9), mean(nr)))
	print("cheapest: " .. (extremes.cheapest and extremes.cheapest.key or "?"))
	print("priciest: " .. (extremes.priciest and extremes.priciest.key or "?"))
	print("bargain: " .. (extremes.bargain and (extremes.bargain.key .. " margin=" .. extremes.bargain.margin) or "?"))
	print("overpay: " .. (extremes.overpay and (extremes.overpay.key .. " margin=" .. extremes.overpay.margin) or "?"))
	print("invariantFails: " .. #invariantFails)
	for _, f in ipairs(invariantFails) do
		print("  FAIL: " .. f)
	end
end

local args = { ... }
local mode = "solo"
local n = 1000
-- Per-tier runs: MEASURE session + bankroll that clears its gate.
-- Budget: session 1, $1000. Standard: session 2, $1000 (MinCash 300).
-- HighRoller: session 3, $10000 + qualified wins.
local tierRun = "standard"
if tierRun == "standard" then
	MEASURE = 2
elseif tierRun == "highroller" then
	MEASURE = 3
	hrQualified[1] = true
end
local cashStart = if MEASURE == 3 then 10000 else GameConfig.StartingCash
runScenario(mode, n, cashStart)
summarize(mode .. " N=" .. n)
if #schedulerErrors > 0 then
	print("schedulerErrors: " .. #schedulerErrors)
	for _, e in ipairs(schedulerErrors) do
		print("ERR:", string.sub(tostring(e), 1, 200))
	end
end
