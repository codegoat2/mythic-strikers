--[[
	MythicStrikers — StadiumBuilder
	Constructs the Mythic Strikers Arena: the visual centrepiece of the world.

	REPLACES the original blockout, which was four solid Dark-stone-grey boxes
	standing in for stands. Everything below exists to remove one of the
	prototype's symptoms:

	  • a single giant block per stand  -> tiered rake, vomitories, stairways
	  • no way in                       -> entrances, concourse, turnstiles
	  • no roof                         -> cantilever canopy on trusses
	  • no architecture                 -> tunnel, technical area, media bay
	  • no crowd                        -> populated seating
	  • no identity                     -> house colours, banners, big screen

	GAMEPLAY CONTRACT — DO NOT CHANGE THESE NAMES OR POSITIONS
	Other systems bind to this geometry by name:
	  • Ball            (BallService)
	  • KickoffPoint    (BallService)
	  • GoalA_Trigger   (BallService goal detection; TeamA defends -Z)
	  • GoalB_Trigger   (TeamB defends +Z)
	  • SpawnTeamA_1..6 (TeamService)
	  • SpawnTeamB_1..6
	  • SpawnSpectator_1..4
	Field dimensions come from Shared.Config.Constants so the pitch cannot
	drift out of sync with the ball and match logic.

	LAYOUT (centred on origin, pitch surface at y = 0)
	    Z = -140 ......... GoalA end (Team A defends)
	    Z =   0 ......... centre circle
	    Z = +140 ......... GoalB end (Team B defends)
	    X = -84 ......... touchline W      X = +84 ......... touchline E

	    pitch -> run-off -> ad boards -> walkway -> stand rake
	         84        92         93        104        outward
--]]

local RunService = game:GetService("RunService")
assert(RunService:IsServer(), "StadiumBuilder must run on the server.")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Palette    = require(ReplicatedStorage.Shared.Config.Palette)
local Kit        = require(script.Parent.BuildKit)
local AssetRegistry = require(ReplicatedStorage.Shared.Config.AssetRegistry)

-- ─────────────────────────────────────────────
-- Geometry constants
-- ─────────────────────────────────────────────
local FL = Constants.FIELD_LENGTH   -- 280 (Z)
local FW = Constants.FIELD_WIDTH    -- 168 (X)
local GW = Constants.GOAL_WIDTH     -- 28
local GH = Constants.GOAL_HEIGHT    -- 14
local GD = Constants.GOAL_DEPTH      -- 6

local PITCH_Y   = 0
local HALF_L    = FL / 2
local HALF_W    = FW / 2

-- Distance from pitch edge outward to each successive band.
local RUNOFF    = 8     -- grass apron
local ADBOARD_Z = 1.2   -- ad board sits just past the apron
local WALKWAY   = 11    -- walkway width between ad boards and stand rake
local STAND_GAP = 1.0   -- small gap so the rake does not touch the walkway

-- Stand rake.
local ROWS      = 16
local RISE      = 2.1   -- vertical per row
local RUN       = 3.0   -- depth per row
local VOM_W     = 12    -- width of a vomitory (stairway gap)

-- How much of the bowl gets crowd figures. Filling every seat costs thousands
-- of parts for no visual gain; the lower bowl is where the eye goes.
local CROWD_ROWS   = 9
local CROWD_FILL   = 0.62
local CROWD_PER_ROW = 26

-- Vapour / colour under the canopy.
local HOUSE_PRIMARY = Palette.Teams.A.Primary
local HOUSE_SECOND  = Palette.World.Navy
local HOUSE_TRIM    = Palette.World.OffWhite

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

--- Build a CFrame for a stand part: -Z faces the pitch, +Z is "deeper" into
--- the stand, X runs along the stand face.
local function standCf(origin: Vector3, outward: Vector3): CFrame
	return CFrame.lookAt(origin, origin - outward)
end

--- Split [0, width] into segments, skipping the vomitory gaps.
--- Returns an array of { centreAlong, length }.
local function segmentsWithGaps(width: number, gaps: { number })
	local sorted = {}
	for _, g in gaps do
		table.insert(sorted, g)
	end
	table.sort(sorted)

	local segs = {}
	local cursor = -width / 2
	for _, g in sorted do
		local gStart = g - VOM_W / 2
		if gStart > cursor then
			table.insert(segs, { centre = (cursor + gStart) / 2, length = gStart - cursor })
		end
		cursor = gStart + VOM_W
	end
	if cursor < width / 2 then
		table.insert(segs, { centre = (cursor + width / 2) / 2, length = width / 2 - cursor })
	end
	return segs
end

-- ─────────────────────────────────────────────
-- Stand
-- ─────────────────────────────────────────────

