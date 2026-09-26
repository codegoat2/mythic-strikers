--[[
	MythicStrikers — UIController
	Owns all in-match HUD elements and the mobile virtual joystick.

	HUD ELEMENTS:
	  • Scoreboard (TeamA score — TeamB score)
	  • Match timer
	  • Mythic Energy bar
	  • Stamina bar
	  • Awakening meter + active glow
	  • Technique slots (1–4) with cooldown overlays
	  • Possession indicator
	  • Countdown display
	  • Goal notification banner
	  • Half-time / Match-end overlay
	  • Notification toasts (assists, tackles, etc.)

	MOBILE:
	  • Virtual joystick (left side)
	  • Pass / Shoot / Sprint / Tackle action buttons (right side)
	  • Technique wheel (4 buttons)
	  • Awakening button

	DESIGN PHILOSOPHY:
	  All UI is built programmatically — no dependency on pre-built Studio GUIs.
	  This makes the codebase fully portable and avoids broken asset references.
	  Colour palette: dark background (#0D0D1A), accent gold (#FFD700),
	  TeamA blue (#1E90FF), TeamB red (#FF3C3C), energy cyan (#00FFFF),
	  awakening purple (#BF5FFF).
--]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes   = require(ReplicatedStorage.Remotes)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local UIController = {}

-- ─────────────────────────────────────────────
-- Injected refs
-- ─────────────────────────────────────────────
local _inputController: table? = nil
local _footballController: table? = nil

-- ─────────────────────────────────────────────
-- Platform
-- ─────────────────────────────────────────────
local _isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- ─────────────────────────────────────────────
-- Colours
-- ─────────────────────────────────────────────
local C = {
	BG          = Color3.fromRGB(10,  10,  26),
	BG_PANEL    = Color3.fromRGB(18,  18,  40),
	ACCENT      = Color3.fromRGB(255, 215, 0),
	TEAM_A      = Color3.fromRGB(30,  144, 255),
	TEAM_B      = Color3.fromRGB(255, 60,  60),
	ENERGY      = Color3.fromRGB(0,   255, 255),
	STAMINA     = Color3.fromRGB(80,  220, 80),
	AWAKENING   = Color3.fromRGB(191, 95,  255),
	TEXT        = Color3.fromRGB(240, 240, 255),
	TEXT_DIM    = Color3.fromRGB(140, 140, 160),
	WHITE       = Color3.new(1, 1, 1),
	COOLDOWN_OV = Color3.fromRGB(0,   0,   0),
}

-- ─────────────────────────────────────────────
-- UI helpers
-- ─────────────────────────────────────────────

local function makeFrame(parent, name, size, pos, bgColor, transparency)
	local f = Instance.new("Frame")
	f.Name              = name
	f.Size              = size
	f.Position          = pos
	f.BackgroundColor3  = bgColor or C.BG_PANEL
	f.BackgroundTransparency = transparency or 0
	f.BorderSizePixel   = 0
	f.Parent            = parent
	return f
end

local function makeLabel(parent, name, text, textSize, color, size, pos, font)
	local l = Instance.new("TextLabel")
	l.Name              = name
	l.Text              = text
	l.TextSize          = textSize or 18
	l.TextColor3        = color or C.TEXT
	l.Font              = font or Enum.Font.GothamBold
	l.Size              = size or UDim2.new(1, 0, 1, 0)
	l.Position          = pos  or UDim2.new(0, 0, 0, 0)
	l.BackgroundTransparency = 1
	l.TextXAlignment    = Enum.TextXAlignment.Center
	l.TextYAlignment    = Enum.TextYAlignment.Center
	l.Parent            = parent
	return l
end

local function makeCorner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent       = parent
	return c
end

local function makeBar(parent, name, fillColor, bgColor, sizeY, posY)
	local bg = makeFrame(parent, name .. "_BG",
		UDim2.new(1, 0, 0, sizeY or 10),
		UDim2.new(0, 0, 0, posY or 0),
		bgColor or C.BG, 0.3
	)
	makeCorner(bg, 4)
	local fill = makeFrame(bg, name .. "_Fill",
		UDim2.new(1, 0, 1, 0),
		UDim2.new(0, 0, 0, 0),
		fillColor, 0
	)
	makeCorner(fill, 4)
	return bg, fill
end

-- ─────────────────────────────────────────────
-- ScreenGui root
-- ─────────────────────────────────────────────
local _hudGui: ScreenGui
local _overlayGui: ScreenGui   -- goal/halftime/end overlays (always on top)
local _mobileGui: ScreenGui    -- mobile controls

-- ─────────────────────────────────────────────
-- HUD element references
-- ─────────────────────────────────────────────
local _scoreLabel:      TextLabel
local _timerLabel:      TextLabel
local _scoreA:          TextLabel
local _scoreB:          TextLabel

local _energyFill:      Frame
local _staminaFill:     Frame
local _awakeningFill:   Frame
local _awakeningFrame:  Frame
local _awakeningGlow:   Frame

local _techSlots: { Frame }      = {}
local _techLabels: { TextLabel } = {}
local _techCooldownOverlay: { Frame }   = {}
local _techCooldownLabel:   { TextLabel } = {}

local _possessionDot:   Frame
local _countdownLabel:  TextLabel
local _goalBanner:      Frame
local _goalBannerText:  TextLabel
local _notifFrame:      Frame
local _notifLabel:      TextLabel

-- Player card (lobby)
local _playerCard:      Frame?
local _playerName:      TextLabel?
local _playerLevel:     TextLabel?
local _playerXPBar:     Frame?
local _playerRank:      TextLabel?
local _playerTeam:      TextLabel?

-- Objectives UI (lobby)
local _objectivesFrame: Frame?

-- Mobile elements
local _vjBase:     Frame
local _vjThumb:    Frame
local _mobileButtons: { [string]: Frame } = {}

-- ─────────────────────────────────────────────
-- Player card (lobby overlay)
-- ─────────────────────────────────────────────

local function buildPlayerCard()
	if _playerCard then return end

	local panel = makeFrame(_hudGui, "PlayerCard",
		UDim2.new(0, 320, 0, 140),
		UDim2.new(0, 16, 0, 16),
		C.BG_PANEL, 0.15
	)
	makeCorner(panel, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color     = Color3.fromRGB(255, 215, 0)
	stroke.Thickness = 1
	stroke.Transparency = 0.5
	stroke.Parent    = panel

	_playerName = makeLabel(panel, "PlayerName", "–", 20, C.ACCENT,
		UDim2.new(1, -16, 0, 26), UDim2.new(8, 0, 8, 0))
	_playerName.Font = Enum.Font.GothamBold

	_playerLevel = makeLabel(panel, "PlayerLevel", "Lv. 1", 16, C.TEXT,
		UDim2.new(1, -16, 0, 20), UDim2.new(8, 0, 40, 0))

	_playerXPBar = makeFrame(panel, "XPBar",
		UDim2.new(1, -16, 0, 8), UDim2.new(8, 0, 68, 0),
		Color3.fromRGB(30, 30, 40), 0)
	makeCorner(_playerXPBar, 4)
	local xpFill = makeFrame(_playerXPBar, "XPFill",
		UDim2.new(0, 0, 1, 0), UDim2.new(0, 0, 0, 0),
		C.ENERGY, 0)
	makeCorner(xpFill, 4)
	_playerXPBar._fill = xpFill

	_playerRank = makeLabel(panel, "PlayerRank", "Rookie", 14, C.TEXT_DIM,
		UDim2.new(0.5, -8, 0, 20), UDim2.new(16, 0, 100, 0))
	_playerRank.TextXAlignment = Enum.TextXAlignment.Left

	_playerTeam = makeLabel(panel, "PlayerTeam", "Team: —", 14, C.TEXT_DIM,
		UDim2.new(0.5, -8, 0, 20), UDim2.new(0.5, 8, 100, 0))
	_playerTeam.TextXAlignment = Enum.TextXAlignment.Right

	panel.Visible = false
end

local function buildObjectives()
	if _objectivesFrame then return end

	local panel = makeFrame(_hudGui, "Objectives",
		UDim2.new(0, 300, 0, 100),
		UDim2.new(0.5, -150, 1, -120),
		C.BG_PANEL, 0.15
	)
	makeCorner(panel, 10)

	local title = makeLabel(panel, "ObjTitle", "OBJECTIVES", 16, C.ACCENT,
		UDim2.new(1, 0, 0, 20), UDim2.new(0, 8, 0, 4))
	title.Font = Enum.Font.GothamBold

	local list = makeFrame(panel, "ObjList",
		UDim2.new(1, -16, 1, -28),
		UDim2.new(0, 8, 0, 28),
		C.BG, 0.4
	)
	makeCorner(list, 6)

	_objectivesFrame = panel
	panel.Visible = false
end

-- ─────────────────────────────────────────────
-- Build HUD
-- ─────────────────────────────────────────────

local function buildScoreboard()
	-- Top-centre panel
	local panel = makeFrame(_hudGui, "Scoreboard",
		UDim2.new(0, 300, 0, 68),
		UDim2.new(0.5, -150, 0, 8),
		C.BG_PANEL, 0.15
	)
	makeCorner(panel, 10)

	-- Subtle border
	local stroke = Instance.new("UIStroke")
	stroke.Color     = Color3.fromRGB(60, 60, 100)
	stroke.Thickness = 1
	stroke.Parent    = panel

	-- Team A score
	_scoreA = makeLabel(panel, "ScoreA", "0", 36, C.TEAM_A,
		UDim2.new(0.28, 0, 0, 44), UDim2.new(0.02, 0, 0, 4))

	-- Separator
	makeLabel(panel, "Sep", "—", 20, C.TEXT_DIM,
		UDim2.new(0.14, 0, 0, 44), UDim2.new(0.30, 0, 0, 4))

	-- Team B score
	_scoreB = makeLabel(panel, "ScoreB", "0", 36, C.TEAM_B,
		UDim2.new(0.28, 0, 0, 44), UDim2.new(0.56, 0, 0, 4))

	-- Timer — sits in bottom strip of the panel
	_timerLabel = makeLabel(panel, "Timer", "3:00", 14, C.TEXT_DIM,
		UDim2.new(1, 0, 0, 20), UDim2.new(0, 0, 1, -22))
end

local function buildEnergyBars()
	-- Bottom-left panel: Stamina + Energy + Awakening
	local panel = makeFrame(_hudGui, "StatusBars",
		UDim2.new(0, 180, 0, 80),
		UDim2.new(0, 12, 1, -95),
		C.BG_PANEL, 0.2
	)
	makeCorner(panel, 8)

	-- Labels
	makeLabel(panel, "StamLbl", "STAMINA", 11, C.TEXT_DIM,
		UDim2.new(1, -8, 0, 14), UDim2.new(0, 4, 0, 2))
	local _, stamFill = makeBar(panel, "Stamina", C.STAMINA, Color3.fromRGB(30,60,30), 10, 16)
	_staminaFill = stamFill
	stamFill.Size = UDim2.new(1, -8, 0, 10)
	stamFill.Parent.Position = UDim2.new(0, 4, 0, 16)
	stamFill.Parent.Size     = UDim2.new(1, -8, 0, 10)

	makeLabel(panel, "NrgLbl", "MYTHIC ENERGY", 11, C.ENERGY,
		UDim2.new(1, -8, 0, 14), UDim2.new(0, 4, 0, 30))
	local _, nrgFill = makeBar(panel, "Energy", C.ENERGY, Color3.fromRGB(0,30,30), 10, 44)
	_energyFill = nrgFill
	nrgFill.Parent.Position = UDim2.new(0, 4, 0, 44)
	nrgFill.Parent.Size     = UDim2.new(1, -8, 0, 10)

	-- Awakening meter
	_awakeningFrame = makeFrame(panel, "AwakenFrame",
		UDim2.new(1, -8, 0, 12),
		UDim2.new(0, 4, 0, 60),
		Color3.fromRGB(20, 10, 30), 0
	)
	makeCorner(_awakeningFrame, 4)
	_awakeningFill = makeFrame(_awakeningFrame, "AwakenFill",
		UDim2.new(0, 0, 1, 0),
		UDim2.new(0, 0, 0, 0),
		C.AWAKENING, 0
	)
	makeCorner(_awakeningFill, 4)
	makeLabel(panel, "AwakeLbl", "AWAKENING", 11, C.AWAKENING,
		UDim2.new(1, -8, 0, 14), UDim2.new(0, 4, 0, 48))

	-- Active awakening glow (hidden by default)
	_awakeningGlow = makeFrame(panel, "AwakenGlow",
		UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
		C.AWAKENING, 0.85
	)
	_awakeningGlow.Visible = false
	makeCorner(_awakeningGlow, 8)
end

local function buildTechSlots()
	-- Bottom-right: 4 technique slots
	local panel = makeFrame(_hudGui, "TechPanel",
		UDim2.new(0, 200, 0, 54),
		UDim2.new(1, -212, 1, -66),
		C.BG_PANEL, 0.2
	)
	makeCorner(panel, 8)

	local slotKeys = { "Q", "E", "R", "T" }

	for i = 1, 4 do
		local slot = makeFrame(panel, "Slot" .. i,
			UDim2.new(0, 44, 0, 44),
			UDim2.new(0, 4 + (i - 1) * 49, 0, 5),
			Color3.fromRGB(20, 20, 40), 0
		)
		makeCorner(slot, 6)

		-- Key label
		makeLabel(slot, "Key", slotKeys[i], 12, C.TEXT_DIM,
			UDim2.new(1, 0, 0, 16), UDim2.new(0, 0, 0, 0))

		-- Tech name (abbreviated)
		local tl = makeLabel(slot, "TechName", "—", 9, C.TEXT,
			UDim2.new(1, 0, 0, 18), UDim2.new(0, 0, 1, -18))
		_techLabels[i] = tl

		-- Cooldown overlay
		local ov = makeFrame(slot, "CooldownOv",
			UDim2.new(1, 0, 0, 0),
			UDim2.new(0, 0, 1, 0),
			C.COOLDOWN_OV, 0.5
		)
		ov.Visible = false
		makeCorner(ov, 6)
		local cl = makeLabel(ov, "CDLabel", "", 12, C.TEXT,
			UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0))
		_techCooldownOverlay[i] = ov
		_techCooldownLabel[i]   = cl

		_techSlots[i] = slot
	end
end

local function buildPossessionIndicator()
	-- Small dot at bottom-centre when you have the ball
	_possessionDot = makeFrame(_hudGui, "PossessionDot",
		UDim2.new(0, 14, 0, 14),
		UDim2.new(0.5, -7, 1, -22),
		C.ACCENT, 0
	)
	makeCorner(_possessionDot, 7)
	_possessionDot.Visible = false
end

local function buildCountdownDisplay()
	_countdownLabel = makeLabel(_hudGui, "CountdownLabel",
		"", 80, C.ACCENT,
		UDim2.new(1, 0, 0, 120),
		UDim2.new(0, 0, 0.5, -60)
	)
	_countdownLabel.Font             = Enum.Font.GothamBlack
	_countdownLabel.Visible          = false
	_countdownLabel.TextTransparency = 1   -- start fully transparent so fade-in works cleanly
end

local function buildGoalBanner()
	_goalBanner = makeFrame(_hudGui, "GoalBanner",
		UDim2.new(0, 500, 0, 90),
		UDim2.new(0.5, -250, 0, -110),   -- parked above the visible screen area
		C.BG_PANEL, 0.1
	)
	makeCorner(_goalBanner, 12)
	-- Gold neon border stroke
	local stroke = Instance.new("UIStroke")
	stroke.Color     = C.ACCENT
	stroke.Thickness = 2
	stroke.Parent    = _goalBanner

	_goalBannerText = makeLabel(_goalBanner, "GoalText", "GOAL!", 54, C.ACCENT,
		UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0))
	_goalBannerText.Font = Enum.Font.GothamBlack

	-- CRITICAL: hide entirely until a goal fires
	_goalBanner.Visible = false
end

local function buildNotifications()
	_notifFrame = makeFrame(_hudGui, "NotifFrame",
		UDim2.new(0, 260, 0, 36),
		UDim2.new(0.5, -130, 0, 80),
		C.BG_PANEL, 0.2
	)
	makeCorner(_notifFrame, 8)
	_notifLabel = makeLabel(_notifFrame, "NotifText", "", 16, C.TEXT)
	_notifFrame.Visible = false
end

local function buildHUD()
	_hudGui = Instance.new("ScreenGui")
	_hudGui.Name             = "MythicHUD"
	_hudGui.ResetOnSpawn     = false
	_hudGui.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
	_hudGui.DisplayOrder     = 1
	_hudGui.IgnoreGuiInset   = false   -- respect the top inset (camera notch/statusbar)
	_hudGui.Parent           = PlayerGui

	buildScoreboard()
	buildEnergyBars()
	buildTechSlots()
	buildPossessionIndicator()
	buildCountdownDisplay()
	buildGoalBanner()
	buildNotifications()
	buildPlayerCard()
	buildObjectives()
end

-- ─────────────────────────────────────────────
-- Overlay GUI (goal / half-time / end screen)
-- ─────────────────────────────────────────────

local function buildOverlayGui()
	_overlayGui = Instance.new("ScreenGui")
	_overlayGui.Name           = "MythicOverlay"
	_overlayGui.ResetOnSpawn   = false
	_overlayGui.DisplayOrder   = 10
	_overlayGui.Parent         = PlayerGui
end

-- ─────────────────────────────────────────────
-- Mobile GUI
-- ─────────────────────────────────────────────

local VJ_SIZE   = 100   -- px diameter of VJ base
local BTN_SIZE  = 64    -- px action button size

local function makeMobileButton(parent, name, label, pos, color)
	local btn = makeFrame(parent, name,
		UDim2.new(0, BTN_SIZE, 0, BTN_SIZE),
		pos,
		color or C.BG_PANEL, 0.25
	)
	makeCorner(btn, BTN_SIZE / 2)
	makeLabel(btn, "Label", label, 14, C.TEXT)

	-- Touch handlers wired in setupMobileInput()
	return btn
end

local function buildMobileUI()
	if not _isMobile then return end

	_mobileGui = Instance.new("ScreenGui")
	_mobileGui.Name          = "MythicMobile"
	_mobileGui.ResetOnSpawn  = false
	_mobileGui.DisplayOrder  = 5
	_mobileGui.Parent        = PlayerGui

	-- Virtual joystick base (left side)
	_vjBase = makeFrame(_mobileGui, "VJBase",
		UDim2.new(0, VJ_SIZE, 0, VJ_SIZE),
		UDim2.new(0, 40, 1, -(VJ_SIZE + 40)),
		Color3.fromRGB(255,255,255), 0.8
	)
	makeCorner(_vjBase, VJ_SIZE / 2)

	_vjThumb = makeFrame(_vjBase, "VJThumb",
		UDim2.new(0, 46, 0, 46),
		UDim2.new(0.5, -23, 0.5, -23),
		C.ACCENT, 0.3
	)
	makeCorner(_vjThumb, 23)

	-- Action buttons (right side)
	local rightX = UDim2.new(1, -(BTN_SIZE * 2 + 24))
	local rightY = UDim2.new(1, -(BTN_SIZE + 40))

	_mobileButtons["Pass"]   = makeMobileButton(_mobileGui, "PassBtn",   "PASS",   UDim2.new(1, -(BTN_SIZE * 3 + 36), 1, -(BTN_SIZE + 40)), C.TEAM_A)
	_mobileButtons["Shoot"]  = makeMobileButton(_mobileGui, "ShootBtn",  "SHOOT",  UDim2.new(1, -(BTN_SIZE * 2 + 24), 1, -(BTN_SIZE + 40)), C.TEAM_B)
	_mobileButtons["Sprint"] = makeMobileButton(_mobileGui, "SprintBtn", "SPRINT", UDim2.new(1, -(BTN_SIZE + 12),     1, -(BTN_SIZE * 2 + 52)), C.STAMINA)
	_mobileButtons["Tackle"] = makeMobileButton(_mobileGui, "TackleBtn", "TACKLE", UDim2.new(1, -(BTN_SIZE + 12),     1, -(BTN_SIZE + 40)), C.AWAKENING)

	-- Technique buttons (above action buttons)
	local techColors = { C.ENERGY, C.ACCENT, C.AWAKENING, C.TEAM_A }
	for i = 1, 4 do
		_mobileButtons["Tech" .. i] = makeMobileButton(_mobileGui, "Tech" .. i .. "Btn",
			"T" .. i,
			UDim2.new(1, -(BTN_SIZE * (5 - i) + 12 * (4 - i) + 12),
			          1, -(BTN_SIZE * 2 + 52)),
			techColors[i]
		)
	end

	-- Awakening button (large, centre-right)
	_mobileButtons["Awakening"] = makeMobileButton(_mobileGui, "AwakenBtn",
		"⚡", UDim2.new(0.5, 20, 1, -(BTN_SIZE * 2 + 52)), C.AWAKENING
	)
end

-- ─────────────────────────────────────────────
-- Mobile input wiring
-- ─────────────────────────────────────────────

local function setupMobileInput()
	if not _isMobile or not _inputController then return end

	-- Virtual joystick
	local vjTouchId: number? = nil
	local vjAbsPos = _vjBase.AbsolutePosition + _vjBase.AbsoluteSize / 2

	_vjBase.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch then return end
		vjTouchId = input.Fingerprint
		_inputController.SetVJState(true, Vector2.new(vjAbsPos.X, vjAbsPos.Y),
			Vector2.new(input.Position.X, input.Position.Y), vjTouchId)
	end)

	_vjBase.InputChanged:Connect(function(input)
		if input.Fingerprint ~= vjTouchId then return end
		local cur = Vector2.new(input.Position.X, input.Position.Y)
		_inputController.SetVJState(true, Vector2.new(vjAbsPos.X, vjAbsPos.Y), cur, vjTouchId)

		-- Move thumb visual
		local delta   = cur - Vector2.new(vjAbsPos.X, vjAbsPos.Y)
		local clamped = delta.Magnitude > 40 and (delta.Unit * 40) or delta
		_vjThumb.Position = UDim2.new(0.5, clamped.X - 23, 0.5, clamped.Y - 23)
	end)

	_vjBase.InputEnded:Connect(function(input)
		if input.Fingerprint ~= vjTouchId then return end
		vjTouchId = nil
		_inputController.SetVJState(false, Vector2.zero, Vector2.zero, nil)
		_vjThumb.Position = UDim2.new(0.5, -23, 0.5, -23)
	end)

	-- Action buttons
	local function wireBtn(name, downFn, upFn)
		local btn = _mobileButtons[name]
		if not btn then return end
		btn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				if downFn then downFn() end
			end
		end)
		btn.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				if upFn then upFn() end
		end
	end)
