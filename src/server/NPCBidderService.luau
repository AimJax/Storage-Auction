--!nonstrict
-- StorageAuction V2 — config-driven NPC bidder personalities.
--
-- Each NPC forms its OWN noisy estimate of the unit's true value and derives
-- a personal MaximumBid from it. NPCs react to the single GLOBAL CurrentBid
-- no matter who placed it (human or NPC) and never outbid themselves.
-- No LLMs, no learning — deterministic archetype math only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local ItemUtils = require(Shared.ItemUtils)

local NPCBidderService = {}

local rng = Random.new()

-- npcDefs: GameConfig.NPCs. trueValue: server's hidden unit total.
-- Returns per-auction bidder states with EstimatedValue + MaxBid.
function NPCBidderService.CreateBidders(npcDefs, trueValue)
	local bidders = {}
	for _, def in ipairs(npcDefs) do
		local skill = math.clamp(tonumber(def.Skill) or 0.5, 0, 1)
		local noise = (1 - skill) * 0.7
		local estimated = math.max(0, math.floor(trueValue * (1 + (rng:NextNumber() * 2 - 1) * noise) + 0.5))
		local risk = tonumber(def.RiskTolerance) or 0.7
		local maxBid = math.floor(estimated * risk + 0.5)
		if rng:NextNumber() < (tonumber(def.OverpayChance) or 0) then
			maxBid = math.floor(maxBid * 1.18 + 0.5)
		end
		maxBid = math.min(maxBid, math.floor(tonumber(def.Budget) or maxBid))
		if maxBid < 0 then
			maxBid = 0
		end
		table.insert(bidders, {
			Name = def.Name,
			Archetype = def.Archetype or "Average",
			EstimatedValue = estimated,
			MaxBid = maxBid,
			Budget = tonumber(def.Budget) or maxBid,
			Aggression = tonumber(def.Aggression) or 0.5,
			BidChance = tonumber(def.BidChance) or 0.5,
			MaxDelay = tonumber(def.MaxDelay) or 3.0,
			CooldownUntil = 0,
		})
		if GameConfig.DebugAuction then
			print(string.format("[SA] NPC %s (%s) estimated=%d maxBid=%d budget=%d (true=%d)",
				def.Name, bidders[#bidders].Archetype, estimated, maxBid,
				bidders[#bidders].Budget, trueValue))
		end
	end
	return bidders
end

-- Called each bidding tick against the GLOBAL current bid. tryBid(name, amount)
-- performs the bid through the same server path as human bids.
function NPCBidderService.Tick(bidders, now, currentBid, currentBidderName, tryBid)
	for _, b in ipairs(bidders) do
		if b.Name == currentBidderName then
			continue -- never outbid yourself; wait to be outbid
		end
		if now >= b.CooldownUntil and currentBid < b.MaxBid then
			if rng:NextNumber() < b.BidChance then
				local inc = ItemUtils.BidIncrementFor(currentBid)
				local step = if rng:NextNumber() < b.Aggression then 2 else 1
				local amount = math.min(currentBid + inc * step, b.MaxBid)
				if amount > currentBid then
					tryBid(b.Name, amount)
					currentBid = amount
				end
			end
			local pace = 1.25 - b.Aggression * 0.5
			b.CooldownUntil = now + rng:NextNumber(0.5, b.MaxDelay) * pace
		end
	end
	return currentBid
end

return NPCBidderService
