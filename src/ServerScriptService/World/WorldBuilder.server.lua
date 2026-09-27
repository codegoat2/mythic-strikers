--[[
	MythicStrikers — WorldBuilder
	Builds the football town that surrounds the arena.

	REPLACES LobbyBuilder, which produced one isolated arena slab at (0,0,600)
	connected to the stadium by a bare walkway. Past the last building there was
	simply void, which is what made the map read as a test scene rather than a
	place.

	OUTPUT
	  workspace.World
	    Ground            large terrain plane, so nothing floats in emptiness
	    Roads             avenue, cross street, stadium ring road
	    Residential       varied houses, fences, gardens, parked cars
	    Shops             shopfronts and apartment blocks
	    Park              social green with a football mural
	    StreetPitch       casual practice pitch
	    Surrounds         hill ring and treeline, so the horizon is not a cut
	  workspace.Lobby
	    Town centre hub   the player spawn: plaza, spawn ring, shops, prompts
	    (LobbyController scans this for interaction prompts and MatchService reads
	     SpawnLobby_* spawn positions from it, so the name is a contract.)

	LAYOUT — the arena owns the origin, the town wraps around its south side
	    Z = -430 ......... training complex (built by TrainingBuilder)
	    Z = -215 .. +215 . arena
	    Z = +330 ......... TOWN CENTRE  (spawn)
	    Z = +250 .. +580 . residential (west) / shops (east)
	    Z = +430 ......... street football pitch (east)
	    X = -400 .. +400 . town extent
--]]

local RunService = game:GetService("RunService")
assert(RunService:IsServer(), "WorldBuilder must run on the server.")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Palette    = require(ReplicatedStorage.Shared.Config.Palette)
local Kit        = require(script.Parent.BuildKit)

-- ─────────────────────────────────────────────
-- Layout constants
--
-- These drive both the geometry and the label positions, so the map, the
-- billboards and the roads can never disagree about where anything is.
-- ─────────────────────────────────────────────
local TOWN_Z      = 330    -- town centre / player spawn
local AVE_X       = 0      -- main avenue runs along X = 0
local RESIDENTIAL_X = -270 -- residential district centre
local SHOPS_X     = 270    -- shop district centre
local STREETPITCH = Vector3.new(300, 0, 520)
local PARK        = Vector3.new(-260, 0, 520)
local GROUND_EXTENT = 1100 -- half-size of the base ground plane

-- Plinth height. Everything in the town stands on this so roads, plazas and
-- building floors line up instead of z-fighting at slightly different Ys.
local TOWN_Y = 0.6

-- ─────────────────────────────────────────────
-- Ground
-- ─────────────────────────────────────────────

local function buildGround(world: Model)
	local g = Kit.folder("Ground", world)

	-- Base plane. Kept as one large non-colliding receiver with the terrain
	-- material; the town sits on top of it in paved / grassed bands.
	local base = Kit.box(g, "Terrain",
		Vector3.new(GROUND_EXTENT * 2, 4, GROUND_EXTENT * 2),
		CFrame.new(0, -2, 0), Palette.World.Soil, Palette.Materials.Terrain)
	base.CastShadow = false

	-- Grass field for the outlying town so the ground is not one flat brown
	-- expanse. Banded rather than tiled, which is far cheaper.
	for _, band in ipairs({
		{ c = Vector3.new(0, -0.9, 620), s = Vector3.new(900, 2, 380) },
		{ c = Vector3.new(0, -0.9, -560), s = Vector3.new(900, 2, 400) },
		{ c = Vector3.new(-700, -0.9, 0),  s = Vector3.new(400, 2, 1100) },
		{ c = Vector3.new(700, -0.9, 0),   s = Vector3.new(400, 2, 1100) },
	}) do
		local p = Kit.box(g, "GrassBand", band.s, CFrame.new(band.c),
			Palette.World.Grass, Palette.Materials.Grass)
		p.CastShadow = false
	end

	-- Town plateau: a raised paved/grass pad the whole town sits on. This is
	-- what gives the town a level datum instead of everything hugging y=0.
	Kit.box(g, "TownPlateau", Vector3.new(920, TOWN_Y * 2, 760),
		CFrame.new(0, TOWN_Y - TOWN_Y, 380), Palette.World.GrassLight, Palette.Materials.Grass)
end

-- ─────────────────────────────────────────────
-- Roads
-- ─────────────────────────────────────────────

local function buildRoads(world: Model)
	local r = Kit.folder("Roads", world)
	local y = TOWN_Y

	-- Main avenue: arena south gate -> town centre -> out of town north.
	Kit.road(r, "Avenue", Vector3.new(0, y, 200), Vector3.new(0, y, 900), 34, { line = true })
	-- Cross street through town centre, east-west.
	Kit.road(r, "CrossStreet", Vector3.new(-460, y, TOWN_Z), Vector3.new(460, y, TOWN_Z), 28,
		{ line = true, kerb = true })
	-- Stadium ring road: connects the four arena gates to the avenue, so the
	-- stadium is reachable on foot from the town.
	Kit.road(r, "RingNorth", Vector3.new(-360, y, -300), Vector3.new(360, y, -300), 26, { line = true })
	Kit.road(r, "RingWest", Vector3.new(-360, y, -300), Vector3.new(-360, y, 480), 26, { line = true })
	Kit.road(r, "RingEast", Vector3.new(360, y, -300), Vector3.new(360, y, 480), 26, { line = true })
	-- Connector between ring road and town centre.
	Kit.road(r, "LinkSouth", Vector3.new(0, y, 220), Vector3.new(0, y, TOWN_Z), 34, { line = true })

	-- Pavements down both sides of the avenue and the cross street.
	Kit.pavement(r, "AvenueWalkW", Vector3.new(-24, y, 200), Vector3.new(-24, y, 900), 9)
	Kit.pavement(r, "AvenueWalkE", Vector3.new(24, y, 200), Vector3.new(24, y, 900), 9)
	Kit.pavement(r, "CrossWalkN", Vector3.new(-460, y, TOWN_Z + 21), Vector3.new(460, y, TOWN_Z + 21), 8)
	Kit.pavement(r, "CrossWalkS", Vector3.new(-460, y, TOWN_Z - 21), Vector3.new(460, y, TOWN_Z - 21), 8)

	-- Streetlights down the avenue, spaced, alternating sides.
	for i = 0, 9 do
		local z = 250 + i * 68
		local side = if i % 2 == 0 then -1 else 1
		Kit.streetlight(r, "AvenueLamp" .. i,
			Vector3.new(side * 21, y, z), if side < 0 then 0 else math.pi, i % 3 == 0)
	end
	for i = 0, 6 do
		local x = -420 + i * 140
		Kit.streetlight(r, "CrossLamp" .. i, Vector3.new(x, y, TOWN_Z + 18), math.pi, i % 2 == 0)
		Kit.streetlight(r, "CrossLampS" .. i, Vector3.new(x, y, TOWN_Z - 18), 0, false)
	end