end

--- Start cooldown overlay animation for a slot.

	wireBtn("Pass",   _inputController.TriggerPass, nil)
	wireBtn("Shoot",  _inputController.TriggerShootStart, _inputController.TriggerShootEnd)
	wireBtn("Sprint", _inputController.TriggerSprintStart, _inputController.TriggerSprintEnd)
	wireBtn("Tackle", _inputController.TriggerTackle, nil)
	wireBtn("Awakening", _inputController.TriggerAwakening, nil)
	for i = 1, 4 do
		local slot = i
		wireBtn("Tech" .. i, function()
			_inputController.TriggerTechnique(slot)
		end, nil)
	end
end

-- ─────────────────────────────────────────────
-- Cooldown display loop
-- ─────────────────────────────────────────────

local _cooldownExpiry: { [number]: number } = {}

local function updateCooldownDisplays()
	local now = tick()
	for i = 1, 4 do
		local expires = _cooldownExpiry[i]
		if expires and now < expires then
			local remaining = expires - now
			local totalCD   = _cooldownExpiry["duration" .. i] or 1
			local ratio     = math.clamp(remaining / totalCD, 0, 1)

			_techCooldownOverlay[i].Visible = true
			_techCooldownOverlay[i].Size    = UDim2.new(1, 0, ratio, 0)
			_techCooldownOverlay[i].Position = UDim2.new(0, 0, 1 - ratio, 0)
			_techCooldownLabel[i].Text       = string.format("%.1f", remaining)
		else
			_techCooldownOverlay[i].Visible = false
		end
	end
