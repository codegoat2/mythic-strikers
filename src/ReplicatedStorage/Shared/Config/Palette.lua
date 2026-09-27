--[[
	MythicStrikers — Palette
	The single source of truth for colour and material in Mythic Strikers.

	WHY THIS EXISTS
	The prototype had no palette. Every builder inlined its own BrickColor
	table, so the stadium, the town and the training grounds each invented
	their own version of "blue" and their own version of "grass". That is
	why the world read as unrelated blocks bolted together.

	DIRECTION
	  • Environment: desaturated, believable, cool-leaning neutrals.
	    Deep blue / navy / charcoal / concrete / natural grass.
	  • Accents: reserved. Supernatural colour is ONLY for techniques,
	    energy, interactive elements and landmarks. If a whole building is
	    glowing, the hierarchy is broken.
	  • Team colours: recognisable but not neon. Azure and crimson.

	USAGE
	    local Palette = require(ReplicatedStorage.Shared.Config.Palette)
	    Palette.World.Asphalt              -- Color3
	    Palette.World.asphalt()            -- BrickColor
	    Palette.Materials.Road             -- Enum.Material
--]]

local Palette = {}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

--- 0xRRGGBB integer -> Color3
--- Written with arithmetic rather than bit shifts: this place's Luau build
--- rejects the bitwise operators, so >> and & cannot be used anywhere.
local function rgb(hex: number): Color3
	local h = math.floor(hex)
	local r = math.floor(h / 65536) % 256
	local g = math.floor(h / 256) % 256
	local b = h % 256
	return Color3.new(r / 255, g / 255, b / 255)
end

--- Wrap a colour as a BrickColor. Used only where the legacy builders still
--- expect one — new code should pass Color3 directly.
local function brick(c: Color3): BrickColor
	return BrickColor.new(c)
end

-- ─────────────────────────────────────────────
-- WORLD — ground, roads, structure
-- ─────────────────────────────────────────────
Palette.World = {
	-- Base neutrals
	Void        = rgb(0x0A0E14),
	Charcoal    = rgb(0x1B1E24),
	CharcoalMid = rgb(0x2A2E35),
	Graphite    = rgb(0x3A3F47),

	-- Signature blues
	Navy        = rgb(0x16233B),
	DeepBlue    = rgb(0x1B3358),
	SteelBlue   = rgb(0x2C4A6E),

	-- White / paper
	White       = rgb(0xEDF1F5),
	OffWhite    = rgb(0xD8DEE5),
	Paper       = rgb(0xC3CBD4),

	-- Concrete family — deliberately varied so large surfaces are not flat
	ConcreteDark  = rgb(0x5A6068),
	Concrete      = rgb(0x7E848B),
	ConcreteLight = rgb(0x9BA1A8),
	ConcretePale  = rgb(0xB4BAC1),

	-- Roads
	Asphalt     = rgb(0x2E3238),
	AsphaltWorn = rgb(0x3A3F46),
	RoadLine    = rgb(0xD8DCE0),
	Kerb        = rgb(0xA8AEB5),
	Pavement    = rgb(0x8A9098),

	-- Brick / render / plaster (residential)
	BrickRed    = rgb(0x8C5A48),
	BrickSand   = rgb(0xA98A6E),
	RenderWarm  = rgb(0xB4AFA6),
	RenderCool  = rgb(0xA39E96),
	Plaster     = rgb(0xC6C0B6),
	TileRoof    = rgb(0x5A3E42),
	TileRoofAlt = rgb(0x3B4A5A),
	Wood        = rgb(0x7A5A3C),
	WoodDark    = rgb(0x5A422A),

	-- Metal / glass
	Metal       = rgb(0x8A9099),
	MetalDark   = rgb(0x565C64),
	MetalLight  = rgb(0xB4BAC1),
	Glass       = rgb(0x8FB4CC),
	GlassDark   = rgb(0x3E5A70),

	-- Vegetation — natural, never neon
	Grass       = rgb(0x3C7A44),
	GrassDark   = rgb(0x316A38),
	GrassLight  = rgb(0x4A8A4E),
	Foliage     = rgb(0x2F5E38),
	FoliageLight= rgb(0x3E7A44),
	Trunk       = rgb(0x4A3A2C),
	Bush        = rgb(0x35663C),
	Soil        = rgb(0x3E3228),

	-- Water
	Water       = rgb(0x2A4A66),
	WaterLight  = rgb(0x3E6E90),
}

