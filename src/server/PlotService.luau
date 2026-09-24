--!nonstrict
-- StorageAuction MVP — manual warehouse plot claiming (session-local).
--
-- Players start with NO plot. A plot is assigned only when its sign prompt
-- is triggered ("Claim Plot", E). Claimed plots cannot be taken by others;
-- leaving frees the plot, destroys the runtime warehouse, and re-enables
-- claiming. Full servers never kick: claim attempts fail with a toast.
--
-- Scalability model: ownership is SESSION-LOCAL. Plot index/position is
-- temporary per server; progression data lives in the data services.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local PlotService = {}

local Remotes = nil
local WarehouseService = nil
local DisplayService = nil

-- plots[index] = { index, name, model, origin (CFrame), originPos (Vector3),
--                  signLabel (TextLabel or nil), prompt (ProximityPrompt or nil),
--                  ownerUserId (number or nil) }
local plots = {}

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

local function setPromptEnabled(plot, enabled)
	if plot.prompt then
		pcall(function()
			plot.prompt.Enabled = enabled
		end)
	end
end

local function ensureClaimPrompt(plot)
	if plot.prompt then
		return plot.prompt
	end
	local board = plot.model:FindFirstChild("Board", true)
	if not (board and board:IsA("BasePart")) then
		return nil
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ClaimPrompt"
	prompt.ObjectText = "Warehouse Plot"
	prompt.ActionText = "Claim"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
	prompt.Parent = board
	plot.prompt = prompt
	return prompt
end

function PlotService.Init(deps)
	Remotes = deps.Remotes
	WarehouseService = deps.WarehouseService
	DisplayService = deps.DisplayService

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
		local plot = {
			index = index,
			name = name,
			model = model,
			origin = if originPart and originPart:IsA("BasePart") then originPart.CFrame else nil,
			originPos = if originPart and originPart:IsA("BasePart") then originPart.Position else model:GetPivot().Position,
			signLabel = signLabel,
			prompt = nil,
			ownerUserId = nil,
		}
		if plot.origin == nil then
			warn("[SA] Plot " .. name .. " has no WarehouseOrigin part; using model pivot.")
			plot.origin = model:GetPivot()
		end
		-- Claim prompt: authored on the sign board, created if missing.
		local board = model:FindFirstChild("Board", true)
		if board and board:IsA("BasePart") then
			local prompt = board:FindFirstChild("ClaimPrompt")
			if not (prompt and prompt:IsA("ProximityPrompt")) then
				prompt = nil
			end
			plot.prompt = prompt
		end
		ensureClaimPrompt(plot)
		setPlotSign(plot, "AVAILABLE")
		setPromptEnabled(plot, true)
		plots[index] = plot
	end
	if #plots == 0 then
		warn("[SA] WarehouseDistrict has no Plot_NN models; warehouse plots disabled.")
		return
	end
	for _, plot in ipairs(plots) do
		local captured = plot
		if captured.prompt then
			captured.prompt.Triggered:Connect(function(player)
				PlotService.ClaimPlot(player, captured.index)
			end)
		else
			warn("[SA] Plot " .. captured.name .. " has no claim prompt; it cannot be claimed.")
		end
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

-- Manual claim of ONE specific plot. Never picks a different plot, never
-- steals, never moves placed players. One plot per player (session).
function PlotService.ClaimPlot(player, index)
	if not player then
		return nil
	end
	if #plots == 0 then
		notify(player, "Warehouse plots are unavailable.")
		return nil
	end
	local plot = plots[math.floor(tonumber(index) or 0)]
	if not plot then
		notify(player, "That plot does not exist.")
		return nil
	end
	if plot.ownerUserId == player.UserId then
		notify(player, "You already own " .. plot.name .. ".")
		return plot
	end
	if plot.ownerUserId ~= nil then
		notify(player, plot.name .. " is already claimed.")
		return nil
	end
	local owned = PlotService.GetPlot(player)
	if owned then
		notify(player, "You already own " .. owned.name .. ".")
		return nil
	end
	plot.ownerUserId = player.UserId
	plot.model:SetAttribute("OwnerUserId", player.UserId)
	setPlotSign(plot, player.Name .. "'s Warehouse")
	setPromptEnabled(plot, false)
	if WarehouseService then
		WarehouseService.BuildFor(player, plot)
	end
	-- Rebuild restored display proxies inside the newly claimed warehouse
	-- (works on ANY plot: proxies resolve to this clone's anchors).
	if DisplayService then
		DisplayService.RefreshProxies(player)
	end
	notify(player, plot.name .. " claimed!")
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
		setPromptEnabled(plot, true)
	end
end

return PlotService