end

-- ─────────────────────────────────────────────
-- Remote handlers
-- ─────────────────────────────────────────────

local function onScoreUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	if _scoreA then _scoreA.Text = tostring(payload.ScoreA or 0) end
	if _scoreB then _scoreB.Text = tostring(payload.ScoreB or 0) end
end

local function onMatchStateUpdate(payload: table)
	if typeof(payload) ~= "table" then return end

	-- Update timer
	if payload.TimeLeft and _timerLabel then
		local t = math.max(0, math.floor(payload.TimeLeft))
		local mins = math.floor(t / 60)
		local secs = t % 60
		_timerLabel.Text = string.format("%d:%02d", mins, secs)
	end

	-- Update score from state packet too
	if payload.ScoreA ~= nil then onScoreUpdate(payload) end

	-- Half indicator
	if payload.Half and _timerLabel then
		-- Prepend half number
		local t = math.max(0, math.floor(payload.TimeLeft or 0))
		local mins = math.floor(t / 60)
		local secs = t % 60
		local halfTag = payload.Half == 1 and "H1" or "H2"
		_timerLabel.Text = string.format("%s  %d:%02d", halfTag, mins, secs)
	end

	-- Half-time overlay
	if payload.State == "HalfTime" then
		UIController.ShowNotification("HALF TIME", 6)
	end

	-- Match ended
	if payload.State == "Ended" then
		local winner = payload.WinnerTeam
		local msg = winner == nil and "DRAW!"
			or (winner == "TeamA" and "TEAM A WINS!" or "TEAM B WINS!")
		UIController.ShowFullscreenMessage(msg, 6)
	end
