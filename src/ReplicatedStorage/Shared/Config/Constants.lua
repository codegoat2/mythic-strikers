--[[
	MythicStrikers — Constants
	Hard values that do not change at runtime.
	Import this wherever a magic number would otherwise appear.
--]]

local Constants = {}

-- ─────────────────────────────────────────────
-- PHYSICS & WORLD
-- ─────────────────────────────────────────────
Constants.GRAVITY               = -196.2          -- studs/s²  (Roblox workspace gravity default ×2 for snappy feel)
Constants.BALL_RADIUS           = 1.2             -- studs
Constants.BALL_MASS             = 0.5             -- relative mass used in shot power calc
Constants.BALL_FRICTION         = 0.35            -- rolling friction coefficient
Constants.BALL_BOUNCE           = 0.55            -- restitution
Constants.BALL_MAX_SPEED        = 220             -- studs/s hard cap

-- ─────────────────────────────────────────────
-- FIELD DIMENSIONS  (centred on 0,0,0)
-- ─────────────────────────────────────────────
Constants.FIELD_LENGTH          = 280             -- studs  (Z axis)
Constants.FIELD_WIDTH           = 168             -- studs  (X axis)
Constants.GOAL_WIDTH            = 28              -- studs
Constants.GOAL_HEIGHT           = 14             -- studs
Constants.GOAL_DEPTH            = 6              -- studs
Constants.CENTRE_CIRCLE_RADIUS  = 24             -- studs
Constants.PENALTY_AREA_WIDTH    = 72             -- studs
Constants.PENALTY_AREA_DEPTH    = 48             -- studs
Constants.GOAL_AREA_WIDTH       = 32             -- studs
Constants.GOAL_AREA_DEPTH       = 16             -- studs

-- ─────────────────────────────────────────────
-- PLAYER MOVEMENT
-- ─────────────────────────────────────────────
Constants.WALK_SPEED            = 16             -- studs/s
Constants.SPRINT_SPEED          = 28             -- studs/s
Constants.DRIBBLE_SPEED         = 20             -- studs/s  (slower than sprint to reward timing)
Constants.SPRINT_STAMINA_DRAIN  = 12             -- per second
Constants.STAMINA_REGEN_RATE    = 8              -- per second (when not sprinting)
Constants.MAX_STAMINA           = 100
Constants.SPRINT_MIN_STAMINA    = 10             -- must have this much to start sprinting

-- ─────────────────────────────────────────────
-- POSSESSION
-- ─────────────────────────────────────────────
Constants.POSSESSION_RANGE      = 4.5            -- studs — distance to auto-receive ball
Constants.TACKLE_RANGE          = 3.8            -- studs — distance to attempt tackle
Constants.TACKLE_COOLDOWN       = 1.5            -- seconds
Constants.PASS_MAX_RANGE        = 180            -- studs
Constants.PASS_MIN_POWER        = 40             -- studs/s
Constants.PASS_MAX_POWER        = 130            -- studs/s
Constants.SHOT_MIN_POWER        = 60             -- studs/s
Constants.SHOT_MAX_POWER        = 200            -- studs/s
Constants.CHARGED_SHOT_TIME     = 1.5            -- seconds to reach max charge
Constants.LOOSE_BALL_SPEED_CAP  = 180            -- cap when ball is uncontrolled in-play
Constants.INTERCEPTION_RANGE    = 5.0            -- studs — defender can intercept in-flight ball

-- ─────────────────────────────────────────────
-- GOALKEEPER
-- ─────────────────────────────────────────────
Constants.GK_DIVE_RANGE         = 14             -- studs horizontal
Constants.GK_REACH_HEIGHT       = 18             -- studs vertical
Constants.GK_REACTION_WINDOW    = 0.35           -- seconds before ball arrives for dive

