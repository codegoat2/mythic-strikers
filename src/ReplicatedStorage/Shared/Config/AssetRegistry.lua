--[[
	MythicStrikers — AssetRegistry
	Maps technique/VFX/SFX/animation tags to actual Roblox assets.

	This is the single source of truth for asset wiring. TechniqueDefinitions
	stores abstract tags; this module resolves them to real instances/IDs.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local AssetRegistry = {}

-- ─────────────────────────────────────────────
-- Paths
-- ─────────────────────────────────────────────
local WORLD_ASSETS = ServerStorage:FindFirstChild("WorldAssets")
local BALLS = WORLD_ASSETS and WORLD_ASSETS:FindFirstChild("Balls")
local VFX = WORLD_ASSETS and WORLD_ASSETS:FindFirstChild("VFX")
local ANIMATIONS = WORLD_ASSETS and WORLD_ASSETS:FindFirstChild("Animations")
local AUDIO = WORLD_ASSETS and WORLD_ASSETS:FindFirstChild("Audio")
local SOUNDS = ReplicatedStorage:FindFirstChild("Sounds")

-- ─────────────────────────────────────────────
-- Ball
-- ─────────────────────────────────────────────
AssetRegistry.BallModel = BALLS and BALLS:FindFirstChild("TexturedSoccerBall")

-- ─────────────────────────────────────────────
-- Animations
-- ─────────────────────────────────────────────
-- DashAnimation contains R6 dash/fast-movement animations.
-- SonicSpeedAnimations contains high-speed run animations.
-- These are used as template models; actual Animation objects are cloned
-- from them at runtime when a technique requests an animation.
AssetRegistry.AnimationModels = {
	Dash = ANIMATIONS and ANIMATIONS:FindFirstChild("DashAnimation"),
	SonicSpeed = ANIMATIONS and ANIMATIONS:FindFirstChild("SonicSpeedAnimations"),
}

-- ─────────────────────────────────────────────
-- VFX Models
-- ─────────────────────────────────────────────
AssetRegistry.VFX = {
	Explosion = VFX and VFX:FindFirstChild("ExplosionVFX"),
	RealisticExplosion = VFX and VFX:FindFirstChild("RealisticExplosionVFX"),
	MagicBlast = VFX and VFX:FindFirstChild("MagicBlastVFX"),
	Tornado = VFX and VFX:FindFirstChild("TornadoVFX"),
	DarkSmoke = VFX and VFX:FindFirstChild("DarkSmokeEffect"),
	FrostyBlueCrystals = VFX and VFX:FindFirstChild("FrostyBlueCrystals"),
	LightningBolt = VFX and VFX:FindFirstChild("LightningBoltVFX"),
	FireTorch = VFX and VFX:FindFirstChild("FireTorchVFX"),
	ElectricShock = VFX and VFX:FindFirstChild("ElectricShockVFX"),
	LitFlame = VFX and VFX:FindFirstChild("LitFlameTorch"),
}

-- ─────────────────────────────────────────────
-- Audio
-- ─────────────────────────────────────────────
AssetRegistry.Sounds = {
	BlackFlash = SOUNDS and SOUNDS:FindFirstChild("BlackFlash"),
	Ripple = SOUNDS and SOUNDS:FindFirstChild("Ripple"),
	HeavyThunder = SOUNDS and SOUNDS:FindFirstChild("HeavyThunder"),
	WindWhoosh = SOUNDS and SOUNDS:FindFirstChild("WindWhoosh"),
	ReverseSuckSwoosh = SOUNDS and SOUNDS:FindFirstChild("ReverseSuckSwoosh"),
	Explosion = SOUNDS and SOUNDS:FindFirstChild("Explosion"),
	CheeringVictory = SOUNDS and SOUNDS:FindFirstChild("CheeringVictory"),
	MultipleThunder = SOUNDS and SOUNDS:FindFirstChild("MultipleThunder"),
	LightningStrike = SOUNDS and SOUNDS:FindFirstChild("LightningStrike"),
	PlankSwingWhoosh = SOUNDS and SOUNDS:FindFirstChild("PlankSwingWhoosh"),
	BallKick = SOUNDS and SOUNDS:FindFirstChild("BallKick"),
	WhistleShort = SOUNDS and SOUNDS:FindFirstChild("WhistleShort"),
	WhistleGoal = SOUNDS and SOUNDS:FindFirstChild("WhistleGoal"),
	GoalHorn = SOUNDS and SOUNDS:FindFirstChild("GoalHorn"),
	GoalCheer = SOUNDS and SOUNDS:FindFirstChild("GoalCheer"),
	UIClick = SOUNDS and SOUNDS:FindFirstChild("UIClick"),
}

-- ─────────────────────────────────────────────
-- World Props
-- ─────────────────────────────────────────────
AssetRegistry.WorldProps = {
	Coin = WORLD_ASSETS and WORLD_ASSETS:FindFirstChild("Coins") and WORLD_ASSETS.Coins:FindFirstChild("CollectableCoin"),
	GoalPost = WORLD_ASSETS and WORLD_ASSETS:FindFirstChild("Props") and WORLD_ASSETS.Props:FindFirstChild("FootballGoalPost"),
}

-- ─────────────────────────────────────────────
-- Technique -> Asset mapping
-- ─────────────────────────────────────────────
AssetRegistry.TechniqueAssets = {
	SOLAR_ROAR = {
		VFX = "MagicBlast",
		SFX = "Explosion",
		Animation = "Dash",
	},
	THUNDER_FANG = {
		VFX = "LightningBolt",
		SFX = "LightningStrike",
		Animation = "Dash",
	},
	GALE_PHANTOM = {
		VFX = "Tornado",
		SFX = "WindWhoosh",
		Animation = "SonicSpeed",
	},
	SHADOW_SHIFT = {
		VFX = "DarkSmoke",
		SFX = "ReverseSuckSwoosh",
		Animation = "Dash",
	},
	STARLINE_PASS = {
		VFX = "MagicBlast",
		SFX = "Ripple",
		Animation = "Dash",
	},
	TITAN_RAMPART = {
		VFX = "FrostyBlueCrystals",
		SFX = "HeavyThunder",
		Animation = nil,
	},
	ASTRAL_SHIELD = {
		VFX = "FrostyBlueCrystals",
		SFX = "BlackFlash",
		Animation = nil,
	},
}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

--- Get a VFX model by key. Returns the Model/Folder, or nil.
function AssetRegistry.GetVFX(key: string): Instance?
	return AssetRegistry.VFX[key]
end

--- Get a Sound by key. Returns the Sound, or nil.
function AssetRegistry.GetSound(key: string): Sound?
	return AssetRegistry.Sounds[key]
end

--- Get an animation template model by key.
function AssetRegistry.GetAnimationTemplate(key: string): Model?
	return AssetRegistry.AnimationModels[key]
end

--- Get assets for a technique ID.
function AssetRegistry.GetTechniqueAssets(techId: string): { VFX: string?, SFX: string?, Animation: string? }
	return AssetRegistry.TechniqueAssets[techId] or {}
end

--- Clone a VFX effect and parent it under workspace. Returns the root
--- instance, or nil if the VFX key is missing.
function AssetRegistry.SpawnVFX(key: string, position: Vector3, parent: Instance?): Instance?
	local template = AssetRegistry.GetVFX(key)
	if not template then return nil end

	local clone = template:Clone()
	clone.Position = position
	clone.Parent = parent or workspace
	
	-- Enable all particle emitters in the clone
	for _, emitter in ipairs(clone:GetDescendants()) do
		if emitter:IsA("ParticleEmitter") then
			emitter.Enabled = true
		end
	end
	
	return clone
end

--- Play a sound effect at a position. Returns the Sound instance.
function AssetRegistry.PlaySFX(key: string, position: Vector3, volume: number?): Sound?
	local sound = AssetRegistry.GetSound(key)
	if not sound then return nil end

	local clone = sound:Clone()
	clone.Position = position
	clone.Volume = volume or 1.0
	clone.Parent = workspace
	clone:Play()
	
	game.Debris:AddItem(clone, clone.TimeLength + 1)
	return clone
end

return AssetRegistry