end

local function onPlayerEnergyUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	local ratio = (payload.MaxEnergy and payload.MaxEnergy > 0)
		and (payload.Energy / payload.MaxEnergy) or 0
	if _energyFill then
		_energyFill.Size = UDim2.new(math.clamp(ratio, 0, 1), 0, 1, 0)
	end
end

local function onPlayerStaminaUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	local ratio = (payload.MaxStamina and payload.MaxStamina > 0)
		and (payload.Stamina / payload.MaxStamina) or 0
	if _staminaFill then
		_staminaFill.Size = UDim2.new(math.clamp(ratio, 0, 1), 0, 1, 0)
	end
end

local function onAwakeningUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	local ratio = (payload.Meter or 0) / 100
	if _awakeningFill then
		_awakeningFill.Size = UDim2.new(math.clamp(ratio, 0, 1), 0, 1, 0)
	end
	if _awakeningGlow then
		_awakeningGlow.Visible = (payload.IsActive == true)
	end
end

local function onGoalScored(payload: table)
	if typeof(payload) ~= "table" then return end

	-- Update score immediately
	onScoreUpdate(payload)

	-- Animate goal banner drop-in
	if _goalBanner then
		-- Build message
		local msg = "⚽  GOAL!"
		if payload.ScorerUserId then
			local scorer = Players:GetPlayerByUserId(payload.ScorerUserId)
			if scorer then
				msg = "⚽  GOAL!   " .. scorer.DisplayName
			end
		end
		if _goalBannerText then _goalBannerText.Text = msg end

		-- Start above screen, make visible, tween down
		_goalBanner.Position    = UDim2.new(0.5, -250, 0, -110)
		_goalBanner.Visible     = true
		_goalBanner.BackgroundTransparency = 0.1

		TweenService:Create(_goalBanner,
			TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, -250, 0, 28) }
		):Play()

		-- Hold 3s then slide back up and hide
		task.delay(3.2, function()
			if not _goalBanner then return end
			TweenService:Create(_goalBanner,
				TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Position = UDim2.new(0.5, -250, 0, -110) }
			):Play()
			task.delay(0.35, function()
				if _goalBanner then _goalBanner.Visible = false end
			end)
		end)
	end
