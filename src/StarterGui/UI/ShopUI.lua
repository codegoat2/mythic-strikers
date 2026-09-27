--[[
	MythicStrikers — ShopUI
	Full in-game shop screen, emote picker, leaderboard, notice board,
	match confirm dialog, and player stats panel.

	All screens are built programmatically — no pre-built Studio GUI required.

	SCREENS:
	  Shop      — browse items by shop type, buy, see balance
	  Emote     — pick and play an emote
	  Notice    — quest/event stub board
	  Leaderboard — top players list
	  MatchConfirm — "Join match?" dialog
	  PlayerStats  — own stats snapshot

	DESIGN:
	  Dark anime aesthetic matching HUD: #0D0D1A backgrounds, gold accents,
	  element-coloured tier badges, smooth tween open/close transitions.
--]]

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService        = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

local TWEEN_INFO = TweenInfo.new(0.12)
local CLOSE_TWEEN_INFO = TweenInfo.new(0.15)

-- ─── Responsive sizing ──────────────────────────────────────────────
-- Convert fixed pixel dimensions to scale-based with min/max constraints
-- so panels look good on both desktop and mobile (phone/tablet).

-- Returns the effective size as a scale-based UDim2, clamped to [min, max] pixels.
local function responsiveSize(desiredPx, minPx, maxPx, scaleRef)
	local basePx = desiredPx or 0
	local minV = minPx or basePx * 0.5
	local maxV = maxPx or basePx
	local s = scaleRef or 1
	local effective = math.clamp(basePx * s, minV, maxV)
	return effective
end

-- Get current screen dimensions for responsive layout
local function getScreenSize()
	local screenGui = PlayerGui:FindFirstChildOfClass("ScreenGui")
	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
	if viewport then
		return viewport.X, viewport.Y
	end
	return 1920, 1080
end

-- Compute a scale factor relative to a 1920x1080 reference (minimum 0.6 for very small screens)
local function getScaleFactor()
	local w, h = getScreenSize()
	local refW, refH = 1920, 1080
	-- Use the smaller dimension to determine scale
	local scale = math.min(w / refW, h / refH)
	return math.clamp(scale, 0.6, 1.4)
end

-- Build a scale-based UDim2 for a panel, with pixel bounds via UISizeConstraint
local function makePanelSize(desiredW, desiredH, minW, minH, maxW, maxH)
	local scale = getScaleFactor()
	local w = responsiveSize(desiredW, minW or desiredW * 0.6, maxW or desiredW * 1.2, scale)
	local h = responsiveSize(desiredH, minH or desiredH * 0.6, maxH or desiredH * 1.2, scale)
	return UDim2.new(0, w, 0, h)
end

-- Position: centered, but with offset compensation so it stays on screen
local function centerPanel(panelSize)
	local w, h = getScreenSize()
	local px, py = panelSize.X.Offset, panelSize.Y.Offset
	return UDim2.new(0.5, -px/2, 0.5, -py/2)
end

local function addSizeConstraint(parent, minW, minH, maxW, maxH)
	local sc = Instance.new("UISizeConstraint")
	if minW then sc.MinSize = Vector2.new(minW, minH or 0) end
	if maxW then sc.MaxSize = Vector2.new(maxW, maxH or math.huge) end
	sc.Parent = parent
	return sc
end

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes   = require(ReplicatedStorage.Remotes)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local ShopUI = {}

-- ─────────────────────────────────────────────
-- Colours
-- ─────────────────────────────────────────────
local C = {
	BG        = Color3.fromRGB(10,  10,  26),
	PANEL     = Color3.fromRGB(18,  18,  42),
	PANEL2    = Color3.fromRGB(24,  24,  54),
	ACCENT    = Color3.fromRGB(255, 215, 0),
	TEXT      = Color3.fromRGB(240, 240, 255),
	DIM       = Color3.fromRGB(140, 140, 165),
	GREEN     = Color3.fromRGB(80,  220, 80),
	RED       = Color3.fromRGB(255, 80,  80),
	BLUE      = Color3.fromRGB(0,   180, 255),
	PURPLE    = Color3.fromRGB(191, 95,  255),
	GOLD      = Color3.fromRGB(255, 215, 0),
}

local TIER_COLORS = {
	Common    = Color3.fromRGB(140, 140, 165),
	Rare      = Color3.fromRGB(0,   180, 255),
	Epic      = Color3.fromRGB(191, 95,  255),
	Legendary = Color3.fromRGB(255, 150, 0),
	Mythic    = Color3.fromRGB(255, 60,  180),
}

-- ─────────────────────────────────────────────
-- GUI helpers
-- ─────────────────────────────────────────────

