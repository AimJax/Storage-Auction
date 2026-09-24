--!nonstrict
-- StorageAuction V2 — config-driven NPC bidder personalities.
--
-- NPCs estimate like humans: from VISIBLE clues (appraised with skill-based
-- error) plus a GUESS per hidden box (config average × personality × noise).
-- TrueTotalValue is NEVER an input. Each NPC also rolls per-auction INTEREST
-- (else sits out or cheap-pokes only), and only up to MaxActiveNPCs contest
-- seriously. NPCs react to the single GLOBAL CurrentBid (human or NPC) with
-- a reaction pause so bidding feels human, never machine-gun chains.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local ItemUtils = require(Shared.ItemUtils)

local NPCBidderService = {}

local rng = Random.new()

local RARE_PLUS = { Rare = true, Epic = true, Legendary = true, Mythic = true }

local function hasRarePlus(visibleItems)
	for _, item in ipairs(visibleItems) do
		if RARE_PLUS[item.Rarity] then
			return true
		end
	end
	return false
end

-- npcDefs: GameConfig.NPCs. visibleItems: server unit's real visible loot
-- (FinalValue used internally as appraisal proxy ONLY). hiddenCount: boxes
-- still sealed. hiddenBaseline: optional per-tier per-box hidden guess
-- (defaults to GameConfig.AvgHiddenItemValue). Returns per-auction bidder states.
function NPCBidderService.CreateBidders(npcDefs, visibleItems, hiddenCount, hiddenBaseline, budgetMult)
	visibleItems = visibleItems or {}
	hiddenCount = hiddenCount or 0
	local baseline = tonumber(hiddenBaseline) or GameConfig.AvgHiddenItemValue
	local budgetScale = tonumber(budgetMult) or 1
	local rareVisible = hasRarePlus(visibleItems)
	local bidders = {}

	for _, def in ipairs(npcDefs) do
		local skill = math.clamp(tonumber(def.Skill) or 0.5, 0, 1)
		local risk = tonumber(def.RiskTolerance) or 0.7

		-- 1) Appraise what everyone can see, with skill-based error.
		local visibleTrue = 0
		for _, item in ipairs(visibleItems) do
			visibleTrue += tonumber(item.FinalValue) or 0
		end
		local visibleEstimate = math.max(0, math.floor(
			visibleTrue * (1 + (rng:NextNumber() * 2 - 1) * (1 - skill) * 0.5) + 0.5))

		-- 2) Guess the sealed boxes: config average × personality × noise.
		-- Never touches actual hidden values.
		local spread = 0.25 + (1 - skill) * 0.9
		local hiddenGuess = 0
		if hiddenCount > 0 then
			local perBox = baseline * (0.4 + risk * 0.8)
			hiddenGuess = math.max(0, math.floor(
				hiddenCount * perBox * rng:NextNumber(math.max(0.05, 1 - spread), 1 + spread) + 0.5))
		end

		local estimated = visibleEstimate + hiddenGuess
		local maxBid = math.floor(estimated * risk + 0.5)
		if rng:NextNumber() < (tonumber(def.OverpayChance) or 0) then
			maxBid = math.floor(maxBid * 1.18 + 0.5)
		end
		-- Tier-scaled house budget cap (isolated: personalities untouched).
		local budget = math.floor((tonumber(def.Budget) or maxBid) * budgetScale)
		maxBid = math.min(maxBid, budget)
		if maxBid < 0 then
			maxBid = 0
		end

		-- 3) Interest roll (with light personality biases).
		local chance = tonumber(def.InterestChance) or 0.5
		if rareVisible then
			chance += tonumber(def.InterestBonusRare) or 0
		end
		chance += math.min((tonumber(def.InterestBonusPerHidden) or 0) * hiddenCount, 0.3)
		chance = math.clamp(chance, 0, 0.95)
		local interested = rng:NextNumber() < chance

		table.insert(bidders, {
			Name = def.Name,
			Archetype = def.Archetype or "Average",
			Interested = interested,
			VisibleEstimate = visibleEstimate,
			HiddenGuess = hiddenGuess,
			EstimatedValue = estimated,
			MaxBid = maxBid,
			Budget = budget,
			Aggression = tonumber(def.Aggression) or 0.5,
			BidChance = tonumber(def.BidChance) or 0.5,
			MaxDelay = tonumber(def.MaxDelay) or 3.0,
			CooldownUntil = 0,
			BidsPlaced = 0, -- history: blocks late surprise entrants
			_lateBlockedLogged = false,
		})
	end

	-- 4) Participation cap: demote extras (lowest aggression first), promote
	-- to minimum. Demoted/uninterested NPCs get a rare cheap poke at most —
	-- they can never suddenly join at $1,000.
	local function isSerious(b)
		return b.Interested
	end
	local serious = {}
	for _, b in ipairs(bidders) do
		if isSerious(b) then
			table.insert(serious, b)
		end
	end
	if #serious > GameConfig.MaxActiveNPCs then
		table.sort(serious, function(a, b) return a.Aggression > b.Aggression end)
		for i = GameConfig.MaxActiveNPCs + 1, #serious do
			serious[i].Interested = false
		end
	elseif #serious < GameConfig.MinActiveNPCs then
		local idle = {}
		for _, b in ipairs(bidders) do
			if not isSerious(b) then
				table.insert(idle, b)
			end
		end
		while #serious < GameConfig.MinActiveNPCs and #idle > 0 do
			local pick = table.remove(idle, rng:NextInteger(1, #idle))
			pick.Interested = true
			table.insert(serious, pick)
		end
	end
	for _, b in ipairs(bidders) do
		if not b.Interested then
			b.MaxBid = math.min(b.MaxBid, GameConfig.CasualPokeMaxBid)
			b.BidChance = math.min(b.BidChance, GameConfig.CasualPokeChance)
			b.MaxDelay = math.max(b.MaxDelay, 5.0)
		end
		if GameConfig.DebugAuction then
			if b.Interested then
				print(string.format("[SA] NPC %s interested=true", b.Name))
				print(string.format("[SA] visibleEstimate=%d hiddenGuess=%d estimate=%d maxBid=%d",
					b.VisibleEstimate, b.HiddenGuess, b.EstimatedValue, b.MaxBid))
			else
				print(string.format("[SA] NPC %s interested=false", b.Name))
			end
		end
	end
	return bidders
end

-- Called each bidding tick against the GLOBAL current bid. tryBid(name, amount)
-- performs the bid through the same server path as human bids. lastBidAt gates
-- a reaction pause; only one NPC tends to answer per tick (dampened chains).
-- activeHumans scales all pressure down (PvP takes over); timeLeft drives
-- late-bid suppression; highestIsHuman gates it. pressureMult (optional,
-- default 1) scales tier filler presence without changing any personality.
-- Returns updated currentBid.
function NPCBidderService.Tick(bidders, now, currentBid, currentBidderName, lastBidAt, activeHumans, timeLeft, highestIsHuman, tryBid, pressureMult)
	if now - (lastBidAt or -1000) < GameConfig.NPCReactionPause then
		return currentBid -- let the last bid breathe; no instant chains
	end
	activeHumans = math.max(0, math.floor(tonumber(activeHumans) or 0))
	local pressure = (GameConfig.NPCPressureByHumans[math.min(activeHumans, 3)] or 0.1)
		* (tonumber(pressureMult) or 1)
	highestIsHuman = highestIsHuman == true
	local answeredThisTick = false
	for _, b in ipairs(bidders) do
		if b.Name == currentBidderName then
			continue -- never outbid yourself; wait to be outbid
		end
		-- No late joining: zero prior bids + final seconds = stay out.
		if b.BidsPlaced == 0 and timeLeft <= GameConfig.NPCLateWindow then
			if GameConfig.DebugAuction and not b._lateBlockedLogged then
				b._lateBlockedLogged = true
				print(string.format("[SA] NPC %s lateBidSuppressed=true (no prior bids)", b.Name))
			end
			continue
		end
		local effectiveMax = math.floor(b.MaxBid * (0.45 + 0.55 * pressure) + 0.5)
		if now >= b.CooldownUntil and currentBid < effectiveMax then
			local chance = b.BidChance * pressure
			if timeLeft <= GameConfig.NPCLateWindow and highestIsHuman then
				chance *= if activeHumans >= 2 then GameConfig.NPCLateBidMultPvP else GameConfig.NPCLateBidMult
			end
			if answeredThisTick then
				chance *= 0.3 -- dampen multi-NPC pile-ons within one tick
			end
			if rng:NextNumber() < chance then
				local inc = ItemUtils.BidIncrementFor(currentBid)
				local step = if rng:NextNumber() < b.Aggression * pressure then 2 else 1
				local amount = math.min(currentBid + inc * step, effectiveMax)
				if amount >= currentBid + inc then
					if tryBid(b.Name, amount) then
						b.BidsPlaced += 1
						currentBid = amount
						answeredThisTick = true
						if GameConfig.DebugAuction then
							print(string.format("[SA] NPC %s bid $%d (pressure=%.2f, activeHumans=%d)",
								b.Name, amount, pressure, activeHumans))
						end
					end
				end
			end
			local pace = (1.25 - b.Aggression * 0.5) * (2 - pressure)
			b.CooldownUntil = now + rng:NextNumber(0.5, b.MaxDelay) * pace
		end
	end
	return currentBid
end

return NPCBidderService
