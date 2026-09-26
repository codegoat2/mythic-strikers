--[[
	MythicStrikers — LobbyBuilder
	Procedurally constructs the explorable lobby world.

	LAYOUT  (all coordinates relative to LOBBY_ORIGIN = 0, 0, 600)
	The lobby sits behind the stadium on the +Z side.
	It is divided into zones arranged around a central plaza:

	         [Training Grounds]
	               ↑
	  [House Row]  [PLAZA]  [House Row]
	               ↓
	      [Market Street / Shops]
	               ↓
	        [Lobby Spawn Ring]

	BUILDINGS:
	  • 6 Player Houses  — enterable, with furniture, personalisation boards
	  • Technique Shop   — buy/unlock technique cosmetics
	  • Gear Shop        — boots, gloves, ball skins
	  • Aura Shop        — awakening aura effects
	  • Trophy Room      — display case, leaderboard boards
	  • Locker Room      — change loadout, equip techniques
	  • Training Dome    — free-kick / dribble practice area
	  • Canteen          — social hangout, emote zone
	  • Notice Board     — quests / events (Phase 7)

	INTERACTION:
	  Every interactive object has a ProximityPrompt and an
	  "InteractType" StringValue child so LobbyController knows
	  what to open when triggered.

	OPTIMISATION:
	  • All static parts are Anchored.
	  • No physics on decorative items.
	  • Terrain is flat — no complex terrain mesh.
	  • Part count kept reasonable via union-style large blocks.
--]]

local RunService = game:GetService("RunService")
assert(RunService:IsServer(), "LobbyBuilder must run on the server.")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants         = require(ReplicatedStorage.Shared.Config.Constants)

-- ─────────────────────────────────────────────
-- Origin
-- ─────────────────────────────────────────────
local O = Constants.LOBBY_ORIGIN   -- Vector3(0, 0, 600)

-- ─────────────────────────────────────────────
-- Model container
-- ─────────────────────────────────────────────
local lobbyModel: Model

-- ─────────────────────────────────────────────
-- Colour palette
-- ─────────────────────────────────────────────
local COL = {
	GROUND      = BrickColor.new("Sand green"),
	PAVEMENT    = BrickColor.new("Light stone grey"),
	WALL_A      = BrickColor.new("Brick yellow"),
	WALL_B      = BrickColor.new("Medium stone grey"),
	WALL_C      = BrickColor.new("Sand red"),
	WALL_DARK   = BrickColor.new("Dark stone grey"),
	ROOF_A      = BrickColor.new("Brown"),
	ROOF_B      = BrickColor.new("Dark orange"),
	ROOF_C      = BrickColor.new("Dark blue"),
	DOOR        = BrickColor.new("Brown"),
	WINDOW      = BrickColor.new("Cyan"),
	NEON_BLUE   = BrickColor.new("Cyan"),
	NEON_GOLD   = BrickColor.new("Bright yellow"),
	NEON_PURPLE = BrickColor.new("Magenta"),
	NEON_GREEN  = BrickColor.new("Lime green"),
	WOOD        = BrickColor.new("Brown"),
	STONE       = BrickColor.new("Medium stone grey"),
	WHITE       = BrickColor.new("White"),
	BLACK       = BrickColor.new("Black"),
	GRASS       = BrickColor.new("Bright green"),
	WATER       = BrickColor.new("Bright blue"),
}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function p(
	name: string,
	size: Vector3,
	cf:   CFrame,
	col:  BrickColor,
	mat:  Enum.Material?,
	cc:   boolean?,
	trans: number?
): Part
	local part = Instance.new("Part")
	part.Name        = name
	part.Size        = size
	part.CFrame      = cf
	part.BrickColor  = col
	part.Material    = mat or Enum.Material.SmoothPlastic
	part.Anchored    = true
	part.CanCollide  = cc ~= false
	part.CastShadow  = false
	part.Transparency = trans or 0
	part.Parent      = lobbyModel
	return part
end

local function corner(parent: Instance, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 4)
	c.Parent = parent
	return c
end

local function addPrompt(
	part:     BasePart,
	action:   string,
	label:    string,
	dist:     number?,
	interactType: string
)
	-- InteractType tag — read by LobbyController
	local tag = Instance.new("StringValue")
	tag.Name   = "InteractType"
	tag.Value  = interactType
	tag.Parent = part

	local pp = Instance.new("ProximityPrompt")
	pp.ActionText       = action
	pp.ObjectText       = label
	pp.MaxActivationDistance = dist or Constants.LOBBY_INTERACTION_RANGE
	pp.HoldDuration     = 0
	pp.RequiresLineOfSight = false
	pp.Parent           = part
	return pp
end

local function makeSign(
	parent:  BasePart,
	text:    string,
	offset:  Vector3,
	neonCol: BrickColor?
)
	local sign = Instance.new("Part")
	sign.Name       = "Sign"
	sign.Size       = Vector3.new(6, 2, 0.3)
	sign.CFrame     = parent.CFrame + offset
	sign.BrickColor = neonCol or COL.NEON_GOLD
	sign.Material   = Enum.Material.Neon
	sign.Anchored   = true
	sign.CanCollide = false
	sign.CastShadow = false
	sign.Parent     = lobbyModel

	local sg = Instance.new("SurfaceGui")
	sg.Face    = Enum.NormalId.Front
	sg.Parent  = sign
	local lbl  = Instance.new("TextLabel")
	lbl.Size   = UDim2.new(1,0,1,0)
	lbl.Text   = text
	lbl.TextScaled = true
	lbl.Font   = Enum.Font.GothamBlack
	lbl.TextColor3 = Color3.new(1,1,1)
	lbl.BackgroundTransparency = 1
	lbl.Parent = sg
	return sign
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0  = a
	w.Part1  = b
	w.Parent = a