end

local function onMatchCountdown(count: number)
	if not _countdownLabel then return end
	if count <= 0 then
		_countdownLabel.Visible = false
		return
	end
	_countdownLabel.Text    = tostring(math.ceil(count))
	_countdownLabel.Visible = true
	TweenService:Create(_countdownLabel,
		TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextTransparency = 0 }
	):Play()
	task.delay(0.8, function()
		TweenService:Create(_countdownLabel,
			TweenInfo.new(0.2),
			{ TextTransparency = 1 }
		):Play()
	end)
end

local function onNotifyPlayer(payload: table)
	if typeof(payload) ~= "table" then return end
	local t = payload.Type or ""
	if t == "Tackle" then
		local tackler = Players:GetPlayerByUserId(payload.TacklerId)
		if tackler and tackler == LocalPlayer then
			UIController.ShowNotification("CLEAN TACKLE!", 2)
		end
	elseif t == "Save" then
		local keeper = Players:GetPlayerByUserId(payload.KeeperId)
		if keeper and keeper == LocalPlayer then
			UIController.ShowNotification("GREAT SAVE!", 2.5)
		end
	elseif t == "LevelUp" then
		UIController.ShowLevelUp(payload.NewLevel or (payload.OldLevel + 1))
	elseif t == "MatchResult" then
		-- Result screen with full stats
		local msg = payload.IsWinner and "VICTORY!"
			or (payload.IsDraw and "DRAW" or "DEFEAT")
		UIController.ShowMatchResult(msg, payload)
	elseif t == "TechniqueUnlocked" then
		-- Prefer the readable name; fall back to the id if the name is absent.
		UIController.ShowNotification(
			string.format("TECHNIQUE DISCOVERED — %s", payload.Name or payload.TechId or "?"), 3.5)
	elseif t == "ObjectiveComplete" then
		UIController.ShowNotification(
			string.format("OBJECTIVE COMPLETE — +%d XP  +%d coins",
				payload.RewardXP or 0, payload.RewardCoins or 0), 3.5)
	elseif t == "TrainingComplete" then
		UIController.ShowNotification(payload.Message or "TRAINING COMPLETE", 3)
	elseif t == "TrainingProgress" then
		UIController.ShowNotification(payload.Message or "TRAINING", 1.2)
	elseif t == "TrainingStart" then
		UIController.ShowNotification(payload.Message or "DRILL STARTED", 2.5)
	elseif t == "MasteryLevelUp" then
		UIController.ShowNotification(payload.Message or "MASTERY LEVEL UP", 2.5)
	elseif t == "Awakening" then
		UIController.ShowFullscreenMessage("MYTHIC AWAKENING", 2.5)
	elseif t == "AwakeningDenied" then
		UIController.ShowNotification(payload.Message or "Not enough Mythic Energy", 2)
	elseif t == "ShopNotEnoughCoins" then
		UIController.ShowNotification("Not enough coins", 2)
	end
