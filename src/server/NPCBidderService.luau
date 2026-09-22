--!nonstrict
-- StorageAuction M1 — deliberately simple NPC bidders.
-- Each auction: maxWilling = hiddenValue * noise. During bidding, each tick
-- they may outbid the current bid if it is still below their max.
-- Exists so SOLO testing still produces meaningful auctions.

local NPCBidderService = {}

local rng = Random.new()

-- hiddenValue: server's true total of container contents (unknown to players).
-- npcDefs: from GameConfig.NPCs. Returns per-auction bidder states.
function NPCBidderService.CreateBidders(npcDefs, hiddenValue)
	local bidders = {}
	for _, def in ipairs(npcDefs) do
		local noise = rng:NextNumber(def.ValueNoiseMin, def.ValueNoiseMax)
		table.insert(bidders, {
			Name = def.Name,
			MaxWilling = math.floor(hiddenValue * noise + 0.5),
			BidChance = def.BidChance,
			MaxDelay = def.MaxDelay,
			CooldownUntil = 0,
		})
	end
	return bidders
end

-- Called each bidding tick. tryBid(name, amount) performs the bid.
-- Returns the new current bid info or nil.
function NPCBidderService.Tick(bidders, now, currentBid, minIncrement, tryBid)
	for _, b in ipairs(bidders) do
		if now >= b.CooldownUntil and currentBid < b.MaxWilling then
			if rng:NextNumber() < b.BidChance then
				local step = rng:NextInteger(1, 2)
				local amount = math.min(currentBid + minIncrement * step, b.MaxWilling)
				if amount > currentBid then
					tryBid(b.Name, amount, true)
					-- After this tick's bid, currentBid changed; refresh local copy.
					currentBid = amount
				end
			end
			b.CooldownUntil = now + rng:NextNumber(0.8, b.MaxDelay)
		end
	end
	return currentBid
end

return NPCBidderService