end

-- ─────────────────────────────────────────────
-- Ground plane
-- ─────────────────────────────────────────────
local function buildGround()
	-- Main ground
	p("LobbyGround",
		Vector3.new(400, 2, 400),
		CFrame.new(O + Vector3.new(0, -1, 0)),
		COL.GROUND, Enum.Material.Grass)

	-- Central plaza pavement (stone circle)
	p("Plaza",
		Vector3.new(80, 0.5, 80),
		CFrame.new(O + Vector3.new(0, 0.25, 0)),
		COL.PAVEMENT, Enum.Material.Cobblestone)

	-- Market street pavement
	p("MarketStreet",
		Vector3.new(60, 0.5, 100),
		CFrame.new(O + Vector3.new(0, 0.25, 120)),
		COL.PAVEMENT, Enum.Material.SmoothPlastic)

	-- North walkway to training
	p("NorthWalk",
		Vector3.new(20, 0.5, 80),
		CFrame.new(O + Vector3.new(0, 0.25, -90)),
		COL.PAVEMENT, Enum.Material.SmoothPlastic)

	-- East + West walkways (to house rows)
	p("EastWalk",
		Vector3.new(120, 0.5, 20),
		CFrame.new(O + Vector3.new(80, 0.25, 0)),
		COL.PAVEMENT, Enum.Material.SmoothPlastic)
	p("WestWalk",
		Vector3.new(120, 0.5, 20),
		CFrame.new(O + Vector3.new(-80, 0.25, 0)),
		COL.PAVEMENT, Enum.Material.SmoothPlastic)

	-- Decorative plaza fountain base
	p("FountainBase",
		Vector3.new(14, 1.5, 14),
		CFrame.new(O + Vector3.new(0, 0.75, 0)),
		COL.STONE, Enum.Material.Marble)
	p("FountainPool",
		Vector3.new(10, 0.5, 10),
		CFrame.new(O + Vector3.new(0, 1.25, 0)),
		COL.WATER, Enum.Material.Neon, false, 0.4)
	p("FountainPillar",
		Vector3.new(2, 5, 2),
		CFrame.new(O + Vector3.new(0, 3.5, 0)),
		COL.WHITE, Enum.Material.Marble)
	-- Fountain top glow
	local fglow = p("FountainGlow",
		Vector3.new(3, 0.5, 3),
		CFrame.new(O + Vector3.new(0, 6.5, 0)),
		COL.NEON_BLUE, Enum.Material.Neon, false, 0.2)
	-- PointLight in fountain
	local fl = Instance.new("PointLight")
	fl.Brightness = 3
	fl.Range      = 24
	fl.Color      = Color3.fromRGB(0, 200, 255)
	fl.Parent     = fglow

	-- Plaza lamp posts (4 corners)
	for _, offset in ipairs({
		Vector3.new(-28, 0, -28), Vector3.new( 28, 0, -28),
		Vector3.new(-28, 0,  28), Vector3.new( 28, 0,  28),
	}) do
		p("LampPost", Vector3.new(1, 12, 1),
			CFrame.new(O + offset + Vector3.new(0, 6, 0)),
			COL.WALL_DARK, Enum.Material.Metal)
		local lamp = p("LampHead", Vector3.new(3, 1, 3),
			CFrame.new(O + offset + Vector3.new(0, 12.5, 0)),
			COL.NEON_GOLD, Enum.Material.Neon, false)
		local pl = Instance.new("PointLight")
		pl.Brightness = 2
		pl.Range = 30
		pl.Color = Color3.fromRGB(255, 220, 120)
		pl.Parent = lamp
	end
end

-- ─────────────────────────────────────────────
-- Generic house builder
-- ─────────────────────────────────────────────

