--[[
	MythicStrikers — TechniqueDefinitions
	Master library of all special techniques (Update 1.0).

	Update 1.0 Roster (7 starter techniques):
	  SHOOTING: Solar Roar, Thunder Fang
	  DRIBBLING: Gale Phantom, Shadow Shift
	  PASSING: Starline Pass
	  DEFENSE: Titan Rampart
	  GOALKEEPER: Astral Shield

	All techniques are original Mythic Strikers concepts.
	Animation / VFX / SFX IDs are mapped in AssetRegistry to real Roblox assets.
--]]

local T = {
	-- Types
	SHOOT    = "Shoot",
	DRIBBLE  = "Dribble",
	PASS     = "Pass",
	BLOCK    = "Block",
	GK       = "Goalkeeper",
	MOVE     = "Movement",
	COMBO    = "Combination",
	-- Tiers
	BASIC    = "Basic",
	ADV      = "Advanced",
	ULT      = "Ultimate",
	MYTH     = "Mythic",
	-- Elements
	FIRE     = "Fire",
	LIGHTNING = "Lightning",
	WIND     = "Wind",
	EARTH    = "Earth",
	WATER    = "Water",
	ICE      = "Ice",
	SHADOW   = "Shadow",
	LIGHT    = "Light",
	VOID     = "Void",
	COSMIC   = "Cosmic",
}