-- ─────────────────────────────────────────────
-- MATERIALS — reinforce what an object IS
-- ─────────────────────────────────────────────
Palette.Materials = {
	-- Ground
	Road      = Enum.Material.Asphalt,
	Path      = Enum.Material.Concrete,
	Plaza     = Enum.Material.Cobblestone,
	Concrete  = Enum.Material.Concrete,
	Terrain   = Enum.Material.Ground,
	Pitch     = Enum.Material.Grass,
	Foliage   = Enum.Material.LeafyGrass,
	LeafyGrass= Enum.Material.LeafyGrass,

	-- Structure
	Wall      = Enum.Material.Concrete,
	WallBrick = Enum.Material.Brick,
	WallWood  = Enum.Material.WoodPlanks,
	WallPanel = Enum.Material.Metal,
	Roof      = Enum.Material.Slate,
	RoofTile  = Enum.Material.RoofShingles,

	-- Metal / glass
	Metal      = Enum.Material.Metal,
	MetalDark  = Enum.Material.DiamondPlate,
	MetalPanel = Enum.Material.Metal,
	Glass      = Enum.Material.Glass,
	Fence      = Enum.Material.CorrodedMetal,
	Water      = Enum.Material.Glass,

	-- Detail
	Fabric = Enum.Material.Fabric,
	Rubber = Enum.Material.Rubber,
	Seat   = Enum.Material.SmoothPlastic,
	Smooth = Enum.Material.SmoothPlastic,
	Plastic= Enum.Material.Plastic,
	Ice    = Enum.Material.Ice,
	Line   = Enum.Material.SmoothPlastic,
	Neon   = Enum.Material.Metal,
}

-- ─────────────────────────────────────────────
-- TEAMS — controlled, not neon
-- ─────────────────────────────────────────────
Palette.Teams = {
	A = {
		Name    = "Azure",
		Primary = rgb(0x2C6FD1),
		Deep    = rgb(0x1B3F80),
		Trim    = rgb(0x8FC0F5),
		Seats   = rgb(0x27507F),
	},
	B = {
		Name    = "Crimson",
		Primary = rgb(0xC4304A),
		Deep    = rgb(0x7A1A2C),
		Trim    = rgb(0xF090A2),
		Seats   = rgb(0x7A2436),
	},
	Neutral = {
		Name    = "Neutral",
		Primary = rgb(0x5A6068),
		Deep    = rgb(0x3A3F47),
		Trim    = rgb(0x9BA1A8),
		Seats   = rgb(0x4A5058),
	},
	Spec = {
		Name    = "Spectator",
		Primary = rgb(0x3A3F47),
		Deep    = rgb(0x2A2E35),
		Trim    = rgb(0x7E848B),
		Seats   = rgb(0x33373D),
	},
}

-- ─────────────────────────────────────────────
-- ACCENT — SUPERNATURAL
--
-- These are the only saturated colours in the world. Use them for:
--   • technique VFX            • energy readouts
--   • interactive surfaces     • landmark glow
--   • match-state emphasis
-- Never for: walls, roofs, generic props, a whole shopfront.
-- ─────────────────────────────────────────────
Palette.Accent = {
	Mythic   = rgb(0x3FE0E8),  -- primary energy / Mythic UI
	Arcane   = rgb(0x8B5CF0),  -- technique purple
	Ember    = rgb(0xFFA83D),  -- warnings / fire techniques
	Verdant  = rgb(0x4ADE80),  -- confirmations / success
	Rose     = rgb(0xFF5A6E),  -- danger / deficit
	Solar    = rgb(0xFFD24A),  -- ball / kick highlight
	DeepSea  = rgb(0x1B6E8C),  -- water glow
}

-- ─────────────────────────────────────────────
-- SEATING / STADIUM CROWD
-- ─────────────────────────────────────────────
Palette.Crowd = {
	SeatA     = rgb(0x2A4C74),
	SeatB     = rgb(0x74283A),
	SeatEmpty = rgb(0x4A5058),
	SeatMix   = { rgb(0x2A4C74), rgb(0x74283A), rgb(0x4A5058), rgb(0x6E747C) },
}

-- ─────────────────────────────────────────────
-- UI — one system for HUD, menus, cards, loading
-- ─────────────────────────────────────────────
Palette.UI = {
	-- Surfaces, darkest to lightest
	Void        = rgb(0x070B12),
	Background  = rgb(0x0B1220),
	Panel       = rgb(0x121A2A),
	PanelRaised = rgb(0x1A2436),
	PanelHigh   = rgb(0x243047),
	Overlay     = rgb(0x0B1220),

	-- Lines
	Stroke      = rgb(0x263449),
	StrokeSoft  = rgb(0x1B2434),
	StrokeFocus = rgb(0x3FE0E8),

	-- Text
	Text        = rgb(0xEAF0F7),
	TextDim     = rgb(0x8A9AB0),
	TextFaint   = rgb(0x55637A),
	TextOnAccent= rgb(0x06121A),

	-- Semantic
	Accent      = rgb(0x3FE0E8),
	AccentDim   = rgb(0x1E7A85),
	Success     = rgb(0x4ADE80),
	Warning     = rgb(0xFFA83D),
	Danger      = rgb(0xFF5A6E),
	Stamina     = rgb(0x4ADE80),
	Energy      = rgb(0x3FE0E8),
	XP          = rgb(0x8B5CF0),

	-- Resource bars
	BarTrack    = rgb(0x161F2E),
	BarStamina  = rgb(0x3FBF6B),
	BarEnergy   = rgb(0x35C8D8),
	BarXP       = rgb(0x7C4FE0),
	BarAwaken   = rgb(0xFFD24A),

	-- Team
	TeamA       = rgb(0x2C6FD1),
	TeamB       = rgb(0xC4304A),
}