local function buildHouse(
	name:    string,
	origin:  Vector3,
	wallCol: BrickColor,
	roofCol: BrickColor,
	label:   string,
	interactType: string
)
	local W, H, D = 20, 14, 20   -- width, height, depth

	-- Foundation
	p(name.."_Foundation",
		Vector3.new(W + 2, 1, D + 2),
		CFrame.new(origin + Vector3.new(0, 0.5, 0)),
		COL.STONE, Enum.Material.Concrete)

	-- Walls
	-- Front
	p(name.."_WallFront",
		Vector3.new(W, H, 1),
		CFrame.new(origin + Vector3.new(0, H/2 + 1, D/2)),
		wallCol, Enum.Material.Brick)
	-- Back
	p(name.."_WallBack",
		Vector3.new(W, H, 1),
		CFrame.new(origin + Vector3.new(0, H/2 + 1, -D/2)),
		wallCol, Enum.Material.Brick)
	-- Left
	p(name.."_WallLeft",
		Vector3.new(1, H, D),
		CFrame.new(origin + Vector3.new(-W/2, H/2 + 1, 0)),
		wallCol, Enum.Material.Brick)
	-- Right
	p(name.."_WallRight",
		Vector3.new(1, H, D),
		CFrame.new(origin + Vector3.new(W/2, H/2 + 1, 0)),
		wallCol, Enum.Material.Brick)
	-- Floor
	p(name.."_Floor",
		Vector3.new(W, 1, D),
		CFrame.new(origin + Vector3.new(0, 1, 0)),
		COL.WOOD, Enum.Material.WoodPlanks)
	-- Ceiling
	p(name.."_Ceiling",
		Vector3.new(W, 1, D),
		CFrame.new(origin + Vector3.new(0, H + 1, 0)),
		COL.WHITE, Enum.Material.SmoothPlastic)

	-- Roof (hip roof — two slanted halves)
	p(name.."_RoofA",
		Vector3.new(W + 4, 1.5, D/2 + 2),
		CFrame.new(origin + Vector3.new(0, H + 2.5, -D/4))
			* CFrame.Angles(math.rad(25), 0, 0),
		roofCol, Enum.Material.Concrete)
	p(name.."_RoofB",
		Vector3.new(W + 4, 1.5, D/2 + 2),
		CFrame.new(origin + Vector3.new(0, H + 2.5, D/4))
			* CFrame.Angles(math.rad(-25), 0, 0),
		roofCol, Enum.Material.Concrete)
	p(name.."_RoofRidge",
		Vector3.new(W + 4, 1, 2),
		CFrame.new(origin + Vector3.new(0, H + 5.5, 0)),
		roofCol, Enum.Material.Concrete)

	-- Door (on front wall face)
	local door = p(name.."_Door",
		Vector3.new(4, 7, 0.5),
		CFrame.new(origin + Vector3.new(0, 4.5, D/2 + 0.3)),
		COL.DOOR, Enum.Material.Wood)
	addPrompt(door, "Enter", label, 8, interactType)
	makeSign(door, label, Vector3.new(0, 6, 0),
		interactType == "Shop" and COL.NEON_GOLD or COL.NEON_BLUE)

	-- Windows (2 on front)
	for _, wx in ipairs({-6, 6}) do
		p(name.."_Win_"..wx,
			Vector3.new(4, 4, 0.3),
			CFrame.new(origin + Vector3.new(wx, H/2 + 1, D/2 + 0.5)),
			COL.WINDOW, Enum.Material.Glass, false, 0.3)
	end
	-- Side windows
	for _, wz in ipairs({-5, 5}) do
		p(name.."_WinSideL_"..wz,
			Vector3.new(0.3, 4, 4),
			CFrame.new(origin + Vector3.new(-W/2 - 0.2, H/2 + 1, wz)),
			COL.WINDOW, Enum.Material.Glass, false, 0.3)
		p(name.."_WinSideR_"..wz,
			Vector3.new(0.3, 4, 4),
			CFrame.new(origin + Vector3.new(W/2 + 0.2, H/2 + 1, wz)),
			COL.WINDOW, Enum.Material.Glass, false, 0.3)
	end

	-- Interior furniture (simple props)
	-- Table
	p(name.."_Table",
		Vector3.new(6, 1, 4),
		CFrame.new(origin + Vector3.new(4, 4, -4)),
		COL.WOOD, Enum.Material.WoodPlanks)
	-- Chairs (2)
	p(name.."_Chair1",
		Vector3.new(2, 3, 2),
		CFrame.new(origin + Vector3.new(2, 2.5, -1)),
		COL.WOOD, Enum.Material.Wood)
	p(name.."_Chair2",
		Vector3.new(2, 3, 2),
		CFrame.new(origin + Vector3.new(6, 2.5, -1)),
		COL.WOOD, Enum.Material.Wood)
	-- Rug
	p(name.."_Rug",
		Vector3.new(8, 0.1, 8),
		CFrame.new(origin + Vector3.new(0, 1.55, 2)),
		BrickColor.new("Magenta"), Enum.Material.Fabric, false)
	-- Bookshelf on back wall
	p(name.."_Shelf",
		Vector3.new(5, 8, 1),
		CFrame.new(origin + Vector3.new(-7, 5, -D/2 + 1)),
		COL.WOOD, Enum.Material.WoodPlanks)
	-- Trophy board (technique display)
	local board = p(name.."_Board",
		Vector3.new(6, 4, 0.3),
		CFrame.new(origin + Vector3.new(6, 8, -D/2 + 0.5)),
		COL.NEON_PURPLE, Enum.Material.Neon, false, 0.3)
	addPrompt(board, "View", "Player Board", 6, "PlayerBoard")
end

-- ─────────────────────────────────────────────
-- Shop builder
-- ─────────────────────────────────────────────

