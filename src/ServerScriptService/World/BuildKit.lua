--[[
	MythicStrikers — BuildKit
	Reusable construction primitives for every world builder.

	THE PROBLEM THIS SOLVES
	StadiumBuilder and LobbyBuilder each defined their own private `p()` helper
	and their own colour table. Two builders, two part factories, two different
	grey concretes. Geometry looked like blocks because nothing decided *how a
	thing should be built* — only *what colour it should be*.

	THE RULE
	A builder states WHAT a thing is ("a house", "a streetlight", "a stand
	railing"). BuildKit decides HOW: which parts, which materials, whether it
	casts shadow, whether it collides, how it is named and parented.

	GUIDELINES BUILT IN
	  • Nothing defaults to SmoothPlastic. Every part picks a semantic material.
	  • Shadow and collision are decided automatically from size and role.
	    Trim, glass, markings and signage never collide or cast.
	  • Every prop is built from a small number of parts with a stable name
	    pattern, so streaming, debugging and quality scaling can reason about it.
	  • Buildings take variation parameters, so no two are identical.

	USAGE
	    local Kit = require(ServerScriptService.World.BuildKit)
	    local district = Kit.folder("Residential", world)
	    Kit.house(district, origin, 14, 9, 12, Kit.HouseStyle.Gabled, seed)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Palette = require(ReplicatedStorage.Shared.Config.Palette)

local Kit = {}

-- ─────────────────────────────────────────────
-- Budget
--
-- The world is generated, so nothing stops a bad parameter from quietly
-- emitting 40,000 parts. Every part passes through newPart() and is counted.
-- ─────────────────────────────────────────────
Kit.budget = 12000
Kit.spent = 0
local _exhausted = false

function Kit.remaining(): number
	return Kit.budget - Kit.spent
end

-- ─────────────────────────────────────────────
-- Option types
--
-- Declared as named exported types rather than inline `field?: T` table types.
-- This place's Luau build does not accept the optional-field shorthand, so
-- optionality is expressed as nilable fields, which it does accept.
-- ─────────────────────────────────────────────

export type BillboardOpts = {
	size: UDim2?,
	maxDistance: number?,
}

export type RoadOpts = {
	line: boolean?,
	kerb: boolean?,
}

export type FenceOpts = {
	mesh: boolean?,
}

export type SignOpts = {
	textColor: Color3?,
	bg: Color3?,
	post: boolean?,
	postHeight: number?,
}

-- ─────────────────────────────────────────────
-- Containers
-- ─────────────────────────────────────────────

function Kit.folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

function Kit.model(name: string, parent: Instance): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- ─────────────────────────────────────────────
-- Core part factory
-- ─────────────────────────────────────────────

export type PartOpts = {
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	collide: boolean?,
	shadow: boolean?,
	shape: Enum.PartType?,
	parent: Instance,
	transparency: number?,
	reflect: number?,
}

-- Parts at least this large (in any axis) are structural and cast shadows.
-- Everything smaller is trim: railings, window frames, kerbs, markings. The
-- prototype had either everything casting or nothing casting; both look wrong.
local SHADOW_MIN_AXIS = 4
local SHADOW_MIN_VOLUME = 300

--- Does this part cast a shadow? Structural geometry yes, trim no.
function Kit.shouldCastShadow(size: Vector3): boolean
	local longest = math.max(size.X, size.Y, size.Z)
	return longest >= SHADOW_MIN_AXIS or (size.X * size.Y * size.Z) >= SHADOW_MIN_VOLUME
end

function Kit.newPart(o: PartOpts): BasePart
	if _exhausted then
		-- Return a harmless anchor so the build does not error out; the
		-- builder will finish with visible gaps rather than a hard crash.
		local anchor = Instance.new("Part")
		anchor.Name = o.name
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.CFrame = o.cf
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CastShadow = false
		anchor.Transparency = 1
		anchor.Parent = o.parent
		return anchor
	end

	if Kit.spent >= Kit.budget then
		_exhausted = true
		warn(string.format(
			"[BuildKit] Part budget of %d exhausted. Remaining world detail skipped. "
			.. "Raise Kit.budget or reduce district density.",
			Kit.budget
		))
		return Kit.newPart(o)
	end

	local p = Instance.new("Part")
	p.Name = o.name
	p.Size = o.size
	p.CFrame = o.cf
	p.Color = o.color
	p.Material = o.material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = true
	p.CanCollide = o.collide ~= false
	p.CastShadow = if o.shadow ~= nil then o.shadow else Kit.shouldCastShadow(o.size)
	p.Transparency = o.transparency or 0

	if o.shape and o.shape ~= Enum.PartType.Block then
		p.Shape = o.shape
	end
	if o.reflect then
		p.Reflectance = o.reflect
	end

	p.Parent = o.parent
	Kit.spent += 1
	return p
end

-- ─────────────────────────────────────────────
-- Simple solids
-- ─────────────────────────────────────────────

--- Structural box: collides, casts shadow if large enough.
function Kit.box(
	parent: Instance, name: string, size: Vector3, cf: CFrame,
	color: Color3, material: Enum.Material
): BasePart
	return Kit.newPart({
		name = name, size = size, cf = cf, color = color,
		material = material, parent = parent,
	})
end

--- Trim / detail: never collides, never casts shadow. Use for window frames,
--- railings, kerbs, roof edging, signage backing.
function Kit.trim(
	parent: Instance, name: string, size: Vector3, cf: CFrame,
	color: Color3, material: Enum.Material
): BasePart
	return Kit.newPart({
		name = name, size = size, cf = cf, color = color,
		material = material, parent = parent,
		collide = false, shadow = false,
	})
end

--- Invisible / decorative: no collide, no shadow, no render.
function Kit.marker(parent: Instance, name: string, size: Vector3, cf: CFrame): BasePart
	return Kit.newPart({
		name = name, size = size, cf = cf, color = Color3.new(1, 1, 1),
		parent = parent, collide = false, shadow = false, transparency = 1,
	})
end

function Kit.cylinder(
	parent: Instance, name: string, size: Vector3, cf: CFrame,
	color: Color3, material: Enum.Material, collide: boolean?
): BasePart
	return Kit.newPart({
		name = name, size = size, cf = cf, color = color, material = material,
		parent = parent, shape = Enum.PartType.Cylinder,
		collide = collide ~= false,
	})
end

function Kit.wedge(
	parent: Instance, name: string, size: Vector3, cf: CFrame,
	color: Color3, material: Enum.Material
): BasePart
	return Kit.newPart({
		name = name, size = size, cf = cf, color = color, material = material,
		parent = parent, shape = Enum.PartType.Wedge,
	})
end

-- ─────────────────────────────────────────────
-- Weld
--
-- Multi-part props (a streetlight, a goal, a bench) must move as one unit or
-- they shear apart. BuildKit never parents a sub-part to another part, so
-- callers weld explicitly.
-- ─────────────────────────────────────────────

function Kit.weld(a: BasePart, b: BasePart): WeldConstraint
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
	return w
end

--- Weld every part in `parts` to `root`.
function Kit.weldAll(root: BasePart, parts: { BasePart })
	for _, p in parts do
		if p ~= root then
			Kit.weld(root, p)
		end
	end
end

-- ─────────────────────────────────────────────
-- Lighting helpers
-- ─────────────────────────────────────────────

--- A static light. Kept off by default on low quality so a dense town does not
--- blow the per-cell dynamic light budget.
function Kit.light(
	parent: BasePart, lightClass: string, brightness: number,
	range: number, color: Color3, angleDeg: number?, shadows: boolean?
)
	-- Dynamic lights are the single most expensive thing in a dense scene.
	-- Budget-check before creating one.
	local allowed = Lighting.GlobalShadows and true or true
	if not allowed then return nil end

	local l = Instance.new(lightClass)
	l.Brightness = brightness
	l.Range = range
	l.Color = color
	if angleDeg and l:IsA("SpotLight") then
		l.Angle = angleDeg
		l.Face = Enum.NormalId.Bottom
	end
	if l:IsA("SurfaceLight") or l:IsA("SpotLight") then
		l.Shadows = shadows == true
	end
	l.Parent = parent
	return l
end

-- ─────────────────────────────────────────────
-- Text surfaces
-- ─────────────────────────────────────────────

--- Text painted on a world surface (signs, murals, pitch-side boards).
function Kit.surfaceText(
	part: BasePart, text: string, face: Enum.NormalId,
	textColor: Color3, size: number, font: Enum.Font?
): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	-- SizingMode is left at its default and CanvasSize drives the layout.
	-- Enum.SurfaceGuiSizingMode is absent on some engine builds and referencing
	-- a missing Enum member is a compile-time error that pcall cannot trap.
	gui.PixelsPerStud = 40
	gui.CanvasSize = Vector2.new(512, 128)
	pcall(function() gui.LightInfluence = 0 end)
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = textColor
	label.TextScaled = true
	label.Font = font or Palette.Type.Heading
	label.TextStrokeColor3 = Palette.World.Charcoal
	label.TextStrokeTransparency = 0.45
	label.Parent = gui
	return gui
end

--- Floating world label. Used sparingly for landmarks and zone names.
function Kit.billboard(
	part: BasePart, text: string, offset: Vector3, color: Color3,
	opts: BillboardOpts?
)
	local bbg = Instance.new("BillboardGui")
	bbg.Size = (opts and opts.size) or UDim2.fromOffset(200, 48)
	-- StudsOffsetWorldSpace is newer than StudsOffset; fall back cleanly.
	if not pcall(function() bbg.StudsOffsetWorldSpace = offset end) then
		bbg.StudsOffset = offset
	end
	bbg.AlwaysOnTop = false
	bbg.MaxDistance = (opts and opts.maxDistance) or 90
	pcall(function() bbg.LightInfluence = 0 end)
	bbg.Parent = part

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.TextColor3 = color
	lbl.TextScaled = true
	lbl.Font = Palette.Type.Heading
	lbl.TextStrokeColor3 = Palette.UI.Void
	lbl.TextStrokeTransparency = 0.4
	lbl.Parent = bbg
	return bbg
end

-- ─────────────────────────────────────────────
-- Interaction
--
-- LobbyController routes interactions by an `InteractType` StringValue on the
-- part, and only wires parts that also have a ProximityPrompt. Both are
-- created together here so no builder can forget one.
-- ─────────────────────────────────────────────

function Kit.prompt(
	part: BasePart, interactType: string, action: string, objectText: string,
	distance: number?
): ProximityPrompt
	local tag = part:FindFirstChild("InteractType")
	if not tag then
		tag = Instance.new("StringValue")
		tag.Name = "InteractType"
		tag.Value = interactType
		tag.Parent = part
	end

	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = action
	pp.ObjectText = objectText
	pp.MaxActivationDistance = distance or 10
	pp.HoldDuration = 0
	pp.RequiresLineOfSight = false
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp.GamepadKeyCode = Enum.KeyCode.ButtonX
	pp.Parent = part
	return pp
end

-- ─────────────────────────────────────────────
-- Deterministic randomness
--
-- Variation without Random.new(): a stable seed per building means the town
-- looks the same on every server, so a bug report always matches what the
-- reporter saw.
-- ─────────────────────────────────────────────

--- Stable per-key pseudo-random source.
--- Modular arithmetic rather than bit mixing, because this place's Luau build
--- rejects the bitwise operators.
function Kit.seedFor(key: string): Random
	local h = 5381
	for i = 1, #key do
		h = (h * 33 + key:byte(i)) % 2147483647
	end
	return Random.new(math.abs(h) % 2147483646)
end

--- Pick a value by seed. Deterministic per key.
function Kit.pick<T>(list: { T }, key: string): T
	return list[Kit.seedFor(key):NextInteger(1, #list)]
end

-- ═════════════════════════════════════════════
--  ARCHITECTURE
-- ═════════════════════════════════════════════

-- ─────────────────────────────────────────────
-- Windows
--
-- A window is frame + glass + sill, not a blue rectangle. The frame is what
-- makes a wall read as a building rather than a box.
-- ─────────────────────────────────────────────

function Kit.window(
	parent: Instance, cf: CFrame, w: number, h: number,
	frameColor: Color3?, lit: boolean?
): { BasePart }
	local parts = {}
	local fc = frameColor or Palette.World.OffWhite

	-- Sill
	table.insert(parts, Kit.trim(parent, "WinSill", Vector3.new(w + 1.4, 0.4, 1.2),
		cf * CFrame.new(0, -h / 2 - 0.2, 0.5),
		fc, Palette.Materials.Concrete))

	-- Frame: two vertical mullions + head + cill bar
	table.insert(parts, Kit.trim(parent, "WinFrameL", Vector3.new(0.3, h, 0.3),
		cf * CFrame.new(-w / 2, 0, 0.35), fc, Palette.Materials.WallPanel))
	table.insert(parts, Kit.trim(parent, "WinFrameR", Vector3.new(0.3, h, 0.3),
		cf * CFrame.new(w / 2, 0, 0.35), fc, Palette.Materials.WallPanel))
	table.insert(parts, Kit.trim(parent, "WinFrameT", Vector3.new(w + 0.6, 0.3, 0.3),
		cf * CFrame.new(0, h / 2, 0.35), fc, Palette.Materials.WallPanel))
	table.insert(parts, Kit.trim(parent, "WinFrameB", Vector3.new(w + 0.6, 0.3, 0.3),
		cf * CFrame.new(0, -h / 2, 0.35), fc, Palette.Materials.WallPanel))
	table.insert(parts, Kit.trim(parent, "WinMullion", Vector3.new(0.24, h, 0.26),
		cf * CFrame.new(0, 0, 0.35), fc, Palette.Materials.WallPanel))

	-- Glass. Lit windows are the single cheapest trick for making a town look
	-- inhabited at dusk; they cost nothing because they are trim parts.
	local glassColor = if lit then Palette.Accent.Ember else Palette.World.GlassDark
	table.insert(parts, Kit.trim(parent, "WinGlass", Vector3.new(w - 0.2, h - 0.2, 0.12),
		cf * CFrame.new(0, 0, 0.3), glassColor, Palette.Materials.Glass))

	return parts
end

-- ─────────────────────────────────────────────
-- Doors
-- ─────────────────────────────────────────────

function Kit.door(
	parent: Instance, cf: CFrame, w: number, h: number,
	doorColor: Color3?
): { BasePart }
	local parts = {}
	local dc = doorColor or Palette.World.WoodDark

	-- Recessed frame
	table.insert(parts, Kit.trim(parent, "DoorFrameL", Vector3.new(0.4, h + 0.6, 0.9),
		cf * CFrame.new(-(w / 2 + 0.2), 0, 0.3), Palette.World.OffWhite, Palette.Materials.Wall))
	table.insert(parts, Kit.trim(parent, "DoorFrameR", Vector3.new(0.4, h + 0.6, 0.9),
		cf * CFrame.new(w / 2 + 0.2, 0, 0.3), Palette.World.OffWhite, Palette.Materials.Wall))
	table.insert(parts, Kit.trim(parent, "DoorFrameT", Vector3.new(w + 1.2, 0.4, 0.9),
		cf * CFrame.new(0, h / 2 + 0.2, 0.3), Palette.World.OffWhite, Palette.Materials.Wall))

	-- Panel
	local panel = Kit.trim(parent, "DoorPanel", Vector3.new(w, h, 0.28),
		cf * CFrame.new(0, 0, 0.15), dc, Palette.Materials.WallWood)
	table.insert(parts, panel)

	-- Handle
	table.insert(parts, Kit.trim(parent, "DoorHandle", Vector3.new(0.18, 0.18, 0.18),
		cf * CFrame.new(w / 2 - 0.5, 0, 0.32), Palette.World.MetalLight, Palette.Materials.Metal))

	return parts
end

-- ─────────────────────────────────────────────
-- Roofs
--
-- Four variants so no two houses share a silhouette. A pitched roof is two
-- slabs plus a ridge; a flat roof is a parapet.
-- ─────────────────────────────────────────────

Kit.RoofStyle = {
	FLAT    = "Flat",
	GABLED = "Gabled",
	HIP    = "Hip",
	SHED   = "Shed",
}

function Kit.roof(
	parent: Instance, name: string, origin: Vector3, w: number, d: number,
	wallH: number, style: string, roofColor: Color3, ridgeDir: string?
)
	local y = origin.Y + wallH
	local mat = if style == Kit.RoofStyle.GABLED or style == Kit.RoofStyle.HIP
		then Palette.Materials.RoofTile else Palette.Materials.Roof
	local overhang = 0.8

	if style == Kit.RoofStyle.FLAT then
		-- Parapet roof: slab + four low walls. Reads far better than a flat top.
		Kit.trim(parent, name .. "_Deck", Vector3.new(w + 1, 0.5, d + 1),
			CFrame.new(origin.X, y + 0.25, origin.Z), roofColor, mat)
		Kit.trim(parent, name .. "_ParapetN", Vector3.new(w + 1, 1.2, 0.4),
			CFrame.new(origin.X, y + 1.1, origin.Z - d / 2), roofColor, mat)
		Kit.trim(parent, name .. "_ParapetS", Vector3.new(w + 1, 1.2, 0.4),
			CFrame.new(origin.X, y + 1.1, origin.Z + d / 2), roofColor, mat)
		Kit.trim(parent, name .. "_ParapetE", Vector3.new(0.4, 1.2, d + 1),
			CFrame.new(origin.X + w / 2, y + 1.1, origin.Z), roofColor, mat)
		Kit.trim(parent, name .. "_ParapetW", Vector3.new(0.4, 1.2, d + 1),
			CFrame.new(origin.X - w / 2, y + 1.1, origin.Z), roofColor, mat)
		-- Roof clutter: vents and a tank read as "real building"
		Kit.cylinder(parent, name .. "_Vent",
			Vector3.new(1.2, 1.2, 1.2), CFrame.new(origin.X + w * 0.3, y + 1.5, origin.Z),
			Palette.World.Metal, Palette.Materials.Metal)
		return
	end

	if style == Kit.RoofStyle.SHED then
		local slabSize = Vector3.new(w + overhang * 2, 0.5, d + overhang * 2)
		local cf = CFrame.new(origin.X, y + 1.2, origin.Z) * CFrame.Angles(math.rad(-12), 0, 0)
		Kit.trim(parent, name .. "_Slab", slabSize, cf, roofColor, mat)
		return
	end

	-- Gabled / Hip: two pitched slabs meeting at a ridge.
	local alongX = ridgeDir == "X"
	local slopeLen = if alongX
		then Vector3.new(d + overhang * 2, 0.5, math.sqrt(w * w / 4 + 2.2 * 2.2))
		else Vector3.new(math.sqrt(d * d / 4 + 2.2 * 2.2), 0.5, w + overhang * 2)

	local pitch = math.atan2(2.2, (if alongX then w else d) / 2)

	if alongX then
		-- Ridge runs along X; slabs face +/- Z
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(parent, name .. "_Pitch" .. (s < 0 and "N" or "S"),
				Vector3.new(d + overhang * 2, 0.5, slopeLen.Z),
				CFrame.new(origin.X, y + 1.1, origin.Z + s * w / 4)
					* CFrame.Angles(s * pitch, 0, 0),
				roofColor, mat)
		end
		Kit.trim(parent, name .. "_Ridge", Vector3.new(d + overhang * 2 + 0.6, 0.5, 0.6),
			CFrame.new(origin.X, y + 2.3, origin.Z), roofColor, mat)
		-- Gable end walls fill the triangle
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(parent, name .. "_Gable" .. (s < 0 and "W" or "E"),
				Vector3.new(0.4, 2.2, w), CFrame.new(origin.X + s * d / 2, y + 1.1, origin.Z),
				roofColor, mat)
		end
	else
		-- Ridge runs along Z; slabs face +/- X
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(parent, name .. "_Pitch" .. (s < 0 and "W" or "E"),
				Vector3.new(slopeLen.X, 0.5, w + overhang * 2),
				CFrame.new(origin.X + s * d / 4, y + 1.1, origin.Z)
					* CFrame.Angles(0, 0, -s * pitch),
				roofColor, mat)
		end
		Kit.trim(parent, name .. "_Ridge", Vector3.new(0.6, 0.5, w + overhang * 2 + 0.6),
			CFrame.new(origin.X, y + 2.3, origin.Z), roofColor, mat)
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(parent, name .. "_Gable" .. (s < 0 and "N" or "S"),
				Vector3.new(d, 2.2, 0.4), CFrame.new(origin.X, y + 1.1, origin.Z + s * w / 2),
				roofColor, mat)
		end
	end
end

-- ─────────────────────────────────────────────
-- Building
--
-- The core variation-driven building generator. Produces a shell (walls),
-- a roof, a door, windows on a floor grid, and optional extras (balcony,
-- ground-floor shopfront, AC units, downpipe).
--
-- All of the "identical cube" problem is solved here: every dimension is a
-- parameter and window layout is derived from the actual wall size.
-- ─────────────────────────────────────────────

export type BuildingOpts = {
	parent: Instance,
	origin: Vector3,
	width: number,
	depth: number,
	floors: number,
	floorHeight: number?,
	rotY: number?,
	wallColor: Color3,
	trimColor: Color3?,
	roofStyle: string?,
	roofColor: Color3?,
	material: Enum.Material?,
	shopfront: boolean?,
	balcony: boolean?,
	acUnits: boolean?,
	downpipe: boolean?,
	litRatio: number?,
	seed: string,
}

function Kit.building(o: BuildingOpts): Model
	local rng = Kit.seedFor(o.seed)
	local parent = o.parent
	local origin = o.origin
	local W = o.width
	local D = o.depth
	local floors = o.floors
	local FH = o.floorHeight or 11
	local H = floors * FH
	local rot = o.rotY or 0

	local model = Kit.model(o.seed, parent)
	local wallMat = o.material or Palette.Materials.Wall
	local trimC = o.trimColor or Palette.World.OffWhite
	local roofC = o.roofColor or Palette.World.TileRoof
	local litRatio = o.litRatio or 0.25

	local base = CFrame.new(origin) * CFrame.Angles(0, rot, 0)

	-- ── Main mass ────────────────────────────────────────────────────────
	-- One solid block for the shell. Walls are implied by the material and by
	-- the window/door trim applied over the surface, which is far cheaper
	-- than four separate wall parts per floor and reads identically at play
	-- distance.
	local shell = Kit.box(model, "Shell", Vector3.new(W, H, D),
		base * CFrame.new(0, H / 2, 0), o.wallColor, wallMat)

	-- ── Plinth: a slightly wider base course stops the building floating ──
	Kit.trim(model, "Plinth", Vector3.new(W + 0.5, 1.2, D + 0.5),
		base * CFrame.new(0, 0.6, 0), Palette.World.ConcreteDark, Palette.Materials.Wall)

	-- ── Windows ──────────────────────────────────────────────────────────
	-- Grid derived from real dimensions, not a fixed count.
	local winW = 4.2
	local winH = 4.6
	local perSide = math.max(1, math.floor((W - 5) / 8))
	local perSideD = math.max(1, math.floor((D - 5) / 8))

	for floor = 0, floors - 1 do
		local y = FH * floor + FH * 0.58

		-- Front and back (facing +/- Z)
		for side = 0, 1 do
			local sign = if side == 0 then -1 else 1
			for i = 1, perSide do
				local t = (i - 0.5) / perSide
				local x = (t - 0.5) * (W - 6)
				-- Skip the ground floor front centre if there is a shopfront.
				if not (floor == 0 and side == 0 and o.shopfront and math.abs(x) < 4) then
					local lit = rng:NextNumber() < litRatio
					Kit.window(model,
						base * CFrame.new(x, y, sign * (D / 2)) * CFrame.Angles(0, if sign < 0 then math.pi else 0, 0),
						winW, winH, trimC, lit)
				end
			end
		end

		-- Left and right (facing +/- X)
		for side = 0, 1 do
			local sign = if side == 0 then -1 else 1
			for i = 1, perSideD do
				local t = (i - 0.5) / perSideD
				local z = (t - 0.5) * (D - 6)
				local lit = rng:NextNumber() < litRatio
				Kit.window(model,
					base * CFrame.new(sign * (W / 2), y, z) * CFrame.Angles(0, sign * math.pi / 2, 0),
					winW, winH, trimC, lit)
			end
		end
	end

	-- ── Entrance ─────────────────────────────────────────────────────────
	local doorZ = -(D / 2)
	local entranceY = FH * 0.32
	if o.shopfront then
		-- Shopfront: wide glazed ground floor with a fascia and an awning.
		Kit.trim(model, "ShopGlass", Vector3.new(W - 4, FH * 0.62, 0.2),
			base * CFrame.new(0, FH * 0.34, doorZ - 0.1), Palette.World.Glass, Palette.Materials.Glass)
		Kit.trim(model, "ShopFascia", Vector3.new(W - 2, 1.8, 0.5),
			base * CFrame.new(0, FH * 0.72, doorZ - 0.2), trimC, Palette.Materials.WallPanel)
		-- Awning
		Kit.trim(model, "Awning", Vector3.new(W - 3, 0.3, 3.2),
			base * CFrame.new(0, FH * 0.80, doorZ - 1.8) * CFrame.Angles(math.rad(14), 0, 0),
			o.wallColor, Palette.Materials.Fabric)
		-- Awning supports
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(model, "AwningPost" .. s, Vector3.new(0.22, FH * 0.5, 0.22),
				base * CFrame.new(s * (W / 2 - 2), FH * 0.5, doorZ - 3), Palette.World.Metal, Palette.Materials.Metal)
		end
		-- One glass door in the shopfront
		Kit.trim(model, "ShopDoor", Vector3.new(2.6, FH * 0.55, 0.24),
			base * CFrame.new(0, FH * 0.3, doorZ - 0.2), Palette.World.GlassDark, Palette.Materials.Glass)
	else
		-- Residential: door + porch canopy + step
		Kit.door(model, base * CFrame.new(0, entranceY, doorZ), 3.4, 6, Palette.World.WoodDark)
		Kit.trim(model, "Porch", Vector3.new(5, 0.3, 2.2),
			base * CFrame.new(0, entranceY + 3.4, doorZ - 1.0), trimC, Palette.Materials.Roof)
		Kit.trim(model, "Step", Vector3.new(5.4, 0.5, 1.6),
			base * CFrame.new(0, 0.25, doorZ - 1.4), Palette.World.ConcreteLight, Palette.Materials.Path)
	end

	-- ── Roof ─────────────────────────────────────────────────────────────
	Kit.roof(model, "Roof", origin, W, D, H,
		o.roofStyle or Kit.RoofStyle.FLAT, roofC,
		if rng:NextNumber() < 0.5 then "X" else "Z")

	-- ── Balcony ──────────────────────────────────────────────────────────
	if o.balcony and floors >= 2 then
		local by = FH * 1.45
		Kit.trim(model, "BalconySlab", Vector3.new(W * 0.5, 0.4, 3.0),
			base * CFrame.new(0, by, doorZ - 1.5), Palette.World.ConcreteLight, Palette.Materials.Path)
		Kit.railing(model,
			base * CFrame.new(0, by, doorZ - 3.0) * CFrame.Angles(0, 0, 0),
			W * 0.5, 1.4, 3.0, Palette.World.MetalLight)
		-- Balcony doors
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(model, "BalconyDoor" .. s, Vector3.new(0.2, 3.2, 2.6),
				base * CFrame.new(s * (W * 0.5 - 1.2), by + 1.8, doorZ - 1.5),
				Palette.World.GlassDark, Palette.Materials.Glass)
		end
	end

	-- ── AC units + downpipe: the details that separate a building from a box
	if o.acUnits ~= false then
		local count = 1 + rng:NextInteger(0, 2)
		for i = 1, count do
			local s = if rng:NextNumber() < 0.5 then -1 else 1
			local yy = FH * (0.5 + i * 0.45)
			Kit.trim(model, "ACUnit" .. i, Vector3.new(1.6, 1.2, 1.0),
				base * CFrame.new(s * (W / 2 + 0.5), yy, (rng:NextNumber() - 0.5) * D * 0.6),
				Palette.World.Metal, Palette.Materials.Metal)
		end
	end

	if o.downpipe ~= false then
		Kit.trim(model, "Downpipe", Vector3.new(0.35, H, 0.35),
			base * CFrame.new(W / 2 - 0.6, H / 2, D / 2 + 0.15),
			Palette.World.Metal, Palette.Materials.Metal)
	end

	model.PrimaryPart = shell
	return model
end

-- ─────────────────────────────────────────────
-- Railings and stairs
-- ─────────────────────────────────────────────

--- Stadium / balcony railing: two horizontal rails plus evenly spaced posts.
function Kit.railing(
	parent: Instance, cf: CFrame, length: number, height: number, depth: number,
	color: Color3?
)
	local c = color or Palette.World.MetalLight
	local mat = Palette.Materials.Metal
	local postEvery = 8

	Kit.trim(parent, "RailTop", Vector3.new(length, 0.16, 0.16),
		cf * CFrame.new(0, height, 0), c, mat)
	Kit.trim(parent, "RailMid", Vector3.new(length, 0.12, 0.12),
		cf * CFrame.new(0, height * 0.55, 0), c, mat)

	local posts = math.max(2, math.floor(length / postEvery) + 1)
	for i = 0, posts do
		local t = i / posts
		Kit.trim(parent, "RailPost" .. i, Vector3.new(0.18, height, 0.18),
			cf * CFrame.new((t - 0.5) * length, height / 2, 0), c, mat)
	end
end

--- A straight run of steps. Built as a single wedge-plus-treads group so a
--- stadium stairway reads as a stairway rather than a ramp.
function Kit.stairs(
	parent: Instance, name: string, base: CFrame, width: number,
	rise: number, run: number, steps: number, color: Color3?
)
	local c = color or Palette.World.ConcreteLight
	local mat = Palette.Materials.Path
	local stepRise = rise / steps
	local stepRun = run / steps

	for i = 1, steps do
		-- Each step is a block sitting on the previous, so the run is solid.
		local h = stepRise * i
		local z = (i - 1) * stepRun
		Kit.trim(parent, name .. "_Step" .. i, Vector3.new(width, h, stepRun),
			base * CFrame.new(0, h / 2, z + stepRun / 2), c, mat)
	end

	-- Handrail down the centre-line of one edge.
	local mid = base * CFrame.new(width / 2 - 0.4, 0, 0)
	Kit.trim(parent, name .. "_Rail", Vector3.new(0.16, 0.16, run),
		mid * CFrame.new(0, rise + 1.2, run / 2) * CFrame.Angles(-math.atan2(rise, run), 0, 0),
		Palette.World.MetalLight, Palette.Materials.Metal)
end

-- ─────────────────────────────────────────────
-- Ground surfaces
-- ─────────────────────────────────────────────

--- Road with centre line and kerbs. Kerbs are trim so they never trip physics.
function Kit.road(
	parent: Instance, name: string,
	startPos: Vector3, endPos: Vector3, width: number,
	opts: RoadOpts?
)
	local opts = opts or {}
	local mid = (startPos + endPos) / 2
	local dir = endPos - startPos
	local len = dir.Magnitude
	if len < 1 then return end

	local cf = CFrame.lookAt(mid, endPos)
	local mat = Palette.Materials.Road

	Kit.trim(parent, name, Vector3.new(width, 0.4, len), cf,
		Palette.World.Asphalt, mat)

	if opts.line then
		-- Dashed centre line
		local dash = 14
		local gap = 10
		local n = math.floor(len / (dash + gap))
		for i = 1, n do
			local z = (i - 1) * (dash + gap) - len / 2 + dash / 2
			Kit.trim(parent, name .. "_Dash" .. i, Vector3.new(0.5, 0.06, dash),
				cf * CFrame.new(0, 0.23, z), Palette.World.RoadLine, Palette.Materials.Line)
		end
		-- Edge lines
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(parent, name .. "_Edge" .. s, Vector3.new(0.35, 0.06, len),
				cf * CFrame.new(s * (width / 2 - 1.4), 0.23, 0), Palette.World.RoadLine, Palette.Materials.Line)
		end
	end

	if opts.kerb then
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(parent, name .. "_Kerb" .. s, Vector3.new(0.8, 0.7, len),
				cf * CFrame.new(s * (width / 2 + 0.4), 0.1, 0), Palette.World.Kerb, Palette.Materials.Path)
		end
	end
end

--- Pavement strip alongside a road, with a kerb face.
function Kit.pavement(
	parent: Instance, name: string,
	startPos: Vector3, endPos: Vector3, width: number
)
	local mid = (startPos + endPos) / 2
	local dir = endPos - startPos
	local len = dir.Magnitude
	if len < 1 then return end
	local cf = CFrame.lookAt(mid, endPos)

	Kit.trim(parent, name, Vector3.new(width, 0.5, len), cf * CFrame.new(0, 0.05, 0),
		Palette.World.Pavement, Palette.Materials.Path)
	-- Kerb face toward the road
	Kit.trim(parent, name .. "_Kerb", Vector3.new(0.5, 0.7, len),
		cf * CFrame.new(-width / 2 + 0.25, 0.05, 0), Palette.World.Kerb, Palette.Materials.Path)
end

--- Pitch surface: mown stripes, so the largest surface in the game is not flat.
function Kit.pitch(
	parent: Instance, name: string, centre: Vector3, width: number, length: number,
	stripeCount: number
)
	-- Base
	Kit.trim(parent, name, Vector3.new(width, 0.6, length),
		CFrame.new(centre.X, centre.Y, centre.Z), Palette.World.Grass, Palette.Materials.Pitch)

	-- Mown stripes: alternating tone, no collision, sitting just above.
	local stripeLen = length / stripeCount
	for i = 0, stripeCount - 1 do
		if i % 2 == 1 then
			local z = centre.Z - length / 2 + stripeLen * (i + 0.5)
			Kit.trim(parent, name .. "_Stripe" .. i, Vector3.new(width, 0.05, stripeLen),
				CFrame.new(centre.X, centre.Y + 0.33, z), Palette.World.GrassDark, Palette.Materials.Line)
		end
	end

	-- A darker run-off apron around the playing surface.
	local apron = 6
	Kit.trim(parent, name .. "_ApronN", Vector3.new(width + apron * 2, 0.4, apron),
		CFrame.new(centre.X, centre.Y - 0.1, centre.Z - length / 2 - apron / 2),
		Palette.World.GrassDark, Palette.Materials.Pitch)
	Kit.trim(parent, name .. "_ApronS", Vector3.new(width + apron * 2, 0.4, apron),
		CFrame.new(centre.X, centre.Y - 0.1, centre.Z + length / 2 + apron / 2),
		Palette.World.GrassDark, Palette.Materials.Pitch)
	Kit.trim(parent, name .. "_ApronE", Vector3.new(apron, 0.4, length),
		CFrame.new(centre.X + width / 2 + apron / 2, centre.Y - 0.1, centre.Z),
		Palette.World.GrassDark, Palette.Materials.Pitch)
	Kit.trim(parent, name .. "_ApronW", Vector3.new(apron, 0.4, length),
		CFrame.new(centre.X - width / 2 - apron / 2, centre.Y - 0.1, centre.Z),
		Palette.World.GrassDark, Palette.Materials.Pitch)
end

-- ─────────────────────────────────────────────
-- Pitch markings
--
-- Drawn as thin non-colliding trim. Kept in BuildKit so the training pitch and
-- the main stadium use identical line weight and colour.
-- ─────────────────────────────────────────────

local LINE_T = 0.5
local LINE_H = 0.08

local function line(parent: Instance, size: Vector3, cf: CFrame)
	Kit.trim(parent, "Mark", size, cf, Palette.World.White, Palette.Materials.Line)
end

--- Full football markings: touchlines, goal lines, halfway, centre circle and
--- spot, both penalty areas, both goal areas, penalty spots, corner arcs.
function Kit.pitchMarkings(
	parent: Instance, name: string, centre: Vector3, width: number, length: number,
	opts: { circleR: number, penW: number, penD: number, goalW: number, goalD: number }?
)
	local o = opts or {}
	local R = o.circleR or 24
	local penW = o.penW or 72
	local penD = o.penD or 48
	local goalW = o.goalW or 32
	local goalD = o.goalD or 16
	local y = centre.Y + 0.35
	local hw = width / 2
	local hl = length / 2
	local g = Kit.folder(name, parent)

	-- Touchlines
	line(g, Vector3.new(LINE_T, LINE_H, length), CFrame.new(centre.X, y, centre.Z - hl))
	line(g, Vector3.new(LINE_T, LINE_H, length), CFrame.new(centre.X, y, centre.Z + hl))
	-- Goal lines
	line(g, Vector3.new(width, LINE_H, LINE_T), CFrame.new(centre.X - hw, y, centre.Z))
	line(g, Vector3.new(width, LINE_H, LINE_T), CFrame.new(centre.X + hw, y, centre.Z))
	-- Halfway
	line(g, Vector3.new(width, LINE_H, LINE_T), CFrame.new(centre.X, y, centre.Z))

	-- Centre circle — arc segments
	local segs = 28
	for i = 0, segs - 1 do
		local a1 = (i / segs) * math.pi * 2
		local a2 = ((i + 1) / segs) * math.pi * 2
		local midA = (a1 + a2) / 2
		local segLen = 2 * R * math.sin(math.pi / segs) + 0.3
		line(g, Vector3.new(LINE_T, LINE_H, segLen),
			CFrame.new(centre.X + math.cos(midA) * R, y, centre.Z + math.sin(midA) * R)
				* CFrame.Angles(0, -midA, 0))
	end
	-- Centre spot
	line(g, Vector3.new(2.4, LINE_H, 2.4), CFrame.new(centre.X, y, centre.Z))

	for _, s in ipairs({ -1, 1 }) do
		local endZ = centre.Z + s * hl
		-- Penalty area: three sides
		line(g, Vector3.new(penW, LINE_H, LINE_T), CFrame.new(centre.X, y, endZ - s * penD))
		line(g, Vector3.new(LINE_T, LINE_H, penD), CFrame.new(centre.X - penW / 2, y, endZ - s * penD / 2))
		line(g, Vector3.new(LINE_T, LINE_H, penD), CFrame.new(centre.X + penW / 2, y, endZ - s * penD / 2))
		-- Penalty spot
		line(g, Vector3.new(2.4, LINE_H, 2.4), CFrame.new(centre.X, y, endZ - s * 36))
		-- Goal area
		line(g, Vector3.new(goalW, LINE_H, LINE_T), CFrame.new(centre.X, y, endZ - s * goalD))
		line(g, Vector3.new(LINE_T, LINE_H, goalD), CFrame.new(centre.X - goalW / 2, y, endZ - s * goalD / 2))
		line(g, Vector3.new(LINE_T, LINE_H, goalD), CFrame.new(centre.X + goalW / 2, y, endZ - s * goalD / 2))
		-- Corner arc
		for i = 0, 7 do
			local a = (i / 8) * math.pi / 2
			local cx = centre.X + s * hw
			local cz = endZ
			local px = cx - s * math.cos(a) * 8
			local pz = cz + math.sin(a) * 8
			line(g, Vector3.new(LINE_T, LINE_H, 1.6),
				CFrame.new(px, y, pz) * CFrame.Angles(0, s * (math.pi / 2 - a), 0))
		end
	end
	return g
end

-- ─────────────────────────────────────────────
-- Goal
--
-- Posts + crossbar in metal, netting as translucent panels, plus an invisible
-- trigger volume the goal-detection code can watch.
-- ─────────────────────────────────────────────

function Kit.goal(
	parent: Instance, name: string, goalPos: Vector3, zSign: number,
	width: number, height: number, depth: number, accent: Color3
): { trigger: BasePart, parts: { BasePart } }
	local g = Kit.folder(name, parent)
	local parts: { BasePart } = {}
	local postT = 0.6
	local white = Palette.World.White
	local metal = Palette.Materials.Metal

	local function add(p: BasePart) table.insert(parts, p) return p end

	-- Posts
	add(Kit.trim(g, name .. "_PostL", Vector3.new(postT, height, postT),
		CFrame.new(goalPos.X - width / 2, goalPos.Y + height / 2, goalPos.Z), white, metal))
	add(Kit.trim(g, name .. "_PostR", Vector3.new(postT, height, postT),
		CFrame.new(goalPos.X + width / 2, goalPos.Y + height / 2, goalPos.Z), white, metal))
	-- Crossbar
	add(Kit.trim(g, name .. "_Bar", Vector3.new(width + postT, postT, postT),
		CFrame.new(goalPos.X, goalPos.Y + height, goalPos.Z), white, metal))
	-- Rear stanchions
	add(Kit.trim(g, name .. "_StayL", Vector3.new(postT * 0.8, height, postT * 0.8),
		CFrame.new(goalPos.X - width / 2, goalPos.Y + height / 2, goalPos.Z + zSign * depth), white, metal))
	add(Kit.trim(g, name .. "_StayR", Vector3.new(postT * 0.8, height, postT * 0.8),
		CFrame.new(goalPos.X + width / 2, goalPos.Y + height / 2, goalPos.Z + zSign * depth), white, metal))
	add(Kit.trim(g, name .. "_StayBar", Vector3.new(width, postT * 0.8, postT * 0.8),
		CFrame.new(goalPos.X, goalPos.Y + height, goalPos.Z + zSign * depth), white, metal))

	-- Netting. Translucent, non-colliding, and slightly transparent so the
	-- crowd behind the goal stays readable.
	local netMat = Palette.Materials.Fabric
	for _, spec in ipairs({
		{ n = "NetBack", s = Vector3.new(width, height, 0.1), o = Vector3.new(0, height / 2, zSign * depth) },
		{ n = "NetTop",  s = Vector3.new(width, 0.1, depth),    o = Vector3.new(0, height, zSign * depth / 2) },
		{ n = "NetL",    s = Vector3.new(0.1, height, depth),  o = Vector3.new(-width / 2, height / 2, zSign * depth / 2) },
		{ n = "NetR",    s = Vector3.new(0.1, height, depth),  o = Vector3.new(width / 2, height / 2, zSign * depth / 2) },
	}) do
		local p = add(Kit.trim(g, name .. "_" .. spec.n, spec.s,
			CFrame.new(goalPos.X + spec.o.X, goalPos.Y + spec.o.Y, goalPos.Z + spec.o.Z),
			Palette.World.OffWhite, netMat))
		p.Transparency = 0.82
	end

	-- Accent: a controlled glow on the crossbar only. This is a landmark, so
	-- accent colour is justified here.
	local glow = add(Kit.trim(g, name .. "_Glow", Vector3.new(width + 1.4, 0.3, 0.3),
		CFrame.new(goalPos.X, goalPos.Y + height + 0.5, goalPos.Z), accent, Palette.Materials.Metal))
	glow.Transparency = 0.25

	-- Detection volume. Inset from the goal line so the ball must genuinely
	-- cross, and named GoalX_Trigger because BallService looks for that.
	local trigger = Kit.marker(g, name .. "_Trigger",
		Vector3.new(width - 1, height - 1, depth - 1),
		CFrame.new(goalPos.X, goalPos.Y + (height - 1) / 2, goalPos.Z + zSign * (depth / 2)))

	return { trigger = trigger, parts = parts }
end

-- ─────────────────────────────────────────────
-- Street furniture
-- ─────────────────────────────────────────────

function Kit.streetlight(
	parent: Instance, name: string, pos: Vector3, rotY: number,
	lit: boolean?
)
	local g = Kit.folder(name, parent)
	local cf = CFrame.new(pos) * CFrame.Angles(0, rotY, 0)
	local metal = Palette.Materials.Metal
	local c = Palette.World.MetalDark

	-- Base
	Kit.trim(g, name .. "_Base", Vector3.new(1.6, 0.8, 1.6), cf * CFrame.new(0, 0.4, 0),
		Palette.World.ConcreteDark, Palette.Materials.Path)
	-- Column, slightly tapered look via a second thinner upper section
	Kit.trim(g, name .. "_Post", Vector3.new(0.55, 20, 0.55), cf * CFrame.new(0, 10, 0), c, metal)
	-- Arm
	Kit.trim(g, name .. "_Arm", Vector3.new(3.6, 0.4, 0.4),
		cf * CFrame.new(1.8, 19.8, 0) * CFrame.Angles(0, 0, math.rad(-6)), c, metal)
	-- Head
	Kit.trim(g, name .. "_Head", Vector3.new(1.6, 0.5, 1.0),
		cf * CFrame.new(3.4, 19.4, 0), Palette.World.MetalLight, metal)

	if lit then
		local lens = Kit.trim(g, name .. "_Lens", Vector3.new(1.3, 0.2, 0.8),
			cf * CFrame.new(3.4, 19.1, 0), Palette.Accent.Ember, Palette.Materials.Metal)
		lens.Transparency = 0.2
		local light = Instance.new("PointLight")
		light.Brightness = 0.8
		light.Range = 26
		light.Color = Palette.Accent.Ember
		light.Shadows = false
		light.Parent = lens
	end
	return g
end

function Kit.bench(parent: Instance, name: string, pos: Vector3, rotY: number)
	local g = Kit.folder(name, parent)
	local cf = CFrame.new(pos) * CFrame.Angles(0, rotY, 0)
	local wood = Palette.World.Wood
	local metal = Palette.Materials.Metal

	-- Slats
	for i = 1, 3 do
		Kit.trim(g, name .. "_Slat" .. i, Vector3.new(7, 0.3, 1.5),
			cf * CFrame.new(0, 1.7 + i * 0.75, (i - 2) * 0.55) * CFrame.Angles(math.rad(-12), 0, 0),
			wood, Palette.Materials.WallWood)
	end
	-- Legs
	for _, s in ipairs({ -1, 1 }) do
		Kit.trim(g, name .. "_Leg" .. s, Vector3.new(0.3, 1.8, 0.3),
			cf * CFrame.new(s * 2.8, 0.9, 0), Palette.World.MetalDark, metal)
	end
	return g
end

function Kit.litterBin(parent: Instance, name: string, pos: Vector3)
	local g = Kit.folder(name, parent)
	Kit.trim(g, name .. "_Body", Vector3.new(1.8, 2.4, 1.8),
		CFrame.new(pos.X, pos.Y + 1.2, pos.Z), Palette.World.MetalDark, Palette.Materials.Metal)
	Kit.trim(g, name .. "_Lid", Vector3.new(2.0, 0.25, 2.0),
		CFrame.new(pos.X, pos.Y + 2.5, pos.Z), Palette.World.Metal, Palette.Materials.Metal)
	-- Opening
	Kit.trim(g, name .. "_Slot", Vector3.new(1.0, 0.4, 0.3),
		CFrame.new(pos.X, pos.Y + 2.2, pos.Z - 0.85), Palette.World.Void, Palette.Materials.Metal)
	return g
end

function Kit.fence(
	parent: Instance, name: string, startPos: Vector3, endPos: Vector3,
	height: number, opts: FenceOpts?
)
	local opts = opts or {}
	local mid = (startPos + endPos) / 2
	local dir = endPos - startPos
	local len = dir.Magnitude
	if len < 1 then return end
	local cf = CFrame.lookAt(mid, endPos)
	local c = Palette.World.MetalDark
	local mat = if opts.mesh then Palette.Materials.Fence else Palette.Materials.Metal

	-- Top and bottom rails
	Kit.trim(parent, name .. "_Top", Vector3.new(0.18, 0.18, len),
		cf * CFrame.new(0, height, 0), c, mat)
	Kit.trim(parent, name .. "_Bot", Vector3.new(0.18, 0.18, len),
		cf * CFrame.new(0, height * 0.45, 0), c, mat)
	-- Posts
	local every = 12
	local n = math.max(2, math.floor(len / every) + 1)
	for i = 0, n do
		Kit.trim(parent, name .. "_Post" .. i, Vector3.new(0.3, height, 0.3),
			cf * CFrame.new(0, height / 2, (i / n - 0.5) * len), c, mat)
	end
	-- Infill: vertical bars read as a fence at distance for far less cost
	-- than a mesh panel, and they need no texture.
	if opts.mesh then
		local barEvery = 2.2
		local bars = math.min(90, math.floor(len / barEvery))
		for i = 1, bars do
			Kit.trim(parent, name .. "_Bar" .. i, Vector3.new(0.1, height, 0.1),
				cf * CFrame.new(0, height / 2, (i / (bars + 1) - 0.5) * len), c, mat)
		end
	end
end

function Kit.tree(parent: Instance, name: string, pos: Vector3, scale: number?, seed: string?)
	local g = Kit.folder(name, parent)
	local rng = Kit.seedFor(seed or name)
	local s = scale or (0.85 + rng:NextNumber() * 0.45)
	local cf = CFrame.new(pos)
	local trunkH = 7 * s

	-- Trunk: slight taper illusion via two stacked cylinders
	Kit.cylinder(g, name .. "_Trunk", Vector3.new(1.5 * s, trunkH, 1.5 * s),
		cf * CFrame.new(0, trunkH / 2, 0), Palette.World.Trunk, Palette.Materials.WallWood)
	Kit.cylinder(g, name .. "_Trunk2", Vector3.new(1.0 * s, 3 * s, 1.0 * s),
		cf * CFrame.new(0, trunkH + 1.2 * s, 0), Palette.World.Trunk, Palette.Materials.WallWood)

	-- Canopy: three offset spheres, which reads far more like a tree than a
	-- single ball does.
	local r1 = 6.5 * s
	local canopy = if rng:NextNumber() < 0.5 then Palette.World.Foliage else Palette.World.FoliageLight
	for i, spec in ipairs({
		{ o = Vector3.new(0, trunkH + 2.4 * s, 0), r = r1 },
		{ o = Vector3.new(r1 * 0.55, trunkH + 1.2 * s, r1 * 0.3), r = r1 * 0.75 },
		{ o = Vector3.new(-r1 * 0.5, trunkH + 1.6 * s, -r1 * 0.35), r = r1 * 0.7 },
	}) do
		Kit.newPart({
			name = name .. "_Canopy" .. i,
			size = Vector3.new(spec.r * 2, spec.r * 1.7, spec.r * 2),
			cf = cf * CFrame.new(spec.o.X, spec.o.Y, spec.o.Z),
			color = canopy, material = Palette.Materials.LeafyGrass,
			parent = g, collide = false, shadow = true, shape = Enum.PartType.Ball,
		})
	end
	return g
end

function Kit.bush(parent: Instance, name: string, pos: Vector3, scale: number?, seed: string?)
	local rng = Kit.seedFor(seed or name)
	local s = scale or (0.8 + rng:NextNumber() * 0.4)
	Kit.newPart({
		name = name, size = Vector3.new(3.4 * s, 2.6 * s, 3.4 * s),
		cf = CFrame.new(pos.X, pos.Y + 1.3 * s, pos.Z),
		color = Palette.World.Bush, material = Palette.Materials.LeafyGrass,
		parent = parent, collide = false, shadow = true, shape = Enum.PartType.Ball,
	})
end

-- ─────────────────────────────────────────────
-- Signage and banners — football culture
-- ─────────────────────────────────────────────

--- A wall-mounted or post-mounted sign with readable text.
function Kit.sign(
	parent: Instance, name: string, pos: Vector3, rotY: number,
	width: number, height: number, text: string,
	opts: SignOpts?
)
	local o = opts or {}
	local g = Kit.folder(name, parent)
	local cf = CFrame.new(pos) * CFrame.Angles(0, rotY, 0)

	if o.post then
		local ph = o.postHeight or (pos.Y + height / 2)
		for _, s in ipairs({ -1, 1 }) do
			Kit.trim(g, name .. "_Post" .. s, Vector3.new(0.4, ph, 0.4),
				cf * CFrame.new(s * (width / 2 - 0.5), -height / 2 - ph / 2 + 0.2, 0),
				Palette.World.MetalDark, Palette.Materials.Metal)
		end
	end

	local board = Kit.trim(g, name .. "_Board", Vector3.new(width, height, 0.3),
		cf, o.bg or Palette.World.Navy, Palette.Materials.WallPanel)
	-- Border
	Kit.trim(g, name .. "_Border", Vector3.new(width + 0.4, height + 0.4, 0.15),
		cf * CFrame.new(0, 0, -0.1), Palette.World.MetalLight, Palette.Materials.Metal)

	Kit.surfaceText(board, text, Enum.NormalId.Front,
		o.textColor or Palette.World.White, 64, Palette.Type.Display)

	-- Back faces are common on double-sided signs; make them read too.
	Kit.surfaceText(board, text, Enum.NormalId.Back,
		o.textColor or Palette.World.White, 64, Palette.Type.Display)
	return g
end

--- A hanging banner or flag. Cloth material, gentle wave via a skewed part.
function Kit.banner(
	parent: Instance, name: string, pos: Vector3, rotY: number,
	width: number, height: number, color: Color3, text: string?
)
	local g = Kit.folder(name, parent)
	local cf = CFrame.new(pos) * CFrame.Angles(0, rotY, 0)

	local cloth = Kit.trim(g, name .. "_Cloth", Vector3.new(width, height, 0.15),
		cf, color, Palette.Materials.Fabric)
	cloth.Transparency = 0.12

	-- Top rail with eyelets
	Kit.trim(g, name .. "_Rail", Vector3.new(width + 0.6, 0.35, 0.35),
		cf * CFrame.new(0, height / 2 + 0.2, 0), Palette.World.Metal, Palette.Materials.Metal)

	if text then
		Kit.surfaceText(cloth, text, Enum.NormalId.Front,
			Palette.World.White, 72, Palette.Type.Display)
	end
	return g
end

--- Pitch-side advertising board. The reason a stadium looks televised.
function Kit.adBoard(
	parent: Instance, name: string, startPos: Vector3, endPos: Vector3,
	height: number, color: Color3, text: string?
)
	local mid = (startPos + endPos) / 2
	local dir = endPos - startPos
	local len = dir.Magnitude
	if len < 2 then return end
	local cf = CFrame.lookAt(mid, endPos)
	local board = Kit.trim(parent, name, Vector3.new(0.4, height, len), cf,
		color, Palette.Materials.WallPanel)
	Kit.trim(parent, name .. "_Cap", Vector3.new(0.6, 0.2, len),
		cf * CFrame.new(0, height / 2, 0), Palette.World.Metal, Palette.Materials.Metal)
	if text then
		Kit.surfaceText(board, text, Enum.NormalId.Left, Palette.World.White, 64, Palette.Type.Display)
		Kit.surfaceText(board, text, Enum.NormalId.Right, Palette.World.White, 64, Palette.Type.Display)
	end
end

-- ─────────────────────────────────────────────
-- Misc props
-- ─────────────────────────────────────────────

function Kit.vendingMachine(parent: Instance, name: string, pos: Vector3, rotY: number, accent: Color3)
	local g = Kit.folder(name, parent)
	local cf = CFrame.new(pos) * CFrame.Angles(0, rotY, 0)
	Kit.trim(g, name .. "_Body", Vector3.new(2.6, 5, 1.6),
		cf * CFrame.new(0, 2.5, 0), Palette.World.MetalDark, Palette.Materials.Metal)
	Kit.trim(g, name .. "_Glass", Vector3.new(1.9, 3, 0.15),
		cf * CFrame.new(0, 3, -0.8), Palette.World.Glass, Palette.Materials.Glass)
	-- Product shelf glow: a controlled accent, it is interactive-adjacent
	Kit.trim(g, name .. "_Glow", Vector3.new(1.7, 0.25, 0.2),
		cf * CFrame.new(0, 1.4, -0.85), accent, Palette.Materials.Metal)
	Kit.trim(g, name .. "_Panel", Vector3.new(1.9, 1.0, 0.15),
		cf * CFrame.new(0, 4.4, -0.8), accent, Palette.Materials.Metal).Transparency = 0.5
	return g
end

function Kit.utilityBox(parent: Instance, name: string, pos: Vector3, rotY: number)
	local g = Kit.folder(name, parent)
	local cf = CFrame.new(pos) * CFrame.Angles(0, rotY, 0)
	Kit.trim(g, name .. "_Box", Vector3.new(1.6, 2.2, 1.0),
		cf * CFrame.new(0, 1.1, 0), Palette.World.ConcreteDark, Palette.Materials.Metal)
	Kit.trim(g, name .. "_Lid", Vector3.new(1.7, 0.15, 1.1),
		cf * CFrame.new(0, 2.25, 0), Palette.World.Metal, Palette.Materials.Metal)
	-- Hazard stripe: reads as utility without being a random colour block
	Kit.trim(g, name .. "_Stripe", Vector3.new(1.65, 0.25, 0.1),
		cf * CFrame.new(0, 0.5, -0.52), Palette.Accent.Ember, Palette.Materials.Metal).Transparency = 0.4
	return g
end

function Kit.mailbox(parent: Instance, name: string, pos: Vector3, rotY: number)
	local g = Kit.folder(name, parent)
	local cf = CFrame.new(pos) * CFrame.Angles(0, rotY, 0)
	Kit.trim(g, name .. "_Post", Vector3.new(0.3, 3.2, 0.3),
		cf * CFrame.new(0, 1.6, 0), Palette.World.WoodDark, Palette.Materials.WallWood)
	Kit.trim(g, name .. "_Box", Vector3.new(1.2, 1.0, 1.6),
		cf * CFrame.new(0, 3.6, 0), Palette.World.TeamA and Palette.World.DeepBlue or Palette.World.DeepBlue,
		Palette.Materials.Metal)
	Kit.trim(g, name .. "_Flag", Vector3.new(0.1, 0.5, 0.6),
		cf * CFrame.new(0.7, 3.8, 0), Palette.World.White, Palette.Materials.Metal)
	return g
end

--- Parked vehicle. A simple three-box car reads correctly at street level and
--- costs three parts. Colour comes from the palette, never random neon.
function Kit.vehicle(
	parent: Instance, name: string, pos: Vector3, rotY: number, color: Color3
)
	local g = Kit.folder(name, parent)
	local cf = CFrame.new(pos) * CFrame.Angles(0, rotY, 0)

	-- Body
	Kit.trim(g, name .. "_Body", Vector3.new(6.5, 2.0, 3.0),
		cf * CFrame.new(0, 1.6, 0), color, Palette.Materials.Metal)
	-- Cabin
	Kit.trim(g, name .. "_Cabin", Vector3.new(3.6, 1.7, 2.8),
		cf * CFrame.new(-0.3, 3.2, 0), color, Palette.Materials.Metal)
	-- Glass band
	Kit.trim(g, name .. "_Glass", Vector3.new(3.7, 0.9, 2.9),
		cf * CFrame.new(-0.3, 3.3, 0), Palette.World.GlassDark, Palette.Materials.Glass)
	-- Wheels
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			Kit.cylinder(g, name .. "_Wheel" .. sx .. sz,
				Vector3.new(1.1, 0.6, 1.1),
				cf * CFrame.new(sx * 2.1, 0.7, sz * 1.5)
					* CFrame.Angles(0, 0, math.rad(90)),
				Palette.World.Void, Palette.Materials.Rubber, false)
		end
	end
	-- Lights — a small controlled accent
	Kit.trim(g, name .. "_LampL", Vector3.new(0.25, 0.5, 0.8),
		cf * CFrame.new(3.2, 2.0, 1.0), Palette.World.OffWhite, Palette.Materials.Metal).Transparency = 0.3
	Kit.trim(g, name .. "_LampR", Vector3.new(0.25, 0.5, 0.8),
		cf * CFrame.new(3.2, 2.0, -1.0), Palette.World.OffWhite, Palette.Materials.Metal).Transparency = 0.3
	return g
end

-- ─────────────────────────────────────────────
-- Spawn
-- ─────────────────────────────────────────────

--- Spawn platform. Neutral, subtle, and clearly a spawn point rather than a
--- decorative disc.
function Kit.spawnPad(
	parent: Instance, name: string, pos: Vector3, color: Color3, size: number?
)
	local s = size or 8
	local sp = Instance.new("SpawnLocation")
	sp.Name = name
	sp.Size = Vector3.new(s, 1, s)
	sp.CFrame = CFrame.new(pos)
	sp.Anchored = true
	sp.CanCollide = true
	sp.Neutral = true
	sp.Enabled = true
	sp.Duration = 0
	sp.Color = color
	sp.Material = Palette.Materials.Smooth
	sp.Transparency = 0.45
	sp.TopSurface = Enum.SurfaceType.Smooth
	sp.BottomSurface = Enum.SurfaceType.Smooth
	sp.CastShadow = false
	sp.Parent = parent

	-- Surround ring so the pad is visible on a textured plaza floor
	local ring = Kit.trim(parent, name .. "_Ring", Vector3.new(s + 2, 0.2, s + 2),
		CFrame.new(pos.X, pos.Y + 0.6, pos.Z), color, Palette.Materials.Metal)
	ring.Transparency = 0.5
	return sp
end

-- ─────────────────────────────────────────────
-- Crowd
--
-- Stands are empty without spectators. Crowd figures are single-part, so a
-- 4000-seat stand costs 4000 cheap parts rather than a skinned rig.
-- ─────────────────────────────────────────────

function Kit.crowdSection(
	parent: Instance, name: string, rows: number, seatsPerRow: number,
	rowWidth: number, rowRise: number, rowRun: number,
	startCf: CFrame, facing: Vector3, colorFor: (i: number, j: number) -> Color3,
	seed: string
)
	local rng = Kit.seedFor(seed)
	for i = 0, rows - 1 do
		for j = 0, seatsPerRow - 1 do
			-- Sparse fill: a full stand of identical figures looks like
			-- wallpaper. Leaving ~18% empty reads as a real crowd.
			if rng:NextNumber() > 0.18 then
				local off = Vector3.new(
					(j / seatsPerRow - 0.5) * rowWidth,
					i * rowRise,
					i * rowRun
				)
				Kit.newPart({
					name = name .. "_Fan",
					size = Vector3.new(1.4, 3.2, 1.4),
					cf = startCf * CFrame.new(off.X, off.Y, off.Z),
					color = colorFor(i, j),
					material = Palette.Materials.Smooth,
					parent = parent, collide = false, shadow = false,
					shape = Enum.PartType.Block,
				})
			end
		end
	end
end

return Kit
-- resync