local _gui: ScreenGui
local _root: Frame     -- main backdrop

local function makeFrame(parent, name, size, pos, color, trans)
	local f = Instance.new("Frame")
	f.Name = name; f.Size = size; f.Position = pos
	f.BackgroundColor3 = color or C.PANEL
	f.BackgroundTransparency = trans or 0
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function makeLabel(parent, name, text, ts, color, size, pos, font)
	local l = Instance.new("TextLabel")
	l.Name = name; l.Text = text
	l.TextSize = ts or 16; l.TextColor3 = color or C.TEXT
	l.Font = font or Enum.Font.GothamBold
	l.Size = size or UDim2.new(1,0,1,0)
	l.Position = pos or UDim2.new(0,0,0,0)
	l.BackgroundTransparency = 1
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.TextWrapped = true
	l.Parent = parent
	return l
end

local function makeButton(parent, name, text, size, pos, bgColor, textColor, callback)
	local btn = Instance.new("TextButton")
	btn.Name = name; btn.Text = text
	btn.Size = size; btn.Position = pos
	btn.BackgroundColor3 = bgColor or C.ACCENT
	btn.TextColor3 = textColor or C.BG
	btn.TextSize = 16; btn.Font = Enum.Font.GothamBold
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn
	if callback then
		btn.MouseButton1Click:Connect(callback)
	end
	return btn
end

local function makeScrollFrame(parent, name, size, pos)
	local sf = Instance.new("ScrollingFrame")
	sf.Name = name; sf.Size = size; sf.Position = pos
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.ScrollBarThickness = 6
	sf.ScrollBarImageColor3 = C.ACCENT
	sf.CanvasSize = UDim2.new(0,0,0,0)
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.Parent = sf
	return sf
end

local function corner(parent, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 10)
	c.Parent = parent
	return c
end

local function sep(parent, yPos)
	local l = makeFrame(parent, "Sep", UDim2.new(1,-20,0,1), UDim2.new(0,10,0,yPos), C.DIM, 0.6)
	return l
end

-- ─────────────────────────────────────────────
-- Build root GUI
-- ─────────────────────────────────────────────

local function buildRoot()
	_gui = Instance.new("ScreenGui")
	_gui.Name = "ShopUI"
	_gui.ResetOnSpawn = false
	_gui.DisplayOrder = 20
	_gui.Enabled = false
	_gui.Parent = PlayerGui

	-- Dark backdrop
	_root = makeFrame(_gui, "Root",
		UDim2.new(1,0,1,0), UDim2.new(0,0,0,0),
		C.BG, 0.35)
	_root.Visible = false
end

-- ─────────────────────────────────────────────
-- Panel lifecycle helpers
-- ─────────────────────────────────────────────

local function clearRoot()
	for _, c in ipairs(_root:GetChildren()) do c:Destroy() end
end

local function openPanel(buildFn: () -> ())
	clearRoot()
	_gui.Enabled = true
	_root.Visible = true
	_root.BackgroundTransparency = 1
	buildFn()
	TweenService:Create(_root, TweenInfo.new(0.18), { BackgroundTransparency = 0.35 }):Play()
end

local function closePanel()
	TweenService:Create(_root, TweenInfo.new(0.15), { BackgroundTransparency = 1 }):Play()
	task.delay(0.15, function()
		clearRoot()
		_root.Visible = false
		_gui.Enabled  = false
	end)
end

-- ─────────────────────────────────────────────
-- Shared close button
-- ─────────────────────────────────────────────

local function addCloseBtn(panel: Frame)
	makeButton(panel, "CloseBtn", "✕",
		UDim2.new(0,36,0,36), UDim2.new(1,-44,0,8),
		C.RED, C.TEXT, closePanel)
end

-- ─────────────────────────────────────────────
-- State: catalogue data received from server
-- ─────────────────────────────────────────────
local _currentCatalogue: table? = nil
local _currentShopType: string? = nil
local _coinBalance = 0
local _currentEmoteTrack: AnimationTrack? = nil

-- ─────────────────────────────────────────────
-- SHOP SCREEN
-- ─────────────────────────────────────────────

local SHOP_TITLES = {
	TechniqueShop = "⚡ TECHNIQUE SHOP",
	GearShop      = "👟 GEAR SHOP",
	AuraShop      = "✨ AURA SHOP",
	LockerRoom    = "🎒 LOCKER ROOM",
}