local Techniques = {
	-- ── SHOOTING ────────────────────────────────────────────────────────

	{
		Id          = "SOLAR_ROAR",
		Name        = "Solar Roar",
		Type        = T.SHOOT,
		Tier        = T.BASIC,
		Element     = T.FIRE,
		EnergyCost  = 15,
		Cooldown    = 5,
		Power       = 1.3,
		Range       = 0,
		Duration    = 0.6,
		Animation   = "Dash",
		VFX         = "MagicBlast",
		SFX         = "Explosion",
		Cinematic   = false,
		Description = "A powerful forward shot surrounded by compressed solar energy.",
		Requirements = {},
	},

	{
		Id          = "THUNDER_FANG",
		Name        = "Thunder Fang",
		Type        = T.SHOOT,
		Tier        = T.BASIC,
		Element     = T.LIGHTNING,
		EnergyCost  = 15,
		Cooldown    = 5,
		Power       = 1.25,
		Range       = 0,
		Duration    = 0.5,
		Animation   = "Dash",
		VFX         = "LightningBolt",
		SFX         = "LightningStrike",
		Cinematic   = false,
		Description = "A fast attacking shot that creates a sharp lightning trail.",
		-- Discovered through player progression, not granted at signup.
		Requirements = { MinLevel = 3 },
		Hint         = "Reach Level 3",
	},

	-- ── DRIBBLING ───────────────────────────────────────────────────────

	{
		Id          = "GALE_PHANTOM",
		Name        = "Gale Phantom",
		Type        = T.DRIBBLE,
		Tier        = T.BASIC,
		Element     = T.WIND,
		EnergyCost  = 10,
		Cooldown    = 4,
		Power       = 1.0,
		Range       = 12,
		Duration    = 0.5,
		Animation   = "SonicSpeed",
		VFX         = "Tornado",
		SFX         = "WindWhoosh",
		Cinematic   = false,
		Description = "A high-speed dribble that creates a brief wind afterimage.",
		Requirements = {},
	},

	{
		Id          = "SHADOW_SHIFT",
		Name        = "Shadow Shift",
		Type        = T.DRIBBLE,
		Tier        = T.BASIC,
		Element     = T.SHADOW,
		EnergyCost  = 12,
		Cooldown    = 5,
		Power       = 1.0,
		Range       = 10,
		Duration    = 0.6,
		Animation   = "Dash",
		VFX         = "DarkSmoke",
		SFX         = "ReverseSuckSwoosh",
		Cinematic   = false,
		Description = "A deceptive movement that briefly masks the player's direction.",
		-- Earned by actually using the ball, not by levelling.
		Requirements = { MinSuccessfulDribbles = 10 },
		Hint         = "Complete 10 successful dribbles",
	},

	-- ── PASSING ─────────────────────────────────────────────────────────

	{
		Id          = "STARLINE_PASS",
		Name        = "Starline Pass",
		Type        = T.PASS,
		Tier        = T.BASIC,
		Element     = T.COSMIC,
		EnergyCost  = 8,
		Cooldown    = 4,
		Power       = 1.2,
		Range       = 120,
		Duration    = 0.4,
		Animation   = "Dash",
		VFX         = "MagicBlast",
		SFX         = "Ripple",
		Cinematic   = false,
		Description = "A precision pass represented by a glowing trajectory.",
		Requirements = {},
	},

	-- ── DEFENSE ─────────────────────────────────────────────────────────

	{
		Id          = "TITAN_RAMPART",
		Name        = "Titan Rampart",
		Type        = T.BLOCK,
		Tier        = T.BASIC,
		Element     = T.EARTH,
		EnergyCost  = 15,
		Cooldown    = 6,
		Power       = 1.4,
		Range       = 8,
		Duration    = 0.6,
		Animation   = nil,
		VFX         = "FrostyBlueCrystals",
		SFX         = "HeavyThunder",
		Cinematic   = false,
		Description = "A defensive technique that creates a short-lived supernatural barrier.",
		Requirements = {},
	},

	-- ── GOALKEEPER ──────────────────────────────────────────────────────

	{
		Id          = "ASTRAL_SHIELD",
		Name        = "Astral Shield",
		Type        = T.GK,
		Tier        = T.BASIC,
		Element     = T.COSMIC,
		EnergyCost  = 15,
		Cooldown    = 6,
		Power       = 1.5,
		Range       = 0,
		Duration    = 0.8,
		Animation   = nil,
		VFX         = "FrostyBlueCrystals",
		SFX         = "BlackFlash",
		Cinematic   = false,
		Description = "A supernatural goalkeeper save technique that creates a luminous shield.",
		-- Keeper technique: gated behind level AND the goalkeeper position.
		Requirements = { MinLevel = 5, Position = "Goalkeeper" },
		Hint         = "Reach Level 5 as a Goalkeeper",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Build lookup map
-- ─────────────────────────────────────────────────────────────────────────────

local TechniqueDefinitions = {}
TechniqueDefinitions.List = Techniques
TechniqueDefinitions.Map  = {}

for _, def in ipairs(Techniques) do
	TechniqueDefinitions.Map[def.Id] = def
end

--- Returns a technique definition by ID, or nil if not found.
function TechniqueDefinitions.Get(id: string)
	return TechniqueDefinitions.Map[id]
end

--- Returns all techniques of a given type.
function TechniqueDefinitions.GetByType(techType: string)
	local result = {}
	for _, def in ipairs(Techniques) do
		if def.Type == techType then
			table.insert(result, def)
		end
	end
	return result
end

--- Returns all techniques of a given tier.
function TechniqueDefinitions.GetByTier(tier: string)
	local result = {}
	for _, def in ipairs(Techniques) do
		if def.Tier == tier then
			table.insert(result, def)
		end
	end
	return result
end

--- Returns all techniques by element.
function TechniqueDefinitions.GetByElement(element: string)
	local result = {}
	for _, def in ipairs(Techniques) do
		if def.Element == element then
			table.insert(result, def)
		end
	end
	return result
end

--- Returns the technique IDs a brand-new player owns from the first second.
--- Everything else in the roster is DISCOVERED through play — level, training,
--- or a mastery requirement — so the player always has something to find.
---
--- Update 1.0 gives four: one shot, one dribble, one pass, one block.
function TechniqueDefinitions.GetStarterTechniques(): { string }
	return {
		"SOLAR_ROAR",
		"GALE_PHANTOM",
		"STARLINE_PASS",
		"TITAN_RAMPART",
	}
end

--- Returns every technique that is NOT a starter, i.e. the discovery pool.
function TechniqueDefinitions.GetDiscoverableTechniques(): { table }
	local starters = {}
	for _, id in ipairs(TechniqueDefinitions.GetStarterTechniques()) do
		starters[id] = true
	end
	local result = {}
	for _, def in ipairs(Techniques) do
		if not starters[def.Id] then
			table.insert(result, def)
		end
	end
	return result
end

--- Check a technique's unlock requirements against a profile snapshot.
--- Returns true, or false plus the hint describing what is still needed.
function TechniqueDefinitions.MeetsRequirements(
	def: table,
	level: number,
	stats: table?,
	position: string?
): (boolean, string?)
	local req = def.Requirements
	if type(req) ~= "table" or next(req) == nil then
		return true, nil
	end

	if req.MinLevel and level < req.MinLevel then
		return false, string.format("Reach Level %d", req.MinLevel)
	end
	if req.Position and position ~= req.Position then
		return false, string.format("Set your position to %s", req.Position)
	end
	if req.MinSuccessfulDribbles then
		local have = (stats and stats.SuccessfulDribbles) or 0
		if have < req.MinSuccessfulDribbles then
			return false, string.format(
				"Complete %d successful dribbles (%d/%d)",
				req.MinSuccessfulDribbles, have, req.MinSuccessfulDribbles
			)
		end
	end

	return true, nil
end

return TechniqueDefinitions
