--!nonstrict
-- StorageAuction economy — loans, persistent fixed-repayment debt, and
-- bankruptcy recovery (server-authoritative).
--
-- Design principles:
--   1. Nobody ever hard-locks at $0 (recovery floor + Budget tier).
--   2. Debt creates pressure, never a dead end (partial auto-repayment).
--   3. No borrow-and-run exploit (one active loan, fixed totals, persistence).
--
-- Debt shape persisted via PlayerDataService:
--   { DebtRemaining, DebtTotal, LoanId }

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local DebtService = {}

local EconomyService = nil
local InventoryService = nil
local PlayerStatsService = nil
local AuctionService = nil
local Remotes = nil

-- [UserId] = { remaining, total, loanId }
local debts = {}
-- [UserId] = unix timestamp (os.time) when recovery becomes available again.
-- PERSISTED (never cleared on leave) so rejoining cannot bypass the cooldown.
-- Session-only os.clock() timing is deliberately NOT used here.
local recoveryAvailableAt = {}

function DebtService.Init(deps)
	EconomyService = deps.EconomyService
	InventoryService = deps.InventoryService
	PlayerStatsService = deps.PlayerStatsService
	AuctionService = deps.AuctionService
	Remotes = deps.Remotes

	local takeLoan = Remotes:FindFirstChild(GameConfig.RemoteNames.TakeLoan)
	if takeLoan and takeLoan:IsA("RemoteFunction") then
		takeLoan.OnServerInvoke = function(player, productId)
			local ok, result = DebtService.TakeLoan(player, productId)
			return { ok = ok, result = result }
		end
	end
	local payDebt = Remotes:FindFirstChild(GameConfig.RemoteNames.PayDebt)
	if payDebt and payDebt:IsA("RemoteFunction") then
		payDebt.OnServerInvoke = function(player, amount)
			local ok, result = DebtService.PayDebt(player, amount)
			return { ok = ok, result = result }
		end
	end
	local claimRecovery = Remotes:FindFirstChild(GameConfig.RemoteNames.ClaimRecovery)
	if claimRecovery and claimRecovery:IsA("RemoteFunction") then
		claimRecovery.OnServerInvoke = function(player)
			local ok, result = DebtService.ClaimRecovery(player)
			return { ok = ok, result = result }
		end
	end
end

function DebtService.GetDebt(player)
	local d = debts[player.UserId]
	if not d then
		return { remaining = 0, total = 0, loanId = "" }
	end
	return { remaining = d.remaining, total = d.total, loanId = d.loanId }
end

-- Server-side helper: cash + owned inventory sell value (never plots).
function DebtService.NetWorth(player)
	local worth = EconomyService.GetCash(player)
	for _, item in ipairs(InventoryService.GetItems(player)) do
		worth += tonumber(item.FinalValue) or 0
	end
	return worth
end

local function playerWins(player)
	if PlayerStatsService and PlayerStatsService.GetWins then
		return PlayerStatsService.GetWins(player)
	end
	return 0
end

local function findProduct(productId)
	for _, p in ipairs(GameConfig.LoanProducts) do
		if p.Id == productId then
			return p
		end
	end
	return nil
end

-- Push current debt state to the loan menu UI.
function DebtService.Push(player)
	if not Remotes then
		return
	end
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.DebtChanged)
	if ev then
		ev:FireClient(player, DebtService.GetDebt(player))
	end
end

-- Take a fixed loan product. Validates: known product, no active debt,
-- wins/net-worth eligibility. Returns (ok, debtStateOrMessage).
function DebtService.TakeLoan(player, productId)
	local product = findProduct(productId)
	if not product then
		return false, "Unknown loan product."
	end
	local debt = DebtService.GetDebt(player)
	if debt.remaining > 0 then
		return false, "Repay your current loan first."
	end
	local wins = playerWins(player)
	local worth = DebtService.NetWorth(player)
	if wins < (product.MinWins or 0)
		and worth < (product.MinNetWorth or 0)
		and ((product.MinWins or 0) > 0 or (product.MinNetWorth or 0) > 0)
	then
		return false, string.format("Loan %s needs %d wins or $%d net worth.",
			product.Id, product.MinWins or 0, product.MinNetWorth or 0)
	end
	EconomyService.AddCash(player, product.Amount)
	debts[player.UserId] = { remaining = product.Repay, total = product.Repay, loanId = product.Id }
	if GameConfig.DebugAuction then
		print(string.format("[SA] Loan accepted user=%d amount=%d repay=%d",
			player.UserId, product.Amount, product.Repay))
	end
	PlayerStatsService.Push(player)
	DebtService.Push(player)
	return true, DebtService.GetDebt(player)
end