local function buildItemCard(parent: Instance, item: table, onBuy: (table) -> ())
	-- Card height scales with screen — minimum 80px for mobile
	local cardHeight = math.max(90, 100 * getScaleFactor())
	local card = makeFrame(parent, "Card_"..item.Id,
		UDim2.new(1,-16,0,cardHeight), UDim2.new(0,0,0,0),
		C.PANEL2, 0)
	corner(card, 8)

	-- Tier badge
	local tierColor = TIER_COLORS[item.Tier] or C.DIM
	local badge = makeFrame(card, "Tier",
		UDim2.new(0,70,0,20), UDim2.new(0,8,0,8),
		tierColor, 0)
	corner(badge, 4)
	makeLabel(badge, "TierLbl", item.Tier, 11, C.BG, UDim2.new(1,0,1,0))

	-- Item name
	local nameSize = getScaleFactor() < 0.8 and 15 or 17
	makeLabel(card, "Name", item.Name, nameSize, C.TEXT,
		UDim2.new(0.6,0,0,28), UDim2.new(0,8,0,26),
		Enum.Font.GothamBold)

	-- Description
	local desc = makeLabel(card, "Desc", item.Description, 12, C.DIM,
		UDim2.new(0.65,0,0,26), UDim2.new(0,8,0,54))
	desc.TextXAlignment = Enum.TextXAlignment.Left

	-- Price / status button (right side)
	if item.Owned then
		local owned = makeFrame(card, "OwnedBadge",
			UDim2.new(0,90,0,32), UDim2.new(1,-98,0.5,-16),
			C.GREEN, 0)
		corner(owned, 8)
		makeLabel(owned, "Lbl", "✔ OWNED", 13, C.BG, UDim2.new(1,0,1,0))
	else
		local price = string.format("%d 🪙", item.Price)
		local btnColor = item.CanAfford and C.ACCENT or C.DIM
		local btnSize = makePanelSize(100, 36, 80, 32, 120, 40)
		local btnPos = UDim2.new(1, -btnSize.X.Offset - 8, 0.5, -btnSize.Y.Offset/2, 0, 0)
		local btn = makeButton(card, "BuyBtn", price,
			btnSize, btnPos,
			btnColor, C.BG,
			item.CanAfford and function()
				onBuy(item)
			end or nil)
		if not item.CanAfford then
			-- Dim + tooltip
			btn.Text = price .. "\n(can't afford)"
			btn.TextSize = 11
		end
	end

	return card
end

