--!nonstrict
-- StorageAuction — centralized item definitions (Milestone 1: 10 placeholders).
-- Gameplay scripts must NEVER hard-code items. Require this module instead.
--
-- Generated item instances (see ItemUtils) carry future-proof fields:
--   InstanceId, ItemId, Name, BaseValue, Rarity, Condition,
--   FinalValue, Modifiers (empty table for now: Signed, Golden, etc.)

local ItemDefinitions = {
	{ Id = "old_lamp",       Name = "Old Lamp",          BaseValue = 40,   SpawnWeight = 20 },
	{ Id = "rusty_toolbox",  Name = "Rusty Toolbox",     BaseValue = 60,   SpawnWeight = 18 },
	{ Id = "wooden_chair",   Name = "Wooden Chair",      BaseValue = 80,   SpawnWeight = 16 },
	{ Id = "leather_jacket", Name = "Leather Jacket",    BaseValue = 150,  SpawnWeight = 13 },
	{ Id = "vinyl_record",   Name = "Vinyl Record",      BaseValue = 200,  SpawnWeight = 11 },
	{ Id = "toy_robot",      Name = "Toy Robot",         BaseValue = 300,  SpawnWeight = 9 },
	{ Id = "vintage_comic",  Name = "Vintage Comic",     BaseValue = 500,  SpawnWeight = 6 },
	{ Id = "retro_console",  Name = "Retro Game Console",BaseValue = 700,  SpawnWeight = 4 },
	{ Id = "brass_telescope",Name = "Brass Telescope",   BaseValue = 1100, SpawnWeight = 2 },
	{ Id = "gold_watch",     Name = "Golden Pocket Watch",BaseValue = 2000,SpawnWeight = 1 },
}

local byId = {}
for _, def in ipairs(ItemDefinitions) do
	byId[def.Id] = def
end

function ItemDefinitions.GetById(id)
	return byId[id]
end

function ItemDefinitions.TotalWeight()
	local total = 0
	for _, def in ipairs(ItemDefinitions) do
		total += def.SpawnWeight
	end
	return total
end

return ItemDefinitions
