-- Stage 4: 10k-per-tier generation audit (dev harness, NOT game code).
-- Uses REAL staged modules. Proves tier QualityWeights are actually consumed.
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

local rngState = 13579
Random = { new = function(_s)
	return {
		NextNumber = function(_self, a, b)
			rngState = (rngState * 1103515245 + 12345) % 2147483648
			local r = rngState / 2147483648
			if a == nil then
				return r
			end
			return a + r * (b - a)
		end,
		NextInteger = function(_self, a, b)
			rngState = (rngState * 1103515245 + 12345) % 2147483648
			return a + (rngState % (b - a + 1))
		end,
	}
end }
warn = function(...) end
Color3 = { fromRGB = function(r, g, b)
	return { R = r, G = g, B = b }
end }
game = {
	GetService = function(_s, name)
		if name == "ReplicatedStorage" then
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
local UnitGeneratorService = require("./UnitGeneratorService")

-- Count junk picks through the real junk-def path.
local ItemDefinitions = require("./ItemDefinitions")
local junkPicks = 0
local RealRollJunk = ItemDefinitions.RollJunkDef
ItemDefinitions.RollJunkDef = function(rng)
	junkPicks += 1
	return RealRollJunk(rng)
end

local function pct(sorted, q)
	if #sorted == 0 then
		return 0
	end
	local idx = math.clamp(math.ceil(q * #sorted), 1, #sorted)
	return sorted[idx]
end

local IDS = { "box_1", "box_2", "box_3" }
local results = {}

for _, tierId in ipairs({ "Budget", "Standard", "HighRoller" }) do
	local tier = {}
	for k, v in pairs(GameConfig.Tiers[tierId]) do
		tier[k] = v
	end
	tier.TierId = tierId
	local vals = {}
	local quals = {}
	local visCounts = {}
	local items = 0
	junkPicks = 0
	local rng = Random.new()
	for _ = 1, 10000 do
		local u = UnitGeneratorService.GenerateUnit(rng, IDS, tier)
		table.insert(vals, u.TrueTotalValue)
		quals[u.Quality] = (quals[u.Quality] or 0) + 1
		visCounts[#u.VisibleItems] = (visCounts[#u.VisibleItems] or 0) + 1
		items += #u.AllItems
		check(u.TierId == tierId, "tier tag")
		if failures > 5 then
			break
		end
	end
	table.sort(vals)
	local function mean()
		local s = 0
		for _, v in ipairs(vals) do
			s += v
		end
		return s / #vals
	end
	results[tierId] = { vals = vals, mean = mean(), quals = quals, junk = junkPicks, items = items, vis = visCounts }
	print(string.format("===== %s N=10000 =====", tierId))
	print(string.format("value: mean=%.0f min=%d P10=%d P25=%d P50=%d P75=%d P90=%d P95=%d P99=%d max=%d",
		mean(), pct(vals, 0), pct(vals, 0.10), pct(vals, 0.25), pct(vals, 0.5), pct(vals, 0.75),
		pct(vals, 0.9), pct(vals, 0.95), pct(vals, 0.99), pct(vals, 1)))
	local qline = "quality:"
	for _, q in ipairs(GameConfig.UnitQuality.Order) do
		qline ..= string.format(" %s=%d", q, quals[q] or 0)
	end
	print(qline)
	print(string.format("junk: %d/%d items (%.1f%%)", junkPicks, items, 100 * junkPicks / items))
	local vline = "visible:"
	for c = 0, 3 do
		vline ..= string.format(" %d=%d", c, visCounts[c] or 0)
	end
	print(vline)
	print(string.format("startBid/median: %d/%d = %.2f", tier.StartingBid, pct(vals, 0.5), tier.StartingBid / pct(vals, 0.5)))
end

-- Ordering: Budget < Standard < HighRoller in expected value.
check(results.Budget.mean < results.Standard.mean and results.Standard.mean < results.HighRoller.mean, "G1 mean ordering B<S<HR")
check(pct(results.Budget.vals, 0.5) < pct(results.Standard.vals, 0.5) and pct(results.Standard.vals, 0.5) < pct(results.HighRoller.vals, 0.5), "G2 median ordering")
-- Separation without total isolation: Budget P90 below HR median, but overlap exists.
check(pct(results.Budget.vals, 0.9) < pct(results.HighRoller.vals, 0.5), "G3 Budget P90 < HR median")
check(pct(results.Budget.vals, 1) > pct(results.HighRoller.vals, 0), "G4 some overlap (Budget max > HR min)")
-- Quality weights actually consumed: compare Jackpot counts to weights (3/100 vs 1/100 vs 8/100).
local jB = results.Budget.quals.Jackpot or 0
local jS = results.Standard.quals.Jackpot or 0
local jH = results.HighRoller.quals.Jackpot or 0
print(string.format("jackpots: B=%d S=%d H=%d (expect ~100/300/800)", jB, jS, jH))
check(jB < 200 and jS > 150 and jS < 500 and jH > 500, "G5 Jackpot frequency follows tier weights")
check(results.Budget.junk > results.Standard.junk and results.Standard.junk > results.HighRoller.junk, "G6 junk frequency ordering")
-- Distributions differ (Budget Trash-heavy vs HR Good/Premium-heavy).
local bTrash = (results.Budget.quals.Trash or 0) + (results.Budget.quals.Low or 0)
local hTop = (results.HighRoller.quals.Good or 0) + (results.HighRoller.quals.Premium or 0) + (results.HighRoller.quals.Jackpot or 0)
check(bTrash > 5000 and hTop > 5000, "G7 Budget bottom-heavy, HR top-heavy")

if failures > 0 then
	print("TIER-GEN AUDIT: FAILED")
else
	print("TIER-GEN AUDIT: ALL PASS")
end
