--!nonstrict
-- StorageAuction — shared game tuning (Milestone 1).
-- Single source of truth for timings, economy, and auction rules.
-- Edit values here, never scatter magic numbers in services.

local GameConfig = {
	-- Economy
	StartingCash = 1000,
	MaxCash = 999999999,

	-- Auction rules
	BidStartPrice = 50, -- legacy global default; per-session tier StartingBid is used (see Tiers)

	-- Auction tiers (Stage 4). Tier is a permanent PROPERTY of a physical
	-- unit/session: Unit 1 = Budget, Unit 2 = Standard, Unit 3 = HighRoller.
	-- UnitTiers[i] assigns the tier for Sessions[i]. No rotation, no queue.
	UnitTiers = { "Budget", "Standard", "HighRoller" },

	-- Per-tier tuning. QualityWeights replace the global UnitQuality.Weights
	-- for that tier's rolls (UnitGeneratorService consumes them explicitly).
	-- JunkChanceMult multiplies the quality JunkChance (clamped 0..1);
	-- LuckBonus adds to the quality RarityLuck; ValueScaleMin/Max multiply
	-- the quality ValueScale range (single roll over the combined range).
	-- StartingBid is the session's opening bid. MinCash/MinWins/MinNetWorth
	-- gate HUMAN bidding (server-enforced; NPCs are house bots, ungated).
	-- NPCPressureMult scales the existing filler pressure (1.0 = unchanged).
	Tiers = {
		Budget = {
			DisplayName = "BUDGET",
			MessageName = "Budget",
			StartingBid = 25,
			MinCash = 0, MinWins = 0, MinNetWorth = 0,
			NPCPressureMult = 0.85,
			-- Minimal tier-aware NPC calibration (both proven necessary by sim):
			-- NPCHiddenGuess tracks the tier's hidden value level; NPCBudgetMult
			-- scales house budgets to the tier's price level (HR units trade in
			-- thousands; unscaled $400-900 caps left HR uncontested above ~$900).
			-- Estimators stay clue-based, noisy, and capped — still filler.
			NPCHiddenGuess = 125,
			NPCBudgetMult = 1.0,
			QualityWeights = { Trash = 29, Low = 35, Average = 25, Good = 8, Premium = 2, Jackpot = 1 },
			JunkChanceMult = 1.50, LuckBonus = 0,
			ValueScaleMin = 0.60, ValueScaleMax = 1.00,
			RequirementText = nil, -- open to everyone
		},
		Standard = {
			DisplayName = "STANDARD",
			MessageName = "Standard",
			StartingBid = 100,
			MinCash = 300, MinWins = 0, MinNetWorth = 0,
			NPCPressureMult = 1.00,
			NPCHiddenGuess = 350,
			NPCBudgetMult = 1.0,
			QualityWeights = { Trash = 10, Low = 22, Average = 33, Good = 20, Premium = 12, Jackpot = 3 },
			JunkChanceMult = 1.00, LuckBonus = 0,
			ValueScaleMin = 0.80, ValueScaleMax = 1.30,
			RequirementText = "Requires $300 Cash",
		},
		HighRoller = {
			DisplayName = "HIGH ROLLER",
			MessageName = "High Roller",
			StartingBid = 500,
			MinCash = 2500, MinWins = 3, MinNetWorth = 5000,
			NPCPressureMult = 1.00,
			NPCHiddenGuess = 900,
			NPCBudgetMult = 3.0,
			QualityWeights = { Trash = 3, Low = 10, Average = 27, Good = 30, Premium = 22, Jackpot = 8 },
			JunkChanceMult = 0.40, LuckBonus = 2,
			ValueScaleMin = 1.20, ValueScaleMax = 2.00,
			RequirementText = "Requires $2,500 Cash + 3 wins or $5,000 net worth",
		},
	},

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
	-- Skill 0..1: appraisal/estimate accuracy (1 = sharp, 0 = wild guess).
	-- RiskTolerance: fraction of estimated value used as max-bid baseline.
	-- Aggression: bigger/faster counter-bids. OverpayChance: chance per
	-- auction to stretch ~18% past the risk-based max. Budget: hard cap.
	-- InterestChance: per-auction roll to seriously contest (else a rare
	-- cheap poke at most). InterestBonusRare/PerHidden: lightweight biases.
	NPCs = {
		{ Name = "Dealer Dan",    Archetype = "Conservative", Budget = 500,  Aggression = 0.3, RiskTolerance = 0.50, Skill = 0.70, OverpayChance = 0.05, BidChance = 0.60, MaxDelay = 3.4, InterestChance = 0.55 },
		{ Name = "Collector Kate",Archetype = "Expert",       Budget = 900,  Aggression = 0.5, RiskTolerance = 0.60, Skill = 0.90, OverpayChance = 0.08, BidChance = 0.55, MaxDelay = 3.8, InterestChance = 0.50, InterestBonusRare = 0.25 },
		{ Name = "Rico Flipper",  Archetype = "Aggressive",   Budget = 700,  Aggression = 0.9, RiskTolerance = 0.70, Skill = 0.55, OverpayChance = 0.35, BidChance = 0.75, MaxDelay = 2.4, InterestChance = 0.65, InterestBonusPerHidden = 0.10 },
		{ Name = "Lucky Lou",     Archetype = "Clueless",     Budget = 400,  Aggression = 0.6, RiskTolerance = 0.60, Skill = 0.25, OverpayChance = 0.40, BidChance = 0.45, MaxDelay = 4.6, InterestChance = 0.40 },
	},

	-- NPC filler scaling: pressure drops as real humans participate.
	-- Index = min(activeHumanBidders, 3). Scales BidChance, effective MaxBid,
	-- aggression and pacing. Humans drive PvP; NPCs fill empty servers.
	NPCPressureByHumans = { [0] = 1.00, [1] = 0.65, [2] = 0.30, [3] = 0.10 },
	-- Late-bid suppression: inside LateWindow with a human leading, NPC bid
	-- chance is multiplied (PvP value when 2+ humans active). NPCs with zero
	-- bids so far cannot enter at all inside the window. Human anti-snipe
	-- is unaffected (separate mechanic, applies to every valid bid).
	NPCLateWindow = 5,
	NPCLateBidMult = 0.10,
	NPCLateBidMultPvP = 0.03,

	-- NPC participation rules (all centralized here).
	MinActiveNPCs = 1,   -- promote random NPCs until at least this many contest
	MaxActiveNPCs = 3,   -- demote extras (lowest aggression first), no 4-bot wars
	CasualPokeMaxBid = 150,  -- uninterested NPCs may only poke below this
	CasualPokeChance = 0.10, -- ...and rarely at that
	NPCReactionPause = 0.9,  -- seconds after any bid before NPCs may respond
	AvgHiddenItemValue = 200, -- baseline each hidden box is worth to NPC guessers

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
