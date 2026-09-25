--!nonstrict
-- StorageAuction Stage 5A — runtime ATM loans, debt, recovery.
-- RUNTIME-ONLY: no DataStore, no schema changes. All state lives in the
-- `states` table and dies with the session (Stage 5B will persist it).
-- Single writer of debt state; AuctionService only calls ApplySaleProceeds.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local DebtService = {}

local EconomyService = nil
local PlayerStatsService = nil
local PlayerDataService = nil
local RemoteGuardService = nil
local Remotes = nil
local ATMPrompt = nil

-- Runtime state per player. recoveryAvailableAt is an os.time() wall-clock
-- timestamp (persistable later — never os.clock).
-- [UserId] = { debt = number, recoveryAvailableAt = number }
local states = {}

local function stateFor(userId, create)
	local st = states[userId]
	if not st and create then
		st = { debt = 0, recoveryAvailableAt = 0 }
		states[userId] = st
	end
	return st
end

-- Same NetWorth definition as tier gates: Cash + kept inventory FinalValue.
-- Debt is NOT subtracted in Stage 5A.
local function netWorthOf(player)
	local cash = EconomyService.GetCash(player)
	local stats = PlayerStatsService.GetStats(player)
	return cash + (tonumber(stats.collectionValue) or 0)
end

local function pushDebtChanged(player)
	if not Remotes then
		return
	end
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.DebtChanged)
	if ev then
		ev:FireClient(player, { debt = DebtService.GetDebt(player) })
	end
end

function DebtService.GetDebt(playerOrUserId)
	local id = if typeof(playerOrUserId) == "Instance" then playerOrUserId.UserId else playerOrUserId
	local st = states[id]
	return (st and st.debt) or 0
end

local function loanGateMessage(loanId, loan)
	if loanId == "A" then
		return nil -- open to everyone
	end
	local winsText = string.format("%d wins", tonumber(loan.MinWins) or 0)
	local worthText = string.format("$%d net worth", tonumber(loan.MinNetWorth) or 0)
	return string.format("Loan %s requires %s or %s.", loanId, winsText, worthText)
end

local function loanEligibility(player, loanId, loan)
	local stats = PlayerStatsService.GetStats(player)
	local wins = tonumber(stats.auctionsWon) or 0
	if wins >= (tonumber(loan.MinWins) or 0) then
		return true, nil
	end
	if netWorthOf(player) >= (tonumber(loan.MinNetWorth) or 0) then
		return true, nil
	end
	return false, loanGateMessage(loanId, loan)
end

-- Physical ATM authority for MUTATING actions: the player must stand near
-- the real ATM Body/prompt (its MaxActivationDistance + 2 tolerance).
-- GetATMState stays readable from anywhere; loans/recovery do not.
local function isNearATM(player)
	if not ATMPrompt or not player then
		return false
	end
	local body = ATMPrompt:FindFirstChild("Body")
	local anchor = nil
	if body and body:IsA("BasePart") then
		anchor = body
	elseif ATMPrompt:IsA("BasePart") then
		anchor = ATMPrompt
	end
	if not anchor then
		return false
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local prompt = anchor:FindFirstChildOfClass("ProximityPrompt")
	if not prompt and ATMPrompt then
		prompt = ATMPrompt:FindFirstChildOfClass("ProximityPrompt")
	end
	local maxDist = 10
	if prompt then
		maxDist = tonumber(prompt.MaxActivationDistance) or 10
	end
	maxDist += 2
	local delta = root.Position - anchor.Position
	return delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z <= maxDist * maxDist
end

-- Full ATM panel state for one player (server-computed, safe to render).
function DebtService.GetState(player)
	local cash = EconomyService.GetCash(player)
	local debt = DebtService.GetDebt(player)
	local now = os.time()
	local st = states[player.UserId]
	local loans = {}
	for _, id in ipairs(GameConfig.LoanOrder) do
		local loan = GameConfig.Loans[id]
		if loan then
			local entry = {
				id = id,
				borrow = loan.Borrow,
				repay = loan.Repay,
				eligible = debt <= 0,
				reason = nil,
			}
			if debt > 0 then
				entry.reason = "Repay your current loan first."
			else
				local ok, reason = loanEligibility(player, id, loan)
				entry.eligible = ok
				entry.reason = reason
			end
			table.insert(loans, entry)
		end
	end
	local grant = math.max(0, GameConfig.RecoveryTargetCash - cash)
	local availableAt = (st and st.recoveryAvailableAt) or 0
	local recovery = { eligible = false, reason = nil, grant = grant, cooldownRemaining = 0 }
	if cash >= GameConfig.RecoveryThreshold then
		recovery.reason = "Recovery is for broke players (under $" .. GameConfig.RecoveryThreshold .. ")."
	elseif now < availableAt then
		recovery.cooldownRemaining = availableAt - now
		recovery.reason = "Recovery on cooldown (" .. recovery.cooldownRemaining .. "s)."
	else
		recovery.eligible = true
	end
	return { cash = cash, debt = debt, loans = loans, recovery = recovery }
