--!nonstrict
-- StorageAuction V2 — randomized hidden loot generation (server only).
--
-- One unit is generated BEFORE Inspection. Its contents are fixed from that
-- moment: rummaging reveals these exact instances, never rerolls.
-- TrueTotalValue and per-box contents stay server-side; clients only ever
-- receive visible-clue summaries (names + condition bands, no values).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local ItemUtils = require(Shared.ItemUtils)

local UnitGeneratorService = {}

local function rollQuality(rng)
	local weights = GameConfig.UnitQuality.Weights
	local total = 0
	for _, name in ipairs(GameConfig.UnitQuality.Order) do
		total += weights[name] or 0
	end
	local roll = rng:NextNumber() * total
	for _, name in ipairs(GameConfig.UnitQuality.Order) do
		roll -= weights[name] or 0
		if roll <= 0 then
			return name
		end
	end
	return "Average"
end

-- How many of the unit's real items show during Inspection. Weights come
-- from config; counts above the actual item total are ignored.
local function rollVisibleCount(rng, total)
	local weights = GameConfig.VisibleCountWeights or { [0] = 15, [1] = 35, [2] = 35, [3] = 15 }
	local sum = 0
	for count = 0, total do
		sum += weights[count] or 0
	end
	if sum <= 0 then
		return math.min(1, total)
	end
	local roll = rng:NextNumber() * sum
	for count = 0, total do
		roll -= weights[count] or 0
		if roll <= 0 then
			return count
		end
	end
	return total
end

-- containerIds: array of Studio container ids (sorted by caller for stability).
-- Returns one REAL item set with a visible/hidden split:
--   { Seed, Quality, AllItems, VisibleItems, HiddenItems, Containers,
--     TrueTotalValue }
-- VisibleItems/HiddenItems reference the SAME item tables as Containers and
-- AllItems (no clones, no rerolls). TrueTotalValue covers visible + hidden.
-- Containers: { { ContainerId, Items = { item } } }, one item per box
-- (preserves the pending Sell/Keep + display flow untouched).
function UnitGeneratorService.GenerateUnit(rng, containerIds, tierId)
	rng = rng or Random.new()
	local tier = GameConfig.AuctionTiers[tierId] or GameConfig.AuctionTiers.Standard
	local seed = rng:NextInteger(1, 999999999)
	local quality = rollQuality(rng, tier.QualityWeights)
	local qdef = GameConfig.UnitQuality.Defs[quality] or GameConfig.UnitQuality.Defs.Average

	local function lootOpts()
		return {
			JunkChance = math.min(0.9, qdef.JunkChance * (tier.JunkChanceMult or 1)),
			ValueScaleMin = qdef.ValueScaleMin * (tier.ValueScaleMult and tier.ValueScaleMult.Min or 1),
			ValueScaleMax = qdef.ValueScaleMax * (tier.ValueScaleMult and tier.ValueScaleMult.Max or 1),
			RarityLuck = qdef.RarityLuck + (tier.RarityLuckBonus or 0),
		}
	end

	-- Hidden loot: one item per Studio container. Fixed now, revealed later.
	local containers = {}
	local allItems = {}
	local trueTotal = 0
	local sortedIds = {}
	for _, id in ipairs(containerIds) do
		table.insert(sortedIds, id)
	end
	table.sort(sortedIds)
	for _, id in ipairs(sortedIds) do
		local item = ItemUtils.GenerateInstance(rng, lootOpts())
		trueTotal += item.FinalValue
		table.insert(allItems, item)
		table.insert(containers, { ContainerId = id, Items = { item } })
	end

	-- Visible/hidden split over the SAME item tables: shuffle indices, first
	-- N become visible. Visible items are real loot, part of the true total.
	local order = {}
	for i = 1, #allItems do
		order[i] = i
	end
	for i = #order, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	local visibleTarget = rollVisibleCount(rng, #allItems)
	local visible, hidden = {}, {}
	for rank, idx in ipairs(order) do
		if rank <= visibleTarget then
			table.insert(visible, allItems[idx])
		else
			table.insert(hidden, allItems[idx])
		end
	end

	if GameConfig.DebugAuction then
		print(string.format("[SA] Tier=%s Generated unit quality=%s trueValue=%d boxes=%d visible=%d hidden=%d",
			tostring(tierId), quality, trueTotal, #containers, #visible, #hidden))
	end

	return {
		Seed = seed,
		Quality = quality,
		TierId = tierId,
		AllItems = allItems,
		VisibleItems = visible,
		HiddenItems = hidden,
		Containers = containers,
		TrueTotalValue = trueTotal,
	}
end

return UnitGeneratorService
