--!nonstrict
-- StorageAuction MVP — first progression layer (session-only foundation).
--
-- Tracks per player:
--   AuctionsWon: incremented when a real player wins and pays.
--   CollectionValue: sum of FinalValue over currently KEPT inventory items.
--   PremiumUnlocked: AuctionsWon >= threshold OR CollectionValue >= threshold.
--
-- Session-only for now; structured so DataStore fields can be added next
-- (see PlayerDataService) without changing callers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local PlayerStatsService = {}

local InventoryService = nil
local Remotes = nil

local auctionsWon = {} -- [UserId] = number

function PlayerStatsService.Init(deps)
	InventoryService = deps.InventoryService
	Remotes = deps.Remotes
end

local function collectionValue(player)
	local total = 0
	for _, item in ipairs(InventoryService.GetItems(player)) do
		total += tonumber(item.FinalValue) or 0
	end
	return total
end

function PlayerStatsService.GetStats(player)
	local won = auctionsWon[player.UserId] or 0
	local value = collectionValue(player)
	return {
		auctionsWon = won,
		collectionValue = value,
		premiumUnlocked = won >= GameConfig.PremiumAuctionsWinsRequired
			or value >= GameConfig.PremiumAuctionsValueRequired,
		winsRequired = GameConfig.PremiumAuctionsWinsRequired,
		valueRequired = GameConfig.PremiumAuctionsValueRequired,
	}
end

function PlayerStatsService.Push(player)
	if not Remotes then
		return
	end
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.StatsChanged)
	if ev then
		ev:FireClient(player, PlayerStatsService.GetStats(player))
	end
end

function PlayerStatsService.RecordWin(player)
	if not player then
		return
	end
	auctionsWon[player.UserId] = (auctionsWon[player.UserId] or 0) + 1
	PlayerStatsService.Push(player)
end

function PlayerStatsService.GetWins(player)
	if not player then
		return 0
	end
	return auctionsWon[player.UserId] or 0
end

-- Restore persisted win count (sanitized, never negative). Called once at
-- load; never increments. No persistence logic lives here.
function PlayerStatsService.RestoreWins(player, count)
	if not player then
		return
	end
	count = math.floor(tonumber(count) or 0)
	if count < 0 then
		count = 0
	end
	auctionsWon[player.UserId] = count
	PlayerStatsService.Push(player)
end

function PlayerStatsService.ClearPlayer(player)
	if player then
		auctionsWon[player.UserId] = nil
	end
end

return PlayerStatsService
