--!nonstrict
-- StorageAuction — centralized item definitions (Milestone 1: 10 placeholders).
-- Gameplay scripts must NEVER hard-code items. Require this module instead.
--
-- Generated item instances (see ItemUtils) carry future-proof fields:
--   InstanceId, ItemId, Name, BaseValue, Rarity, Condition,
--   FinalValue, Modifiers (empty table for now: Signed, Golden, etc.)

local ItemDefinitions = {
	{ Id = "old_lamp",       Name = "Old Lamp",          BaseValue = 40,   SpawnWeight = 20, ModelKey = "OldLamp" },
	{ Id = "rusty_toolbox",  Name = "Rusty Toolbox",     BaseValue = 60,   SpawnWeight = 18, ModelKey = "RustyToolbox" },
	{ Id = "wooden_chair",   Name = "Wooden Chair",      BaseValue = 80,   SpawnWeight = 16, ModelKey = "WoodenChair" },
	{ Id = "leather_jacket", Name = "Leather Jacket",    BaseValue = 150,  SpawnWeight = 13, ModelKey = "LeatherJacket" },
	{ Id = "vinyl_record",   Name = "Vinyl Record",      BaseValue = 200,  SpawnWeight = 11, ModelKey = "VinylRecord" },
	{ Id = "toy_robot",      Name = "Toy Robot",         BaseValue = 300,  SpawnWeight = 9,  ModelKey = "ToyRobot" },
	{ Id = "vintage_comic",  Name = "Vintage Comic",     BaseValue = 500,  SpawnWeight = 6,  ModelKey = "VintageComic" },
	{ Id = "retro_console",  Name = "Retro Game Console",BaseValue = 700,  SpawnWeight = 4,  ModelKey = "RetroConsole" },
	{ Id = "brass_telescope",Name = "Brass Telescope",   BaseValue = 1100, SpawnWeight = 2,  ModelKey = "BrassTelescope" },
	{ Id = "gold_watch",     Name = "Golden Pocket Watch",BaseValue = 2000,SpawnWeight = 1,  ModelKey = "GoldWatch" },
	-- Junk defs: only picked via JunkChance (trash-unit filler), never in the
	-- normal weighted pool, so base probabilities stay exactly as tuned.
	{ Id = "tangled_cables", Name = "Tangled Cables",    BaseValue = 15,   SpawnWeight = 0,  ModelKey = "TangledCables", Junk = true },
	{ Id = "broken_toaster", Name = "Broken Toaster",    BaseValue = 25,   SpawnWeight = 0,  ModelKey = "BrokenToaster", Junk = true },
	{ Id = "stained_mattress", Name = "Stained Mattress",BaseValue = 35,   SpawnWeight = 0,  ModelKey = "StainedMattress", Junk = true },
}

local byId = {}
for _, def in ipairs(ItemDefinitions) do
	byId[def.Id] = def
end

function ItemDefinitions.GetById(id)
	return byId[id]
end

-- Uniform pick among Junk-flagged defs (trash-unit filler). Normal weighted
-- rolls never select these (SpawnWeight 0), so base odds are untouched.
function ItemDefinitions.RollJunkDef(rng)
	rng = rng or Random.new()
	local junk = {}
	for _, def in ipairs(ItemDefinitions) do
		if def.Junk then
			table.insert(junk, def)
		end
	end
	if #junk == 0 then
		return ItemDefinitions[1]
	end
	return junk[rng:NextInteger(1, #junk)]
end

function ItemDefinitions.TotalWeight()
	local total = 0
	for _, def in ipairs(ItemDefinitions) do
		total += def.SpawnWeight
	end
	return total
end

return ItemDefinitions
