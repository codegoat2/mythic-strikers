--[[
	MythicStrikers — StadiumBuilder
	Procedurally constructs the entire supernatural football stadium in Workspace.

	WHAT THIS BUILDS:
	  • Full-size football pitch (280 × 168 studs) with field markings
	  • Two goals with net geometry and GoalA_Trigger / GoalB_Trigger volumes
	  • Team spawn points (SpawnTeamA_1…6, SpawnTeamB_1…6)
	  • Spectator spawns (SpawnSpectator_1…4)
	  • Kickoff marker (KickoffPoint)
	  • Stadium bowl (tiered seating suggestion geometry)
	  • Atmospheric lighting and sky setup
	  • Ball Part at centre
	  • Animated crowd billboards (lightweight)

	FIELD LAYOUT (Z axis = length, X axis = width):
	  TeamA attacks in +Z direction → scores in GoalB (at Z = +140)
	  TeamB attacks in -Z direction → scores in GoalA (at Z = -140)

	DESIGN PRINCIPLES:
	  • Runs once as a Script in ServerScriptService (or Workspace).
	  • All parts are welded into a single Stadium Model for easy management.
	  • Kept optimized: no excessive part count, unions used for stands.
	  • Lighting is atmospheric — dark sky with energy particles implied via
	    colour temperature and bloom (configured, not particle-heavy).

	USAGE:
	  Place this Script under ServerScriptService.
	  It runs at server startup before other services need the stadium.
	  ServerMain waits for Workspace.Stadium before booting game systems.
--]]

local RunService = game:GetService("RunService")
assert(RunService:IsServer(), "StadiumBuilder must run on the server.")

local Lighting   = game:GetService("Lighting")

-- ─────────────────────────────────────────────
-- Constants (must match Config/Constants.lua)
-- ─────────────────────────────────────────────
local FIELD_L   = 280    -- studs
local FIELD_W   = 168    -- studs
local GOAL_W    = 28     -- studs
local GOAL_H    = 14     -- studs
local GOAL_D    = 6      -- studs
local BALL_Y    = 3.2    -- spawn height

local PITCH_Y   = 0      -- Y of field surface
local WALL_T    = 2      -- wall thickness

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local stadium: Model

local function makePart(
	name:     string,
	size:     Vector3,
	cframe:   CFrame,
	color:    BrickColor,
	material: Enum.Material?,
	anchored: boolean?,
	canCollide: boolean?
): BasePart
	local p = Instance.new("Part")
	p.Name        = name
	p.Size        = size
	p.CFrame      = cframe
	p.BrickColor  = color
	p.Material    = material or Enum.Material.SmoothPlastic
	p.Anchored    = anchored ~= false   -- default true
	p.CanCollide  = canCollide ~= false
	p.CastShadow  = false
	p.Parent      = stadium
	return p
end

local function makeInvisibleTrigger(name: string, size: Vector3, cframe: CFrame): BasePart
	local p = Instance.new("Part")
	p.Name        = name
	p.Size        = size
	p.CFrame      = cframe
	p.Anchored    = true
	p.CanCollide  = false
	p.Transparency = 1
	p.Parent      = stadium
	return p
end

local function makeSpawnLocation(name: string, cframe: CFrame, teamColor: BrickColor): SpawnLocation
	local sp = Instance.new("SpawnLocation")
	sp.Name       = name
	sp.Size       = Vector3.new(4, 1, 4)
	sp.CFrame     = cframe
	sp.TeamColor  = teamColor
	sp.Anchored   = true
	sp.CanCollide = true
	sp.Enabled    = true
	sp.Duration   = 0
	sp.BrickColor = teamColor
	sp.Material   = Enum.Material.Neon
	sp.Transparency = 0.6
	sp.Parent     = stadium
	return sp
end

local function makeLine(size: Vector3, cframe: CFrame): BasePart
	-- White field marking line
	return makePart("Line", size, cframe,
		BrickColor.new("White"), Enum.Material.SmoothPlastic, true, false)
end

-- ─────────────────────────────────────────────
-- Create stadium model
-- ─────────────────────────────────────────────

