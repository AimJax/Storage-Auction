--!nonstrict
-- StorageAuction — rarity hierarchy + probabilities + value multipliers.
-- All probability tuning lives here. Services must require this module.

local RarityConfig = {
	Order = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" },

	-- SpawnWeight: relative probability. ValueMult: multiplies BaseValue.
	-- Colors: used by client reveal UI.
	Definitions = {
		Common =    { Weight = 50.0, ValueMult = 1.0, Color = Color3.fromRGB(180, 180, 180) },
		Uncommon =  { Weight = 25.0, ValueMult = 1.6, Color = Color3.fromRGB(90, 200, 90) },
		Rare =      { Weight = 13.0, ValueMult = 2.8, Color = Color3.fromRGB(80, 140, 255) },
		Epic =      { Weight = 7.0,  ValueMult = 5.0, Color = Color3.fromRGB(170, 90, 255) },
		Legendary = { Weight = 3.5,  ValueMult = 9.0, Color = Color3.fromRGB(255, 170, 30) },
		Mythic =    { Weight = 1.5,  ValueMult = 16.0, Color = Color3.fromRGB(255, 70, 120) },
	},
}

return RarityConfig