end

--- Server pushes the player's daily / match objective state.
local function onObjectiveUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	UIController.ShowObjectives(payload)
end

--- Server pushes XP / level / overall after any reward grant.
local function onProgressUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	UIController.SetProgress(payload)
end

--- Server pushes the full level-up presentation payload.
local function onPlayerLevelUp(payload: table)
	if typeof(payload) ~= "table" then return end
	UIController.ShowLevelUpPanel(payload)
end

local function onBallStateUpdate(payload: table)
	if typeof(payload) ~= "table" then return end
	local hasPoss = (payload.Possessor == LocalPlayer.UserId)
	if _possessionDot then
		_possessionDot.Visible = hasPoss
	end
end

-- ─────────────────────────────────────────────
-- Update loop (cooldown overlays + charge bar)
-- ─────────────────────────────────────────────

local function onRenderStepped()
	updateCooldownDisplays()

	-- Charge indicator: tint the shoot button slightly when charging
	if _isMobile and _footballController then
		local ratio = _footballController.GetChargeRatio and _footballController.GetChargeRatio() or 0
		local btn   = _mobileButtons["Shoot"]
		if btn then
			btn.BackgroundColor3 = C.TEAM_B:Lerp(C.ACCENT, ratio)
		end
	end
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

function UIController.Init(inputCtrl: table?, footballCtrl: table?)
	_inputController   = inputCtrl
	_footballController = footballCtrl

	buildHUD()
	buildOverlayGui()
	buildMobileUI()

	if _isMobile then
		task.spawn(setupMobileInput)
	end

	-- Remote listeners
	Remotes.OnClientEvent(Constants.Remotes.ScoreUpdate,         onScoreUpdate)
	Remotes.OnClientEvent(Constants.Remotes.MatchStateUpdate,    onMatchStateUpdate)
	Remotes.OnClientEvent(Constants.Remotes.PlayerEnergyUpdate,  onPlayerEnergyUpdate)
	Remotes.OnClientEvent(Constants.Remotes.PlayerStaminaUpdate, onPlayerStaminaUpdate)
	Remotes.OnClientEvent(Constants.Remotes.AwakeningUpdate,     onAwakeningUpdate)
	Remotes.OnClientEvent(Constants.Remotes.GoalScored,          onGoalScored)
	Remotes.OnClientEvent(Constants.Remotes.MatchCountdown,      onMatchCountdown)
	Remotes.OnClientEvent(Constants.Remotes.NotifyPlayer,        onNotifyPlayer)
	Remotes.OnClientEvent(Constants.Remotes.BallStateUpdate,     onBallStateUpdate)
	Remotes.OnClientEvent(Constants.Remotes.ObjectiveUpdate,     onObjectiveUpdate)
	Remotes.OnClientEvent(Constants.Remotes.PlayerProgressUpdate, onProgressUpdate)
	Remotes.OnClientEvent(Constants.Remotes.PlayerLevelUp,       onPlayerLevelUp)

	RunService.RenderStepped:Connect(onRenderStepped)

	print(string.format("[UIController] Initialised. Mobile: %s", tostring(_isMobile)))
end

--- Set the display name for a technique slot.
function UIController.SetTechSlotName(slot: number, name: string)
	if _techLabels[slot] then
		-- Abbreviate to 6 chars for slot display
		_techLabels[slot].Text = string.sub(name, 1, 6)
	end
end

--- Start cooldown overlay animation for a slot.
function UIController.StartCooldownDisplay(slot: number, duration: number)
	_cooldownExpiry[slot] = tick() + duration
	_cooldownExpiry["duration" .. slot] = duration
end

