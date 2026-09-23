--!nonstrict
-- StorageAuction — pure shared helpers: rarity rolls, condition, value formula.
-- No Roblox services required; safe to require from server AND client (client
-- uses it for display math only — server is authoritative).

local GameConfig = require(script.Parent.GameConfig)
local RarityConfig = require(script.Parent.RarityConfig)
local ItemDefinitions = require(script.Parent.ItemDefinitions)

local ItemUtils = {}

local nextInstanceSeq = 0

function ItemUtils.RollRarity(rng, luck)
	rng = rng or Random.new()
	luck = luck or 0
	local total = 0
	local weights = {}
	for _, name in ipairs(RarityConfig.Order) do
		local w = RarityConfig.Definitions[name].Weight
		if name == "Rare" or name == "Epic" or name == "Legendary" or name == "Mythic" then
			w *= 1 + luck * 0.7
		elseif name == "Common" then
			w /= 1 + luck * 0.4
		end
		weights[name] = w
		total += w
	end
	local roll = rng:NextNumber() * total
	for _, name in ipairs(RarityConfig.Order) do
		roll -= weights[name]
		if roll <= 0 then
			return name
		end
	end
	return "Common"
end

function ItemUtils.RollCondition(rng)
	rng = rng or Random.new()
	return rng:NextInteger(GameConfig.MinCondition, GameConfig.MaxCondition)
end

function ItemUtils.ConditionMultiplier(condition)
	local floor = GameConfig.ConditionFloor
	return floor + (1 - floor) * (condition / 100)
end

function ItemUtils.CalcFinalValue(baseValue, rarityName, condition)
	local rarityDef = RarityConfig.Definitions[rarityName]
	local rarityMult = if rarityDef then rarityDef.ValueMult else 1.0
	local raw = math.floor(baseValue * rarityMult * ItemUtils.ConditionMultiplier(condition) + 0.5)
	return math.clamp(raw, GameConfig.MinItemValue, GameConfig.MaxItemValue)
end

-- Named condition bands for display (multiplier stays formula-driven).
function ItemUtils.ConditionName(condition)
	condition = tonumber(condition) or 0
	if condition < 20 then
		return "Broken"
	elseif condition < 40 then
		return "Poor"
	elseif condition < 60 then
		return "Used"
	elseif condition < 80 then
		return "Good"
	elseif condition < 95 then
		return "Excellent"
	else
		return "Mint"
	end
end

-- Single source for bid increments: first tier whose MaxPrice covers price.
function ItemUtils.BidIncrementFor(price)
	price = tonumber(price) or 0
	for _, tier in ipairs(GameConfig.BidIncrementTiers) do
		if price <= tier.MaxPrice then
			return tier.Increment
		end
	end
	return GameConfig.BidIncrementTiers[#GameConfig.BidIncrementTiers].Increment
end

function ItemUtils.RollItemDef(rng)
	rng = rng or Random.new()
	local total = ItemDefinitions.TotalWeight()
	local roll = rng:NextNumber() * total
	for _, def in ipairs(ItemDefinitions) do
		roll -= def.SpawnWeight
		if roll <= 0 then
			return def
		end
	end
	return ItemDefinitions[1]
end

-- Server-side: create a full randomized item instance.
-- opts (all optional): JunkChance (force junk def), ValueScaleMin/Max
-- (multiply final value), RarityLuck (bias rarity upward).
function ItemUtils.GenerateInstance(rng, opts)
	rng = rng or Random.new()
	opts = opts or {}
	local def
	if opts.JunkChance and rng:NextNumber() < opts.JunkChance then
		def = ItemDefinitions.RollJunkDef(rng)
	else
		def = ItemUtils.RollItemDef(rng)
	end
	local rarity = ItemUtils.RollRarity(rng, opts.RarityLuck or 0)
	local condition = ItemUtils.RollCondition(rng)
	local scale = 1
	if opts.ValueScaleMin or opts.ValueScaleMax then
		scale = rng:NextNumber(opts.ValueScaleMin or 1, opts.ValueScaleMax or 1)
	end
	nextInstanceSeq += 1
	return {
		InstanceId = "m1_" .. tostring(os.clock()):gsub("%.", "") .. "_" .. tostring(nextInstanceSeq),
		ItemId = def.Id,
		Name = def.Name,
		BaseValue = def.BaseValue,
		ModelKey = def.ModelKey,
		Rarity = rarity,
		Condition = condition,
		ConditionName = ItemUtils.ConditionName(condition),
		FinalValue = math.clamp(
			math.floor(ItemUtils.CalcFinalValue(def.BaseValue, rarity, condition) * scale + 0.5),
			GameConfig.MinItemValue, GameConfig.MaxItemValue),
		-- Reserved for future modifiers (Signed, Golden, Sealed, serials...)
		-- without rewriting inventory architecture.
		Modifiers = {},
	}
end

return ItemUtils
