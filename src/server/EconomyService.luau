--!nonstrict
-- StorageAuction — server-authoritative Cash ledger.
-- All Cash reads/writes go through here. Client never sets its own balance.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local EconomyService = {}
EconomyService.__index = EconomyService

local balances = {} -- [UserId] = number
local remotesFolder = nil

function EconomyService.Init(remotes)
	remotesFolder = remotes
end

local function pushCashChanged(player, amount)
	if remotesFolder then
		local ev = remotesFolder:FindFirstChild(GameConfig.RemoteNames.CashChanged)
		if ev then
			ev:FireClient(player, amount)
		end
	end
	local leader = player:FindFirstChild("leaderstats")
	if leader then
		local cash = leader:FindFirstChild("Cash")
		if cash then
			cash.Value = amount
		end
	end
end

-- Idempotent setup: reuses existing leaderstats/Cash instead of creating
-- duplicates on double-init. Silent mode skips the push so DataStore load
-- can restore final values before the client ever sees a number.
function EconomyService.SetupPlayer(player, startingCash, silent)
	startingCash = startingCash or GameConfig.StartingCash
	if balances[player.UserId] == nil then
		balances[player.UserId] = startingCash
	end
	local leader = player:FindFirstChild("leaderstats")
	if not (leader and leader:IsA("Folder")) then
		leader = Instance.new("Folder")
		leader.Name = "leaderstats"
		leader.Parent = player
	end
	local cash = leader:FindFirstChild("Cash")
	if not (cash and cash:IsA("IntValue")) then
		cash = Instance.new("IntValue")
		cash.Name = "Cash"
		cash.Parent = leader
	end
	cash.Value = balances[player.UserId]
	if not silent then
		pushCashChanged(player, balances[player.UserId])
	end
end

function EconomyService.GetCash(playerOrUserId)
	local id = if typeof(playerOrUserId) == "Instance" then playerOrUserId.UserId else playerOrUserId
	return balances[id] or 0
end

-- Returns true/false; clamps at 0. Never lets balance go negative via deduct.
function EconomyService.AddCash(player, amount)
	amount = math.floor(amount or 0)
	if amount <= 0 then
		return false
	end
	local id = player.UserId
	balances[id] = math.min(GameConfig.MaxCash, (balances[id] or 0) + amount)
	pushCashChanged(player, balances[id])
	return true
end

function EconomyService.DeductCash(player, amount)
	amount = math.floor(amount or 0)
	if amount <= 0 then
		return false
	end
	local id = player.UserId
	local cur = balances[id] or 0
	if cur < amount then
		return false
	end
	balances[id] = cur - amount
	pushCashChanged(player, balances[id])
	return true
end

function EconomyService.SetCash(player, amount)
	balances[player.UserId] = math.clamp(math.floor(amount or 0), 0, GameConfig.MaxCash)
	pushCashChanged(player, balances[player.UserId])
end

function EconomyService.CanAfford(player, amount)
	return (balances[player.UserId] or 0) >= amount
end

function EconomyService.ClearPlayer(player)
	balances[player.UserId] = nil
end

-- NOTE: no PlayerRemoving handler here on purpose. Lifecycle cleanup is
-- centralized in init.server (save-before-clear order).

return EconomyService
