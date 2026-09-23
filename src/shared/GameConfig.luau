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

	-- Price-tiered minimum increments (single source; no hard-coded math).
	BidIncrementTiers = {
		{ MaxPrice = 499, Increment = 25 },
		{ MaxPrice = 1999, Increment = 50 },
		{ MaxPrice = 4999, Increment = 100 },
		{ MaxPrice = math.huge, Increment = 250 },
	},

	-- Anti-snipe: a valid bid with less than Window seconds left pushes the
	-- timer out to Extension seconds, at most MaxExtensions times per auction.
	AntiSnipeWindow = 3,
	AntiSnipeExtension = 5,
	AntiSnipeMaxExtensions = 6,

	-- Verbose server Output for auction debugging (never sent to clients).
	DebugAuction = false,

	-- Bidding is local: players must stand within BidRadius (studs, XZ) of
	-- the auction area center in front of the unit. Server-authoritative.
	-- Radius covers chairs (~11), mat (~12), door (10) and boxes (~22).
	BidRadius = 24,

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

	-- Showroom (MVP): fixed personal-collection slots, one shared area.
	-- Display assignments are tracked per player so per-player showrooms
	-- can replace the shared area later without changing the record shape.
	DisplaySlotCount = 6,

	-- First progression gate (teaser only — no premium gameplay yet).
	PremiumAuctionsWinsRequired = 5,
	PremiumAuctionsValueRequired = 5000,

	-- Value formula: FinalValue = clamp(floor(BaseValue * RarityMult * ConditionMult), Min/Max)
	-- ConditionMult = ConditionFloor + (1 - ConditionFloor) * (Condition / 100)
	ConditionFloor = 0.3,
	MinCondition = 10,
	MaxCondition = 100,
	MinItemValue = 5,
	MaxItemValue = 6000,

	-- NPC bidder personalities (config-driven, deterministic).
	-- Skill 0..1: 1 = near-perfect value estimate, 0 = wild guess.
	-- RiskTolerance: fraction of estimated value used as max bid baseline.
	-- Aggression: bigger/faster counter-bids. OverpayChance: chance per
	-- auction to stretch ~18% past the risk-based max. Budget: hard cap.
	NPCs = {
		{ Name = "Dealer Dan",    Archetype = "Conservative", Budget = 1500, Aggression = 0.3, RiskTolerance = 0.55, Skill = 0.70, OverpayChance = 0.05, BidChance = 0.60, MaxDelay = 3.2 },
		{ Name = "Collector Kate",Archetype = "Expert",       Budget = 3000, Aggression = 0.5, RiskTolerance = 0.75, Skill = 0.90, OverpayChance = 0.08, BidChance = 0.55, MaxDelay = 3.6 },
		{ Name = "Rico Flipper",  Archetype = "Aggressive",   Budget = 2200, Aggression = 0.9, RiskTolerance = 0.90, Skill = 0.55, OverpayChance = 0.35, BidChance = 0.75, MaxDelay = 2.2 },
		{ Name = "Lucky Lou",     Archetype = "Clueless",     Budget = 1000, Aggression = 0.6, RiskTolerance = 1.00, Skill = 0.25, OverpayChance = 0.40, BidChance = 0.45, MaxDelay = 4.5 },
	},

	-- Inspection visibility: how many of the unit's REAL items are shown.
	-- Weights keyed by visible count; counts above the actual item total are
	-- ignored. Creates varying risk levels between auctions.
	VisibleCountWeights = { [0] = 15, [1] = 35, [2] = 35, [3] = 15 },

	-- Hidden unit quality profiles: weights sum to 100. JunkChance forces a
	-- junk-def pick; ValueScale multiplies final item values; RarityLuck
	-- biases rarity rolls upward (0 = neutral).
	UnitQuality = {
		Weights = { Trash = 16, Low = 26, Average = 32, Good = 15, Premium = 8, Jackpot = 3 },
		Order = { "Trash", "Low", "Average", "Good", "Premium", "Jackpot" },
		Defs = {
			Trash   = { MinItems = 2, MaxItems = 3, JunkChance = 0.70, ValueScaleMin = 0.3, ValueScaleMax = 0.6, RarityLuck = 0 },
			Low     = { MinItems = 2, MaxItems = 4, JunkChance = 0.45, ValueScaleMin = 0.5, ValueScaleMax = 0.9, RarityLuck = 0 },
			Average = { MinItems = 3, MaxItems = 4, JunkChance = 0.25, ValueScaleMin = 0.8, ValueScaleMax = 1.2, RarityLuck = 1 },
			Good    = { MinItems = 3, MaxItems = 5, JunkChance = 0.12, ValueScaleMin = 1.0, ValueScaleMax = 1.6, RarityLuck = 2 },
			Premium = { MinItems = 4, MaxItems = 5, JunkChance = 0.05, ValueScaleMin = 1.4, ValueScaleMax = 2.2, RarityLuck = 3 },
			Jackpot = { MinItems = 4, MaxItems = 6, JunkChance = 0.00, ValueScaleMin = 1.8, ValueScaleMax = 3.0, RarityLuck = 5 },
		},
	},

	-- Remote folder / event names (must match server Remotes module)
	RemotesFolderName = "SA_Remotes",
	RemoteNames = {
		AuctionState = "AuctionState",
		CashChanged = "CashChanged",
		ItemRevealed = "ItemRevealed",
		InventoryChanged = "InventoryChanged",
		Notify = "Notify",
		DisplayChanged = "DisplayChanged",
		StatsChanged = "StatsChanged",
		PlaceBid = "PlaceBid",
		OpenContainer = "OpenContainer",
		KeepItem = "KeepItem",
		SellItem = "SellItem",
		DisplayItem = "DisplayItem",
		RemoveDisplay = "RemoveDisplay",
	},
}

return GameConfig
