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

-- containerIds: array of Studio container ids (sorted by caller for stability).
-- Returns { Seed, Quality, VisibleItems, Containers, TrueTotalValue }.
-- Containers: { { ContainerId, Items = { itemInstance } } }, one item per box
-- (preserves the pending Sell/Keep + display flow untouched).
function UnitGeneratorService.GenerateUnit(rng, containerIds)
	rng = rng or Random.new()
	local seed = rng:NextInteger(1, 999999999)
	local quality = rollQuality(rng)
	local qdef = GameConfig.UnitQuality.Defs[quality] or GameConfig.UnitQuality.Defs.Average

	local function lootOpts()
		return {
			JunkChance = qdef.JunkChance,
			ValueScaleMin = qdef.ValueScaleMin,
			ValueScaleMax = qdef.ValueScaleMax,
			RarityLuck = qdef.RarityLuck,
		}
	end

	-- Hidden loot: one item per Studio container. Fixed now, revealed later.
	local containers = {}
	local trueTotal = 0
	local sortedIds = {}
	for _, id in ipairs(containerIds) do
		table.insert(sortedIds, id)
	end
	table.sort(sortedIds)
	for _, id in ipairs(sortedIds) do
		local item = ItemUtils.GenerateInstance(rng, lootOpts())
		trueTotal += item.FinalValue
		table.insert(containers, { ContainerId = id, Items = { item } })
	end

	-- Visible clues: display-only, NOT loot, NOT in the true total.
	-- (NPCs form their own noisy estimates; humans read these.)
	local clueCount = 2 + rng:NextInteger(0, 2)
	local visible = {}
	for _ = 1, clueCount do
		local item = ItemUtils.GenerateInstance(rng, lootOpts())
		table.insert(visible, {
			Name = item.Name,
			Rarity = item.Rarity,
			Condition = item.Condition,
			ConditionName = item.ConditionName,
		})
	end

	if GameConfig.DebugAuction then
		print(string.format("[SA] Generated unit quality=%s trueValue=%d boxes=%d clues=%d",
			quality, trueTotal, #containers, #visible))
	end

	return {
		Seed = seed,
		Quality = quality,
		VisibleItems = visible,
		Containers = containers,
		TrueTotalValue = trueTotal,
	}
end

return UnitGeneratorService
