--!nonstrict
-- StorageAuction M1 — server bootstrap.
-- Creates remotes, builds map, wires services, starts auction loop.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local EconomyService = require(script.Parent.EconomyService)
local InventoryService = require(script.Parent.InventoryService)
local NPCBidderService = require(script.Parent.NPCBidderService)
local AuctionService = require(script.Parent.AuctionService)
local MapBuilder = require(script.Parent.MapBuilder)
local PlayerDataService = require(script.Parent.PlayerDataService)

-- 1) Remotes (created at runtime so Studio needs zero manual setup).
local function ensureRemotes()
	local folder = ReplicatedStorage:FindFirstChild(GameConfig.RemotesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = GameConfig.RemotesFolderName
		folder.Parent = ReplicatedStorage
	end
	local defs = {
		{ GameConfig.RemoteNames.AuctionState, "RemoteEvent" },
		{ GameConfig.RemoteNames.CashChanged, "RemoteEvent" },
		{ GameConfig.RemoteNames.ItemRevealed, "RemoteEvent" },
		{ GameConfig.RemoteNames.InventoryChanged, "RemoteEvent" },
		{ GameConfig.RemoteNames.PlaceBid, "RemoteFunction" },
		{ GameConfig.RemoteNames.OpenContainer, "RemoteFunction" },
		{ GameConfig.RemoteNames.SellItem, "RemoteFunction" },
	}
	for _, d in ipairs(defs) do
		if not folder:FindFirstChild(d[1]) then
			local inst = Instance.new(d[2])
			inst.Name = d[1]
			inst.Parent = folder
		end
	end
	return folder
end

local remotes = ensureRemotes()

-- 2) Services.
EconomyService.Init(remotes)
InventoryService.Init(remotes)
PlayerDataService.Init(EconomyService, InventoryService)

-- 3) Map.
local mapHandles = MapBuilder.Build(GameConfig.ContainersPerUnit)

-- 4) Auction state machine.
AuctionService.Init({
	EconomyService = EconomyService,
	InventoryService = InventoryService,
	NPCBidderService = NPCBidderService,
	MapBuilder = MapBuilder,
	MapHandles = mapHandles,
	Remotes = remotes,
})

-- 5) Players.
local function onPlayerAdded(player)
	PlayerDataService.Load(player)
	-- Send initial snapshot shortly after spawn so UI populates.
	task.delay(1, function()
		if player.Parent then
			local ev = remotes:FindFirstChild(GameConfig.RemoteNames.AuctionState)
			if ev then
				ev:FireClient(player, AuctionService.GetSnapshot())
			end
			local cashEv = remotes:FindFirstChild(GameConfig.RemoteNames.CashChanged)
			if cashEv then
				cashEv:FireClient(player, EconomyService.GetCash(player))
			end
			local invEv = remotes:FindFirstChild(GameConfig.RemoteNames.InventoryChanged)
			if invEv then
				invEv:FireClient(player, InventoryService.GetItems(player))
			end
		end
	end)
end

local function onPlayerRemoving(player)
	PlayerDataService.Save(player)
	InventoryService.ClearPlayer(player)
	EconomyService.ClearPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

game:BindToClose(function()
	for _, p in ipairs(Players:GetPlayers()) do
		PlayerDataService.Save(p)
	end
end)

print("[SA] StorageAuction M1 server ready.")