end

-- ─────────────────────────────────────────────
-- Street details
--
-- Traffic lights, bus stops and extra street furniture that make the roads
-- read as real infrastructure rather than coloured strips.
-- ─────────────────────────────────────────────

local function buildStreetDetails(world: Model)
	-- Disabled until the Color3-nil crash is fixed.
end

-- ─────────────────────────────────────────────
-- Building placement helper
--
-- Buildings are placed along a street frontage facing the road, which is what
-- stops the town reading as scattered boxes on a lawn.
-- ─────────────────────────────────────────────

local function faceTowards(from: Vector3, to: Vector3): number
	return math.atan2(to.X - from.X, to.Z - from.Z)
end

-- ─────────────────────────────────────────────
-- Residential
-- ─────────────────────────────────────────────

local WALLS = {
	Palette.World.RenderWarm, Palette.World.RenderCool, Palette.World.Plaster,
	Palette.World.BrickRed, Palette.World.BrickSand, Palette.World.ConcreteLight,
}
local ROOFS = {
	Palette.World.TileRoof, Palette.World.TileRoofAlt, Palette.World.MetalDark,
	Palette.World.BrickSand,
}
local ROOF_STYLES = {
	Kit.RoofStyle.GABLED, Kit.RoofStyle.HIP, Kit.RoofStyle.FLAT, Kit.RoofStyle.SHED,
}