local function buildShop(
	name:      string,
	origin:    Vector3,
	shopType:  string,    -- "TechniqueShop" | "GearShop" | "AuraShop" | "LockerRoom"
	signText:  string,
	signColor: BrickColor
)
	local W, H, D = 24, 16, 22

	-- Foundation
	p(name.."_Foundation",
		Vector3.new(W + 2, 1.5, D + 2),
		CFrame.new(origin + Vector3.new(0, 0.75, 0)),
		COL.STONE, Enum.Material.Concrete)

	-- Walls (slightly grander than houses)
	p(name.."_WallFront",  Vector3.new(W, H, 1),  CFrame.new(origin + Vector3.new(0, H/2+1.5, D/2)), COL.WALL_B, Enum.Material.SmoothPlastic)
	p(name.."_WallBack",   Vector3.new(W, H, 1),  CFrame.new(origin + Vector3.new(0, H/2+1.5,-D/2)), COL.WALL_B, Enum.Material.SmoothPlastic)
	p(name.."_WallLeft",   Vector3.new(1, H, D),  CFrame.new(origin + Vector3.new(-W/2, H/2+1.5, 0)), COL.WALL_B, Enum.Material.SmoothPlastic)
	p(name.."_WallRight",  Vector3.new(1, H, D),  CFrame.new(origin + Vector3.new( W/2, H/2+1.5, 0)), COL.WALL_B, Enum.Material.SmoothPlastic)
	p(name.."_Floor",      Vector3.new(W, 1, D),  CFrame.new(origin + Vector3.new(0, 1.5, 0)), COL.PAVEMENT, Enum.Material.Marble)
	p(name.."_Ceiling",    Vector3.new(W, 1, D),  CFrame.new(origin + Vector3.new(0, H+1.5, 0)), COL.WHITE, Enum.Material.SmoothPlastic)

	-- Flat modern roof
	p(name.."_Roof",
		Vector3.new(W + 2, 1, D + 2),
		CFrame.new(origin + Vector3.new(0, H + 2, 0)),
		COL.WALL_DARK, Enum.Material.Concrete)

	-- Large display windows (storefront feel)
	for _, wx in ipairs({-7, 0, 7}) do
		p(name.."_DisplayWin_"..wx,
			Vector3.new(5, 8, 0.3),
			CFrame.new(origin + Vector3.new(wx, H/2 + 1.5, D/2 + 0.3)),
			COL.WINDOW, Enum.Material.Glass, false, 0.15)
	end

	-- Main entrance door (double)
	local door = p(name.."_Door",
		Vector3.new(5, 9, 0.4),
		CFrame.new(origin + Vector3.new(0, 6, D/2 + 0.3)),
		COL.WINDOW, Enum.Material.Glass, true, 0.2)
	addPrompt(door, "Enter", signText, 10, shopType)

	-- Neon sign above door
	local sign = p(name.."_SignBoard",
		Vector3.new(W - 2, 2.5, 0.5),
		CFrame.new(origin + Vector3.new(0, H + 0.5, D/2 + 0.4)),
		signColor, Enum.Material.Neon, false, 0.1)
	local sg = Instance.new("SurfaceGui")
	sg.Face  = Enum.NormalId.Front
	sg.Parent = sign
	local lbl = Instance.new("TextLabel")
	lbl.Size   = UDim2.new(1,0,1,0)
	lbl.Text   = signText
	lbl.TextScaled = true
	lbl.Font   = Enum.Font.GothamBlack
	lbl.TextColor3 = Color3.new(1,1,1)
	lbl.BackgroundTransparency = 1
	lbl.Parent = sg

	-- Interior counters
	p(name.."_Counter",
		Vector3.new(W - 4, 3, 3),
		CFrame.new(origin + Vector3.new(0, 3, -D/2 + 4)),
		COL.WALL_DARK, Enum.Material.SmoothPlastic)
	-- Counter NPC placeholder (simple mannequin block)
	local npc = p(name.."_NPCBody",
		Vector3.new(2, 5, 1),
		CFrame.new(origin + Vector3.new(0, 5, -D/2 + 3)),
		COL.NEON_PURPLE, Enum.Material.Neon, false, 0.2)
	local npcHead = p(name.."_NPCHead",
		Vector3.new(2, 2, 2),
		CFrame.new(origin + Vector3.new(0, 8.5, -D/2 + 3)),
		COL.WHITE, Enum.Material.SmoothPlastic)
	-- NPC interact prompt
	addPrompt(npcHead, "Talk", "Shop Keeper", 8, shopType)

	-- Display shelves with glowing item orbs
	local orbColors = {
		BrickColor.new("Bright yellow"),
		BrickColor.new("Cyan"),
		BrickColor.new("Magenta"),
		BrickColor.new("Lime green"),
	}
	for i = 1, 4 do
		p(name.."_Shelf_"..i,
			Vector3.new(4, 0.5, 3),
			CFrame.new(origin + Vector3.new(-8 + (i-1)*5, 6, -D/2 + 2)),
			COL.WOOD, Enum.Material.WoodPlanks)
		local orb = p(name.."_Orb_"..i,
			Vector3.new(2, 2, 2),
			CFrame.new(origin + Vector3.new(-8 + (i-1)*5, 7.5, -D/2 + 2)),
			orbColors[i], Enum.Material.Neon, false, 0.2)
		local pl = Instance.new("PointLight")
		pl.Brightness = 1.5
		pl.Range = 10
		pl.Color = orb.Color
		pl.Parent = orb
	end

	-- Floor neon strip
	p(name.."_FloorStrip",
		Vector3.new(W - 2, 0.2, 1),
		CFrame.new(origin + Vector3.new(0, 1.55, -4)),
		signColor, Enum.Material.Neon, false, 0.3)
end