local function buildStand(stadium: Model, o: {
	name: string,
	inner: Vector3,          -- centre of the stand's front edge, at pitch level
	outward: Vector3,        -- horizontal unit pointing away from the pitch
	along: Vector3,          -- horizontal unit running along the stand face
	width: number,
	seatColor: Color3,
	roofHeight: number?,
	vomitories: number,
	cornerFill: boolean?,
})
	local outward = o.outward.Unit
	local along = o.along.Unit
	local g = Kit.folder(o.name, stadium)
	local seatColor = o.seatColor

	-- Vomitory positions spread evenly across the face.
	local gaps = {}
	for i = 1, o.vomitories do
		local t = (i - 0.5) / o.vomitories
		table.insert(gaps, (t - 0.5) * o.width)
	end
	local segs = segmentsWithGaps(o.width, gaps)

	local rakeDepth = ROWS * RUN
	local rakeHeight = ROWS * RISE

	-- ── Substructure: the stepped concrete rake ─────────────────────────
	-- Each row is a solid block from the ground up, which is what produces the
	-- staircase silhouette from the pitch. One part per row.
	for i = 0, ROWS - 1 do
		local h = RISE * (i + 1)
		local pos = o.inner + outward * (RUN * (i + 0.5)) + Vector3.new(0, h / 2, 0)
		Kit.trim(g, o.name .. "_Rake" .. i,
			Vector3.new(o.width, h, RUN),
			standCf(pos, outward),
			if i % 2 == 0 then Palette.World.Concrete else Palette.World.ConcreteDark,
			Palette.Materials.Wall)
	end

	-- ── Seating: a strip per row per segment, so the rake is broken up by
	--    vomitories the way a real bowl is.
	for i = 0, ROWS - 1 do
		for _, seg in ipairs(segs) do
			if seg.length > 2 then
				local pos = o.inner
					+ outward * (RUN * (i + 0.72))
					+ along * seg.centre
					+ Vector3.new(0, RISE * (i + 1) + 1.1, 0)
				-- Alternating shade per row band gives the bowl texture.
				local c = if (math.floor(i / 2) % 2 == 0)
					then seatColor
					else Palette.World.ConcreteDark
				Kit.trim(g, o.name .. "_Seat_" .. i .. "_" .. tostring(math.floor(seg.centre)),
					Vector3.new(seg.length - 0.6, 1.8, RUN * 0.85),
					standCf(pos, outward),
					c, Palette.Materials.Seat)
			end
		end
	end

	-- ── Vomitory stairways: the visible gap gets an actual staircase, plus a
	--    barrier wall either side so it reads as a tunnel mouth from the pitch.
	for _, gPos in ipairs(gaps) do
		for i = 0, ROWS - 1 do
			local h = RISE * (i + 1)
			local pos = o.inner
				+ outward * (RUN * (i + 0.5))
				+ along * gPos
				+ Vector3.new(0, h / 2, 0)
			Kit.trim(g, o.name .. "_VomStair_" .. i,
				Vector3.new(VOM_W - 1.6, h, RUN * 0.9),
				standCf(pos, outward),
				Palette.World.ConcreteLight, Palette.Materials.Path)
		end

		-- Side walls of the vomitory
		for _, s in ipairs({ -1, 1 }) do
			local pos = o.inner
				+ outward * (rakeDepth / 2)
				+ along * (gPos + s * (VOM_W / 2))
				+ Vector3.new(0, rakeHeight / 2, 0)
			Kit.trim(g, o.name .. "_VomWall_" .. tostring(gPos) .. "_" .. s,
				Vector3.new(0.6, rakeHeight, rakeDepth),
				standCf(pos, outward),
				Palette.World.ConcreteDark, Palette.Materials.Wall)
		end

		-- Back opening: a dark recess where the concourse shows through.
		local backPos = o.inner + outward * (rakeDepth + 3) + along * gPos + Vector3.new(0, rakeHeight * 0.45, 0)
		Kit.trim(g, o.name .. "_VomMouth_" .. tostring(gPos),
			Vector3.new(VOM_W, rakeHeight * 0.9, 0.5),
			standCf(backPos, outward),
			Palette.World.Void, Palette.Materials.Smooth)
	end

	-- ── Front railing: separates the lowest row from the walkway. ─────────
	local railPos = o.inner + outward * (RUN * 0.2) + Vector3.new(0, 1.4, 0)
	Kit.railing(g, standCf(railPos, outward), o.width, 1.6, 0.5,
		Palette.World.MetalLight)
	-- ...but not across the vomitories, where players must walk through.
	for _, gPos in ipairs(gaps) do
		for _, s in ipairs({ -1, 1 }) do
			local p = railPos + along * (gPos + s * (VOM_W / 2 + 1.5))
			Kit.trim(g, o.name .. "_RailPost_" .. tostring(gPos) .. s,
				Vector3.new(0.3, 1.6, 0.3), standCf(p, outward),
				Palette.World.MetalLight, Palette.Materials.Metal)
		end
	end

	-- ── Crowd ────────────────────────────────────────────────────────────
	-- Single-part figures, lower bowl only, and never on a stairway.
	if Kit.remaining() > 4000 then
		for i = 0, math.min(CROWD_ROWS, ROWS) - 1 do
			for _, seg in ipairs(segs) do
				if seg.length > 6 then
					local count = math.max(1, math.floor(seg.length / (o.width / CROWD_PER_ROW)))
					for c = 1, count do
						local t = (c - 0.5) / count
						local pos = o.inner
							+ outward * (RUN * (i + 0.72))
							+ along * (seg.centre + (t - 0.5) * (seg.length - 2))
							+ Vector3.new(0, RISE * (i + 1) + 2.9, 0)
						-- Home end behind one goal is the away section: darker,
						-- sparser, different colour. Cheap, and it makes the
						-- bowl look split rather than uniformly dressed.
						local isAway = o.name == "StandSouth" or o.name == "StandWest"
						local col = if isAway
							then Palette.Crowd.SeatMix[3]
							else Palette.Crowd.SeatMix[(i + c) % #Palette.Crowd.SeatMix + 1]
						Kit.newPart({
							name = o.name .. "_Fan",
							size = Vector3.new(1.5, 3.4, 1.5),
							cf = standCf(pos, outward),
							color = col,
							material = Palette.Materials.Smooth,
							parent = g, collide = false, shadow = false,
						})
					end
				end
			end
		end
	end

	-- ── Roof canopy ──────────────────────────────────────────────────────
	local roofH = o.roofHeight or (rakeHeight + 12)
	local roofDepth = rakeDepth * 0.78
	local roofPos = o.inner + outward * (rakeDepth * 0.52) + Vector3.new(0, roofH, 0)

	-- Canopy deck, tilted slightly toward the pitch for a real profile.
	Kit.trim(g, o.name .. "_RoofDeck",
		Vector3.new(o.width + 4, 1.0, roofDepth),
		standCf(roofPos, outward) * CFrame.Angles(math.rad(6), 0, 0),
		Palette.World.MetalDark, Palette.Materials.Metal)

	-- Fascia: a house-coloured band along the leading edge. This is the single
	-- most identifiable part of the stadium from the pitch.
	local fasciaPos = o.inner + outward * (rakeDepth * 0.14) + Vector3.new(0, roofH - 1.6, 0)
	Kit.trim(g, o.name .. "_Fascia",
		Vector3.new(o.width + 4, 3.2, 0.6),
		standCf(fasciaPos, outward),
		HOUSE_PRIMARY, Palette.Materials.MetalPanel)

	-- Trusses under the canopy
	for i = 0, 4 do
		local t = (i / 4 - 0.5) * (o.width - 6)
		local p = o.inner + outward * (rakeDepth * 0.52) + along * t + Vector3.new(0, roofH - 2.5, 0)
		Kit.trim(g, o.name .. "_Truss" .. i,
			Vector3.new(1.2, 1.2, roofDepth * 0.9),
			standCf(p, outward),
			Palette.World.Metal, Palette.Materials.Metal)
		-- Rear support column down to the concourse slab
		local colPos = o.inner + outward * (rakeDepth * 0.95) + along * t + Vector3.new(0, roofH / 2 - 2, 0)
		Kit.trim(g, o.name .. "_Col" .. i,
			Vector3.new(1.6, roofH - 4, 1.6),
			standCf(colPos, outward),
			Palette.World.MetalDark, Palette.Materials.Metal)
	end

	-- House banners hung off the fascia, angled down at the pitch.
	local bannerCount = math.max(3, math.floor(o.width / 46))
	for i = 1, bannerCount do
		local t = (i - 0.5) / bannerCount - 0.5
		local p = o.inner
			+ outward * (rakeDepth * 0.15 + 1.2)
			+ along * (t * o.width)
			+ Vector3.new(0, roofH - 6, 0)
		-- Alternate house colours so the bowl reads as split, not uniform.
		Kit.banner(g, o.name .. "_Banner" .. i, p,
			math.atan2(outward.X, outward.Z) + math.pi,
			9, 7,
			if i % 2 == 0 then HOUSE_PRIMARY else Palette.Teams.B.Primary)
	end

	-- ── Back wall + concourse ────────────────────────────────────────────
	local backPos = o.inner + outward * (rakeDepth + 6) + Vector3.new(0, rakeHeight * 0.5, 0)
	Kit.trim(g, o.name .. "_BackWall",
		Vector3.new(o.width + 4, rakeHeight + 16, 2.5),
		standCf(backPos, outward),
		Palette.World.ConcreteDark, Palette.Materials.Wall)

	-- Concourse slab behind the stand, at rake height, running the full width.
	local concPos = o.inner + outward * (rakeDepth + 14) + Vector3.new(0, rakeHeight, 0)
	Kit.trim(g, o.name .. "_Concourse",
		Vector3.new(o.width + 10, 1.2, 14),
		standCf(concPos, outward),
		Palette.World.Concrete, Palette.Materials.Path)

	-- Outer facade above the concourse, so the stadium has an outside.
	local facadePos = o.inner + outward * (rakeDepth + 20) + Vector3.new(0, rakeHeight + 6, 0)
	Kit.trim(g, o.name .. "_Facade",
		Vector3.new(o.width + 10, 10, 2),
		standCf(facadePos, outward),
		Palette.World.ConcreteLight, Palette.Materials.Wall)

	return g
end

-- ─────────────────────────────────────────────
-- Entrance
--
-- Ground-level arch on the outward face of a stand. Makes the stadium a place
-- a player could walk into rather than a shape they stand next to.
-- ─────────────────────────────────────────────

local function buildEntrance(stadium: Model, name: string, pos: Vector3, outward: Vector3, label: string)
	local outward = outward.Unit
	local g = Kit.folder(name, stadium)
	local along = Vector3.new(-outward.Z, 0, outward.X)
	local cf = standCf(pos, outward)
	local W = 34
	local H = 22

	-- Portal void
	Kit.trim(g, name .. "_Portal", Vector3.new(W, H, 3),
		cf, Palette.World.Void, Palette.Materials.Smooth)
	-- Surround
	Kit.trim(g, name .. "_Lintel", Vector3.new(W + 6, 3, 4),
		cf * CFrame.new(0, H / 2 + 1.5, -1), Palette.World.ConcreteLight, Palette.Materials.Wall)
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(g, name .. "_Pier" .. s, Vector3.new(3, H + 3, 4),
			cf * CFrame.new(s * (W / 2 + 1.5), 0, -1), Palette.World.ConcreteLight, Palette.Materials.Wall)
	end
	-- Turnstile row inside the mouth
	for i = -3, 3 do
		Kit.trim(g, name .. "_Turnstile" .. i, Vector3.new(1.6, 3.4, 1.6),
			cf * CFrame.new(i * 4, -H / 2 + 1.7, 2), Palette.World.MetalDark, Palette.Materials.Metal)
	end
	-- Steps up from the ground into the concourse
	Kit.stairs(g, name .. "_Steps", cf * CFrame.new(0, -H / 2, 4), W - 4, 8, 10, 8,
		Palette.World.ConcreteLight)

	-- Signage over the lintel
	local board = Kit.trim(g, name .. "_Board", Vector3.new(W - 4, 4, 0.4),
		cf * CFrame.new(0, H / 2 + 1.5, -3.2), HOUSE_SECOND, Palette.Materials.WallPanel)
	Kit.surfaceText(board, label, Enum.NormalId.Front, Palette.World.White, 72, Palette.Type.Display)
	Kit.surfaceText(board, label, Enum.NormalId.Back, Palette.World.White, 72, Palette.Type.Display)

	return g
end

-- ─────────────────────────────────────────────
-- Big screen
-- ─────────────────────────────────────────────

local function buildBigScreen(stadium: Model, pos: Vector3, facingZ: number)
	local g = Kit.folder("BigScreen", stadium)
	local W, H = 84, 46

	-- Support mast
	Kit.trim(g, "BigScreen_Mast", Vector3.new(6, 46, 6),
		CFrame.new(pos.X, pos.Y + 23, pos.Z), Palette.World.MetalDark, Palette.Materials.Metal)
	-- Screen housing
	local cf = CFrame.new(pos.X, pos.Y, pos.Z)
	Kit.trim(g, "BigScreen_Housing", Vector3.new(W + 6, H + 6, 5),
		cf, Palette.World.Charcoal, Palette.Materials.Metal)
	-- Screen face: a dark emissive panel. The live score text is written onto
	-- it at runtime by the scoreboard remote.
	local screen = Kit.trim(g, "BigScreen_Face", Vector3.new(W, H, 0.6),
		cf * CFrame.new(0, 0, facingZ * 2.8), Palette.World.Void, Palette.Materials.Smooth)
	Kit.newPart({
		name = "BigScreen_Glow", size = Vector3.new(W - 4, H - 4, 0.2),
		cf = cf * CFrame.new(0, 0, facingZ * 3.2),
		color = Palette.World.Void, material = Palette.Materials.Metal,
		parent = g, collide = false, shadow = false, transparency = 0.92,
	})
	Kit.newPart({
		name = "BigScreen_GlowBack", size = Vector3.new(W - 4, H - 4, 0.2),
		cf = cf * CFrame.new(0, 0, -facingZ * 2.8),
		color = Palette.World.Void, material = Palette.Materials.Metal,
		parent = g, collide = false, shadow = false, transparency = 0.92,
	})
	-- Screen frame
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(g, "BigScreen_FrameV" .. s, Vector3.new(2, H + 6, 6),
			cf * CFrame.new(s * (W / 2 + 2), 0, 0), Palette.World.MetalLight, Palette.Materials.Metal)
		Kit.trim(g, "BigScreen_FrameH" .. s, Vector3.new(W + 6, 2, 6),
			cf * CFrame.new(0, s * (H / 2 + 2), 0), Palette.World.MetalLight, Palette.Materials.Metal)
	end
	return g, screen
end

-- ─────────────────────────────────────────────
-- Floodlight tower
--
-- A lattice mast with a lamp rack, not a pole with a yellow box. Four of these
-- are the reason a stadium pitch reads as floodlit.
-- ─────────────────────────────────────────────

local function buildFloodlight(stadium: Model, name: string, base: Vector3, aimAt: Vector3)
	local g = Kit.folder(name, stadium)
	local H = 66
	local metal = Palette.Materials.Metal
	local c = Palette.World.MetalDark

	-- Lattice: four legs plus cross bracing, tapering inward.
	local legOff = 5
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			Kit.trim(g, name .. "_Leg" .. sx .. sz, Vector3.new(1.4, H, 1.4),
				CFrame.new(base.X + sx * legOff, base.Y + H / 2, base.Z + sz * legOff),
				c, metal)
		end
	end
	for i = 1, 7 do
		local t = i / 8
		local y = base.Y + H * t
		local off = legOff * (1 - t * 0.55)
		for _, sz in ipairs({ -1, 1 }) do
			Kit.trim(g, name .. "_Brace" .. i .. "_" .. sz, Vector3.new(off * 2, 0.7, 0.7),
				CFrame.new(base.X, y, base.Z + sz * off), c, metal)
		end
		for _, sx in ipairs({ -1, 1 }) do
			Kit.trim(g, name .. "_BraceZ" .. i .. "_" .. sx, Vector3.new(0.7, 0.7, off * 2),
				CFrame.new(base.X + sx * off, y, base.Z), c, metal)
		end
	end
	-- Concrete footing
	Kit.trim(g, name .. "_Footing", Vector3.new(16, 3, 16),
		CFrame.new(base.X, base.Y + 1.5, base.Z), Palette.World.ConcreteDark, Palette.Materials.Wall)

	-- Lamp rack at the top, aimed at the pitch centre.
	local headCf = CFrame.lookAt(base + Vector3.new(0, H + 4, 0), aimAt)
	Kit.trim(g, name .. "_Rack", Vector3.new(26, 1.4, 4),
		headCf, Palette.World.MetalDark, metal)
	-- Individual lamp boxes
	for row = 0, 1 do
		for col = -4, 4 do
			Kit.trim(g, string.format("%s_Lamp_%d_%d", name, row, col),
				Vector3.new(2.4, 2.0, 1.4),
				headCf * CFrame.new(col * 2.8, 1.8 + row * 2.4, 0),
				Palette.World.OffWhite, metal)
		end
	end
	-- One real light per tower. Sixteen would be a performance disaster; one
	-- wide spotlight aimed at the centre reads the same from the pitch.
	local sl = Instance.new("SpotLight")
	sl.Brightness = 3
	sl.Range = 460
	sl.Angle = 62
	sl.Color = Palette.World.OffWhite
	sl.Shadows = true
	sl.Face = Enum.NormalId.Bottom
	sl.Parent = g:FindFirstChild(name .. "_Rack")

	-- Aircraft warning light — one accent use, justified as a landmark detail.
	Kit.trim(g, name .. "_Warn", Vector3.new(1.2, 1.2, 1.2),
	CFrame.new(base.X, base.Y + H + 8, base.Z), Palette.Accent.Rose,
	Palette.Materials.Metal).Transparency = 0.4

	return g
end

-- ─────────────────────────────────────────────
-- Technical area, benches, tunnel
-- ─────────────────────────────────────────────

local function buildTechnicalArea(stadium: Model, name: string, pos: Vector3, teamColor: Color3)
	local g = Kit.folder(name, stadium)
	local cf = CFrame.new(pos)

	-- Dugout shell: a curved-roof bench shelter
	Kit.trim(g, name .. "_Floor", Vector3.new(34, 0.5, 12),
		cf * CFrame.new(0, 0.25, 0), Palette.World.ConcreteDark, Palette.Materials.Path)
	-- Rear and side walls
	Kit.trim(g, name .. "_Back", Vector3.new(34, 5, 0.8),
		cf * CFrame.new(0, 2.5, 6), teamColor, Palette.Materials.MetalPanel)
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(g, name .. "_Side" .. s, Vector3.new(0.8, 5, 12),
			cf * CFrame.new(s * 17, 2.5, 0), teamColor, Palette.Materials.MetalPanel)
	end
	-- Roof
	Kit.trim(g, name .. "_Roof", Vector3.new(36, 0.8, 14),
		cf * CFrame.new(0, 5.4, 0) * CFrame.Angles(math.rad(5), 0, 0),
		Palette.World.MetalDark, Palette.Materials.Metal)
	-- Bench seat
	Kit.trim(g, name .. "_Bench", Vector3.new(30, 1.4, 3),
		cf * CFrame.new(0, 1.2, 3.5), teamColor, Palette.Materials.Metal)
	Kit.trim(g, name .. "_BenchBase", Vector3.new(30, 0.8, 2),
		cf * CFrame.new(0, 0.4, 3.5), Palette.World.Charcoal, Palette.Materials.Metal)
	-- Water bottles + medical crate: small, but they are what makes a dugout
	-- look occupied rather than modelled.
	Kit.trim(g, name .. "_Crate", Vector3.new(2, 1.6, 1.4),
		cf * CFrame.new(-13, 0.8, 2), Palette.World.Wood, Palette.Materials.WallWood)
	for i = 1, 4 do
		Kit.trim(g, name .. "_Bottle" .. i, Vector3.new(0.4, 0.8, 0.4),
			cf * CFrame.new(4 + i * 0.9, 0.9, 2), Palette.World.Glass, Palette.Materials.Glass)
	end
	-- Team crest board on the rear wall
	local crest = Kit.trim(g, name .. "_Crest", Vector3.new(8, 8, 0.3),
		cf * CFrame.new(0, 3.0, 5.5), teamColor, Palette.Materials.WallPanel)
	Kit.surfaceText(crest, if name == "TechA" then "AZURE" else "CRIMSON",
		Enum.NormalId.Front, Palette.World.White, 72, Palette.Type.Display)

	-- Interaction: the technical area is where a player goes to join a match.
	local pad = Kit.trim(g, name .. "_Pad", Vector3.new(6, 1, 6),
		cf * CFrame.new(0, 0.9, -9), teamColor, Palette.Materials.Metal)
	pad.Transparency = 0.5
	Kit.prompt(pad, "MatchPortal", "Enter Match", "Technical Area", 12)
	Kit.billboard(pad, "ENTER MATCH", Vector3.new(0, 6, 0), Palette.World.White,
		{ maxDistance = 60 })

	return g
end

local function buildTunnel(stadium: Model, pos: Vector3, facingZ: number)
	local g = Kit.folder("PlayerTunnel", stadium)
	local cf = CFrame.new(pos)
	local W, H, D = 14, 11, 34

	-- Tunnel mouth, recessed into the stand
	Kit.trim(g, "Tunnel_Mouth", Vector3.new(W, H, 1),
		cf * CFrame.new(0, H / 2, 0), Palette.World.Void, Palette.Materials.Smooth)
	-- Portal frame
	Kit.trim(g, "Tunnel_Lintel", Vector3.new(W + 5, 3, 3),
		cf * CFrame.new(0, H + 1.5, 0), HOUSE_SECOND, Palette.Materials.WallPanel)
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(g, "Tunnel_Pier" .. s, Vector3.new(3, H + 3, 3),
			cf * CFrame.new(s * (W / 2 + 1.5), 0, 0), HOUSE_SECOND, Palette.Materials.WallPanel)
	end
	-- Tunnel tube running back under the stand
	Kit.trim(g, "Tunnel_Tube", Vector3.new(W, H, D),
		cf * CFrame.new(0, H / 2, -facingZ * D / 2), Palette.World.Void, Palette.Materials.Smooth)
	-- Floor so it does not read as a black hole
	Kit.trim(g, "Tunnel_Floor", Vector3.new(W, 0.4, D),
		cf * CFrame.new(0, 0.2, -facingZ * D / 2), Palette.World.Concrete, Palette.Materials.Path)
	-- Ceiling lights down the tunnel
	for i = 1, 5 do
		Kit.trim(g, "Tunnel_Light" .. i, Vector3.new(W - 3, 0.3, 1.2),
			cf * CFrame.new(0, H - 0.4, -facingZ * (3 + i * 6)),
			Palette.Accent.Ember, Palette.Materials.Metal).Transparency = 0.5
	end
	-- Signage
	local board = Kit.trim(g, "Tunnel_Sign", Vector3.new(W - 1, 2.4, 0.3),
		cf * CFrame.new(0, H + 1.5, -1.8), HOUSE_PRIMARY, Palette.Materials.WallPanel)
	Kit.surfaceText(board, "PLAYER TUNNEL", Enum.NormalId.Front,
		Palette.World.White, 64, Palette.Type.Display)
	return g
end

-- ─────────────────────────────────────────────
-- Corner flags
-- ─────────────────────────────────────────────

local function buildCornerFlags(parent: Instance, centre: Vector3, hw: number, hl: number)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local pos = centre + Vector3.new(sx * hw, 0, sz * hl)
			local flag = Kit.folder("CornerFlag" .. (sx < 0 and "W" or "E") .. (sz < 0 and "N" or "S"), parent)
			Kit.cylinder(flag, "Pole", Vector3.new(0.25, 6, 0.25),
				CFrame.new(pos.X, pos.Y + 3, pos.Z), Palette.World.White, Palette.Materials.Metal)
			local cloth = Kit.trim(flag, "Cloth", Vector3.new(2.4, 1.6, 0.1),
				CFrame.new(pos.X + sx * 1.2, pos.Y + 5.2, pos.Z),
				Palette.Accent.Ember, Palette.Materials.Fabric)
			cloth.Transparency = 0.25
		end
	end
end

-- ─────────────────────────────────────────────
-- Build
-- ─────────────────────────────────────────────

local function buildStadium(): Model
	local existing = workspace:FindFirstChild("Stadium")
	if existing then
		existing:Destroy()
	end

	local stadium = Instance.new("Model")
	stadium.Name = "Stadium"
	-- Parented empty and immediately, so ServerMain's existence check passes
	-- straight away. Readiness is signalled by the Ready attribute instead.
	stadium.Parent = workspace

	-- Reset the shared part budget for this build.
	Kit.spent = 0

	-- ── PITCH ────────────────────────────────────────────────────────────
	local pitchCentre = Vector3.new(0, PITCH_Y, 0)
	Kit.pitch(stadium, "Pitch", pitchCentre, FW, FL, 14)
	Kit.pitchMarkings(stadium, "Markings", pitchCentre, FW, FL, {
		circleR = Constants.CENTRE_CIRCLE_RADIUS,
		penW = Constants.PENALTY_AREA_WIDTH,
		penD = Constants.PENALTY_AREA_DEPTH,
		goalW = Constants.GOAL_AREA_WIDTH,
		goalD = Constants.GOAL_AREA_DEPTH,
	})
	buildCornerFlags(stadium, pitchCentre, HALF_W, HALF_L)

	-- ── GOALS ────────────────────────────────────────────────────────────
	-- TeamA defends -Z, TeamB defends +Z. Trigger names are part of the
	-- gameplay contract with BallService.
	local goalPostTemplate = AssetRegistry.WorldProps.GoalPost
	if goalPostTemplate then
		local function placeGoal(name, pos, zSign)
			local model = goalPostTemplate:Clone()
			model.Name = name
			model:PivotTo(CFrame.new(pos))
			model.Parent = stadium

			local trigger = Instance.new("Part")
			trigger.Name = name .. "_Trigger"
			trigger.Size = Vector3.new(GW - 1, GH - 1, GD - 1)
			trigger.CFrame = CFrame.new(pos.X, pos.Y + (GH - 1) / 2, pos.Z + zSign * (GD / 2))
			trigger.Transparency = 1
			trigger.CanCollide = false
			trigger.CastShadow = false
			trigger.Parent = stadium
		end

		placeGoal("GoalA", Vector3.new(0, PITCH_Y, -HALF_L), -1)
		placeGoal("GoalB", Vector3.new(0, PITCH_Y, HALF_L), 1)
	else
		local goalA = Kit.goal(stadium, "GoalA",
			Vector3.new(0, PITCH_Y, -HALF_L), -1, GW, GH, GD, Palette.Teams.A.Primary)
		goalA.trigger.Name = "GoalA_Trigger"
		local goalB = Kit.goal(stadium, "GoalB",
			Vector3.new(0, PITCH_Y, HALF_L), 1, GW, GH, GD, Palette.Teams.B.Primary)
		goalB.trigger.Name = "GoalB_Trigger"
	end

	-- ── KICKOFF MARKER ───────────────────────────────────────────────────
	local kickoff = Kit.marker(stadium, "KickoffPoint", Vector3.new(2, 2, 2),
		CFrame.new(0, PITCH_Y + 1, 0))

	-- ── BALL ──────────────────────────────────────────────────────────────
	-- Unanchored: BallService takes ownership of its physics.
	local template = ServerStorage.WorldAssets.Balls.TexturedSoccerBall
	if not template then
		warn("[StadiumBuilder] TexturedSoccerBall not found in ServerStorage.WorldAssets.Balls")
		template = ServerStorage.WorldAssets:FindFirstChild("TexturedSoccerBall")
	end

	local ball
	if template then
		ball = template:Clone()
		ball.Name = "Ball"
		ball.Position = Vector3.new(0, PITCH_Y + 3.2, 0)
		ball.Parent = stadium
	else
		ball = Instance.new("Part")
		ball.Name = "Ball"
		ball.Shape = Enum.PartType.Ball
		ball.Size = Vector3.new(2.4, 2.4, 2.4)
		ball.Color = Palette.World.White
		ball.Material = Palette.Materials.Smooth
		ball.CFrame = CFrame.new(0, PITCH_Y + 3.2, 0)
		ball.Anchored = false
		ball.CanCollide = true
		ball.CastShadow = true
		ball.TopSurface = Enum.SurfaceType.Smooth
		ball.BottomSurface = Enum.SurfaceType.Smooth
		ball.Parent = stadium
		for _, normalId in ipairs({
			Enum.NormalId.Front, Enum.NormalId.Back,
			Enum.NormalId.Left, Enum.NormalId.Right,
			Enum.NormalId.Top, Enum.NormalId.Bottom,
		}) do
			local d = Instance.new("Decal")
			d.Face = normalId
			d.Texture = "rbxasset://textures/SoccerBall.png"
			d.Parent = ball
		end
	end

	-- ── PERIMETER: ad boards ─────────────────────────────────────────────
	-- Continuous LED ring, the single strongest "this is a real venue" cue.
	local adColor = Palette.World.Navy
	Kit.adBoard(stadium, "AdNorth",
		Vector3.new(-HALF_W, PITCH_Y, -HALF_L - RUNOFF),
		Vector3.new(HALF_W, PITCH_Y, -HALF_L - RUNOFF), 3.2, adColor, "MYTHIC STRIKERS")
	Kit.adBoard(stadium, "AdSouth",
		Vector3.new(-HALF_W, PITCH_Y, HALF_L + RUNOFF),
		Vector3.new(HALF_W, PITCH_Y, HALF_L + RUNOFF), 3.2, Palette.Teams.A.Primary, "AZURE FC")
	Kit.adBoard(stadium, "AdWest",
		Vector3.new(-HALF_W - RUNOFF, PITCH_Y, -HALF_L),
		Vector3.new(-HALF_W - RUNOFF, PITCH_Y, HALF_L), 3.2, Palette.Teams.B.Primary, "CRIMSON UNITED")
	Kit.adBoard(stadium, "AdEast",
		Vector3.new(HALF_W + RUNOFF, PITCH_Y, -HALF_L),
		Vector3.new(HALF_W + RUNOFF, PITCH_Y, HALF_L), 3.2, adColor, "MYTHIC ENERGY")

	-- ── WALKWAY ──────────────────────────────────────────────────────────
	-- Paved strip between ad boards and the stand rake. Without it the stands
	-- grow straight out of the grass.
	local walkInset = RUNOFF + ADBOARD_Z + 1
	local standInnerX = HALF_W + walkInset + WALKWAY
	local standInnerZ = HALF_L + walkInset + WALKWAY
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(stadium, "WalkwayX" .. s,
			Vector3.new(WALKWAY, 0.4, FL + standInnerZ * 2),
			CFrame.new(s * (HALF_W + walkInset + WALKWAY / 2), PITCH_Y, 0),
			Palette.World.Concrete, Palette.Materials.Path)
		Kit.trim(stadium, "WalkwayZ" .. s,
			Vector3.new(HALF_W * 2, 0.4, WALKWAY),
			CFrame.new(0, PITCH_Y, s * (HALF_L + walkInset + WALKWAY / 2)),
			Palette.World.Concrete, Palette.Materials.Path)
	end

	-- ── STANDS ───────────────────────────────────────────────────────────
	-- East / West stands run along Z, North / South along X. Corner regions are
	-- left to a lower infill block so the bowl closes.
	local rakeDepth = ROWS * RUN
	local rakeHeight = ROWS * RISE

	buildStand(stadium, {
		name = "StandWest",
		inner = Vector3.new(-standInnerX, PITCH_Y, 0),
		outward = Vector3.new(-1, 0, 0),
		along = Vector3.new(0, 0, 1),
		width = standInnerZ * 2,
		seatColor = Palette.Crowd.SeatA,
		vomitories = 4,
	})
	buildStand(stadium, {
		name = "StandEast",
		inner = Vector3.new(standInnerX, PITCH_Y, 0),
		outward = Vector3.new(1, 0, 0),
		along = Vector3.new(0, 0, -1),
		width = standInnerZ * 2,
		seatColor = Palette.Crowd.SeatA,
		vomitories = 4,
	})
	buildStand(stadium, {
		name = "StandNorth",
		inner = Vector3.new(0, PITCH_Y, -standInnerZ),
		outward = Vector3.new(0, 0, -1),
		along = Vector3.new(1, 0, 0),
		width = standInnerX * 2,
		seatColor = Palette.Crowd.SeatB,
		vomitories = 3,
	})
	buildStand(stadium, {
		name = "StandSouth",
		inner = Vector3.new(0, PITCH_Y, standInnerZ),
		outward = Vector3.new(0, 0, 1),
		along = Vector3.new(-1, 0, 0),
		width = standInnerX * 2,
		seatColor = Palette.Crowd.SeatB,
		vomitories = 3,
	})

	-- ── CORNER INFILL ────────────────────────────────────────────────────
	-- Closes the four corner gaps between perpendicular stands. A single
	-- stepped block per corner, one row lower than the main rake, is enough to
	-- make the bowl read as continuous.
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local cx = sx * (standInnerX + rakeDepth / 2)
			local cz = sz * (standInnerZ + rakeDepth / 2)
			-- Elliptical approximation of the corner bowl using 4 stepped
			-- blocks stepping down toward the corner.
			for i = 0, 4 do
				local t = i / 4
				local inset = 6 + t * 34
				Kit.trim(stadium, string.format("Corner_%d_%d_%d", sx, sz, i),
					Vector3.new(28 - t * 12, rakeHeight * (1 - t * 0.45), 28 - t * 12),
					CFrame.new(cx - sx * inset * 0.35, rakeHeight * (1 - t * 0.45) / 2,
						cz - sz * inset * 0.35),
					Palette.World.Concrete, Palette.Materials.Wall)
			end
		end
	end

	-- ── ENTRANCES ────────────────────────────────────────────────────────
	-- Four ground-level arches, one per stand, on the outward face.
	local entOffset = rakeDepth + 24
	buildEntrance(stadium, "EntranceNorth",
		Vector3.new(0, PITCH_Y, -(standInnerZ + entOffset)), Vector3.new(0, 0, -1), "GATE NORTH")
	buildEntrance(stadium, "EntranceSouth",
		Vector3.new(0, PITCH_Y, standInnerZ + entOffset), Vector3.new(0, 0, 1), "GATE SOUTH")
	buildEntrance(stadium, "EntranceWest",
		Vector3.new(-(standInnerX + entOffset), PITCH_Y, 0), Vector3.new(-1, 0, 0), "GATE WEST")
	buildEntrance(stadium, "EntranceEast",
		Vector3.new(standInnerX + entOffset, PITCH_Y, 0), Vector3.new(1, 0, 0), "GATE EAST")

	-- ── TUNNEL + TECHNICAL AREAS ─────────────────────────────────────────
	-- Behind the south technical area, the players' tunnel.
	buildTunnel(stadium, Vector3.new(0, PITCH_Y, standInnerZ + rakeDepth * 0.5), -1)
	buildTechnicalArea(stadium, "TechA",
		Vector3.new(-26, PITCH_Y, HALF_L + walkInset + 5), Palette.Teams.A.Primary)
	buildTechnicalArea(stadium, "TechB",
		Vector3.new(26, PITCH_Y, HALF_L + walkInset + 5), Palette.Teams.B.Primary)

	-- Media bay: a small two-tier press box opposite the technical areas,
	-- which is what makes the far touchline look televised.
	local mediaCf = CFrame.new(0, PITCH_Y, -(standInnerZ + rakeDepth * 0.45))
	Kit.trim(stadium, "MediaBay_Deck", Vector3.new(46, 1, 12),
		mediaCf * CFrame.new(0, 6, 0), Palette.World.ConcreteLight, Palette.Materials.Path)
	Kit.trim(stadium, "MediaBay_Front", Vector3.new(46, 7, 0.6),
		mediaCf * CFrame.new(0, 9, -6), Palette.World.Glass, Palette.Materials.Glass)
	Kit.trim(stadium, "MediaBay_Roof", Vector3.new(48, 0.8, 14),
		mediaCf * CFrame.new(0, 13, 0), Palette.World.MetalDark, Palette.Materials.Metal)
	for i = -2, 2 do
		Kit.trim(stadium, "MediaBay_Desk" .. i, Vector3.new(7, 1.2, 2),
			mediaCf * CFrame.new(i * 9, 7, -3), Palette.World.MetalDark, Palette.Materials.Metal)
	end

	-- ── BIG SCREENS ──────────────────────────────────────────────────────
	-- Two, one behind each goal, angled in. One is never visible from the
	-- cheap seats, and a single screen makes half the bowl face backwards.
	local screenZ = standInnerZ + rakeDepth + 12
	buildBigScreen(stadium, Vector3.new(0, rakeHeight + 26, -screenZ), 1)
	buildBigScreen(stadium, Vector3.new(0, rakeHeight + 26, screenZ), -1)

	-- ── FLOODLIGHTS ──────────────────────────────────────────────────────
	local towerBase = Vector3.new(standInnerX + rakeDepth + 26, PITCH_Y,
		standInnerZ + rakeDepth + 26)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			buildFloodlight(stadium, string.format("Floodlight_%d_%d", sx, sz),
				Vector3.new(towerBase.X * sx, PITCH_Y, towerBase.Z * sz),
				Vector3.new(0, 0, 0))
		end
	end

	-- ── SPAWNS ───────────────────────────────────────────────────────────
	-- Positions are unchanged from the prototype: balance and kickoff strategy
	-- were tuned against them.
	local TEAM_A = Palette.Teams.A.Primary
	local TEAM_B = Palette.Teams.B.Primary
	local SPEC = Palette.Teams.Spec.Primary

	local function spawn(name: string, pos: Vector3, color: Color3, rotY: number?)
		local sp = Instance.new("SpawnLocation")
		sp.Name = name
		sp.Size = Vector3.new(5, 1, 5)
		sp.CFrame = CFrame.new(pos) * CFrame.Angles(0, rotY or 0, 0)
		sp.Color = color
		sp.Material = Palette.Materials.Smooth
		sp.Anchored = true
		sp.CanCollide = true
		sp.Neutral = true
		sp.Enabled = true
		sp.Duration = 0
		sp.Transparency = 0.5
		sp.TopSurface = Enum.SurfaceType.Smooth
		sp.BottomSurface = Enum.SurfaceType.Smooth
		sp.CastShadow = false
		sp.Parent = stadium
		return sp
	end

	-- Team A defends -Z, so their formation sits in the -Z half.
	for i, off in ipairs({
		Vector3.new(-20, 1, -60), Vector3.new(0, 1, -60), Vector3.new(20, 1, -60),
		Vector3.new(-15, 1, -90), Vector3.new(15, 1, -90), Vector3.new(0, 1, -110),
	}) do
		spawn("SpawnTeamA_" .. i, off, TEAM_A, 0)
	end
	for i, off in ipairs({
		Vector3.new(-20, 1, 60), Vector3.new(0, 1, 60), Vector3.new(20, 1, 60),
		Vector3.new(-15, 1, 90), Vector3.new(15, 1, 90), Vector3.new(0, 1, 110),
	}) do
		spawn("SpawnTeamB_" .. i, off, TEAM_B, math.pi)
	end

	-- Spectators stand on the walkway, inside the rail, outside the ad boards.
	for i, off in ipairs({
		Vector3.new(-(HALF_W + walkInset + 4), 1, -30),
		Vector3.new(-(HALF_W + walkInset + 4), 1, 30),
		Vector3.new(HALF_W + walkInset + 4, 1, -30),
		Vector3.new(HALF_W + walkInset + 4, 1, 30),
	}) do
		spawn("SpawnSpectator_" .. i, off, SPEC)
	end

	-- ── FINISH ───────────────────────────────────────────────────────────
	stadium.PrimaryPart = kickoff
	stadium:SetAttribute("Ready", true)

	print("[StadiumBuilder] Mythic Strikers Arena built.")
	print(string.format("  Pitch %d x %d studs", FL, FW))
	print(string.format("  Stands: 4 tiers, %d rows, rise %.1f, rake %.0f studs",
		ROWS, RISE, rakeDepth))
	print(string.format("  Parts: %d (budget %d, %d remaining)", Kit.spent, Kit.budget, Kit.remaining()))

	return stadium
end

local ok, err = pcall(buildStadium)
if not ok then
	warn("[StadiumBuilder] Failed to build stadium: " .. tostring(err))
end