--- Show a short floating notification.
function UIController.ShowNotification(message: string, duration: number?)
	if not _notifFrame then return end
	_notifLabel.Text    = message
	_notifFrame.Visible = true
	_notifFrame.BackgroundTransparency = 0.2
	_notifLabel.TextTransparency = 0

	task.delay(duration or 2.5, function()
		if _notifFrame then
			TweenService:Create(_notifFrame,
				TweenInfo.new(0.5),
				{ BackgroundTransparency = 1 }
			):Play()
			TweenService:Create(_notifLabel,
				TweenInfo.new(0.5),
				{ TextTransparency = 1 }
			):Play()
			task.delay(0.5, function()
				if _notifFrame then _notifFrame.Visible = false end
			end)
		end
	end)
end

--- Show a large fullscreen message (halftime, match end, etc.)
function UIController.ShowFullscreenMessage(message: string, duration: number?)
	if not _overlayGui then return end

	-- Clear previous
	for _, c in ipairs(_overlayGui:GetChildren()) do c:Destroy() end

	local frame = makeFrame(_overlayGui, "FullMsg",
		UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
		C.BG, 0.3
	)
	local lbl = makeLabel(frame, "Msg", message, 60, C.ACCENT)
	lbl.Font  = Enum.Font.GothamBlack

	task.delay(duration or 5, function()
		if frame and frame.Parent then
			TweenService:Create(frame,
				TweenInfo.new(0.5),
				{ BackgroundTransparency = 1 }
			):Play()
			TweenService:Create(lbl,
				TweenInfo.new(0.5),
				{ TextTransparency = 1 }
			):Play()
			task.delay(0.5, function()
				if frame and frame.Parent then frame:Destroy() end
			end)
		end
	end)
end

-- Helper for XP calculation (avoids circular dependency on PlayerService on client)
local function PlayerService_GetNextLevelXP(level: number): number
	local base = 100
	for i = 2, level do
		base = math.floor(base * 1.25)
	end
	return base
end

--- Show player card (lobby mode).
function UIController.ShowPlayerCard(profile: table)
	if not _playerCard then return end
	if _playerName then
		_playerName.Text = profile.DisplayName or "–"
	end
	if _playerLevel then
		_playerLevel.Text = string.format("Lv. %d", profile.Level or 1)
	end
	if _playerRank then
		_playerRank.Text = tostring(profile.Rank or "Rookie")
	end
	if _playerXPBar and _playerXPBar._fill then
		local xp = profile.XP or 0
		local nextLvlXP = PlayerService_GetNextLevelXP(profile.Level or 1)
		if nextLvlXP > 0 then
			local ratio = math.clamp(xp / nextLvlXP, 0, 1)
			_playerXPBar._fill.Size = UDim2.new(ratio, 0, 1, 0)
		end
	end
	_playerCard.Visible = true
end

--- Hide player card.
function UIController.HidePlayerCard()
	if _playerCard then
		_playerCard.Visible = false
	end
end

--- Render the objectives panel from the server's authoritative state.
--- Accepts the ObjectiveService payload: { Daily = {...}, Match = {...} }
--- where each entry is { Label, Progress, Target, Complete, RewardXP }.
function UIController.ShowObjectives(payload: table)
	if not _objectivesFrame then return end

	local daily = payload.Daily or {}
	local match = payload.Match or {}

	-- Nothing to show: hide rather than leave an empty panel on screen.
	if #daily == 0 and #match == 0 then
		_objectivesFrame.Visible = false
		return
	end
	_objectivesFrame.Visible = true

	local list = _objectivesFrame:FindFirstChild("ObjList")
	if not list then return end
	for _, c in ipairs(list:GetChildren()) do
		if c:IsA("TextLabel") or c:IsA("Frame") then c:Destroy() end
	end

	local row = 0
	local function addSection(heading: string, entries: {})
		if #entries == 0 then return end
		row += 1
		local head = makeLabel(list, "ObjHead" .. row, heading, 12, C.ACCENT,
			UDim2.new(1, -8, 0, 18), UDim2.new(0, 4, 0, 4 + (row - 1) * 22))
		head.TextXAlignment = Enum.TextXAlignment.Left
		head.Font = Enum.Font.GothamBold
		row += 1

		for _, obj in ipairs(entries) do
			local done = (obj.Complete == true) or (obj.Progress >= (obj.Target or 0))
			local color = done and Color3.fromRGB(120, 255, 130) or C.TEXT_DIM
			local mark  = done and "[x]" or "[ ]"
			local count = ""
			if (obj.Target or 0) > 1 then
				count = string.format("  %d/%d", obj.Progress or 0, obj.Target)
			end
			local lbl = makeLabel(list, "Obj" .. row,
				string.format("%s %s%s", mark, obj.Label or "?", count), 14, color,
				UDim2.new(1, -8, 0, 20), UDim2.new(0, 4, 0, 4 + (row - 1) * 22))
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			row += 1
		end
		row += 0.5
	end

	addSection("TODAY'S GOALS", daily)
	addSection("MATCH OBJECTIVES", match)
end

--- Update the persistent progression readout from PlayerProgressUpdate.
function UIController.SetProgress(payload: table)
	if typeof(payload) ~= "table" then return end

	if _playerLevel then
		_playerLevel.Text = string.format("Lv. %d   OVR %d", payload.Level or 1, payload.Overall or 0)
	end

	local xp = payload.XP or 0
	-- Prefer the server's own figure; fall back to the local formula so the bar
	-- still moves if a payload predates the XPNeeded field.
	local needed = payload.XPNeeded or PlayerService_GetNextLevelXP(payload.Level or 1)
	local ratio = (needed > 0) and math.clamp(xp / needed, 0, 1) or 0

	if _playerXPBar and _playerXPBar._fill then
		_playerXPBar._fill.Size = UDim2.new(ratio, 0, 1, 0)
	end
end