-- ─────────────────────────────────────────────
-- Trophy Room
-- ─────────────────────────────────────────────

local function buildTrophyRoom(origin: Vector3)
	local W, H, D = 20, 16, 20

	p("Trophy_Foundation", Vector3.new(W+2,1.5,D+2), CFrame.new(origin+Vector3.new(0,.75,0)), COL.STONE, Enum.Material.Marble)
	p("Trophy_WallF", Vector3.new(W,H,1), CFrame.new(origin+Vector3.new(0,H/2+1.5,D/2)), COL.WALL_C, Enum.Material.SmoothPlastic)
	p("Trophy_WallBk",Vector3.new(W,H,1), CFrame.new(origin+Vector3.new(0,H/2+1.5,-D/2)),COL.WALL_C, Enum.Material.SmoothPlastic)
	p("Trophy_WallL", Vector3.new(1,H,D), CFrame.new(origin+Vector3.new(-W/2,H/2+1.5,0)), COL.WALL_C, Enum.Material.SmoothPlastic)
	p("Trophy_WallR", Vector3.new(1,H,D), CFrame.new(origin+Vector3.new( W/2,H/2+1.5,0)), COL.WALL_C, Enum.Material.SmoothPlastic)
	p("Trophy_Floor",  Vector3.new(W,1,D), CFrame.new(origin+Vector3.new(0,1.5,0)), COL.PAVEMENT, Enum.Material.Marble)
	p("Trophy_Ceiling",Vector3.new(W,1,D), CFrame.new(origin+Vector3.new(0,H+1.5,0)), COL.WHITE)
	p("Trophy_Roof",   Vector3.new(W+2,1,D+2), CFrame.new(origin+Vector3.new(0,H+2,0)), COL.NEON_GOLD, Enum.Material.Neon, false, 0.4)

	local door = p("Trophy_Door",Vector3.new(4,8,0.4), CFrame.new(origin+Vector3.new(0,5.5,D/2+.3)), COL.DOOR, Enum.Material.Wood)
	addPrompt(door, "Enter", "Trophy Room", 8, "TrophyRoom")
	makeSign(door, "🏆 TROPHY ROOM", Vector3.new(0,7,0), COL.NEON_GOLD)

	-- Trophy pedestals (6)
	for i = 1, 6 do
		local px = -10 + (i-1) * 4
		p("Trophy_Pedestal_"..i, Vector3.new(2,3,2), CFrame.new(origin+Vector3.new(px,3,-4)), COL.STONE, Enum.Material.Marble)
		local cup = p("Trophy_Cup_"..i, Vector3.new(2,3,2), CFrame.new(origin+Vector3.new(px,5.5,-4)), COL.NEON_GOLD, Enum.Material.Neon, false, 0.1)
		local cl = Instance.new("PointLight")
		cl.Brightness = 1; cl.Range = 8; cl.Color = Color3.fromRGB(255,200,0); cl.Parent = cup
	end

	-- Leaderboard board on back wall
	local lb = p("Trophy_Leaderboard", Vector3.new(14,8,0.4), CFrame.new(origin+Vector3.new(0,9,-D/2+.5)), COL.NEON_BLUE, Enum.Material.Neon, false, 0.2)
	addPrompt(lb, "View", "Top Players", 6, "Leaderboard")
	local sg = Instance.new("SurfaceGui"); sg.Face = Enum.NormalId.Front; sg.Parent = lb
	local lbl = Instance.new("TextLabel"); lbl.Size=UDim2.new(1,0,1,0); lbl.Text="TOP STRIKERS"; lbl.TextScaled=true; lbl.Font=Enum.Font.GothamBlack; lbl.TextColor3=Color3.new(1,1,1); lbl.BackgroundTransparency=1; lbl.Parent=sg
end

-- ─────────────────────────────────────────────
-- Training Dome
-- ─────────────────────────────────────────────