end

-- Take a fixed loan: Cash += Borrow, debt = Repay. Client sends only the ID.
-- Returns (ok, message). Rejects while player data is still loading, and
-- refuses when cash is already at MaxCash (a clamped Borrow credit must
-- never create full Repay debt for partial cash).
function DebtService.TakeLoan(player, loanId)
	if not player then
		return false, "Invalid player."
	end
	if PlayerDataService and not PlayerDataService.IsLoaded(player) then
		return false, PlayerDataService.NotReadyMessage()
	end
	loanId = tostring(loanId or "")
	local loan = GameConfig.Loans[loanId]
	if not loan then
		return false, "Unknown loan offer."
	end
	if not isNearATM(player) then
		return false, "Visit the ATM to use it."
	end
	local st = stateFor(player.UserId, true)
	if st.debt > 0 then
		return false, "You already have an active loan. Repay it first."
	end
	local ok, reason = loanEligibility(player, loanId, loan)
	if not ok then
		return false, reason
	end
	if EconomyService.GetCash(player) + loan.Borrow > GameConfig.MaxCash then
		return false, "Cash balance is too high for this loan."
	end
	EconomyService.AddCash(player, loan.Borrow)
	st.debt = loan.Repay
	pushDebtChanged(player)
	PlayerStatsService.Push(player)
	return true, string.format("Loan %s: borrowed $%d, repay $%d.", loanId, loan.Borrow, loan.Repay)
end

-- Single reusable sale splitter used by ALL sale paths (auction reveal sell
-- AND Bag sell). Routes DebtRepaymentRate of the gross to debt (capped at
-- remaining debt — never overpays), credits the rest to Cash.
-- Never makes cash negative. Returns (cashAdded, debtPaid, remainingDebt).
function DebtService.ApplySaleProceeds(player, grossValue)
	local gross = math.floor(tonumber(grossValue) or 0)
	local st = stateFor(player.UserId, false)
	local debt = (st and st.debt) or 0
	if gross <= 0 then
		return 0, 0, debt
	end
	local rate = math.clamp(tonumber(GameConfig.DebtRepaymentRate) or 0.25, 0, 1)
	local pay = math.min(math.floor(gross * rate), debt)
	local cashAdded = gross - pay
	if pay > 0 and st then
		st.debt = debt - pay
		pushDebtChanged(player)
	end
	if cashAdded > 0 then
		EconomyService.AddCash(player, cashAdded)
	end
	PlayerStatsService.Push(player)
	return cashAdded, pay, debt - pay
end

-- Bankruptcy safety top-up: cash below Threshold may claim up to Target.
-- Debt is NEVER touched by recovery (it exists to prevent deadlock).
-- Returns (ok, messageOrGrant).
function DebtService.ClaimRecovery(player)
	if not player then
		return false, "Invalid player."
	end
	if PlayerDataService and not PlayerDataService.IsLoaded(player) then
		return false, PlayerDataService.NotReadyMessage()
	end
	if not isNearATM(player) then
		return false, "Visit the ATM to use it."
	end
	local cash = EconomyService.GetCash(player)
	if cash >= GameConfig.RecoveryThreshold then
		return false, "Recovery is for broke players (under $" .. GameConfig.RecoveryThreshold .. ")."
	end
	local now = os.time()
	local st = stateFor(player.UserId, true)
	if now < st.recoveryAvailableAt then
		return false, "Recovery on cooldown (" .. (st.recoveryAvailableAt - now) .. "s)."
	end
	local grant = GameConfig.RecoveryTargetCash - cash
	if grant <= 0 then
		return false, "Recovery is for broke players (under $" .. GameConfig.RecoveryThreshold .. ")."
	end
	EconomyService.AddCash(player, grant)
	st.recoveryAvailableAt = now + GameConfig.RecoveryCooldown
	PlayerStatsService.Push(player)
	return true, grant
