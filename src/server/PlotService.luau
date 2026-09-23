--!nonstrict
-- StorageAuction MVP — server-local warehouse plot assignment.
--
-- Scalability model: plot ownership is SESSION-LOCAL. Only players inside
-- THIS server hold plots; nothing about Plot_01..N is ever persisted.
-- Persistent progression (inventory, displays later, stats) lives in the
-- data services, never here.
--
-- Signing: occupied plots show "<Name>'s Warehouse", free plots AVAILABLE.
-- On release the runtime warehouse is destroyed, attributes cleared, and
-- the plot returns to the free pool. Full servers never kick: assignment
-- fails cleanly and auction gameplay continues.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local PlotService = {}

local MapHandles = nil
local Remotes = nil
local WarehouseService = nil

-- plots[index] = { model, origin (CFrame), originPos (Vector3),
--                  signLabel (TextLabel or nil), ownerUserId (number or nil) }
local plots = {}

-- "a<b" sorted pair key -> true. Session cache; failures are NOT cached so
-- a flaky lookup retries on the next join instead of locking sequential.
local friendCache = {}

local function notify(player, text)
	if not Remotes then
		return
	end
	local ev = Remotes:FindFirstChild(GameConfig.RemoteNames.Notify)
	if ev then
		ev:FireClient(player, text)
	end
end

local function setPlotSign(plot, text)
	if plot.signLabel then
		pcall(function()
			plot.signLabel.Text = text
		end)
	end
end

-- Non-blocking-tolerant friend check: any failure means "not friends"
-- (caller falls back to plain sequential assignment).
local function areFriends(aUserId, bUserId)
	if aUserId == bUserId then
		return true
	end
	local lo, hi = math.min(aUserId, bUserId), math.max(aUserId, bUserId)
	local key = lo .. ":" .. hi
	if friendCache[key] ~= nil then
		return friendCache[key]
	end
	local ok, result = pcall(function()
		local pages = Players:GetFriendsAsync(aUserId)
		local advanced = 0
		while true do
			for _, item in ipairs(pages:GetCurrentPage()) do
				local id = tonumber(item.Id) or tonumber(item.id)
				if id == bUserId then
					return true
				end
			end
			if pages.IsFinished or advanced >= 2 then
				break
			end
			advanced += 1
			pages:AdvanceToNextPageAsync()
		end
		return false
	end)
	if ok and result then
		friendCache[key] = true
		return true
	end
	return false
end

local function freePlots()
	local free = {}
	for i, plot in ipairs(plots) do
		if plot.ownerUserId == nil then
			table.insert(free, plot)
		end
	end
	return free
end

-- Modular pick step (party-aware assignment can extend this later):
-- prefer the free plot nearest to friend-occupied plots, else lowest index.
-- NEVER moves an already-assigned player.
local function pickPlot(player, free)
	if #free == 0 then
		return nil
	end
	if #free == 1 then
		return free[1]
	end
	local friendOrigins = {}
	for _, plot in ipairs(plots) do
		if plot.ownerUserId ~= nil and areFriends(player.UserId, plot.ownerUserId) then
			table.insert(friendOrigins, plot.originPos)
		end
	end
	if #friendOrigins == 0 then
		return free[1] -- free is index-ordered: lowest plot number wins
	end
	local best, bestScore = free[1], nil
	for _, plot in ipairs(free) do
		local nearest = nil
		for _, origin in ipairs(friendOrigins) do
			local dx = plot.originPos.X - origin.X
			local dz = plot.originPos.Z - origin.Z
			local d2 = dx * dx + dz * dz
			if nearest == nil or d2 < nearest then
				nearest = d2
			end
		end
		if bestScore == nil or nearest < bestScore then
			best, bestScore = plot, nearest
		end
	end
	return best
end

function PlotService.Init(deps)
	MapHandles = deps.MapHandles
	Remotes = deps.Remotes
	WarehouseService = deps.WarehouseService

	local district = game.Workspace:FindFirstChild("StorageAuctionMap")
	if district then
		district = district:FindFirstChild("WarehouseDistrict")
	end
	if not district then
		warn("[SA] No WarehouseDistrict in map; warehouse plots disabled (auctions unaffected).")
		return
	end
	local names = {}
	for _, child in ipairs(district:GetChildren()) do
		if child:IsA("Model") and string.match(child.Name, "^Plot_%d%d$") then
			table.insert(names, child.Name)
		end
	end
	table.sort(names)
	for index, name in ipairs(names) do
		local model = district:FindFirstChild(name)
		local originPart = model:FindFirstChild("WarehouseOrigin")
		local signLabel = nil
		local sign = model:FindFirstChild("PlotSign")
		if sign then
			local label = sign:FindFirstChild("TextLabel", true)
			if label and label:IsA("TextLabel") then
				signLabel = label
			end
		end
		plots[index] = {
			index = index,
			name = name,
			model = model,
			origin = if originPart and originPart:IsA("BasePart") then originPart.CFrame else nil,
			originPos = if originPart and originPart:IsA("BasePart") then originPart.Position else model:GetPivot().Position,
			signLabel = signLabel,
			ownerUserId = nil,
		}
		if plots[index].origin == nil then
			warn("[SA] Plot " .. name .. " has no WarehouseOrigin part; using model pivot.")
			plots[index].origin = model:GetPivot()
		end
		setPlotSign(plots[index], "AVAILABLE")
	end
	if #plots == 0 then
		warn("[SA] WarehouseDistrict has no Plot_NN models; warehouse plots disabled.")
	end
end

function PlotService.IsAvailable()
	return #plots > 0
end

function PlotService.PlotCount()
	return #plots
end

function PlotService.GetPlot(player)
	if not player then
		return nil
	end
	for _, plot in ipairs(plots) do
		if plot.ownerUserId == player.UserId then
			return plot
		end
	end
	return nil
end

function PlotService.GetPlotByIndex(index)
	return plots[tonumber(index) or 0]
end

function PlotService.AssignPlot(player)
	if not player then
		return nil
	end
	local existing = PlotService.GetPlot(player)
	if existing then
		return existing
	end
	if #plots == 0 then
		return nil
	end
	local plot = pickPlot(player, freePlots())
	if not plot then
		notify(player, "No warehouse plot available in this server.")
		return nil
	end
	plot.ownerUserId = player.UserId
	plot.model:SetAttribute("OwnerUserId", player.UserId)
	setPlotSign(plot, player.Name .. "'s Warehouse")
	if WarehouseService then
		WarehouseService.BuildFor(player, plot)
	end
	return plot
end

function PlotService.ReleasePlot(player)
	if not player then
		return
	end
	local plot = PlotService.GetPlot(player)
	if WarehouseService then
		WarehouseService.DestroyFor(player)
	end
	if plot then
		plot.ownerUserId = nil
		plot.model:SetAttribute("OwnerUserId", nil)
		setPlotSign(plot, "AVAILABLE")
	end
end

return PlotService