local function buildTrainingDome(origin: Vector3)
	-- Dome base
	p("Dome_Floor", Vector3.new(50,1,50), CFrame.new(origin+Vector3.new(0,0.5,0)), COL.GRASS, Enum.Material.Grass)

	-- Dome ring walls (12 segments)
	local DOME_R = 28
	local SEGS   = 12
	for i = 1, SEGS do
		local a = (i / SEGS) * math.pi * 2
		local x = math.cos(a) * DOME_R
		local z = math.sin(a) * DOME_R
		p("Dome_Wall_"..i,
			Vector3.new(16, 20, 1),
			CFrame.new(origin + Vector3.new(x, 10, z))
				* CFrame.Angles(0, -a + math.pi/2, 0),
			COL.WALL_B, Enum.Material.Glass, true, 0.6)
	end

	-- Dome ceiling (flat for performance)
	p("Dome_Ceiling", Vector3.new(54,1,54), CFrame.new(origin+Vector3.new(0,21,0)), COL.WINDOW, Enum.Material.Glass, false, 0.7)

	-- Dome lighting
	local dlight = p("Dome_Light", Vector3.new(4,1,4), CFrame.new(origin+Vector3.new(0,20,0)), COL.NEON_GOLD, Enum.Material.Neon, false, 0.1)
	local pl = Instance.new("PointLight"); pl.Brightness=4; pl.Range=60; pl.Color=Color3.fromRGB(255,240,200); pl.Parent=dlight

	-- Entrance
	local door = p("Dome_Door", Vector3.new(6,10,0.5), CFrame.new(origin+Vector3.new(0,6,DOME_R+.3)), COL.WINDOW, Enum.Material.Glass, true, 0.2)
	addPrompt(door, "Enter", "Training Dome", 10, "Training")
	makeSign(door, "⚡ TRAINING DOME", Vector3.new(0,8,0), COL.NEON_GREEN)

	-- Practice ball (static prop)
	p("Dome_Ball", Vector3.new(3,3,3), CFrame.new(origin+Vector3.new(0,2.5,0)), COL.WHITE, Enum.Material.SmoothPlastic)

	-- Goal net (small, practice size)
	p("Dome_GoalL",  Vector3.new(0.5,6,0.5), CFrame.new(origin+Vector3.new(-8,4,-18)), COL.WHITE, Enum.Material.Metal)
	p("Dome_GoalR",  Vector3.new(0.5,6,0.5), CFrame.new(origin+Vector3.new( 8,4,-18)), COL.WHITE, Enum.Material.Metal)
	p("Dome_GoalBar",Vector3.new(16,0.5,0.5), CFrame.new(origin+Vector3.new(0,7,-18)), COL.WHITE, Enum.Material.Metal)
	p("Dome_GoalNet",Vector3.new(16,6,0.3), CFrame.new(origin+Vector3.new(0,4,-20)), COL.WHITE, Enum.Material.SmoothPlastic, false, 0.7)

	-- Spawn pad inside dome
	local sp = Instance.new("SpawnLocation")
	sp.Name="SpawnTraining"; sp.Size=Vector3.new(4,1,4)
	sp.CFrame=CFrame.new(origin+Vector3.new(0,1.5,0))
	sp.Anchored=true; sp.CanCollide=true; sp.Enabled=true; sp.Duration=0
	sp.BrickColor=COL.NEON_GREEN; sp.Material=Enum.Material.Neon; sp.Transparency=0.5
	sp.Parent = lobbyModel
end

-- ─────────────────────────────────────────────
-- Canteen (social hangout)
-- ─────────────────────────────────────────────

local function buildCanteen(origin: Vector3)
	local W,H,D = 26,12,22
	p("Canteen_Foundation",Vector3.new(W+2,1.5,D+2),CFrame.new(origin+Vector3.new(0,.75,0)),COL.STONE,Enum.Material.Concrete)
	p("Canteen_WallF",Vector3.new(W,H,1),CFrame.new(origin+Vector3.new(0,H/2+1.5,D/2)),COL.WALL_A,Enum.Material.Brick)
	p("Canteen_WallBk",Vector3.new(W,H,1),CFrame.new(origin+Vector3.new(0,H/2+1.5,-D/2)),COL.WALL_A,Enum.Material.Brick)
	p("Canteen_WallL",Vector3.new(1,H,D),CFrame.new(origin+Vector3.new(-W/2,H/2+1.5,0)),COL.WALL_A,Enum.Material.Brick)
	p("Canteen_WallR",Vector3.new(1,H,D),CFrame.new(origin+Vector3.new(W/2,H/2+1.5,0)),COL.WALL_A,Enum.Material.Brick)
	p("Canteen_Floor",Vector3.new(W,1,D),CFrame.new(origin+Vector3.new(0,1.5,0)),COL.WOOD,Enum.Material.WoodPlanks)
	p("Canteen_Roof",Vector3.new(W+2,1.5,D+2),CFrame.new(origin+Vector3.new(0,H+2.5,0)),COL.ROOF_A,Enum.Material.Concrete)

	local door = p("Canteen_Door",Vector3.new(4,8,0.5),CFrame.new(origin+Vector3.new(0,5.5,D/2+.3)),COL.DOOR,Enum.Material.Wood)
	addPrompt(door,"Enter","Canteen",8,"Canteen")
	makeSign(door,"🍜 CANTEEN",Vector3.new(0,6,0),COL.NEON_GOLD)

	-- Tables and stools (4 tables)
	for i = 1,2 do for j = 1,2 do
		local tx = -6+(i-1)*12; local tz = -5+(j-1)*8
		p("CT_Table_"..i..j,Vector3.new(6,2,4),CFrame.new(origin+Vector3.new(tx,3.5,tz)),COL.WOOD,Enum.Material.WoodPlanks)
		for s = 1,4 do
			local sx = tx-2+(s%2)*4; local sz = tz-2+math.floor(s/2)*4
			p("CT_Stool_"..i..j..s,Vector3.new(2,2,2),CFrame.new(origin+Vector3.new(sx,2.5,sz)),COL.WOOD,Enum.Material.Wood)
		end
	end end

	-- Bar counter
	p("Canteen_Bar",Vector3.new(W-4,3,3),CFrame.new(origin+Vector3.new(0,3,-D/2+3)),COL.WALL_DARK,Enum.Material.SmoothPlastic)
	-- Emote zone marker
	local ez = p("Canteen_EmoteZone",Vector3.new(8,0.2,8),CFrame.new(origin+Vector3.new(0,1.6,5)),COL.NEON_PURPLE,Enum.Material.Neon,false,0.4)
	addPrompt(ez,"Dance","Emote Zone",6,"Emote")
	local sg=Instance.new("SurfaceGui");sg.Face=Enum.NormalId.Top;sg.Parent=ez
	local lbl=Instance.new("TextLabel");lbl.Size=UDim2.new(1,0,1,0);lbl.Text="EMOTE ZONE";lbl.TextScaled=true;lbl.Font=Enum.Font.GothamBold;lbl.TextColor3=Color3.new(1,1,1);lbl.BackgroundTransparency=1;lbl.Parent=sg