end

function DebtService.SetupPlayer(player)
	if player then
		states[player.UserId] = { debt = 0, recoveryAvailableAt = 0 }
	end
end

-- Restore persisted debt state (Stage 5B). Sanitized: debt clamps to >= 0,
-- recoveryAvailableAt must be a sane non-negative timestamp or 0.
-- Never touches DataStore; PlayerDataService owns the payload.
function DebtService.RestorePlayer(player, data)
	if not player then
		return
	end
	local debt = 0
	local availableAt = 0
	if typeof(data) == "table" then
		debt = math.floor(tonumber(data.debt) or 0)
		if debt < 0 then
			debt = 0
		end
		availableAt = math.floor(tonumber(data.recoveryAvailableAt) or 0)
		if availableAt < 0 then
			availableAt = 0
		end
	end
	states[player.UserId] = { debt = debt, recoveryAvailableAt = availableAt }
	pushDebtChanged(player)
end

-- Sanitized snapshot for persistence. No internals leak by reference.
function DebtService.GetPersistentState(player)
	local id = if typeof(player) == "Instance" then player.UserId else player
	local st = states[id]
	return {
		debt = (st and math.max(0, math.floor(st.debt or 0))) or 0,
		recoveryAvailableAt = (st and math.max(0, math.floor(st.recoveryAvailableAt or 0))) or 0,
	}
end

function DebtService.ClearPlayer(player)
	if player then
		states[player.UserId] = nil
	end
end

function DebtService.Init(deps)
	EconomyService = deps.EconomyService
	PlayerStatsService = deps.PlayerStatsService
	PlayerDataService = deps.PlayerDataService
	RemoteGuardService = deps.RemoteGuardService
	Remotes = deps.Remotes
	ATMPrompt = deps.ATMPrompt

	local getState = Remotes:FindFirstChild(GameConfig.RemoteNames.GetATMState)
	if getState and getState:IsA("RemoteFunction") then
		getState.OnServerInvoke = function(player)
			return { ok = true, state = DebtService.GetState(player) }
		end
	end
	local takeLoan = Remotes:FindFirstChild(GameConfig.RemoteNames.TakeLoan)
	if takeLoan and takeLoan:IsA("RemoteFunction") then
		takeLoan.OnServerInvoke = function(player, loanId)
			if RemoteGuardService and not RemoteGuardService.Check(player, "TakeLoan") then
				return { ok = false, message = "Too fast. Try again.", state = DebtService.GetState(player) }
			end
			local ok, msg = DebtService.TakeLoan(player, loanId)
			return { ok = ok, message = msg, state = DebtService.GetState(player) }
		end
	end
	local claimRecovery = Remotes:FindFirstChild(GameConfig.RemoteNames.ClaimRecovery)
	if claimRecovery and claimRecovery:IsA("RemoteFunction") then
		claimRecovery.OnServerInvoke = function(player)
			if RemoteGuardService and not RemoteGuardService.Check(player, "ClaimRecovery") then
				return { ok = false, result = "Too fast. Try again.", state = DebtService.GetState(player) }
			end
			local ok, result = DebtService.ClaimRecovery(player)
			return { ok = ok, result = result, state = DebtService.GetState(player) }
		end
	end

	-- ATM ProximityPrompt: server-authoritative trigger that tells the
	-- opener's client to show the ATM panel (state itself comes via GetATMState).
	if ATMPrompt then
		local prompt = ATMPrompt:FindFirstChildOfClass("ProximityPrompt")
		if not prompt then
			local body = ATMPrompt:FindFirstChild("Body")
			if body then
				prompt = body:FindFirstChildOfClass("ProximityPrompt")
			end
		end
		if prompt then
			prompt.Triggered:Connect(function(player)
				local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.ATMOpened)
				if ev then
					ev:FireClient(player)
				end
			end)
		else
			warn("[SA] ATM has no ProximityPrompt; ATM UI unreachable in-world.")
		end
	end

	-- NOTE: no PlayerRemoving handler here on purpose. Player lifecycle
	-- cleanup is centralized in init.server (save-before-clear order); an
	-- independent clear could race the save and wipe restored debt.
end

return DebtService