-- ─────────────────────────────────────────────
-- TYPOGRAPHY
--
-- One display face for identity, one body face for information. Nothing
-- else. The prototype mixed Gotham, GothamBold, SciFi, Code and Foundation
-- across two files, which is why no screen looked related to another.
-- ─────────────────────────────────────────────
Palette.Type = {
	Display = Enum.Font.GothamBlack,   -- titles, wordmark, big numbers
	Heading = Enum.Font.GothamBold,    -- section headers
	Body    = Enum.Font.Gotham,        -- labels, values
	BodyBold= Enum.Font.GothamMedium,  -- emphasised values
	Numeric = Enum.Font.GothamMedium,  -- scoreboard, timers
}

-- ─────────────────────────────────────────────
-- SPACING SCALE — 4px base
-- ─────────────────────────────────────────────
Palette.Space = {
	XXS = 2,
	XS  = 4,
	SM  = 8,
	MD  = 12,
	LG  = 16,
	XL  = 24,
	XXL = 32,
	XXXL= 48,
}

-- ─────────────────────────────────────────────
-- RADII
-- ─────────────────────────────────────────────
Palette.Radius = {
	SM = 4,
	MD = 8,
	LG = 12,
	Pill = 999,
}

-- ─────────────────────────────────────────────
-- MOTION
-- ─────────────────────────────────────────────
Palette.Motion = {
	Fast   = 0.10,
	Normal = 0.18,
	Slow   = 0.32,
	Celebration = 0.85,
}

-- ─────────────────────────────────────────────
-- QUALITY TIERS
-- ─────────────────────────────────────────────
Palette.Quality = {
	-- Shadows is a plain label, not Enum.ShadowQuality: that enum is absent on
	-- some engine builds and referencing a missing Enum member is a compile
	-- error in Luau that pcall cannot trap. LightingService reads Shadows as
	-- the string "Low" / "Medium" / "High" and decides what to do with it.
	LOW    = { Shadows = "Low",    PostFX = false, Particles = 0.35, DynamicLights = 0,  NPCDetail = 0 },
	MEDIUM = { Shadows = "Low",    PostFX = true,  Particles = 0.65, DynamicLights = 4,  NPCDetail = 1 },
	HIGH   = { Shadows = "Medium", PostFX = true,  Particles = 1.0,  DynamicLights = 10, NPCDetail = 2 },
	ULTRA  = { Shadows = "High",   PostFX = true,  Particles = 1.0,  DynamicLights = 20, NPCDetail = 3 },
}

-- ─────────────────────────────────────────────
-- Material mapping
--
-- Builders pass a semantic name ("Road", "Wall", "Roof") and get the right
-- Enum.Material back. This is what stops the world drifting back into
-- SmoothPlastic-everything.
-- ─────────────────────────────────────────────
local MATERIAL_BY_SEMANTIC: { [string]: Enum.Material } = {
	Road = Enum.Material.Asphalt,
	Path = Enum.Material.Concrete,
	Plaza = Enum.Material.Cobblestone,
	Wall = Enum.Material.Concrete,
	WallBrick = Enum.Material.Brick,
	WallPanel = Enum.Material.Metal,
	Roof = Enum.Material.Slate,
	RoofTile = Enum.Material.RoofShingles,
	Metal = Enum.Material.Metal,
	MetalGrate = Enum.Material.DiamondPlate,
	Glass = Enum.Material.Glass,
	Fence = Enum.Material.CorrodedMetal,
	Pitch = Enum.Material.Grass,
	Terrain = Enum.Material.Ground,
	Water = Enum.Material.Glass,
	Fabric = Enum.Material.Fabric,
	Seat = Enum.Material.SmoothPlastic,
	Smooth = Enum.Material.SmoothPlastic,
	Accent = Enum.Material.Metal,
	Line = Enum.Material.SmoothPlastic,
}

--- Semantic name -> Enum.Material, with a safe default.
function Palette.material(semantic: string): Enum.Material
	return MATERIAL_BY_SEMANTIC[semantic] or Enum.Material.SmoothPlastic
end

-- ─────────────────────────────────────────────
-- brick() accessors for legacy builders
--
-- Existing builder code passes BrickColor around. Rather than rewrite every
-- call site, expose the palette as BrickColors too.
-- ─────────────────────────────────────────────
Palette.bc = brick
Palette.hex = rgb

return Palette
-- resync