end

-- ─────────────────────────────────────────────
-- Notice Board
-- ─────────────────────────────────────────────

local function buildNoticeBoard(origin: Vector3)
	p("NoticePost_L",Vector3.new(1,8,1),CFrame.new(origin+Vector3.new(-4,4,0)),COL.WOOD,Enum.Material.Wood)
	p("NoticePost_R",Vector3.new(1,8,1),CFrame.new(origin+Vector3.new( 4,4,0)),COL.WOOD,Enum.Material.Wood)
	p("NoticeBeam",  Vector3.new(9,1,1),CFrame.new(origin+Vector3.new( 0,8.5,0)),COL.WOOD,Enum.Material.Wood)
	local board = p("NoticeBoard",Vector3.new(8,5,0.4),CFrame.new(origin+Vector3.new(0,5.5,0.3)),COL.NEON_BLUE,Enum.Material.Neon,false,0.15)
	addPrompt(board,"Read","Notice Board",6,"NoticeBoard")
	local sg=Instance.new("SurfaceGui");sg.Face=Enum.NormalId.Front;sg.Parent=board
	local lbl=Instance.new("TextLabel");lbl.Size=UDim2.new(1,0,1,0);lbl.Text="📋 QUESTS & EVENTS";lbl.TextScaled=true;lbl.Font=Enum.Font.GothamBold;lbl.TextColor3=Color3.new(1,1,1);lbl.BackgroundTransparency=1;lbl.Parent=sg
end

-- ─────────────────────────────────────────────
-- Lobby spawn ring
-- ─────────────────────────────────────────────

local function buildSpawnRing()
	local R = Constants.LOBBY_SPAWN_RADIUS
	local spawnColors = {
		BrickColor.new("Bright blue"), BrickColor.new("Bright red"),
		BrickColor.new("Lime green"),  BrickColor.new("Bright yellow"),
		BrickColor.new("Cyan"),        BrickColor.new("Magenta"),
		BrickColor.new("White"),       BrickColor.new("Teal"),
	}
	for i = 1, 8 do
		local a  = ((i-1) / 8) * math.pi * 2
		local sx = O.X + math.cos(a) * R
		local sz = O.Z + 160 + math.sin(a) * R   -- south of lobby, near entry
		local sp = Instance.new("SpawnLocation")
		sp.Name       = "SpawnLobby_" .. i
		sp.Size       = Vector3.new(4,1,4)
		sp.CFrame     = CFrame.new(sx, O.Y + 1, sz)
		sp.TeamColor  = BrickColor.new("Medium stone grey")
		sp.Anchored   = true
		sp.CanCollide = true
		sp.Enabled    = true
		sp.Duration   = 0
		sp.BrickColor = spawnColors[i]
		sp.Material   = Enum.Material.Neon
		sp.Transparency = 0.5
		sp.Parent     = lobbyModel
	end

	-- Spawn ring glow ground decal
	p("SpawnRingGlow",
		Vector3.new(R*2+8, 0.3, R*2+8),
		CFrame.new(O + Vector3.new(0, 0.5, 160)),
		COL.NEON_BLUE, Enum.Material.Neon, false, 0.7)

	-- Welcome arch
	p("WelcomeArchL",Vector3.new(2,16,2),CFrame.new(O+Vector3.new(-12,8,130)),COL.NEON_GOLD,Enum.Material.Neon,true,0.1)
	p("WelcomeArchR",Vector3.new(2,16,2),CFrame.new(O+Vector3.new( 12,8,130)),COL.NEON_GOLD,Enum.Material.Neon,true,0.1)
	local archTop = p("WelcomeArchTop",Vector3.new(26,2,2),CFrame.new(O+Vector3.new(0,16,130)),COL.NEON_GOLD,Enum.Material.Neon,false,0.1)
	local sg=Instance.new("SurfaceGui");sg.Face=Enum.NormalId.Back;sg.Parent=archTop
	local lbl=Instance.new("TextLabel");lbl.Size=UDim2.new(1,0,1,0);lbl.Text="⚡ MYTHIC STRIKERS";lbl.TextScaled=true;lbl.Font=Enum.Font.GothamBlack;lbl.TextColor3=Color3.fromRGB(255,215,0);lbl.BackgroundTransparency=1;lbl.Parent=sg
end

-- ─────────────────────────────────────────────
-- Path-to-stadium connector bridge
-- ─────────────────────────────────────────────