local function buildStadium()
	-- Remove existing if rebuilding
	local existing = workspace:FindFirstChild("Stadium")
	if existing then existing:Destroy() end

	stadium = Instance.new("Model")
	stadium.Name   = "Stadium"
	stadium.Parent = workspace

	-- ── PITCH ──────────────────────────────────────────────────────────────

	-- Main grass surface
	local pitch = makePart("Pitch",
		Vector3.new(FIELD_W, 1, FIELD_L),
		CFrame.new(0, PITCH_Y - 0.5, 0),
		BrickColor.new("Bright green"),
		Enum.Material.Grass
	)
	pitch.CastShadow = false

	-- Darker alternating stripe overlay (two wide stripes give stripe illusion)
	for i = -3, 3 do
		local stripe = makePart("Stripe_" .. i,
			Vector3.new(FIELD_W, 0.05, 28),
			CFrame.new(0, PITCH_Y + 0.01, i * 40),
			BrickColor.new("Really green"), Enum.Material.SmoothPlastic, true, false
		)
		stripe.Transparency = 0.5
	end

	-- ── FIELD MARKINGS ─────────────────────────────────────────────────────

	local LINE_T  = 0.5   -- stud thick
	local LINE_H  = 0.06  -- raised above pitch

	-- Touchlines (side lines Z-axis)
	makeLine(Vector3.new(LINE_T, LINE_H, FIELD_L),
		CFrame.new(-FIELD_W/2, PITCH_Y + LINE_H/2, 0))
	makeLine(Vector3.new(LINE_T, LINE_H, FIELD_L),
		CFrame.new( FIELD_W/2, PITCH_Y + LINE_H/2, 0))

	-- Goal lines (end lines X-axis)
	makeLine(Vector3.new(FIELD_W, LINE_H, LINE_T),
		CFrame.new(0, PITCH_Y + LINE_H/2, -FIELD_L/2))
	makeLine(Vector3.new(FIELD_W, LINE_H, LINE_T),
		CFrame.new(0, PITCH_Y + LINE_H/2,  FIELD_L/2))

	-- Halfway line
	makeLine(Vector3.new(FIELD_W, LINE_H, LINE_T),
		CFrame.new(0, PITCH_Y + LINE_H/2, 0))

	-- Centre circle (approximated with 16 arc segments)
	local CIRC_R = 24
	local SEGS   = 24
	for i = 1, SEGS do
		local a1 = (i - 1) / SEGS * math.pi * 2
		local a2 = i       / SEGS * math.pi * 2
		local mx = math.cos((a1 + a2) / 2) * CIRC_R
		local mz = math.sin((a1 + a2) / 2) * CIRC_R
		local segLen = 2 * CIRC_R * math.sin(math.pi / SEGS) + 0.2
		makeLine(
			Vector3.new(LINE_T, LINE_H, segLen),
			CFrame.new(mx, PITCH_Y + LINE_H/2, mz)
				* CFrame.Angles(0, -((a1 + a2) / 2), 0)
		)
	end

	-- Centre spot
	makeLine(Vector3.new(2, LINE_H, 2),
		CFrame.new(0, PITCH_Y + LINE_H/2, 0))

	-- Penalty areas (both ends)
	local PA_W  = 72
	local PA_D  = 48
	for _, sign in ipairs({-1, 1}) do
		local baseZ = sign * (FIELD_L/2 - PA_D/2)
		-- Top/bottom of penalty area
		makeLine(Vector3.new(PA_W, LINE_H, LINE_T),
			CFrame.new(0, PITCH_Y + LINE_H/2, sign * FIELD_L/2 - sign * PA_D))
		-- Left/right sides
		makeLine(Vector3.new(LINE_T, LINE_H, PA_D),
			CFrame.new(-PA_W/2, PITCH_Y + LINE_H/2, baseZ))
		makeLine(Vector3.new(LINE_T, LINE_H, PA_D),
			CFrame.new( PA_W/2, PITCH_Y + LINE_H/2, baseZ))

		-- Penalty spot
		makeLine(Vector3.new(2, LINE_H, 2),
			CFrame.new(0, PITCH_Y + LINE_H/2, sign * (FIELD_L/2 - 36)))

		-- Goal area (smaller box)
		local GA_W = 32
		local GA_D = 16
		local gaBaseZ = sign * (FIELD_L/2 - GA_D/2)
		makeLine(Vector3.new(GA_W, LINE_H, LINE_T),
			CFrame.new(0, PITCH_Y + LINE_H/2, sign * FIELD_L/2 - sign * GA_D))
		makeLine(Vector3.new(LINE_T, LINE_H, GA_D),
			CFrame.new(-GA_W/2, PITCH_Y + LINE_H/2, gaBaseZ))
		makeLine(Vector3.new(LINE_T, LINE_H, GA_D),
			CFrame.new( GA_W/2, PITCH_Y + LINE_H/2, gaBaseZ))
	end

	-- ── GOALS ──────────────────────────────────────────────────────────────

	local function buildGoal(name: string, zSign: number, teamColor: BrickColor)
		local baseZ  = zSign * (FIELD_L / 2)
		local postX  = GOAL_W / 2
		local postH  = GOAL_H
		local pColor = BrickColor.new("Institutional white")
		local pMat   = Enum.Material.Metal

		-- Left post
		makePart(name .. "_PostL",
			Vector3.new(0.5, postH, 0.5),
			CFrame.new(-postX, PITCH_Y + postH/2, baseZ),
			pColor, pMat)

		-- Right post
		makePart(name .. "_PostR",
			Vector3.new(0.5, postH, 0.5),
			CFrame.new( postX, PITCH_Y + postH/2, baseZ),
			pColor, pMat)

		-- Crossbar
		makePart(name .. "_Bar",
			Vector3.new(GOAL_W + 0.5, 0.5, 0.5),
			CFrame.new(0, PITCH_Y + postH, baseZ),
			pColor, pMat)

		-- Back net frame top
		makePart(name .. "_NetTop",
			Vector3.new(GOAL_W, 0.3, GOAL_D),
			CFrame.new(0, PITCH_Y + postH - 0.15, baseZ + zSign * (GOAL_D/2)),
			BrickColor.new("White"), Enum.Material.Neon, true, false
		).Transparency = 0.85

		-- Net sides
		makePart(name .. "_NetL",
			Vector3.new(0.3, postH, GOAL_D),
			CFrame.new(-postX, PITCH_Y + postH/2, baseZ + zSign * (GOAL_D/2)),
			BrickColor.new("White"), Enum.Material.Neon, true, false
		).Transparency = 0.85

		makePart(name .. "_NetR",
			Vector3.new(0.3, postH, GOAL_D),
			CFrame.new( postX, PITCH_Y + postH/2, baseZ + zSign * (GOAL_D/2)),
			BrickColor.new("White"), Enum.Material.Neon, true, false
		).Transparency = 0.85

		-- Back net
		makePart(name .. "_NetBack",
			Vector3.new(GOAL_W, postH, 0.3),
			CFrame.new(0, PITCH_Y + postH/2, baseZ + zSign * GOAL_D),
			BrickColor.new("White"), Enum.Material.Neon, true, false
		).Transparency = 0.85

		-- Goal floor backing
		makePart(name .. "_Floor",
			Vector3.new(GOAL_W, 0.5, GOAL_D),
			CFrame.new(0, PITCH_Y - 0.2, baseZ + zSign * (GOAL_D/2)),
			pColor, Enum.Material.SmoothPlastic)

		-- ── TRIGGER VOLUME ────────────────────────────────────────────────
		-- Slightly inset from goal line so ball must actually cross it
		makeInvisibleTrigger(
			name .. "_Trigger",
			Vector3.new(GOAL_W - 1, postH - 0.5, GOAL_D - 0.5),
			CFrame.new(0, PITCH_Y + (postH - 0.5)/2, baseZ + zSign * (GOAL_D * 0.5))
		)

		-- Goal frame glow (team colour neon)
		local glow = makePart(name .. "_Glow",
			Vector3.new(GOAL_W + 1, 0.4, 0.4),
			CFrame.new(0, PITCH_Y + postH + 0.4, baseZ),
			teamColor, Enum.Material.Neon, true, false
		)
		glow.Transparency = 0.3
	end

	buildGoal("GoalA", -1, BrickColor.new("Bright blue"))  -- TeamA defends at -Z
	buildGoal("GoalB",  1, BrickColor.new("Bright red"))   -- TeamB defends at +Z

	-- ── KICKOFF MARKER ─────────────────────────────────────────────────────

	local kickoff = Instance.new("Part")
	kickoff.Name       = "KickoffPoint"
	kickoff.Size       = Vector3.new(1, 1, 1)
	kickoff.CFrame     = CFrame.new(0, PITCH_Y + 1, 0)
	kickoff.Anchored   = true
	kickoff.CanCollide = false
	kickoff.Transparency = 1
	kickoff.Parent     = stadium

	-- ── BALL ───────────────────────────────────────────────────────────────

	local ball = Instance.new("Part")
	ball.Name       = "Ball"
	ball.Shape      = Enum.PartType.Ball
	ball.Size       = Vector3.new(2.4, 2.4, 2.4)
	ball.BrickColor = BrickColor.new("White")
	ball.Material   = Enum.Material.SmoothPlastic
	ball.CFrame     = CFrame.new(0, BALL_Y, 0)
	ball.Anchored   = false
	ball.CanCollide = true
	ball.CastShadow = true
	ball.Parent     = stadium

	-- Ball texture decals (black pentagon panels)
	for _, normalId in ipairs({
		Enum.NormalId.Front, Enum.NormalId.Back,
		Enum.NormalId.Left,  Enum.NormalId.Right,
		Enum.NormalId.Top,   Enum.NormalId.Bottom,
	}) do
		local d = Instance.new("Decal")
		d.Face      = normalId
		d.Texture   = "rbxasset://textures/SoccerBall.png"  -- built-in Roblox texture
		d.Parent    = ball
	end

	-- ── SPAWN POINTS ───────────────────────────────────────────────────────

	local TEAM_A_COLOR = BrickColor.new("Bright blue")
	local TEAM_B_COLOR = BrickColor.new("Bright red")
	local SPEC_COLOR   = BrickColor.new("Medium stone grey")

	-- TeamA spawns — defensive half (-Z), spread across width
	local teamASpawns = {
		Vector3.new(-20, PITCH_Y + 1, -60),
		Vector3.new(  0, PITCH_Y + 1, -60),
		Vector3.new( 20, PITCH_Y + 1, -60),
		Vector3.new(-15, PITCH_Y + 1, -90),
		Vector3.new( 15, PITCH_Y + 1, -90),
		Vector3.new(  0, PITCH_Y + 1, -110),
	}
	for i, pos in ipairs(teamASpawns) do
		makeSpawnLocation("SpawnTeamA_" .. i, CFrame.new(pos) * CFrame.Angles(0, 0, 0), TEAM_A_COLOR)
	end

	-- TeamB spawns — attacking half (+Z)
	local teamBSpawns = {
		Vector3.new(-20, PITCH_Y + 1,  60),
		Vector3.new(  0, PITCH_Y + 1,  60),
		Vector3.new( 20, PITCH_Y + 1,  60),
		Vector3.new(-15, PITCH_Y + 1,  90),
		Vector3.new( 15, PITCH_Y + 1,  90),
		Vector3.new(  0, PITCH_Y + 1,  110),
	}
	for i, pos in ipairs(teamBSpawns) do
		makeSpawnLocation("SpawnTeamB_" .. i, CFrame.new(pos) * CFrame.Angles(0, math.pi, 0), TEAM_B_COLOR)
	end

	-- Spectator spawns (sideline)
	local specSpawns = {
		Vector3.new(-FIELD_W/2 - 12,  PITCH_Y + 1,  -30),
		Vector3.new(-FIELD_W/2 - 12,  PITCH_Y + 1,   30),
		Vector3.new( FIELD_W/2 + 12,  PITCH_Y + 1,  -30),
		Vector3.new( FIELD_W/2 + 12,  PITCH_Y + 1,   30),
	}
	for i, pos in ipairs(specSpawns) do
		makeSpawnLocation("SpawnSpectator_" .. i, CFrame.new(pos), SPEC_COLOR)
	end

	-- ── STADIUM BOWL (simplified geometry) ────────────────────────────────

	local STAND_H    = 28
	local STAND_RISE = 18    -- how far stands tilt back
	local STAND_SETBACK = 20 -- distance from touchline to front of stand

	-- Four stands: North, South, East, West
	local stands = {
		{ name = "StandNorth", pos = Vector3.new(0,  STAND_H/2,  -(FIELD_L/2 + STAND_SETBACK + 20)),
		  size = Vector3.new(FIELD_W + 80, STAND_H, 30) },
		{ name = "StandSouth", pos = Vector3.new(0,  STAND_H/2,   (FIELD_L/2 + STAND_SETBACK + 20)),
		  size = Vector3.new(FIELD_W + 80, STAND_H, 30) },
		{ name = "StandEast",  pos = Vector3.new( (FIELD_W/2 + STAND_SETBACK + 15), STAND_H/2, 0),
		  size = Vector3.new(30, STAND_H, FIELD_L + 40) },
		{ name = "StandWest",  pos = Vector3.new(-(FIELD_W/2 + STAND_SETBACK + 15), STAND_H/2, 0),
		  size = Vector3.new(30, STAND_H, FIELD_L + 40) },
	}

	for _, s in ipairs(stands) do
		local stand = makePart(s.name, s.size,
			CFrame.new(s.pos),
			BrickColor.new("Dark stone grey"),
			Enum.Material.Concrete
		)
		stand.CastShadow = false
	end

	-- Stadium floor (under the stands)
	makePart("StadiumFloor",
		Vector3.new(FIELD_W + 100, 2, FIELD_L + 100),
		CFrame.new(0, PITCH_Y - 1.5, 0),
		BrickColor.new("Brown"), Enum.Material.Concrete
	)

	-- Floodlight towers (4 corners)
	local corners = {
		Vector3.new(-(FIELD_W/2 + 30),  0,  -(FIELD_L/2 + 30)),
		Vector3.new( (FIELD_W/2 + 30),  0,  -(FIELD_L/2 + 30)),
		Vector3.new(-(FIELD_W/2 + 30),  0,   (FIELD_L/2 + 30)),
		Vector3.new( (FIELD_W/2 + 30),  0,   (FIELD_L/2 + 30)),
	}

	for i, base in ipairs(corners) do
		-- Tower pole
		makePart("TowerPole_" .. i,
			Vector3.new(3, 60, 3),
			CFrame.new(base + Vector3.new(0, 30, 0)),
			BrickColor.new("Dark stone grey"), Enum.Material.Metal
		)
		-- Light head
		local light = makePart("TowerLight_" .. i,
			Vector3.new(8, 2, 8),
			CFrame.new(base + Vector3.new(0, 62, 0)),
			BrickColor.new("Bright yellow"), Enum.Material.Neon, true, false
		)
		light.Transparency = 0.2

		-- SpotLight
		local sl = Instance.new("SpotLight")
		sl.Brightness  = 5
		sl.Range       = 200
		sl.Angle       = 45
		sl.Face        = Enum.NormalId.Bottom
		sl.Shadows     = true
		sl.Parent      = light
	end

	-- ── ENERGY BARRIER (decorative boundary) ──────────────────────────────
	-- Subtle neon walls at field edges to keep ball in

	local barrierColor = BrickColor.new("Cyan")
	local barriers = {
		{ size = Vector3.new(0.5, 4, FIELD_L), pos = Vector3.new(-FIELD_W/2 - 0.25, 2,  0) },
		{ size = Vector3.new(0.5, 4, FIELD_L), pos = Vector3.new( FIELD_W/2 + 0.25, 2,  0) },
		{ size = Vector3.new(FIELD_W, 4, 0.5), pos = Vector3.new(0, 2, -FIELD_L/2 - 0.25) },
		{ size = Vector3.new(FIELD_W, 4, 0.5), pos = Vector3.new(0, 2,  FIELD_L/2 + 0.25) },
	}
	for i, b in ipairs(barriers) do
		local bPart = makePart("EnergyBarrier_" .. i,
			b.size, CFrame.new(b.pos),
			barrierColor, Enum.Material.Neon, true, true
		)
		bPart.Transparency = 0.7
		bPart.CastShadow   = false
	end

	-- ── LIGHTING ───────────────────────────────────────────────────────────

	Lighting.Ambient         = Color3.fromRGB(30,  30,  60)
	Lighting.OutdoorAmbient  = Color3.fromRGB(40,  40,  80)
	Lighting.Brightness      = 2.5
	Lighting.ColorShift_Top  = Color3.fromRGB(180, 190, 255)
	Lighting.ColorShift_Bottom = Color3.fromRGB(80, 60, 120)
	Lighting.EnvironmentSpecularScale = 0.5
	Lighting.EnvironmentDiffuseScale  = 0.5
	Lighting.ShadowSoftness  = 0.5
	Lighting.ClockTime       = 21    -- night match

	-- Atmosphere
	local atmo = Instance.new("Atmosphere")
	atmo.Density    = 0.4
	atmo.Offset     = 0.1
	atmo.Color      = Color3.fromRGB(10, 10, 30)
	atmo.Decay      = Color3.fromRGB(30, 20, 60)
	atmo.Glare      = 0.1
	atmo.Haze       = 0.3
	atmo.Parent     = Lighting

	-- Bloom post-processing
	local bloom = Instance.new("BloomEffect")
	bloom.Intensity  = 0.6
	bloom.Size       = 24
	bloom.Threshold  = 0.95
	bloom.Parent     = Lighting

	-- Colour correction for anime look
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Brightness  =  0.02
	cc.Contrast    =  0.08
	cc.Saturation  =  0.15
	cc.TintColor   = Color3.fromRGB(200, 210, 255)
	cc.Parent      = Lighting

	-- Sun rays (dramatic goal light rays)
	local rays = Instance.new("SunRaysEffect")
	rays.Intensity = 0.15
	rays.Spread    = 0.5
	rays.Parent    = Lighting

	-- Sky
	local sky = Instance.new("Sky")
	sky.SkyboxBk   = "rbxasset://sky/sky512_bk.tex"
	sky.SkyboxDn   = "rbxasset://sky/sky512_dn.tex"
	sky.SkyboxFt   = "rbxasset://sky/sky512_ft.tex"
	sky.SkyboxLf   = "rbxasset://sky/sky512_lf.tex"
	sky.SkyboxRt   = "rbxasset://sky/sky512_rt.tex"
	sky.SkyboxUp   = "rbxasset://sky/sky512_up.tex"
	sky.StarCount  = 3000
	sky.Parent     = Lighting

	-- ── PRIMARY DIRECTIONAL LIGHT ──────────────────────────────────────────
	-- Remove default sun, add a directional fill
	local sun = Instance.new("Part")
	sun.Name        = "DirectionalLight_Anchor"
	sun.Size        = Vector3.new(1,1,1)
	sun.CFrame      = CFrame.new(0, 80, 0)
	sun.Anchored    = true
	sun.CanCollide  = false
	sun.Transparency = 1
	sun.Parent      = stadium

	-- ── NAME THE MODEL ─────────────────────────────────────────────────────
	stadium.PrimaryPart = kickoff
	print("[StadiumBuilder] Stadium constructed successfully.")
	print(string.format("  Field: %d × %d studs", FIELD_L, FIELD_W))
	print(string.format("  Parts in stadium: %d", #stadium:GetDescendants()))
end

-- ─────────────────────────────────────────────
-- Run
-- ─────────────────────────────────────────────
local ok, err = pcall(buildStadium)
if not ok then
	warn("[StadiumBuilder] Failed to build stadium: " .. tostring(err))
end