--- Full level-up panel: old -> new level, XP, overall, and unlocks.
function UIController.ShowLevelUpPanel(payload: table)
	if not _overlayGui then return end
	for _, c in ipairs(_overlayGui:GetChildren()) do c:Destroy() end

	local bg = makeFrame(_overlayGui, "LevelUpBG",
		UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
		C.BG, 0.55
	)

	local title = makeLabel(bg, "LUTitle", "LEVEL UP!", 54, C.ACCENT,
		UDim2.new(0, 520, 0, 64), UDim2.new(0.5, -260, 0, 150))
	title.Font = Enum.Font.GothamBlack

	local arrow = string.format("LEVEL %d  →  LEVEL %d",
		payload.OldLevel or 1, payload.NewLevel or 1)
	local sub = makeLabel(bg, "LUSub", arrow, 30, C.TEXT,
		UDim2.new(0, 520, 0, 40), UDim2.new(0.5, -260, 0, 220))
	sub.Font = Enum.Font.GothamBold

	local detail = string.format("OVERALL %d      %d / %d XP",
		payload.Overall or 0, payload.XP or 0, payload.XPNeeded or 0)
	makeLabel(bg, "LUDetail", detail, 18, C.TEXT_DIM,
		UDim2.new(0, 520, 0, 28), UDim2.new(0.5, -260, 0, 272))

	-- Unlocks, if this level granted any.
	local unlocks = payload.Unlocks or {}
	if #unlocks > 0 then
		local y = 312
		for _, label in ipairs(unlocks) do
			local lbl = makeLabel(bg, "LUUnlock" .. y, "+ " .. label, 18, C.TEAM_A,
				UDim2.new(0, 520, 0, 24), UDim2.new(0.5, -260, 0, y))
			lbl.Font = Enum.Font.Gotham
			y += 26
		end
	end

	-- Play the level-up sting if one has been authored into the place.
	local sfx = workspace:FindFirstChild("Sounds")
	if sfx then
		local lvl = sfx:FindFirstChild("LevelUp")
		if lvl and lvl:IsA("Sound") then lvl:Play() end
	end

	task.delay(4, function()
		if bg and bg.Parent then bg:Destroy() end
	end)
end

--- Hide objectives panel.
function UIController.HideObjectives()
	if _objectivesFrame then
		_objectivesFrame.Visible = false
	end
end

--- Show a level-up notification with animation.
function UIController.ShowLevelUp(newLevel: number)
	UIController.ShowFullscreenMessage("LEVEL UP!  Lv. " .. newLevel, 4)
	local sfx = workspace:FindFirstChild("Sounds")
	if sfx then
		local lvl = sfx:FindFirstChild("LevelUp")
		if lvl then lvl:Play() end
	end
end

--- Show match result screen with detailed stats.
function UIController.ShowMatchResult(title, payload)
	if not _overlayGui then return end
	for _, c in ipairs(_overlayGui:GetChildren()) do c:Destroy() end

	local bg = makeFrame(_overlayGui, "ResultBG",
		UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
		C.BG, 0.4
	)

	local winColor = payload.IsWinner and Color3.fromRGB(100, 255, 100)
		or (payload.IsDraw and C.ACCENT or C.TEAM_B)

	local titleLbl = makeLabel(bg, "ResultTitle", string.upper(title), 48, winColor,
		UDim2.new(0, 400, 0, 60), UDim2.new(0.5, -200, 0, 40))
	titleLbl.Font = Enum.Font.GothamBlack

	local stats = payload.Stats or {}
	local labels = {
		{ "PASSES COMPLETED",  stats.passes or 0 },
		{ "TACKLES WON",       stats.tacklesSuccess or 0 },
		{ "SHOTS",             stats.shots or 0 },
		{ "SAVES",             stats.saves or 0 },
		{ "GOALS",             payload.Goals or 0 },
		{ "ASSISTS",           payload.Assists or 0 },
	}

	for i, entry in ipairs(labels) do
		local y = 120 + (i - 1) * 30
		local nameLbl = makeLabel(bg, "Stat" .. i .. "_N", entry[1], 14, C.TEXT_DIM,
			UDim2.new(0, 260, 0, 24), UDim2.new(0.5, -330, 0, y))
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		local valLbl = makeLabel(bg, "Stat" .. i .. "_V", tostring(entry[2]), 14, C.TEXT,
			UDim2.new(0, 120, 0, 24), UDim2.new(0.5, 40, 0, y))
		valLbl.TextXAlignment = Enum.TextXAlignment.Right
	end

	local xpLbl = makeLabel(bg, "ResultXP", string.format("+%d XP", math.floor(payload.XP or 0)),
		18, C.ENERGY,
		UDim2.new(0, 180, 0, 28), UDim2.new(0.5, -90, 0, 340))
	xpLbl.Font = Enum.Font.GothamBold

	local coinLbl = makeLabel(bg, "ResultCoins", string.format("+%d COINS", math.floor(payload.Coins or 0)),
		18, C.ACCENT,
		UDim2.new(0, 180, 0, 28), UDim2.new(0.5, -90, 0, 380))
	coinLbl.Font = Enum.Font.GothamBold

	task.delay(8, function()
		if bg and bg.Parent then
			TweenService:Create(bg,
				TweenInfo.new(0.5),
				{ BackgroundTransparency = 1 }
			):Play()
			task.delay(0.5, function()
				if bg and bg.Parent then bg:Destroy() end
			end)
		end
	end)
end

--- Show a save effect animation.
function UIController.PlaySaveEffect(isLocal: boolean)
	if not isLocal then return end
	UIController.ShowNotification("SAVE!", 1.5)
	local sfx = workspace:FindFirstChild("Sounds")
	if sfx then
		local save = sfx:FindFirstChild("Save")
		if save then save:Play() end
	end
end

--- Show a tackle effect animation.
function UIController.PlayTackleEffect(isTackler: boolean)
	if not isTackler then return end
	UIController.ShowNotification("TACKLE!", 1.2)
	local sfx = workspace:FindFirstChild("Sounds")
	if sfx then
		local tkl = sfx:FindFirstChild("Tackle")
		if tkl then tkl:Play() end
	end
end

return UIController
