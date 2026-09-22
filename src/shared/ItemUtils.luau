--!nonstrict
-- StorageAuction — pure shared helpers: rarity rolls, condition, value formula.
-- No Roblox services required; safe to require from server AND client (client
-- uses it for display math only — server is authoritative).

local GameConfig = require(script.Parent.GameConfig)
local RarityConfig = require(script.Parent.RarityConfig)
local ItemDefinitions = require(script.Parent.ItemDefinitions)

local ItemUtils = {}

local nextInstanceSeq = 0

function ItemUtils.RollRarity(rng)
	rng = rng or Random.new()
	local total = 0
	for _, name in ipairs(RarityConfig.Order) do
		total += RarityConfig.Definitions[name].Weight
	end
	local roll = rng:NextNumber() * total
	for _, name in ipairs(RarityConfig.Order) do
		roll -= RarityConfig.Definitions[name].Weight
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
	return math.floor(baseValue * rarityMult * ItemUtils.ConditionMultiplier(condition) + 0.5)
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
function ItemUtils.GenerateInstance(rng)
	rng = rng or Random.new()
	local def = ItemUtils.RollItemDef(rng)
	local rarity = ItemUtils.RollRarity(rng)
	local condition = ItemUtils.RollCondition(rng)
	nextInstanceSeq += 1
	return {
		InstanceId = "m1_" .. tostring(os.clock()):gsub("%.", "") .. "_" .. tostring(nextInstanceSeq),
		ItemId = def.Id,
		Name = def.Name,
		BaseValue = def.BaseValue,
		Rarity = rarity,
		Condition = condition,
		FinalValue = ItemUtils.CalcFinalValue(def.BaseValue, rarity, condition),
		-- Reserved for future modifiers (Signed, Golden, Sealed, serials...)
		-- without rewriting inventory architecture.
		Modifiers = {},
	}
end

return ItemUtils