local function buildShopScreen(shopType: string, catalogue: table, balance: number)
	-- Main panel — responsive size
	local panelSize = makePanelSize(640, 520, 320, 400, 720, 600)
	local panel = makeFrame(_root, "ShopPanel",
		panelSize,
		centerPanel(panelSize),
		C.PANEL, 0)
	corner(panel, 14)
	addSizeConstraint(panel, 300, 360, 720, 600)

	-- Header
	local header = makeFrame(panel, "Header",
		UDim2.new(1,0,0,56), UDim2.new(0,0,0,0),
		C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", SHOP_TITLES[shopType] or shopType, 22, C.ACCENT,
		UDim2.new(0.7,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)

	-- Coin balance
	makeLabel(header, "Balance",
		string.format("🪙 %d", balance), 18, C.GOLD,
		UDim2.new(0,140,0,40), UDim2.new(0.65,0,0,8))
	addCloseBtn(header)
	sep(panel, 56)

	-- Scrollable item list
	local scroll = makeScrollFrame(panel, "ItemList",
		UDim2.new(1,-16,1,-72), UDim2.new(0,8,0,64))

	local function onBuy(item: table)
		-- Optimistic disable — server will confirm
		Remotes.FireServer(Constants.Remotes.ShopPurchase, {
			ItemId = item.Id,
		})
	end

	if #catalogue == 0 then
		makeLabel(scroll, "Empty", "No items available.", 16, C.DIM)
	else
		for _, item in ipairs(catalogue) do
			buildItemCard(scroll, item, onBuy)
		end
	end
end

-- ─────────────────────────────────────────────
-- EMOTE PICKER
-- ─────────────────────────────────────────────

local EMOTES = {
	{ Id="EMOTE_WAVE",      Name="Wave",        Desc="Friendly wave." },
	{ Id="EMOTE_CELEBRATE", Name="Celebrate",   Desc="Arms up victory." },
	{ Id="EMOTE_TAUNT",     Name="Taunt",       Desc="Slow clap taunt." },
	{ Id="EMOTE_DANCE",     Name="Dance",       Desc="Football victory dance." },
	{ Id="EMOTE_POINT",     Name="Point",       Desc="Point at the goal." },
	{ Id="EMOTE_BOW",       Name="Bow",         Desc="Respectful bow." },
}

local EMOTE_ANIMATIONS = {
	EMOTE_WAVE      = 507770239,
	EMOTE_CELEBRATE = 507770677,
	EMOTE_TAUNT     = 507770655,
	EMOTE_DANCE     = 507771019,
	EMOTE_POINT     = 507770453,
	EMOTE_BOW       = 507770979,
}

local function playEmoteAnimation(emoteId: string)
	local char = LocalPlayer.Character
	if not char then return end
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	if not hum then return end

	if _currentEmoteTrack then
		_currentEmoteTrack:Stop()
		_currentEmoteTrack = nil
	end

	local animId = EMOTE_ANIMATIONS[emoteId]
	if not animId then return end

	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. tostring(animId)

	local animator = hum:FindFirstChildWhichIsA("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end

	local track = animator:LoadAnimation(anim)
	track:Play()
	_currentEmoteTrack = track

	game.Debris:AddItem(anim, track.Length + 1)
end

local function buildEmotePicker()
	local panelSize = makePanelSize(440, 360, 320, 340, 500, 420)
	local panel = makeFrame(_root, "EmotePanel",
		panelSize,
		centerPanel(panelSize),
		C.PANEL, 0)
	corner(panel, 14)

	local header = makeFrame(panel, "Header", UDim2.new(1,0,0,50), UDim2.new(0,0,0,0), C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", "💃 EMOTES", 20, C.ACCENT, UDim2.new(0.8,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)
	addCloseBtn(header)
	sep(panel, 50)

	local grid = makeFrame(panel, "Grid",
		UDim2.new(1,-16,1,-62), UDim2.new(0,8,0,58),
		Color3.new(0,0,0), 1)
	local layout = Instance.new("UIGridLayout")
	-- Responsive cell size — minimum 100x70 for touch on mobile
	local cellSize = math.max(100, 120 * getScaleFactor())
	layout.CellSize    = UDim2.new(0,cellSize,0,cellSize)
	layout.CellPadding = UDim2.new(0,8,0,8)
	layout.Parent      = grid

	for _, emote in ipairs(EMOTES) do
		local cell = makeFrame(grid, emote.Id,
			UDim2.new(0,cellSize,0,cellSize), UDim2.new(0,0,0,0), C.PANEL2, 0)
		corner(cell, 8)
		makeLabel(cell, "Name", emote.Name, 14, C.TEXT,
			UDim2.new(1,0,0.5,0), UDim2.new(0,0,0,0))
		makeLabel(cell, "Desc", emote.Desc, 10, C.DIM,
			UDim2.new(1,0,0.5,0), UDim2.new(0,0.5,0,0))

				local btn = Instance.new("TextButton")
		btn.Size   = UDim2.new(1,0,1,0); btn.Position = UDim2.new(0,0,0,0)
		btn.BackgroundTransparency = 1; btn.Text = ""; btn.Parent = cell
		btn.MouseButton1Click:Connect(function()
			playEmoteAnimation(emote.Id)
			Remotes.FireServer(Constants.Remotes.RequestCelebration, { EmoteId = emote.Id })
			closePanel()
		end)
	end
end

-- ─────────────────────────────────────────────
-- NOTICE BOARD (stub — Phase 7 fills with quests)
-- ─────────────────────────────────────────────

local function buildNoticeBoard()
	local panelSize = makePanelSize(500, 400, 340, 340, 560, 440)
	local panel = makeFrame(_root, "NoticePanel",
		panelSize,
		centerPanel(panelSize),
		C.PANEL, 0)
	corner(panel, 14)

	local header = makeFrame(panel, "Header", UDim2.new(1,0,0,50), UDim2.new(0,0,0,0), C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", "📋 NOTICE BOARD", 20, C.BLUE, UDim2.new(0.8,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)
	addCloseBtn(header)
	sep(panel, 50)

	local notices = {
		{ icon="⚽", text="Play 5 matches to unlock Advanced techniques!", color=C.ACCENT },
		{ icon="⚡", text="Score 10 goals to unlock the Meteor Spiral technique.", color=C.BLUE },
		{ icon="🏆", text="Reach Gold rank to unlock the Void Cannon ultimate.", color=C.GOLD },
		{ icon="🎁", text="Daily login bonus: +50 coins every day!", color=C.GREEN },
		{ icon="🔥", text="New: Combination techniques unlocked at Level 10.", color=C.PURPLE },
	}

	local scroll = makeScrollFrame(panel, "Scroll",
		UDim2.new(1,-16,1,-62), UDim2.new(0,8,0,58))

	for _, n in ipairs(notices) do
		local row = makeFrame(scroll, "Notice", UDim2.new(1,-8,0,56), UDim2.new(0,0,0,0), C.PANEL2, 0)
		corner(row, 6)
		makeLabel(row, "Icon", n.icon, 24, n.color, UDim2.new(0,50,1,0), UDim2.new(0,4,0,0))
		local lbl = makeLabel(row, "Text", n.text, 14, C.TEXT,
			UDim2.new(1,-60,1,0), UDim2.new(0,54,0,0))
		lbl.TextXAlignment = Enum.TextXAlignment.Left
	end
end

-- ─────────────────────────────────────────────
-- LEADERBOARD
-- ─────────────────────────────────────────────

local function buildLeaderboard()
	local panel = makeFrame(_root, "LBPanel",
		UDim2.new(0,480,0,460),
		UDim2.new(0.5,-240,0.5,-230),
		C.PANEL, 0)
	corner(panel, 14)

	local header = makeFrame(panel, "Header", UDim2.new(1,0,0,50), UDim2.new(0,0,0,0), C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", "🏆 TOP STRIKERS", 20, C.GOLD,
		UDim2.new(0.8,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)
	addCloseBtn(header)
	sep(panel, 50)

	-- Column headers
	local colHeader = makeFrame(panel, "ColHdr", UDim2.new(1,-16,0,28), UDim2.new(0,8,0,54), C.BG, 0)
	makeLabel(colHeader, "R", "#",    13, C.DIM, UDim2.new(0,30,1,0),  UDim2.new(0,0,0,0))
	makeLabel(colHeader, "N", "Player", 13, C.DIM, UDim2.new(0.4,0,1,0), UDim2.new(0,32,0,0))
	makeLabel(colHeader, "G", "Goals",  13, C.DIM, UDim2.new(0.2,0,1,0), UDim2.new(0.55,0,0,0))
	makeLabel(colHeader, "K", "Rank",   13, C.DIM, UDim2.new(0.25,0,1,0),UDim2.new(0.75,0,0,0))
	sep(panel, 84)

	local scroll = makeScrollFrame(panel, "Scroll",
		UDim2.new(1,-16,1,-96), UDim2.new(0,8,0,90))

	-- Populate with current server players (real data; full leaderboard = Phase 7 DataStore query)
	local playerList = Players:GetPlayers()
	table.sort(playerList, function(a,b)
		-- Sort by display name for now — Phase 7 sorts by rating
		return a.DisplayName < b.DisplayName
	end)

	local rankColors = {
		Mythic="Bright pink", Diamond="Cyan", Platinum="White",
		Gold="Bright yellow", Silver="Medium stone grey", Bronze="Reddish brown", Rookie="Sand green"
	}

	for i, player in ipairs(playerList) do
		local row = makeFrame(scroll, "Row_"..i, UDim2.new(1,-8,0,40), UDim2.new(0,0,0,0),
			i % 2 == 0 and C.PANEL2 or C.PANEL, 0)
		corner(row, 4)

		makeLabel(row, "Rank", tostring(i), 14, C.ACCENT, UDim2.new(0,30,1,0), UDim2.new(0,4,0,0))
		makeLabel(row, "Name", player.DisplayName, 14, C.TEXT,
			UDim2.new(0.4,0,1,0), UDim2.new(0,36,0,0)):ClearAllChildren()
		local nl = makeLabel(row, "Name", player.DisplayName, 14, C.TEXT,
			UDim2.new(0.4,0,1,0), UDim2.new(0,36,0,0))
		nl.TextXAlignment = Enum.TextXAlignment.Left
		makeLabel(row, "Goals", "—", 14, C.BLUE, UDim2.new(0.2,0,1,0), UDim2.new(0.55,0,0,0))
		makeLabel(row, "RankName","Rookie",14,C.GREEN,UDim2.new(0.25,0,1,0),UDim2.new(0.75,0,0,0))
	end

	if #playerList == 0 then
		makeLabel(scroll, "Empty", "No players yet.", 14, C.DIM)
	end
end

-- ─────────────────────────────────────────────
-- MATCH CONFIRM
-- ─────────────────────────────────────────────

local function buildMatchConfirm()
	local panel = makeFrame(_root, "MatchConfirm",
		UDim2.new(0,380,0,220),
		UDim2.new(0.5,-190,0.5,-110),
		C.PANEL, 0)
	corner(panel, 14)

	makeLabel(panel, "Title", "⚡ ENTER MATCH?", 24, C.ACCENT,
		UDim2.new(1,0,0,60), UDim2.new(0,0,0,10), Enum.Font.GothamBlack)
	makeLabel(panel, "Sub", "You will be teleported to the\nMatch Arena.", 14, C.DIM,
		UDim2.new(1,-40,0,50), UDim2.new(0,20,0,72))

	sep(panel, 132)

	makeButton(panel, "Confirm", "✔ JOIN MATCH",
		UDim2.new(0,160,0,42), UDim2.new(0,20,0,148),
		C.GREEN, C.BG, function()
			closePanel()
			-- Notify server to add player to match queue
			Remotes.FireServer(Constants.Remotes.PlayerInput, {
				Action    = "JoinQueue",
				Timestamp = tick(),
			})
		end)

	makeButton(panel, "Cancel", "✕ CANCEL",
		UDim2.new(0,160,0,42), UDim2.new(1,-180,0,148),
		C.RED, C.TEXT, closePanel)
end

-- ─────────────────────────────────────────────
-- PLAYER STATS
-- ─────────────────────────────────────────────

local function buildPlayerStats()
	local panel = makeFrame(_root, "StatsPanel",
		UDim2.new(0,440,0,400),
		UDim2.new(0.5,-220,0.5,-200),
		C.PANEL, 0)
	corner(panel, 14)

	local header = makeFrame(panel, "Header", UDim2.new(1,0,0,50), UDim2.new(0,0,0,0), C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", "📊 YOUR STATS", 20, C.BLUE,
		UDim2.new(0.8,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)
	addCloseBtn(header)
	sep(panel, 50)

	-- Fetch from server
	task.spawn(function()
		local ok, profile = pcall(function()
			return Remotes.InvokeServer("GetPlayerProfile")
		end)
		if not ok or not profile then
			makeLabel(panel, "Error", "Could not load profile.", 16, C.DIM,
				UDim2.new(1,0,1,-60), UDim2.new(0,0,0,60))
			return
		end

		local stats = {
			{ label="Level",         value=tostring(profile.Level or 1) },
			{ label="Rank",          value=profile.Rank or "Rookie" },
			{ label="Rating",        value=tostring(profile.RankedRating or 0) },
			{ label="Coins",         value=string.format("🪙 %d", profile.Coins or 0) },
			{ label="Goals",         value=tostring(profile.Goals or 0) },
			{ label="Assists",       value=tostring(profile.Assists or 0) },
			{ label="Saves",         value=tostring(profile.Saves or 0) },
			{ label="Tackles",       value=tostring(profile.Tackles or 0) },
			{ label="Wins",          value=tostring(profile.Wins or 0) },
			{ label="Losses",        value=tostring(profile.Losses or 0) },
			{ label="Matches",       value=tostring(profile.MatchesPlayed or 0) },
		}

		local scroll = makeScrollFrame(panel, "Scroll",
			UDim2.new(1,-16,1,-62), UDim2.new(0,8,0,58))

		for i, stat in ipairs(stats) do
			local row = makeFrame(scroll, "Stat_"..i, UDim2.new(1,-8,0,36), UDim2.new(0,0,0,0),
				i%2==0 and C.PANEL2 or C.PANEL, 0)
			corner(row, 4)
			local lbl = makeLabel(row, "Label", stat.label, 14, C.DIM,
				UDim2.new(0.5,0,1,0), UDim2.new(0,8,0,0))
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			makeLabel(row, "Value", stat.value, 14, C.TEXT,
				UDim2.new(0.5,0,1,0), UDim2.new(0.5,0,0,0))
		end
	end)
end

local function buildSettings()
	local panel = makeFrame(_root, "SettingsPanel",
		UDim2.new(0,440,0,360),
		UDim2.new(0.5,-220,0.5,-180),
		C.PANEL, 0)
	corner(panel, 14)

	local header = makeFrame(panel, "Header", UDim2.new(1,0,0,50), UDim2.new(0,0,0,0), C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", "⚙️ SETTINGS", 20, C.ACCENT, UDim2.new(0.8,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)
	addCloseBtn(header)
	sep(panel, 50)

	local rows = {
		{ label="Music Volume", value="80%", key="Music" },
		{ label="SFX Volume", value="100%", key="SFX" },
		{ label="Camera Sensitivity", value="50%", key="Camera" },
		{ label="Show Player Names", value="On", key="Names" },
	}
	local y = 58
	for _, r in ipairs(rows) do
		local row = makeFrame(panel, r.key .. "Row", UDim2.new(1,-16,0,36), UDim2.new(0,8,0,y), C.PANEL2, 0)
		corner(row, 6)
		makeLabel(row, "Lbl", r.label, 14, C.TEXT, UDim2.new(0.6,0,1,0), UDim2.new(0,8,0,0)).TextXAlignment = Enum.TextXAlignment.Left
		makeLabel(row, "Val", r.value, 14, C.DIM, UDim2.new(0.4,0,1,0), UDim2.new(0.6,0,0,0))
		y += 42
	end
end

local function buildInventory()
	local panel = makeFrame(_root, "InventoryPanel",
		UDim2.new(0,480,0,400),
		UDim2.new(0.5,-240,0.5,-200),
		C.PANEL, 0)
	corner(panel, 14)

	local header = makeFrame(panel, "Header", UDim2.new(1,0,0,50), UDim2.new(0,0,0,0), C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", "🎒 INVENTORY", 20, C.ACCENT, UDim2.new(0.8,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)
	addCloseBtn(header)
	sep(panel, 50)

	local grid = makeFrame(panel, "Grid", UDim2.new(1,-16,1,-62), UDim2.new(0,8,0,58), C.BG, 0.4)
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0, 72, 0, 72)
	layout.CellPadding = UDim2.new(0, 8, 0, 8)
	layout.Parent = grid

	local items = {
		{ name="Basic Boots", tier="Common", owned=true },
		{ name="Swift Gloves", tier="Rare", owned=true },
		{ name="Mystic Headband", tier="Epic", owned=false },
		{ name="Phoenix Kit", tier="Legendary", owned=false },
		{ name="Aura Charm", tier="Mythic", owned=false },
	}
	for _, item in ipairs(items) do
		local cell = makeFrame(grid, item.name, UDim2.new(0,72,0,72), UDim2.new(0,0,0,0), C.PANEL2, 0)
		corner(cell, 8)
		local tierColor = TIER_COLORS[item.tier] or C.DIM
		makeLabel(cell, "Name", item.name, 12, C.TEXT, UDim2.new(1,0,0.6,0), UDim2.new(0,0,0,0))
		makeLabel(cell, "Tier", item.tier, 11, tierColor, UDim2.new(1,0,0.4,0), UDim2.new(0,0,0,0))
		if not item.owned then
			local lock = makeFrame(cell, "Lock", UDim2.new(1,0,1,0), UDim2.new(0,0,0,0), Color3.new(0,0,0), 0.5)
			corner(lock, 8)
			makeLabel(lock, "LockIcon", "🔒", 20, C.TEXT, UDim2.new(1,0,1,0), UDim2.new(0,0,0,0))
		end
	end
end

local function buildSkills()
	local panel = makeFrame(_root, "SkillsPanel",
		UDim2.new(0,500,0,420),
		UDim2.new(0.5,-250,0.5,-210),
		C.PANEL, 0)
	corner(panel, 14)

	local header = makeFrame(panel, "Header", UDim2.new(1,0,0,50), UDim2.new(0,0,0,0), C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", "⚡ SKILLS", 20, C.ACCENT, UDim2.new(0.8,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)
	addCloseBtn(header)
	sep(panel, 50)

	local skills = {
		{ name="Meteor Spiral", element="Fire", unlocked=true, level=3 },
		{ name="Void Cannon", element="Shadow", unlocked=true, level=1 },
		{ name=" Gale Force", element="Wind", unlocked=false, level=0 },
		{ name="Titan Stomp", element="Earth", unlocked=false, level=0 },
	}
	local grid = makeFrame(panel, "Grid", UDim2.new(1,-16,1,-62), UDim2.new(0,8,0,58), C.BG, 0.4)
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0, 100, 0, 100)
	layout.CellPadding = UDim2.new(0, 8, 0, 8)
	layout.Parent = grid

	for _, s in ipairs(skills) do
		local cell = makeFrame(grid, s.name, UDim2.new(0,100,0,100), UDim2.new(0,0,0,0), C.PANEL2, 0)
		corner(cell, 10)
		local icon = makeLabel(cell, "Icon", s.element:sub(1,1), 32, C.ACCENT, UDim2.new(1,0,0.6,0), UDim2.new(0,0,0,0))
		icon.TextXAlignment = Enum.TextXAlignment.Center
		makeLabel(cell, "Name", s.name, 12, C.TEXT, UDim2.new(1,0,0.4,0), UDim2.new(0,0,0,0)).TextXAlignment = Enum.TextXAlignment.Center
		if not s.unlocked then
			local lock = makeFrame(cell, "Lock", UDim2.new(1,0,1,0), UDim2.new(0,0,0,0), Color3.new(0,0,0), 0.6)
			corner(lock, 10)
			makeLabel(lock, "LockIcon", "🔒", 24, C.TEXT, UDim2.new(1,0,1,0), UDim2.new(0,0,0,0))
		end
	end
end

local function buildMastery()
	local panel = makeFrame(_root, "MasteryPanel",
		UDim2.new(0,500,0,420),
		UDim2.new(0.5,-250,0.5,-210),
		C.PANEL, 0)
	corner(panel, 14)

	local header = makeFrame(panel, "Header", UDim2.new(1,0,0,50), UDim2.new(0,0,0,0), C.BG, 0)
	corner(header, 14)
	makeLabel(header, "Title", "🌟 MASTERY", 20, C.ACCENT, UDim2.new(0.8,0,1,0), UDim2.new(0,12,0,0), Enum.Font.GothamBlack)
	addCloseBtn(header)
	sep(panel, 50)

	local masteries = {
		{ name="Dribbling", xp=120, max=200 },
		{ name="Shooting", xp=85, max=150 },
		{ name="Tackling", xp=200, max=200 },
		{ name="Goalkeeping", xp=45, max=100 },
		{ name="Passing", xp=160, max=200 },
	}
	local scroll = makeScrollFrame(panel, "Scroll", UDim2.new(1,-16,1,-62), UDim2.new(0,8,0,58))
	local y = 0
	for _, m in ipairs(masteries) do
		local row = makeFrame(scroll, m.name, UDim2.new(1,-8,0,56), UDim2.new(0,0,0,y), C.PANEL2, 0)
		corner(row, 6)
		makeLabel(row, "Name", m.name, 14, C.TEXT, UDim2.new(0.5,0,1,0), UDim2.new(0,8,0,0)).TextXAlignment = Enum.TextXAlignment.Left
		local pct = math.clamp(m.xp / m.max, 0, 1)
		local barBg = makeFrame(row, "BarBg", UDim2.new(0.5,0,0,8), UDim2.new(0.5,0,0.5,0), C.BG, 0.5)
		corner(barBg, 4)
		local barFill = makeFrame(barBg, "Fill", UDim2.new(pct,0,1,0), UDim2.new(0,0,0,0), C.ACCENT, 0.8)
		corner(barFill, 4)
		makeLabel(row, "XP", string.format("%d/%d", m.xp, m.max), 12, C.DIM, UDim2.new(0.5,0,1,0), UDim2.new(0.5,0,0,0))
		y += 62
	end
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

function ShopUI.Init()
	buildRoot()
	print("[ShopUI] Initialised.")
end

function ShopUI.Open(shopType: string)
	_currentShopType = shopType
	-- The actual catalogue arrives via ReceiveCatalogue after server responds.
	-- Show a loading state immediately.
	openPanel(function()
		local panel = makeFrame(_root, "ShopPanel",
			UDim2.new(0,640,0,520),
			UDim2.new(0.5,-320,0.5,-260),
			C.PANEL, 0)
		corner(panel, 14)
		addCloseBtn(panel)
		makeLabel(panel, "Loading", "Loading shop...", 20, C.DIM)
	end)
end

function ShopUI.ReceiveCatalogue(payload: table)
	_currentCatalogue = payload.Items or {}
	_coinBalance      = payload.Balance or 0
	if not _gui.Enabled then return end   -- panel was closed
	openPanel(function()
		buildShopScreen(payload.ShopType or _currentShopType or "Shop",
			_currentCatalogue, _coinBalance)
	end)
end

function ShopUI.HandlePurchaseResult(payload: table)
	if not payload.Success then return end
	_coinBalance = payload.NewBalance or _coinBalance
	-- Refresh shop with updated balance/ownership
	if _currentCatalogue and _currentShopType then
		-- Re-mark bought item as owned
		for _, item in ipairs(_currentCatalogue) do
			if item.Id == payload.ItemId then
				item.Owned     = true
				item.CanAfford = false
			end
		end
		openPanel(function()
			buildShopScreen(_currentShopType, _currentCatalogue, _coinBalance)
		end)
	end
end

function ShopUI.OpenEmotePicker()
	openPanel(buildEmotePicker)
end

function ShopUI.OpenNoticeBoard()
	openPanel(buildNoticeBoard)
end

function ShopUI.OpenLeaderboard()
	openPanel(buildLeaderboard)
end

function ShopUI.OpenMatchConfirm()
	openPanel(buildMatchConfirm)
end

function ShopUI.OpenPlayerStats()
	openPanel(buildPlayerStats)
end

function ShopUI.OpenInventory()
	openPanel(buildInventory)
end

function ShopUI.OpenSettings()
	openPanel(buildSettings)
end

function ShopUI.OpenSkills()
	if not _gui then ShopUI.Init() end
	openPanel(buildSkills)
end

function ShopUI.OpenMastery()
	if not _gui then ShopUI.Init() end
	openPanel(buildMastery)
end

function ShopUI.Close()
	closePanel()
end

return ShopUI
