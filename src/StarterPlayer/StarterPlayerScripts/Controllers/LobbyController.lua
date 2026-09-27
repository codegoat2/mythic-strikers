--[[
	MythicStrikers — LobbyController
	Client-side lobby interaction handler.

	RESPONSIBILITIES:
	  • Listen to ProximityPrompt.Triggered events on lobby objects
	  • Route interactions to the correct UI screen via ShopUI
	  • Handle the MatchPortal (teleport/confirm flow)
	  • Play enter/exit sounds for buildings
	  • Show floating name labels over NPCs and buildings
	  • Canteen emote zone — open emote picker
	  • Notice board — open quest/event panel (stub)
	  • Trophy room leaderboard — open leaderboard panel

	INTERACTION TYPES (set as StringValue "InteractType" on Parts):
	  TechniqueShop  → open technique shop
	  GearShop       → open gear shop
	  AuraShop       → open aura shop
	  LockerRoom     → open locker room / loadout
	  PlayerHouse    → enter house interior
	  TrophyRoom     → enter trophy room
	  Training       → enter training dome
	  Canteen        → enter canteen
	  Emote          → open emote picker
	  NoticeBoard    → open notice/quest board
	  Leaderboard    → open leaderboard panel
	  MatchPortal    → prompt to join match queue
	  PlayerBoard    → view player stats board
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes   = require(ReplicatedStorage.Remotes)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local LobbyController = {}

-- ─────────────────────────────────────────────
-- Injected refs
-- ─────────────────────────────────────────────
local _shopUI:   table? = nil
local _uiCtrl:   table? = nil

-- ─────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────
local _initialized    = false
local _inLobby        = true      -- true when player is in lobby zone
local _activeBuilding: string? = nil
local _promptConnections: { RBXScriptConnection } = {}
-- Parts already wired, so a rescan or a late tag does not double-connect a
-- ProximityPrompt (which would open the shop twice per press).
local _wired: { [BasePart]: boolean } = {}

-- ─────────────────────────────────────────────
-- Billboard labels over interactive objects
-- ─────────────────────────────────────────────

local function addBillboard(part: BasePart, text: string, color: Color3)
	local bbg = Instance.new("BillboardGui")
	bbg.Size         = UDim2.new(0, 160, 0, 36)
	bbg.StudsOffset  = Vector3.new(0, 4, 0)
	bbg.AlwaysOnTop  = false
	bbg.MaxDistance  = 40
	bbg.Parent       = part

	local lbl = Instance.new("TextLabel")
	lbl.Size             = UDim2.new(1, 0, 1, 0)
	lbl.Text             = text
	lbl.TextScaled       = true
	lbl.Font             = Enum.Font.GothamBold
	lbl.TextColor3       = color
	lbl.BackgroundTransparency = 0.4
	lbl.BackgroundColor3 = Color3.fromRGB(10, 10, 26)
	lbl.BorderSizePixel  = 0
	lbl.Parent           = bbg

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent       = lbl

	return bbg
end

-- ─────────────────────────────────────────────
-- Interaction routing
-- ─────────────────────────────────────────────

local SHOP_TYPES = {
	TechniqueShop = true,
	GearShop      = true,
	AuraShop      = true,
	LockerRoom    = true,
}

local ENTER_TYPES = {
	PlayerHouse = true,
	TrophyRoom  = true,
	Training    = true,
	Canteen     = true,
}

local function handleInteraction(interactType: string, sourcePart: BasePart)
	if SHOP_TYPES[interactType] then
		-- Request catalogue from server then open shop UI
		Remotes.FireServer(Constants.Remotes.OpenShop, {
			ShopType = interactType,
		})
		if _shopUI then
			_shopUI.Open(interactType)
		end

	elseif ENTER_TYPES[interactType] then
		-- Building enter — just notify UI with a banner
		_activeBuilding = interactType
		if _uiCtrl then
			local names = {
				PlayerHouse = "Player House",
				TrophyRoom  = "Trophy Room",
				Training    = "Training Dome",
				Canteen     = "Canteen",
			}
			_uiCtrl.ShowNotification("Entered " .. (names[interactType] or interactType), 2)
		end

	elseif interactType == "Emote" then
		if _shopUI then
			_shopUI.OpenEmotePicker()
		end

	elseif interactType == "NoticeBoard" then
		if _shopUI then
			_shopUI.OpenNoticeBoard()
		end

	elseif interactType == "Leaderboard" then
		if _shopUI then
			_shopUI.OpenLeaderboard()
		end

	elseif interactType == "MatchPortal" then
		-- Show confirm dialog to join match
		if _shopUI then
			_shopUI.OpenMatchConfirm()
		end

	elseif interactType == "PlayerBoard" then
		-- Show local player stats
		if _shopUI then
			_shopUI.OpenPlayerStats()
		end
	end
end

-- ─────────────────────────────────────────────
-- Wire prompts for a single part
-- ─────────────────────────────────────────────

local function wirePrompt(part: BasePart)
	-- Find InteractType
	local typeVal = part:FindFirstChild("InteractType") :: StringValue?
	if not typeVal then return end
	local interactType = typeVal.Value

	-- Find the ProximityPrompt
	local pp = part:FindFirstChildWhichIsA("ProximityPrompt")
	if not pp then return end

	local conn = pp.Triggered:Connect(function(player)
		if player ~= LocalPlayer then return end
		handleInteraction(interactType, part)
	end)
	table.insert(_promptConnections, conn)

	-- Add billboard for shops and special buildings
	local billboardText = {
		TechniqueShop = "⚡ Technique Shop",
		GearShop      = "👟 Gear Shop",
		AuraShop      = "✨ Aura Shop",
		LockerRoom    = "🎒 Locker Room",
		TrophyRoom    = "🏆 Trophy Room",
		Training      = "⚽ Training",
		Canteen       = "🍜 Canteen",
		MatchPortal   = "▶ Enter Match",
		NoticeBoard   = "📋 Notice Board",
	}
	local billboardColor = {
		TechniqueShop = Color3.fromRGB(0, 200, 255),
		GearShop      = Color3.fromRGB(255, 215, 0),
		AuraShop      = Color3.fromRGB(191, 95, 255),
		LockerRoom    = Color3.fromRGB(80, 220, 80),
		TrophyRoom    = Color3.fromRGB(255, 215, 0),
		Training      = Color3.fromRGB(80, 220, 80),
		Canteen       = Color3.fromRGB(255, 160, 60),
		MatchPortal   = Color3.fromRGB(191, 95, 255),
		NoticeBoard   = Color3.fromRGB(0, 200, 255),
	}

	if billboardText[interactType] then
		addBillboard(part, billboardText[interactType],
			billboardColor[interactType] or Color3.new(1,1,1))
	end
end

-- ─────────────────────────────────────────────
-- Scan lobby model for all interactive parts
-- ─────────────────────────────────────────────

local function scanLobby(lobbyModel: Model)
	local scanned = 0
	local tagged  = 0
	local prompts = 0
	local wired   = 0

	for _, desc in ipairs(lobbyModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			scanned += 1
			if desc:FindFirstChild("InteractType") then
				tagged += 1
				if desc:FindFirstChildWhichIsA("ProximityPrompt") then
					prompts += 1
					if not _wired[desc :: BasePart] then
						_wired[desc :: BasePart] = true
						wirePrompt(desc :: BasePart)
						wired += 1
					end
				end
			end
		end
	end

	print(string.format(
		"[LobbyController] Scan: %d parts, %d tagged, %d with prompts, %d newly wired, %d total connections.",
		scanned, tagged, prompts, wired, #_promptConnections
	))
	if #_promptConnections == 0 then
		warn("[LobbyController] No interactive parts wired. "
			.. "If tagged/prompts are 0 the lobby was scanned before it finished building.")
	end
	return #_promptConnections
end

-- ─────────────────────────────────────────────
-- Server → Client remotes
-- ─────────────────────────────────────────────

local function onShopCatalogueUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	if _shopUI then
		_shopUI.ReceiveCatalogue(payload)
	end
end

local function onShopPurchaseResult(payload: table)
	if typeof(payload) ~= "table" then return end
	if _shopUI then
		_shopUI.HandlePurchaseResult(payload)
	end
	-- Show toast notification
	if _uiCtrl then
		if payload.Success then
			_uiCtrl.ShowNotification(
				string.format("✅ Bought: %s  (-%d coins)", payload.ItemName or "?", payload.CoinsSpent or 0),
				3
			)
		else
			_uiCtrl.ShowNotification("❌ " .. (payload.Reason or "Purchase failed."), 3)
		end
	end
end

local function onNotifyPlayer(payload: table)
	if typeof(payload) ~= "table" then return end
	if payload.Type == "DailyBonus" and _uiCtrl then
		_uiCtrl.ShowNotification("🎁 " .. (payload.Message or "Daily bonus!"), 4)
	end
end

-- ─────────────────────────────────────────────
-- NPC idle wander (client-side visual only)
-- Very lightweight — just oscillates NPC prop Y position slightly
-- ─────────────────────────────────────────────

local _npcWanderTime = 0
local _npcBodies: { BasePart } = {}
local _npcAnchors: { [BasePart]: CFrame } = {}

--- Cache NPC bodies once. The previous version ran
--- workspace:FindFirstChild + GetChildren on EVERY Heartbeat frame — including
--- during matches — and multiplied each part's CFrame by a fresh offset, so
--- float error accumulated and the NPCs drifted away over time.
local function refreshNPCCache(lobby: Model)
	_npcBodies = {}
	_npcAnchors = {}
	for _, part in ipairs(lobby:GetChildren()) do
		if part:IsA("BasePart") and string.find(part.Name, "_NPCBody") then
			table.insert(_npcBodies, part :: BasePart)
			_npcAnchors[part] = part.CFrame
		end
	end
end

local function animateNPCs(dt: number)
	-- Only animate while the player is actually in the town.
	if not _inLobby then return end
	if #_npcBodies == 0 then return end

	_npcWanderTime += dt
	for _, part in ipairs(_npcBodies) do
		local anchor = _npcAnchors[part]
		if anchor and part.Parent then
			-- Bob relative to the cached anchor so nothing accumulates.
			local bob = math.sin(_npcWanderTime * 1.5 + part:GetPivot().Position.X) * 0.4
			part.CFrame = anchor + Vector3.new(0, bob, 0)
		end
	end
end

-- ─────────────────────────────────────────────
-- Init
-- ─────────────────────────────────────────────

function LobbyController.Init(shopUI: table?, uiCtrl: table?)
	if _initialized then return end
	_initialized = true

	_shopUI  = shopUI
	_uiCtrl  = uiCtrl

	-- Remote listeners
	Remotes.OnClientEvent(Constants.Remotes.ShopCatalogueUpdate, onShopCatalogueUpdate)
	Remotes.OnClientEvent(Constants.Remotes.ShopPurchaseResult,  onShopPurchaseResult)
	Remotes.OnClientEvent(Constants.Remotes.NotifyPlayer,        onNotifyPlayer)

	-- Wait for lobby model then scan
	task.spawn(function()
		local lobby = workspace:FindFirstChild("Lobby")
		local waited = 0
		while not lobby and waited < 15 do
			task.wait(0.5)
			waited += 0.5
			lobby = workspace:FindFirstChild("Lobby")
		end
		if lobby then
			scanLobby(lobby :: Model)
			refreshNPCCache(lobby :: Model)
			-- Wait for the builder to finish populating the model. The Lobby
			-- Model appears in Workspace before it has any children, so
			-- scanning on mere existence found an empty town and wired nothing.
			local readyDeadline = tick() + 20
			while lobby:GetAttribute("Ready") ~= true and tick() < readyDeadline do
				task.wait(0.2)
			end
			if lobby:GetAttribute("Ready") ~= true then
				warn("[LobbyController] Lobby never reported Ready — scanning anyway.")
			end

			-- Scan, then keep rescanning briefly. A single early scan can still
			-- land before every prompt has replicated, and `_wired` makes the
			-- extra passes free.
			for attempt = 1, 6 do
				local count = scanLobby(lobby :: Model)
				if count > 0 then break end
				if attempt < 6 then task.wait(2) end
			end

			-- Watch for parts added later (lobby rebuild). The InteractType tag is
			-- parented AFTER its part, so the tag check has to happen on a later
			-- frame than the part's own DescendantAdded event; the old code
			-- checked it before its task.wait and therefore never matched.
			local function tryWire(desc: Instance)
				if not desc:IsA("BasePart") then return end
				task.delay(0.1, function()
					if desc.Parent and desc:FindFirstChild("InteractType")
						and not _wired[desc] then
						_wired[desc] = true
						wirePrompt(desc :: BasePart)
					end
				end)
			end
			lobby.DescendantAdded:Connect(tryWire)
			-- Catch anything already present but tagged late.
			for _, desc in ipairs(lobby:GetDescendants()) do
				tryWire(desc)
			end
		else
			warn("[LobbyController] Lobby model not found after 15s.")
		end
	end)

	-- NPC animation
	RunService.Heartbeat:Connect(animateNPCs)

	-- Lobby fountain animation: a gentle vertical pulse on the jet and a
	-- slow Y-axis wobble on the water disc so the plaza feels alive without
	-- being distracting.
	local TweenService = game:GetService("TweenService")
	task.spawn(function()
		local lobby = workspace:FindFirstChild("Lobby")
		if not lobby then return end
		local jet = lobby:FindFirstChild("Fountain_Jet")
		local water = lobby:FindFirstChild("Fountain_Water")
		if jet and jet:IsA("BasePart") then
			local baseY = jet.Position.Y
			local tween = TweenService:Create(jet, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1), {
				Position = Vector3.new(jet.Position.X, baseY + 0.25, jet.Position.Z),
			})
			tween:Play()
		end
		if water and water:IsA("BasePart") then
			local baseY = water.Position.Y
			local tween = TweenService:Create(water, TweenInfo.new(2.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1), {
				Position = Vector3.new(water.Position.X, baseY + 0.08, water.Position.Z),
			})
			tween:Play()
		end
	end)

	print("[LobbyController] Initialised.")
end

--- Call when player enters the match (disables lobby interaction prompts).
function LobbyController.SetLobbyActive(active: boolean)
	_inLobby = active
	local lobby = workspace:FindFirstChild("Lobby")
	if not lobby then return end
	-- Show/hide all ProximityPrompts
	for _, desc in ipairs(lobby:GetDescendants()) do
		if desc:IsA("ProximityPrompt") then
			desc.Enabled = active
		end
	end
end

return LobbyController