-- ─────────────────────────────────────────────
-- MYTHIC ENERGY
-- ─────────────────────────────────────────────
Constants.MAX_ENERGY            = 100
Constants.ENERGY_REGEN_IDLE     = 1.5            -- per second when not acting
Constants.ENERGY_GAIN_PASS      = 4
Constants.ENERGY_GAIN_DRIBBLE   = 2              -- per successful beat
Constants.ENERGY_GAIN_TACKLE    = 8
Constants.ENERGY_GAIN_INTERCEPT = 6
Constants.ENERGY_GAIN_SHOT      = 3
Constants.ENERGY_GAIN_SAVE      = 12
Constants.ENERGY_GAIN_ASSIST    = 15
Constants.ENERGY_GAIN_GOAL      = 20

-- ─────────────────────────────────────────────
-- AWAKENING
-- ─────────────────────────────────────────────
Constants.MAX_AWAKENING_METER   = 100
Constants.AWAKENING_DURATION    = 18             -- seconds
Constants.AWAKENING_MULT_POWER  = 1.6           -- technique power multiplier
Constants.AWAKENING_MULT_SPEED  = 1.25          -- movement speed multiplier
Constants.AWAKEN_GAIN_GOAL      = 30
Constants.AWAKEN_GAIN_ASSIST    = 20
Constants.AWAKEN_GAIN_SAVE      = 25
Constants.AWAKEN_GAIN_TACKLE    = 12
Constants.AWAKEN_GAIN_TECH_HIT  = 8             -- landing a technique
Constants.AWAKEN_DRAIN_PER_SEC  = 100 / 18      -- drains over full duration

-- ─────────────────────────────────────────────
-- MATCH
-- ─────────────────────────────────────────────
Constants.MIN_PLAYERS_TO_START  = 2        -- minimum queued players to start a 5v5
Constants.MATCH_HALF_DURATION   = 180            -- seconds per half  (3 min; tune as needed)
Constants.MATCH_HALF_TIME_DUR   = 10             -- seconds half-time break
Constants.MATCH_COUNTDOWN       = 5              -- seconds before kickoff
Constants.GOAL_RESET_DELAY      = 4              -- seconds after goal before reset
Constants.MAX_GOALS_SUDDEN_DEATH= nil            -- nil = play full time

-- ─────────────────────────────────────────────
-- ANTI-EXPLOIT THRESHOLDS
-- ─────────────────────────────────────────────
Constants.MAX_REMOTE_RATE       = 30             -- max remote calls per second per player
Constants.MAX_MOVE_DISTANCE     = 40             -- studs per server tick — flag if exceeded
Constants.MAX_SHOOT_DISTANCE    = 8              -- studs from ball to be allowed to shoot

-- ─────────────────────────────────────────────
-- REWARDS (per match)
-- ─────────────────────────────────────────────
Constants.XP_PER_GOAL           = 50
Constants.XP_PER_ASSIST         = 35
Constants.XP_PER_SAVE           = 30
Constants.XP_PER_TACKLE         = 10
Constants.XP_PER_PASS           = 2              -- rewarded at match end, per successful pass
Constants.XP_PER_SHOT_ON_TARGET = 10             -- rewarded at match end, per shot on target
Constants.XP_WIN_BONUS          = 100
Constants.XP_LOSS_BONUS         = 40
Constants.XP_DRAW_BONUS         = 60
Constants.COIN_PER_GOAL         = 10
Constants.COIN_WIN_BONUS        = 25
Constants.COIN_LOSS_BONUS       = 8
Constants.COIN_DRAW_BONUS       = 12
Constants.RATING_WIN_GAIN       = 20
Constants.RATING_LOSS_PENALTY   = 15

-- ─────────────────────────────────────────────
-- TECHNIQUE TIER BASE POWER
-- ─────────────────────────────────────────────
Constants.TECH_POWER = {
	Basic    = 1.2,
	Advanced = 1.8,
	Ultimate = 2.6,
	Mythic   = 3.5,
}

Constants.TECH_ENERGY_COST = {
	Basic    = 15,
	Advanced = 30,
	Ultimate = 55,
	Mythic   = 80,
}

Constants.TECH_COOLDOWN = {
	Basic    = 5,
	Advanced = 10,
	Ultimate = 20,
	Mythic   = 35,
}

-- ─────────────────────────────────────────────
-- SERVER CAPACITY
-- ─────────────────────────────────────────────
Constants.MAX_SERVER_SIZE       = 40             -- max concurrent players per server