local function buildConnectorPath()
	-- Long walkway from lobby south edge to stadium north edge
	-- Stadium is at Z=0, Lobby is at Z=600, so we need Z 0..450 ish
	for i = 0, 5 do
		p("Connector_"..i,
			Vector3.new(16, 1, 80),
			CFrame.new(O + Vector3.new(0, 0, 160 + i * 80)),
			COL.PAVEMENT, Enum.Material.Cobblestone)
	end
	-- Lamp posts along connector (every 40 studs)
	for i = 0, 10 do
		for _, side in ipairs({-10, 10}) do
			p("PathLamp_"..i.."_"..side,
				Vector3.new(1, 10, 1),
				CFrame.new(O + Vector3.new(side, 5, 170 + i * 40)),
				COL.WALL_DARK, Enum.Material.Metal)
			local lhead = p("PathLampHead_"..i.."_"..side,
				Vector3.new(2, 1, 2),
				CFrame.new(O + Vector3.new(side, 10.5, 170 + i * 40)),
				COL.NEON_GOLD, Enum.Material.Neon, false)
			local pl=Instance.new("PointLight");pl.Brightness=1.5;pl.Range=22;pl.Color=Color3.fromRGB(255,220,120);pl.Parent=lhead
		end
	end
	-- "Go to Match" portal at end of path
	local portal = p("MatchPortal",
		Vector3.new(14,18,2),
		CFrame.new(O + Vector3.new(0, 9, 580)),
		COL.NEON_PURPLE, Enum.Material.Neon, false, 0.2)
	addPrompt(portal,"Enter Match","Match Portal",12,"MatchPortal")
	local sg=Instance.new("SurfaceGui");sg.Face=Enum.NormalId.Front;sg.Parent=portal
	local lbl=Instance.new("TextLabel");lbl.Size=UDim2.new(1,0,1,0);lbl.Text="⚡ ENTER MATCH";lbl.TextScaled=true;lbl.Font=Enum.Font.GothamBlack;lbl.TextColor3=Color3.fromRGB(255,215,0);lbl.BackgroundTransparency=1;lbl.Parent=sg
	-- Portal ring light
	local pl=Instance.new("PointLight");pl.Brightness=4;pl.Range=30;pl.Color=Color3.fromRGB(191,95,255);pl.Parent=portal
end

-- ─────────────────────────────────────────────
-- Build everything
-- ─────────────────────────────────────────────

local function buildLobby()
	local existing = workspace:FindFirstChild("Lobby")
	if existing then existing:Destroy() end

	lobbyModel        = Instance.new("Model")
	lobbyModel.Name   = "Lobby"
	lobbyModel.Parent = workspace

	buildGround()
	buildSpawnRing()
	buildConnectorPath()

	-- ── 6 Player Houses ────────────────────────────────────────────
	-- West row (3 houses)
	buildHouse("HouseW1", O+Vector3.new(-100, 1, -30), COL.WALL_A, COL.ROOF_A, "Player House",  "PlayerHouse")
	buildHouse("HouseW2", O+Vector3.new(-100, 1,  10), COL.WALL_B, COL.ROOF_B, "Player House",  "PlayerHouse")
	buildHouse("HouseW3", O+Vector3.new(-100, 1,  50), COL.WALL_C, COL.ROOF_C, "Player House",  "PlayerHouse")

	-- East row (3 houses)
	buildHouse("HouseE1", O+Vector3.new( 100, 1, -30), COL.WALL_C, COL.ROOF_C, "Player House",  "PlayerHouse")
	buildHouse("HouseE2", O+Vector3.new( 100, 1,  10), COL.WALL_A, COL.ROOF_A, "Player House",  "PlayerHouse")
	buildHouse("HouseE3", O+Vector3.new( 100, 1,  50), COL.WALL_B, COL.ROOF_B, "Player House",  "PlayerHouse")

	-- ── Market Street Shops ────────────────────────────────────────
	buildShop("TechShop",   O+Vector3.new(-55, 1, 100), "TechniqueShop", "⚡ TECHNIQUE SHOP",  COL.NEON_BLUE)
	buildShop("GearShop",   O+Vector3.new(  0, 1, 110), "GearShop",      "👟 GEAR SHOP",       COL.NEON_GOLD)
	buildShop("AuraShop",   O+Vector3.new( 55, 1, 100), "AuraShop",      "✨ AURA SHOP",       COL.NEON_PURPLE)
	buildShop("LockerRoom", O+Vector3.new(-55, 1,  60), "LockerRoom",    "🎒 LOCKER ROOM",     COL.NEON_GREEN)

	-- ── Special Buildings ──────────────────────────────────────────
	buildTrophyRoom(O + Vector3.new( 55, 1,  60))
	buildCanteen(   O + Vector3.new(  0, 1, -60))
	buildTrainingDome(O + Vector3.new(0, 1, -140))

	-- ── Notice Board (plaza) ───────────────────────────────────────
	buildNoticeBoard(O + Vector3.new(20, 1, 20))

	-- Set primary part for model
	local kickoff = lobbyModel:FindFirstChild("SpawnLobby_1")
	if kickoff then lobbyModel.PrimaryPart = kickoff end

	local count = 0
	for _ in pairs(lobbyModel:GetDescendants()) do count += 1 end
	print(string.format("[LobbyBuilder] Lobby built — %d instances.", count))
	print("  Houses: 6 | Shops: 4 | Trophy Room | Canteen | Training Dome | Connector Path")
end

-- ─────────────────────────────────────────────
-- Run
-- ─────────────────────────────────────────────
local ok, err = pcall(buildLobby)
if not ok then
	warn("[LobbyBuilder] Failed: " .. tostring(err))
end