-- Manual repayment (ATM "Pay Debt"): amount nil/<=0 means pay in full.
-- Capped by remaining debt and current cash. Returns (ok, debtStateOrMessage).
function DebtService.PayDebt(player, amount)
	local debt = debts[player.UserId]
	if not debt or debt.remaining <= 0 then
		return false, "You have no debt."
	end
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		amount = debt.remaining
	end
	amount = math.min(amount, debt.remaining, EconomyService.GetCash(player))
	if amount <= 0 then
		return false, "Not enough Cash to pay."
	end
	if not EconomyService.DeductCash(player, amount) then
		return false, "Not enough Cash to pay."
	end
	debt.remaining -= amount
	if debt.remaining <= 0 then
		debts[player.UserId] = nil
	end
	PlayerStatsService.Push(player)
	DebtService.Push(player)
	return true, DebtService.GetDebt(player)
end

-- Automatic collection from an item sale. Diverts DebtRepaymentRate of the
-- proceeds; player always keeps the rest. Recovery grants never route here.
-- Returns { cashGain, debtPaid, debtRemaining }.
function DebtService.CollectFromSale(player, gain)
	gain = math.floor(tonumber(gain) or 0)
	local debt = debts[player.UserId]
	local paid = 0
	if debt and debt.remaining > 0 and gain > 0 then
		paid = math.min(math.floor(gain * GameConfig.DebtRepaymentRate), debt.remaining)
		debt.remaining -= paid
		if debt.remaining <= 0 then
			debts[player.UserId] = nil
		end
	end
	local cashGain = gain - paid
	if cashGain > 0 then
		EconomyService.AddCash(player, cashGain)
	end
	if GameConfig.DebugAuction then
		print(string.format("[SA] Debt collection sale=%d paidDebt=%d cashGain=%d remaining=%d",
			gain, paid, cashGain, DebtService.GetDebt(player).remaining))
	end
	PlayerStatsService.Push(player)
	DebtService.Push(player)
	return { cashGain = cashGain, debtPaid = paid, debtRemaining = DebtService.GetDebt(player).remaining }
end

-- Bankruptcy recovery: top cash UP TO RecoveryGrant, only when broke, only
-- when net worth is also low, only off cooldown, never with a pending item.
-- Debt is never touched (recovery is not swallowed). Returns (ok, message).
function DebtService.ClaimRecovery(player)
	local cash = EconomyService.GetCash(player)
	if cash >= GameConfig.RecoveryCashThreshold then
		return false, "Recovery is only for broke players."
	end
	if AuctionService and AuctionService.HasPendingItem
		and AuctionService.HasPendingItem(player)
	then
		return false, "Resolve your current item first."
	end
	if DebtService.NetWorth(player) >= GameConfig.RecoveryGrant then
		return false, "Sell something from your Bag first."
	end
	local last = recoveryAvailableAt[player.UserId] or 0
	local nowUnix = os.time()
	if nowUnix < last then
		return false, string.format("Recovery available again in %ds.", last - nowUnix)
	end
	local grant = GameConfig.RecoveryGrant - cash
	if grant <= 0 then
		return false, "Recovery is only for broke players."
	end
	recoveryAvailableAt[player.UserId] = nowUnix + GameConfig.RecoveryCooldown
	EconomyService.AddCash(player, grant)
	if GameConfig.DebugAuction then
		print(string.format("[SA] Recovery grant user=%d amount=%d", player.UserId, grant))
	end
	PlayerStatsService.Push(player)
	return true, grant
end

-- Persistence support (PlayerDataService calls these; missing fields -> 0).
function DebtService.GetPersistData(player)
	local d = debts[player.UserId]
	local out
	if not d then
		out = { DebtRemaining = 0, DebtTotal = 0, LoanId = "" }
	else
		out = { DebtRemaining = d.remaining, DebtTotal = d.total, LoanId = d.loanId }
	end
	out.RecoveryAvailableAt = recoveryAvailableAt[player.UserId] or 0
	return out
end

function DebtService.LoadPersisted(player, data)
	if typeof(data) ~= "table" then
		return
	end
	local remaining = math.max(0, math.floor(tonumber(data.DebtRemaining) or 0))
	if remaining > 0 then
		debts[player.UserId] = {
			remaining = remaining,
			total = math.max(remaining, math.floor(tonumber(data.DebtTotal) or remaining)),
			loanId = tostring(data.LoanId or ""),
		}
	end
	-- Missing field (older saves) defaults to 0 = immediately eligible.
	recoveryAvailableAt[player.UserId] = math.max(0, math.floor(tonumber(data.RecoveryAvailableAt) or 0))
end

function DebtService.ClearPlayer(player)
	if not player then
		return
	end
	debts[player.UserId] = nil
	-- NOTE: recoveryAvailableAt is intentionally NOT cleared here. It is
	-- persisted session state; Save (which runs before clears) reads it,
	-- and clearing it would reopen the rejoin exploit.
end

return DebtService