-- ─────────────────────────────────────────────
-- LOBBY WORLD
-- ─────────────────────────────────────────────
Constants.LOBBY_ORIGIN          = Vector3.new(0, 0, 600)   -- offset from stadium (far behind +Z)
Constants.LOBBY_SPAWN_RADIUS    = 20            -- radius around lobby spawn ring
Constants.LOBBY_INTERACTION_RANGE = 10          -- studs — ProximityPrompt activation distance
Constants.NPC_WANDER_RADIUS     = 12            -- studs NPCs roam around their anchor
Constants.SHOP_PROXIMITY_DIST   = 8             -- studs to trigger shop prompt

-- ─────────────────────────────────────────────
-- SHOP / ECONOMY
-- ─────────────────────────────────────────────
Constants.SHOP_COIN_TO_ROBUX    = 100           -- cosmetic coins per 1 Developer Product (Phase 9)
Constants.DAILY_COIN_BONUS      = 50            -- free coins awarded once per day on join

-- ─────────────────────────────────────────────
-- UI / HUD
-- ─────────────────────────────────────────────
Constants.HUD_UPDATE_RATE       = 0.1            -- seconds between HUD refreshes
Constants.SCORE_DISPLAY_DELAY   = 0.3            -- seconds after goal before scoreboard pops

-- ─────────────────────────────────────────────
-- RANK THRESHOLDS  (RankedRating)
-- ─────────────────────────────────────────────
Constants.RANKS = {
	{ Name = "Rookie",   Min = 0   },
	{ Name = "Bronze",   Min = 200 },
	{ Name = "Silver",   Min = 500 },
	{ Name = "Gold",     Min = 900 },
	{ Name = "Platinum", Min = 1400 },
	{ Name = "Diamond",  Min = 2000 },
	{ Name = "Mythic",   Min = 2800 },
}

-- ─────────────────────────────────────────────
-- REMOTE EVENT / FUNCTION NAMES
-- Central registry so typos are caught at require-time
-- ─────────────────────────────────────────────
Constants.Remotes = {
	-- Server → Client  =  RemoteEvent  (fire from server, listen on client)
	-- RemoteFunction names are additionally listed in Remotes/init.lua
	GetMatchData      = "GetMatchData",
	GetPlayerProfile  = "GetPlayerProfile",
	GetLeaderboard    = "GetLeaderboard",
	GetTechniques     = "GetTechniques",

	MatchStateUpdate    = "MatchStateUpdate",
	ScoreUpdate         = "ScoreUpdate",
	GoalScored          = "GoalScored",
	BallStateUpdate     = "BallStateUpdate",
	PlayerEnergyUpdate  = "PlayerEnergyUpdate",
	PlayerStaminaUpdate = "PlayerStaminaUpdate",
	PlayerProgressUpdate = "PlayerProgressUpdate",
	PlayerLevelUp        = "PlayerLevelUp",
	ObjectiveUpdate      = "ObjectiveUpdate",
	AwakeningUpdate     = "AwakeningUpdate",
	TechniqueResult     = "TechniqueResult",
	CinematicTrigger    = "CinematicTrigger",
	RewardsGranted      = "RewardsGranted",
	TeamAssigned        = "TeamAssigned",
	MatchCountdown      = "MatchCountdown",
	HalfTimeNotify      = "HalfTimeNotify",
	NotifyPlayer        = "NotifyPlayer",

	-- Client → Server
	PlayerInput         = "PlayerInput",
	RequestTechnique    = "RequestTechnique",
	RequestAwakening    = "RequestAwakening",
	RequestPass         = "RequestPass",
	RequestShoot        = "RequestShoot",
	RequestTackle       = "RequestTackle",
	RequestSprint       = "RequestSprint",
	RequestCelebration  = "RequestCelebration",

	-- Shop / Lobby
	OpenShop            = "OpenShop",
	ShopPurchase        = "ShopPurchase",
	ShopPurchaseResult  = "ShopPurchaseResult",
	ShopCatalogueUpdate = "ShopCatalogueUpdate",
	LobbyInteract       = "LobbyInteract",
	LobbyInteractResult = "LobbyInteractResult",
}

return Constants