local function buildResidential(world: Model)
	local d = Kit.folder("Residential", world)
	local y = TOWN_Y

	-- Two rows of houses either side of a residential street, fronting it.
	-- Each gets its own seed so width, height, roof and colour all differ.
	local streetZ = 420
	local count = 9

	for side = 0, 1 do
		local sx = if side == 0 then -1 else 1
		for i = 0, count - 1 do
			local key = string.format("House_%d_%d", side, i)
			local rng = Kit.seedFor(key)

			local z = streetZ - 200 + i * 50
			local x = RESIDENTIAL_X + sx * (34 + rng:NextNumber() * 12)

			-- Face the road.
			local rot = faceTowards(Vector3.new(x, y, z), Vector3.new(RESIDENTIAL_X, y, streetZ))
			local w = rng:NextInteger(18, 30)
			local dp = rng:NextInteger(16, 24)
			local floors = rng:NextInteger(1, 3)

			Kit.building({
				parent = d,
				origin = Vector3.new(x, y, z),
				width = w, depth = dp, floors = floors,
				rotY = rot,
				wallColor = WALLS[rng:NextInteger(1, #WALLS)],
				trimColor = Palette.World.OffWhite,
				roofStyle = ROOF_STYLES[rng:NextInteger(1, #ROOF_STYLES)],
				roofColor = ROOFS[rng:NextInteger(1, #ROOFS)],
				material = if rng:NextNumber() < 0.3
					then Palette.Materials.WallBrick else Palette.Materials.Wall,
				shopfront = false,
				balcony = floors >= 2 and rng:NextNumber() < 0.6,
				acUnits = true,
				downpipe = true,
				litRatio = 0.35,
				seed = key,
			})

			-- Front garden strip: hedge, a tree, a mailbox on the pavement edge.
			local gx = x + sx * (dp / 2 + 6)
			Kit.bush(d, key .. "_Hedge", Vector3.new(gx, y, z - 8), 1.1, key .. "H")
			Kit.bush(d, key .. "_Hedge2", Vector3.new(gx, y, z + 8), 1.1, key .. "H2")
			Kit.tree(d, key .. "_Garden", Vector3.new(gx + sx * 5, y, z + 14), 0.9, key .. "T")
			Kit.mailbox(d, key .. "_Mail", Vector3.new(x - sx * (w / 2 - 4), y, z + 16), rot)

			-- Driveway and a parked car on roughly half the houses.
			if rng:NextNumber() < 0.55 then
				local cz = z + (w / 2 + 6)
				Kit.trim(d, key .. "_Drive", Vector3.new(9, 0.3, 14),
					CFrame.new(x + sx * (w / 2 + 8), y + 0.15, cz), Palette.World.ConcreteDark,
					Palette.Materials.Road)
				local carColors = {
					Palette.World.DeepBlue, Palette.World.OffWhite,
					Palette.World.Charcoal, Palette.World.SteelBlue, Palette.World.WoodDark,
				}
				Kit.vehicle(d, key .. "_Car",
					Vector3.new(x + sx * (w / 2 + 8), y + 0.3, cz),
					faceTowards(Vector3.new(x, y, cz), Vector3.new(x, y, streetZ)),
					carColors[rng:NextInteger(1, #carColors)])
			end

			-- Side boundary fence, alternating sides so the street is not a wall.
			if i % 2 == 0 then
				Kit.fence(d, key .. "_Fence",
					Vector3.new(x + sx * (w / 2 + 2), y, z + dp / 2 + 3),
					Vector3.new(x + sx * (w / 2 + 2), y, z + dp / 2 + 34),
					4, { mesh = true })
			end
		end
	end

	-- Street trees and a couple of benches along the residential street.
	for i = 0, 6 do
		Kit.tree(d, "ResStreetTree" .. i,
			Vector3.new(RESIDENTIAL_X - 14, y, streetZ - 210 + i * 70), nil, "RT" .. i)
	end
	for i = 0, 2 do
		Kit.bench(d, "ResBench" .. i,
			Vector3.new(RESIDENTIAL_X + 12, y, streetZ - 120 + i * 140), math.pi / 2)
	end

	-- An apartment block at the end of the street: taller, so the district has
	-- a silhouette rather than being uniformly low.
	Kit.building({
		parent = d,
		origin = Vector3.new(RESIDENTIAL_X - 40, y, streetZ + 210),
		width = 44, depth = 30, floors = 6, floorHeight = 10,
		rotY = 0,
		wallColor = Palette.World.ConcreteLight,
		trimColor = Palette.World.Navy,
		roofStyle = Kit.RoofStyle.FLAT,
		roofColor = Palette.World.ConcreteDark,
		material = Palette.Materials.Wall,
		balcony = true, acUnits = true, downpipe = true, litRatio = 0.4,
		seed = "Apartments_A",
	})
	Kit.sign(d, "Apartments_Sign", Vector3.new(RESIDENTIAL_X - 40, y + 8, streetZ + 194),
		0, 26, 6, "HARBOUR VIEW", { textColor = Palette.World.White })
end

-- ─────────────────────────────────────────────
-- Skyline
--
-- Taller buildings that give the town a skyline instead of a uniform
-- two-storey roofscape. They sit along the avenue, north of the town centre,
-- so the stadium silhouette is never occluded.
-- ─────────────────────────────────────────────

local SKYLINE_WALLS = {
	Palette.World.Concrete, Palette.World.ConcreteLight, Palette.World.Plaster,
	Palette.World.RenderCool, Palette.World.Navy,
}
local SKYLINE_ROOFS = {
	Palette.World.MetalDark, Palette.World.ConcreteDark, Palette.World.TileRoof,
}

local function buildSkyline(world: Model)
	local d = Kit.folder("Skyline", world)
	local y = TOWN_Y
	local rng = Kit.seedFor("skyline")

	local positions = {
		{ x = -180, z = 180, w = 38, d = 32, floors = 12 },
		{ x = -120, z = 160, w = 42, d = 28, floors = 10 },
		{ x =  -60, z = 190, w = 34, d = 36, floors = 14 },
		{ x =   60, z = 175, w = 40, d = 30, floors = 11 },
		{ x =  120, z = 155, w = 36, d = 34, floors = 13 },
		{ x =  180, z = 185, w = 44, d = 26, floors = 9  },
	}

	for i, def in ipairs(positions) do
		local key = "Sky_" .. i
		local rot = faceTowards(Vector3.new(def.x, y, def.z), Vector3.new(0, y, 200))
		Kit.building({
			parent = d,
			origin = Vector3.new(def.x, y, def.z),
			width = def.w, depth = def.d, floors = def.floors,
			floorHeight = 9,
			rotY = rot,
			wallColor = SKYLINE_WALLS[rng:NextInteger(1, #SKYLINE_WALLS)],
			trimColor = Palette.World.OffWhite,
			roofStyle = i % 3 == 0 and Kit.RoofStyle.FLAT or Kit.RoofStyle.HIP,
			roofColor = SKYLINE_ROOFS[rng:NextInteger(1, #SKYLINE_ROOFS)],
			material = Palette.Materials.Wall,
			balcony = def.floors >= 12 and rng:NextNumber() < 0.5,
			acUnits = true, downpipe = true, litRatio = 0.55,
			seed = key,
		})
		Kit.sign(d, key .. "_Sign",
			Vector3.new(def.x, y + def.floors * 9 * 0.5, def.z),
			rot, def.w - 10, 3.5,
			string.format("TOWER %d", i),
			{ textColor = Palette.World.White, bg = Palette.World.Navy })
	end

	-- Rooftop garden / helipad markers on the two tallest towers.
	for _, idx in ipairs({ 3, 5 }) do
		local def = positions[idx]
		local topY = y + def.floors * 9 + 1.5
		Kit.trim(d, "SkyPad_" .. idx, Vector3.new(def.w * 0.6, 0.4, def.d * 0.6),
			CFrame.new(def.x, topY, def.z), Palette.World.ConcreteDark,
			Palette.Materials.Path)
		Kit.trim(d, "SkyH_" .. idx, Vector3.new(6, 2.2, 2.2),
			CFrame.new(def.x, topY + 2.5, def.z), Palette.World.MetalLight,
			Palette.Materials.Metal)
	end
end

-- ─────────────────────────────────────────────
-- Shops
-- ─────────────────────────────────────────────

local SHOP_NAMES = {
	{ "KIT & BOOT", "GearShop" },
	{ "ARCANE ARTS", "TechniqueShop" },
	{ "AURA CO.", "AuraShop" },
	{ "MATCH DAY CAFE", "Canteen" },
	{ "THE TACKLE SHOP", "GearShop" },
	{ "STRIKER FITNESS", "GearShop" },
}

local function buildShops(world: Model)
	local d = Kit.folder("Shops", world)
	local y = TOWN_Y
	local streetZ = 400

	for i, def in ipairs(SHOP_NAMES) do
		local key = "Shop_" .. i
		local rng = Kit.seedFor(key)
		-- Line the shops up along the east side of the cross street, facing it.
		local x = SHOPS_X - 120 + (i - 1) % 3 * 62
		local z = streetZ + 40 + math.floor((i - 1) / 3) * 70
		local rot = faceTowards(Vector3.new(x, y, z), Vector3.new(x, y, streetZ))

		Kit.building({
			parent = d,
			origin = Vector3.new(x, y, z),
			width = rng:NextInteger(34, 48), depth = 26, floors = 2,
			rotY = rot,
			wallColor = WALLS[(i % #WALLS) + 1],
			trimColor = Palette.World.OffWhite,
			roofStyle = Kit.RoofStyle.FLAT,
			roofColor = Palette.World.ConcreteDark,
			material = Palette.Materials.Wall,
			shopfront = true,
			acUnits = true, downpipe = false, litRatio = 0.5,
			seed = key,
		})

		-- Shop signage above the awning.
		local signPos = Vector3.new(x, y, z) + (CFrame.Angles(0, rot, 0) * Vector3.new(0, 0, -14))
		local signAccent = i % 2 == 0 and Palette.Teams.A.Primary or Palette.Teams.B.Primary
		Kit.sign(d, key .. "_Sign", Vector3.new(signPos.X, y + 9.5, signPos.Z),
			rot, 24, 5, def[1],
			{ textColor = signAccent, bg = Palette.World.ConcreteDark })

		-- Interaction pad under the awning.
		local padCf = CFrame.new(Vector3.new(x, y, z)) * CFrame.Angles(0, rot, 0)
		local pad = Kit.trim(d, key .. "_Pad", Vector3.new(6, 1, 4),
			padCf * CFrame.new(0, 0.6, -20), Palette.World.MetalLight, Palette.Materials.Metal)
		pad.Transparency = 0.45
		Kit.prompt(pad, def[2], "Browse", def[1], 10)
		Kit.billboard(pad, def[1], Vector3.new(0, 7, 0), Palette.UI.Text, { maxDistance = 70 })
	end

	-- A gym / academy building: the training-advertising landmark.
	Kit.building({
		parent = d,
		origin = Vector3.new(SHOPS_X + 60, y, streetZ - 90),
		width = 52, depth = 34, floors = 2, floorHeight = 13,
		rotY = math.rad(180),
		wallColor = Palette.World.Concrete,
		trimColor = Palette.Teams.A.Trim,
		roofStyle = Kit.RoofStyle.FLAT,
		roofColor = Palette.World.MetalDark,
		material = Palette.Materials.Wall,
		acUnits = true, downpipe = true, litRatio = 0.45,
		seed = "Academy",
	})
	Kit.sign(d, "Academy_Sign", Vector3.new(SHOPS_X + 60, y + 11, streetZ - 107),
		math.rad(180), 34, 5, "STRIKER ACADEMY",
		{ textColor = Palette.Teams.A.Primary, bg = Palette.World.ConcreteDark })
	-- Training posters: football culture, placed on the academy flank.
	for i = 0, 2 do
		Kit.banner(d, "Academy_Poster" .. i,
			Vector3.new(SHOPS_X + 33, y + 8, streetZ - 110 + i * 20),
			math.rad(90), 9, 12, Palette.Teams.A.Deep)
	end

	-- Street furniture along the shop frontage.
	for i = 0, 4 do
		Kit.streetlight(d, "ShopLamp" .. i, Vector3.new(SHOPS_X - 140 + i * 70, y, streetZ + 16), math.pi, i % 2 == 0)
	end
	for i = 0, 3 do
		Kit.litterBin(d, "ShopBin" .. i, Vector3.new(SHOPS_X - 120 + i * 60, y, streetZ + 20))
	end
	Kit.vendingMachine(d, "ShopVend", Vector3.new(SHOPS_X - 96, y, streetZ + 19), 0, Palette.Teams.A.Primary)
	Kit.vendingMachine(d, "ShopVend2", Vector3.new(SHOPS_X + 26, y, streetZ + 19), 0, Palette.Teams.B.Primary)
end

-- ─────────────────────────────────────────────
-- Park + football mural
-- ─────────────────────────────────────────────

local function buildPark(world: Model)
	local d = Kit.folder("Park", world)
	local y = TOWN_Y
	local c = PARK

	-- Mown lawn, deliberately not flat colour: two tones in bands.
	for i = 0, 3 do
		Kit.trim(d, "ParkLawn" .. i, Vector3.new(200, 0.4, 42),
			CFrame.new(c.X, y + 0.2, c.Z - 63 + i * 42),
			if i % 2 == 0 then Palette.World.Grass else Palette.World.GrassLight,
			Palette.Materials.Pitch)
	end

	-- Path through the park.
	Kit.trim(d, "ParkPath", Vector3.new(200, 0.5, 12),
		CFrame.new(c.X, y + 0.4, c.Z), Palette.World.Pavement, Palette.Materials.Path)

	-- Trees around the edge, benches facing in.
	for i = 0, 9 do
		local t = i / 9
		local px = c.X - 90 + t * 180
		local pz = if i % 2 == 0 then c.Z - 74 else c.Z + 74
		Kit.tree(d, "ParkTree" .. i, Vector3.new(px, y, pz), nil, "PT" .. i)
	end
	for i = 0, 3 do
		Kit.bench(d, "ParkBench" .. i, Vector3.new(c.X - 66 + i * 44, y, c.Z - 10), 0)
		Kit.bench(d, "ParkBenchB" .. i, Vector3.new(c.X - 66 + i * 44, y, c.Z + 10), math.pi)
	end
	for i = 0, 3 do
		Kit.litterBin(d, "ParkBin" .. i, Vector3.new(c.X - 50 + i * 34, y, c.Z - 6))
	end

	-- Football mural wall: the park's identity. A painted pitch-and-shield
	-- motif in house colours, made of flat parts rather than a texture.
	local wallZ = c.Z - 86
	Kit.trim(d, "MuralWall", Vector3.new(90, 20, 1.5),
		CFrame.new(c.X, y + 10, wallZ), Palette.World.ConcreteLight, Palette.Materials.Wall)
	Kit.trim(d, "MuralStripeA", Vector3.new(90, 5, 0.4),
		CFrame.new(c.X, y + 15, wallZ + 0.9), Palette.Teams.A.Primary, Palette.Materials.Smooth)
	Kit.trim(d, "MuralStripeB", Vector3.new(90, 5, 0.4),
		CFrame.new(c.X, y + 9, wallZ + 0.9), Palette.Teams.B.Primary, Palette.Materials.Smooth)
	-- Centre circle motif
	for i = 0, 15 do
		local a = (i / 16) * math.pi * 2
		Kit.trim(d, "MuralCircle" .. i, Vector3.new(1.6, 1.6, 0.4),
			CFrame.new(c.X + math.cos(a) * 12, y + 12, wallZ + 0.9)
				* CFrame.Angles(0, 0, a),
			Palette.World.White, Palette.Materials.Smooth)
	end
	local muralBall = Kit.trim(d, "MuralBall", Vector3.new(9, 9, 0.6),
		CFrame.new(c.X, y + 12, wallZ + 1.0), Palette.World.White, Palette.Materials.Smooth)
	muralBall.Shape = Enum.PartType.Ball
	Kit.surfaceText(d:FindFirstChild("MuralWall"), "MYTHIC STRIKERS", Enum.NormalId.Front,
		Palette.World.White, 96, Palette.Type.Display)

	-- Pavilion: small social building at the park edge.
	Kit.building({
		parent = d,
		origin = Vector3.new(c.X - 60, y, c.Z + 60),
		width = 26, depth = 18, floors = 1, floorHeight = 10,
		rotY = 0,
		wallColor = Palette.World.Plaster,
		trimColor = Palette.World.Wood,
		roofStyle = Kit.RoofStyle.GABLED,
		roofColor = Palette.World.TileRoof,
		material = Palette.Materials.WallWood,
		acUnits = false, downpipe = true, litRatio = 0.5,
		seed = "Pavilion",
	})
end

-- ─────────────────────────────────────────────
-- Street football
--
-- A compact hard pitch where players can practise without entering the arena.
-- Cheap to build, and it is the answer to "where do I go to just play?".
-- ─────────────────────────────────────────────

local function buildStreetPitch(world: Model)
	local d = Kit.folder("StreetPitch", world)
	local c = STREETPITCH
	local y = TOWN_Y
	local W, L = 60, 40

	-- Hard court surface
	Kit.trim(d, "Court", Vector3.new(W + 12, 0.6, L + 12),
		CFrame.new(c.X, y + 0.3, c.Z), Palette.World.ConcreteDark, Palette.Materials.Path)
	Kit.trim(d, "CourtInlay", Vector3.new(W + 6, 0.2, L + 6),
		CFrame.new(c.X, y + 0.65, c.Z), Palette.World.Concrete, Palette.Materials.Path)

	-- Compact markings
	Kit.pitchMarkings(d, "CourtMarkings", Vector3.new(c.X, y + 0.6, c.Z), W, L, {
		circleR = 9, penW = 22, penD = 12, goalW = 12, goalD = 6,
	})

	-- Two goals, smaller than arena goals
	Kit.goal(d, "CourtGoalA", Vector3.new(c.X, y + 0.6, c.Z - L / 2), -1, 12, 7, 3,
		Palette.Teams.A.Primary)
	Kit.goal(d, "CourtGoalB", Vector3.new(c.X, y + 0.6, c.Z + L / 2), 1, 12, 7, 3,
		Palette.Teams.B.Primary)

	-- Perimeter fence with a gate gap on the road side
	Kit.fence(d, "CourtFenceW", Vector3.new(c.X - W / 2 - 6, y, c.Z - L / 2 - 6),
		Vector3.new(c.X - W / 2 - 6, y, c.Z + L / 2 + 6), 8, { mesh = true })
	Kit.fence(d, "CourtFenceE", Vector3.new(c.X + W / 2 + 6, y, c.Z - L / 2 - 6),
		Vector3.new(c.X + W / 2 + 6, y, c.Z + L / 2 + 6), 8, { mesh = true })
	Kit.fence(d, "CourtFenceN", Vector3.new(c.X - W / 2 - 6, y, c.Z - L / 2 - 6),
		Vector3.new(c.X + W / 2 + 6, y, c.Z + L / 2 - 6), 8, { mesh = true })
	Kit.fence(d, "CourtFenceS1", Vector3.new(c.X - W / 2 - 6, y, c.Z + L / 2 + 6),
		Vector3.new(c.X - 6, y, c.Z + L / 2 + 6), 8, { mesh = true })
	Kit.fence(d, "CourtFenceS2", Vector3.new(c.X + 6, y, c.Z + L / 2 + 6),
		Vector3.new(c.X + W / 2 + 6, y, c.Z + L / 2 + 6), 8, { mesh = true })

	-- Four floodlights on short poles
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local p = Vector3.new(c.X + sx * (W / 2 + 6), y, c.Z + sz * (L / 2 + 6))
			Kit.trim(d, "CourtPole" .. sx .. sz, Vector3.new(0.9, 22, 0.9),
				CFrame.new(p.X, p.Y + 11, p.Z), Palette.World.MetalDark, Palette.Materials.Metal)
			Kit.trim(d, "CourtHead" .. sx .. sz, Vector3.new(4, 1.2, 2),
				CFrame.new(p.X, p.Y + 22.5, p.Z), Palette.World.MetalLight, Palette.Materials.Metal)
			Kit.trim(d, "CourtLens" .. sx .. sz, Vector3.new(3.4, 0.4, 1.4),
				CFrame.new(p.X, p.Y + 21.7, p.Z), Palette.World.OffWhite,
				Palette.Materials.Metal).Transparency = 0.2
		end
	end

	-- Benches and a couple of stray balls: the pitch looks used.
	for _, s in ipairs({ -1, 1 }) do
		Kit.bench(d, "CourtBench" .. s, Vector3.new(c.X, y, c.Z + s * (L / 2 + 9)), s > 0 and math.pi or 0)
	end
	Kit.trim(d, "CourtBall1", Vector3.new(2.4, 2.4, 2.4),
		CFrame.new(c.X - 18, y + 1.3, c.Z - 12), Palette.World.White,
		Palette.Materials.Smooth).Shape = Enum.PartType.Ball
	Kit.trim(d, "CourtBall2", Vector3.new(2.4, 2.4, 2.4),
		CFrame.new(c.X + 21, y + 1.3, c.Z + 9), Palette.World.White,
		Palette.Materials.Smooth).Shape = Enum.PartType.Ball

	Kit.sign(d, "CourtSign", Vector3.new(c.X, y + 6, c.Z - L / 2 - 12), 0, 24, 4,
		"PICK-UP GAME", { textColor = Palette.World.White, bg = Palette.World.Navy, post = true, postHeight = 6 })
end

-- ─────────────────────────────────────────────
-- Surrounds
--
-- A ring of hills and a treeline. Without these the world simply stops at the
-- last building, which is the single clearest "this map is not finished" cue.
-- ─────────────────────────────────────────────

local function buildSurrounds(world: Model)
	local d = Kit.folder("Surrounds", world)
	local rng = Kit.seedFor("surrounds")
	local inner = 620
	local count = 34

	for i = 0, count - 1 do
		local a = (i / count) * math.pi * 2
		-- Skip the arena side so hills do not block the stadium silhouette.
		if math.abs(a - math.pi / 2) > 0.42 then
			local dist = inner + rng:NextNumber() * 380
			local h = 40 + rng:NextNumber() * 110
			local w = 200 + rng:NextNumber() * 260
			local p = Vector3.new(math.cos(a) * dist, -2, math.sin(a) * dist)
			local hill = Kit.box(d, "Hill" .. i, Vector3.new(w, h, w * 0.8),
				CFrame.new(p.X, p.Y + h / 2, p.Z), Palette.World.GrassDark,
				Palette.Materials.Terrain)
			hill.CastShadow = false
			hill.CanCollide = false

			-- Treeline on the near side of each hill
			local trees = 2 + rng:NextInteger(0, 3)
			for t = 1, trees do
				local ta = a + (rng:NextNumber() - 0.5) * 0.14
				local td = dist - w * 0.45 - rng:NextNumber() * 40
				Kit.tree(d, string.format("HillTree_%d_%d", i, t),
					Vector3.new(math.cos(ta) * td, 0, math.sin(ta) * td),
					1.4, string.format("HT%d_%d", i, t))
			end
		end
	end
end

-- ─────────────────────────────────────────────
-- Town centre  (workspace.Lobby)
--
-- This is the player's home. It is a Model named "Lobby" because
-- LobbyController scans it for interaction prompts and MatchService reads
-- SpawnLobby_* spawn positions from it.
-- ─────────────────────────────────────────────

local function buildTownCentre(): Model
	local existing = workspace:FindFirstChild("Lobby")
	if existing then existing:Destroy() end

	local lobby = Instance.new("Model")
	lobby.Name = "Lobby"
	lobby.Parent = workspace

	local y = TOWN_Y
	local c = Vector3.new(AVE_X, y, TOWN_Z)

	local g = Kit.folder("TownCentre", lobby)

	-- ── Plaza paving: concentric bands, not one flat disc ────────────────
	for i = 0, 5 do
		local r = 66 - i * 11
		Kit.trim(g, "PlazaRing" .. i, Vector3.new(r * 2, 0.5, r * 2),
			CFrame.new(c.X, y + 0.25, c.Z),
			if i % 2 == 0 then Palette.World.Pavement else Palette.World.ConcreteLight,
			Palette.Materials.Path)
	end
	-- Paved apron blending the plaza into the avenue and cross street
	Kit.trim(g, "PlazaApron", Vector3.new(170, 0.5, 170),
		CFrame.new(c.X, y + 0.2, c.Z), Palette.World.Concrete, Palette.Materials.Path)

	-- ── Centrepiece landmark: a ball on a plinth ─────────────────────────
	-- The town's identity object. Football as civic monument, not decoration.
	Kit.trim(g, "Monument_Plinth", Vector3.new(16, 3, 16),
		CFrame.new(c.X, y + 1.5, c.Z), Palette.World.ConcreteDark, Palette.Materials.Path)
	Kit.trim(g, "Monument_Step", Vector3.new(22, 1, 22),
		CFrame.new(c.X, y + 0.5, c.Z), Palette.World.ConcreteLight, Palette.Materials.Path)
	Kit.trim(g, "Monument_Column", Vector3.new(6, 16, 6),
		CFrame.new(c.X, y + 11, c.Z), Palette.World.ConcreteLight, Palette.Materials.Wall)
	Kit.trim(g, "Monument_Cap", Vector3.new(8, 1.4, 8),
		CFrame.new(c.X, y + 19.5, c.Z), Palette.World.MetalLight, Palette.Materials.Metal)
	local ball = Kit.trim(g, "Monument_Ball", Vector3.new(11, 11, 11),
		CFrame.new(c.X, y + 26, c.Z), Palette.World.White, Palette.Materials.Smooth)
	ball.Shape = Enum.PartType.Ball
	-- Panel marks, so it reads as a football and not a white sphere
	for _, n in ipairs({
		Vector3.new(4.5, 0, 0), Vector3.new(-4.5, 0, 0), Vector3.new(0, 4.5, 0),
		Vector3.new(0, -4.5, 0), Vector3.new(0, 0, 4.5), Vector3.new(0, 0, -4.5),
	}) do
		local p = Kit.trim(g, "Monument_Panel", Vector3.new(3.2, 3.2, 1),
			CFrame.new(c.X, y + 26, c.Z) * CFrame.new(n) * CFrame.Angles(
				math.atan2(n.Y, math.sqrt(n.X * n.X + n.Z * n.Z)), 0, 0),
			Palette.World.Charcoal, Palette.Materials.Smooth)
		p.Transparency = 0.15
	end
	-- A single controlled accent: the monument glows faintly. It is a landmark,
	-- which is one of the four sanctioned uses of supernatural colour.
	Kit.trim(g, "Monument_Glow", Vector3.new(14, 14, 14),
		CFrame.new(c.X, y + 26, c.Z), Palette.World.MetalLight,
		Palette.Materials.Metal).Transparency = 0.85
	Kit.billboard(g:FindFirstChild("Monument_Plinth"), "MYTHIC STRIKERS",
		Vector3.new(0, 22, 0), Palette.World.White, { maxDistance = 120 })

	-- ── Plaza fountain ───────────────────────────────────────────────────
	-- A circular water feature between the monument and the spawn ring. Water
	-- is a translucent blue trim; the jet is a thin metal cylinder that pulses
	-- via a Tween at runtime (LobbyController owns the tween loop).
	local fY = y + 0.6
	Kit.trim(g, "Fountain_Base", Vector3.new(18, 0.8, 18),
		CFrame.new(c.X + 30, fY, c.Z), Palette.World.ConcreteDark, Palette.Materials.Path)
	Kit.trim(g, "Fountain_Water", Vector3.new(14, 0.25, 14),
		CFrame.new(c.X + 30, fY + 0.7, c.Z), Palette.World.DeepBlue,
		Palette.Materials.Glass).Transparency = 0.35
	Kit.trim(g, "Fountain_Jet", Vector3.new(1.2, 7, 1.2),
		CFrame.new(c.X + 30, fY + 5.5, c.Z), Palette.World.OffWhite,
		Palette.Materials.Metal).Transparency = 0.55
	Kit.trim(g, "Fountain_Ring", Vector3.new(20, 0.5, 20),
		CFrame.new(c.X + 30, fY + 0.55, c.Z), Palette.World.ConcreteLight,
		Palette.Materials.Path)
	for _, s in ipairs({ -1, 1 }) do
		Kit.bench(g, "FountainBench_" .. s,
			Vector3.new(c.X + 30 + s * 14, y, c.Z + 14), s < 0 and math.pi / 2 or -math.pi / 2)
	end

	-- ── Spawn ring ───────────────────────────────────────────────────────
	-- SpawnLobby_1..8. MatchService reads these for the post-match return, and
	-- ServerMain creates a SpawnLobby_0 bootstrap before this runs.
	local R = Constants.LOBBY_SPAWN_RADIUS
	for i = 1, 8 do
		local a = (i - 1) / 8 * math.pi * 2
		Kit.spawnPad(g, "SpawnLobby_" .. i,
			Vector3.new(c.X + math.cos(a) * R, y + 0.6, c.Z + math.sin(a) * R),
			Palette.Teams.Neutral.Primary, 8)
	end

	-- ── Plaza dressing ───────────────────────────────────────────────────
	for i = 0, 7 do
		local a = (i / 8) * math.pi * 2 + 0.4
		local px = c.X + math.cos(a) * 48
		local pz = c.Z + math.sin(a) * 48
		Kit.tree(g, "PlazaTree" .. i, Vector3.new(px, y, pz), nil, "PT" .. i)
		if i % 2 == 0 then
			Kit.bench(g, "PlazaBench" .. i, Vector3.new(c.X + math.cos(a + 0.4) * 38,
				y, c.Z + math.sin(a + 0.4) * 38), a + math.pi / 2)
		end
		Kit.streetlight(g, "PlazaLamp" .. i,
			Vector3.new(c.X + math.cos(a + 0.2) * 58, y, c.Z + math.sin(a + 0.2) * 58),
			a + math.pi, i % 3 == 0)
	end
	for i = 0, 3 do
		Kit.litterBin(g, "PlazaBin" .. i, Vector3.new(c.X - 30 + i * 20, y, c.Z - 30))
	end

	-- ── Town centre buildings, ringing the plaza ─────────────────────────
	-- Facing inward, so the plaza is enclosed rather than open to the horizon.
	local ringBuildings = {
		{ x = -76, z = -34, w = 40, d = 28, f = 2, name = "LOCKER ROOM",  type = "LockerRoom" },
		{ x = -30, z = -84, w = 46, d = 26, f = 2, name = "TROPHY HALL",  type = "TrophyRoom" },
		{ x =  44, z = -80, w = 38, d = 26, f = 2, name = "NOTICE BOARD", type = "NoticeBoard" },
		{ x =  88, z = -26, w = 42, d = 28, f = 3, name = "LEADERBOARD", type = "Leaderboard" },
		{ x =  84, z =  34, w = 40, d = 28, f = 2, name = "TRAINING HALL", type = "Training" },
		{ x =  32, z =  84, w = 44, d = 26, f = 2, name = "CANTEEN",      type = "Canteen" },
		{ x = -44, z =  80, w = 42, d = 26, f = 2, name = "PLAYER HOUSE", type = "PlayerHouse" },
		{ x = -90, z =  30, w = 36, d = 26, f = 2, name = "STADIUM GATE", type = "MatchPortal" },
	}
	for i, def in ipairs(ringBuildings) do
		local key = "Centre_" .. i
		local rng = Kit.seedFor(key)
		local pos = Vector3.new(c.X + def.x, y, c.Z + def.z)
		-- Face the plaza centre.
		local rot = faceTowards(pos, c)
		Kit.building({
			parent = g,
			origin = pos,
			width = def.w, depth = def.d, floors = def.f, floorHeight = 11,
			rotY = rot,
			wallColor = WALLS[(i * 2) % #WALLS + 1],
			trimColor = Palette.World.OffWhite,
			roofStyle = if i % 2 == 0 then Kit.RoofStyle.FLAT else Kit.RoofStyle.HIP,
			roofColor = ROOFS[(i % #ROOFS) + 1],
			material = Palette.Materials.Wall,
			balcony = def.f >= 3,
			acUnits = true, downpipe = true, litRatio = 0.5,
			seed = key,
		})

		-- Signage on the inward face
		local signPos = pos + (CFrame.Angles(0, rot, 0) * Vector3.new(0, 0, -(def.d / 2 + 0.6)))
		Kit.sign(g, key .. "_Sign", Vector3.new(signPos.X, y + 9.5, signPos.Z),
			rot, def.w - 12, 4.5, def.name,
			{ textColor = Palette.World.White, bg = Palette.World.Navy })

		-- Interaction pad, except the stadium gate which is its own structure
		if def.type ~= "MatchPortal" then
			local padCf = CFrame.new(pos) * CFrame.Angles(0, rot, 0)
			local pad = Kit.trim(g, key .. "_Pad", Vector3.new(6, 1, 4),
				padCf * CFrame.new(0, 0.6, -(def.d / 2 + 5)), Palette.World.MetalLight,
				Palette.Materials.Metal)
			pad.Transparency = 0.45
			Kit.prompt(pad, def.type, "Enter", def.name, 10)
		end
	end

	-- ── Stadium gate: the way back into the arena ───────────────────────
	-- A pair of turnstile blocks flanking an arch, on the avenue side.
	local gateZ = c.Z - 110
	Kit.trim(g, "GateArch_L", Vector3.new(8, 26, 8),
		CFrame.new(c.X - 22, y + 13, gateZ), Palette.World.ConcreteLight, Palette.Materials.Wall)
	Kit.trim(g, "GateArch_R", Vector3.new(8, 26, 8),
		CFrame.new(c.X + 22, y + 13, gateZ), Palette.World.ConcreteLight, Palette.Materials.Wall)
	Kit.trim(g, "GateArch_Top", Vector3.new(52, 6, 8),
		CFrame.new(c.X, y + 29, gateZ), Palette.World.ConcreteLight, Palette.Materials.Wall)
	local gateBoard = Kit.trim(g, "GateBoard", Vector3.new(46, 4.5, 0.4),
		CFrame.new(c.X, y + 29, gateZ - 4.2), Palette.Teams.A.Deep, Palette.Materials.WallPanel)
	Kit.surfaceText(gateBoard, "MYTHIC STRIKERS ARENA", Enum.NormalId.Front,
		Palette.World.White, 64, Palette.Type.Display)
	Kit.surfaceText(gateBoard, "MYTHIC STRIKERS ARENA", Enum.NormalId.Back,
		Palette.World.White, 64, Palette.Type.Display)
	Kit.sign(g, "GateSign", Vector3.new(c.X, y + 30.5, gateZ - 4.3),
		0, 44, 3.5, "ARENA",
		{ textColor = Palette.Teams.A.Primary, bg = Palette.World.MetalDark })
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(g, "GateTurnstile" .. s, Vector3.new(2, 4, 2),
			CFrame.new(c.X + s * 16, y + 2, gateZ), Palette.World.MetalDark, Palette.Materials.Metal)
	end
	-- Match entry prompt, the primary call to action in the whole town
	local gatePad = Kit.trim(g, "GatePad", Vector3.new(10, 1, 6),
		CFrame.new(c.X, y + 0.9, gateZ + 10), Palette.World.MetalLight, Palette.Materials.Metal)
	gatePad.Transparency = 0.4
	Kit.prompt(gatePad, "MatchPortal", "Enter Match Queue", "Mythic Strikers Arena", 14)
	Kit.billboard(gatePad, "ENTER MATCH", Vector3.new(0, 8, 0), Palette.World.White,
		{ maxDistance = 110 })

	-- ── Notice board + emote corner ─────────────────────────────────────
	local nb = Kit.trim(g, "NoticeBoardFace", Vector3.new(18, 12, 0.6),
		CFrame.new(c.X - 30, y + 6, c.Z - 96), Palette.World.WoodDark, Palette.Materials.WallWood)
	Kit.surfaceText(nb, "TOURNAMENT\nTHIS WEEK", Enum.NormalId.Front,
		Palette.World.White, 48, Palette.Type.Heading)
	Kit.prompt(nb, "NoticeBoard", "Read", "Notice Board", 12)

	-- ── NPC anchor points ────────────────────────────────────────────────
	-- NPCService reads these and places townsfolk around them. They are empty
	-- markers, so the population can be tuned without rebuilding the town.
	for i = 1, 24 do
		local a = (i / 24) * math.pi * 2
		local radius = 26 + (i % 4) * 12
		Kit.marker(g, string.format("NPCAnchor_%02d", i),
			Vector3.new(1, 1, 1),
			CFrame.new(c.X + math.cos(a) * radius, y, c.Z + math.sin(a) * radius))
	end

	lobby:SetAttribute("Ready", true)
	print("[WorldBuilder] Town centre built at Z=" .. tostring(TOWN_Z))
	return lobby
end

-- ─────────────────────────────────────────────
-- Run
-- ─────────────────────────────────────────────

local function buildWorld()
	local existing = workspace:FindFirstChild("World")
	if existing then existing:Destroy() end

	local world = Instance.new("Model")
	world.Name = "World"
	world.Parent = workspace

	Kit.spent = 0

	local builders = {
		{ name = "ground", fn = buildGround },
		{ name = "roads", fn = buildRoads },
		{ name = "streetDetails", fn = buildStreetDetails },
		{ name = "residential", fn = buildResidential },
		{ name = "skyline", fn = buildSkyline },
		{ name = "shops", fn = buildShops },
		{ name = "park", fn = buildPark },
		{ name = "streetPitch", fn = buildStreetPitch },
		{ name = "surrounds", fn = buildSurrounds },
		{ name = "townCentre", fn = buildTownCentre },
	}
	for _, b in ipairs(builders) do
		local ok, err = pcall(b.fn, world)
		if not ok then
			warn("[WorldBuilder] Builder '" .. b.name .. "' failed: " .. tostring(err))
			return
		end
		print("[WorldBuilder] " .. b.name .. " ok (" .. Kit.spent .. " parts)")
	end

	world:SetAttribute("Ready", true)
	print("[WorldBuilder] World built.")
	print(string.format("  Parts: %d (budget %d, %d remaining)", Kit.spent, Kit.budget, Kit.remaining()))
end

local ok, err = pcall(buildWorld)
if not ok then
	warn("[WorldBuilder] Failed to build world: " .. tostring(err))
end
