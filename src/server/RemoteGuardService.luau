--!nonstrict
-- StorageAuction — tiny per-user remote spam throttle (server-side).
-- Normal human clicking is unaffected (cooldowns are far below human pace);
-- exploit loops hammering RemoteFunctions get cheap rejections instead of
-- churning game state. Server-internal NPC paths never pass through here.
-- Cooldowns are advisory UX guards, not security boundaries: every remote
-- still validates fully.

local RemoteGuardService = {}

-- [UserId] = { [action] = last os.clock timestamp }
local lastAction = {}

local COOLDOWNS = {
	PlaceBid = 0.08,
	OpenContainer = 0.10,
	KeepItem = 0.10,
	SellItem = 0.10,
	DisplayItem = 0.15,
	RemoveDisplay = 0.15,
	TakeLoan = 0.15,
	ClaimRecovery = 0.15,
	UpgradeWarehouse = 0.25,
}

-- Returns (allowed, retryAfterSeconds). Unknown actions pass through.
function RemoteGuardService.Check(player, action)
	local cooldown = COOLDOWNS[action]
	if not player or cooldown == nil then
		return true, 0
	end
	local now = os.clock()
	local userActions = lastAction[player.UserId]
	if not userActions then
		userActions = {}
		lastAction[player.UserId] = userActions
	end
	local last = userActions[action] or -1000
	local elapsed = now - last
	if elapsed < cooldown then
		return false, cooldown - elapsed
	end
	userActions[action] = now
	return true, 0
end

function RemoteGuardService.ClearPlayer(player)
	if player then
		lastAction[player.UserId] = nil
	end
end

return RemoteGuardService
