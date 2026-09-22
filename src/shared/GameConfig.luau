--!nonstrict
-- StorageAuction — shared game tuning (Milestone 1).
-- Single source of truth for timings, economy, and auction rules.
-- Edit values here, never scatter magic numbers in services.

local GameConfig = {
	-- Economy
	StartingCash = 1000,
	MaxCash = 999999999,

	-- Auction rules
	BidStartPrice = 50,
	MinBidIncrement = 25,

	-- Bidding is local: players must stand within BidRadius (studs, XZ) of
	-- the auction area center in front of the unit. Server-authoritative.
	BidRadius = 35,

	-- Rummaging decision grace: if the timer expires while the winner still
	-- has an unresolved item, they get this many extra seconds (prompts off)
	-- to choose Sell or Keep before Cleanup begins.
	DecisionGracePeriod = 10,

	-- State durations (seconds)
	WaitingDuration = 8,
	InspectionDuration = 15,
	BiddingDuration = 30,
	SoldDuration = 5,
	RummageDuration = 90,
	CleanupDuration = 5,

	-- Unit contents: the Studio map owns the real container set
-- (StorageAuctionMap.StorageUnit.Container_*). This documents the M1 intent.
	ContainersPerUnit = 3,

	-- Value formula: FinalValue = floor(BaseValue * RarityMult * ConditionMult)
	-- ConditionMult = ConditionFloor + (1 - ConditionFloor) * (Condition / 100)
	ConditionFloor = 0.3,
	MinCondition = 10,
	MaxCondition = 100,

	-- NPC bidders (simple, for solo testing)
	NPCs = {
		{ Name = "Dealer Dan", BidChance = 0.65, MaxDelay = 3.0, ValueNoiseMin = 0.6, ValueNoiseMax = 1.3 },
		{ Name = "Collector Kate", BidChance = 0.5, MaxDelay = 4.0, ValueNoiseMin = 0.7, ValueNoiseMax = 1.5 },
	},

	-- Remote folder / event names (must match server Remotes module)
	RemotesFolderName = "SA_Remotes",
	RemoteNames = {
		AuctionState = "AuctionState",
		CashChanged = "CashChanged",
		ItemRevealed = "ItemRevealed",
		InventoryChanged = "InventoryChanged",
		Notify = "Notify",
		PlaceBid = "PlaceBid",
		OpenContainer = "OpenContainer",
		KeepItem = "KeepItem",
		SellItem = "SellItem",
	},
}

return GameConfig
