--[[
	MythicStrikers — Shared Types
	Centralised type definitions used across both server and client.
	Pure data definitions — no logic, no service references.
--]]

local Types = {}

-- ─────────────────────────────────────────────
-- PLAYER / PROFILE
-- ─────────────────────────────────────────────

export type PlayerAttributes = {
	Speed          : number,
	Acceleration   : number,
	Dribbling      : number,
	BallControl    : number,
	Passing        : number,
	Shooting       : number,
	Power          : number,
	Curve          : number,
	Defense        : number,
	Tackling       : number,
	Stamina        : number,
	TechniquePower : number,
	TechniqueCtrl  : number,
	Goalkeeping    : number,
}

export type PlayerProfile = {
	UserId         : number,
	DisplayName    : string,
	Level          : number,
	XP             : number,
	Coins          : number,
	Rank           : string,
	Goals          : number,
	Assists        : number,
	Saves          : number,
	Tackles        : number,
	MatchesPlayed  : number,
	Wins           : number,
	Losses         : number,
	RankedRating   : number,
	EquippedStyle  : string,
	EquippedTechs  : { string },
	EquippedAwaken : string,
	Cosmetics      : { [string]: string },
	Statistics     : { [string]: number },
	Attributes     : PlayerAttributes,
}

-- ─────────────────────────────────────────────
-- TEAM
-- ─────────────────────────────────────────────

export type TeamId = "TeamA" | "TeamB" | "Spectator"

export type TeamData = {
	Id          : TeamId,
	Name        : string,
	Score       : number,
	Players     : { number },   -- array of UserIds
	Color       : Color3,
	SpawnPrefix : string,       -- spawn tag used in workspace
}

-- ─────────────────────────────────────────────
-- MATCH
-- ─────────────────────────────────────────────

export type MatchState =
	"Waiting"
	| "Countdown"
	| "Active"
	| "HalfTime"
	| "Ended"
	| "Resetting"

export type MatchMode = "1v1" | "3v3" | "5v5" | "6v6" | "Training"

export type MatchConfig = {
	Mode         : MatchMode,
	Duration     : number,   -- seconds per half
	HalfTime     : number,   -- seconds
	MaxPlayers   : number,
	CountdownSec : number,
}

export type MatchData = {
	Id          : string,
	Mode        : MatchMode,
	State       : MatchState,
	TeamA       : TeamData,
	TeamB       : TeamData,
	TimeLeft    : number,
	HalfNumber  : number,
	KickoffTeam : TeamId,
}

-- ─────────────────────────────────────────────
-- BALL
-- ─────────────────────────────────────────────

export type BallState = {
	Position    : Vector3,
	Velocity    : Vector3,
	Possessor   : number?,   -- UserId or nil
	LastTouch   : number?,
	IsLoose     : boolean,
	IsInFlight  : boolean,
}

-- ─────────────────────────────────────────────
-- TECHNIQUES
-- ─────────────────────────────────────────────

export type TechniqueType =
	"Shoot"
	| "Dribble"
	| "Pass"
	| "Tackle"
	| "Block"
	| "Goalkeeper"
	| "Movement"
	| "Combination"

export type TechniqueTier = "Basic" | "Advanced" | "Ultimate" | "Mythic"

export type Element =
	"Fire" | "Lightning" | "Wind" | "Earth" | "Water"
	| "Ice" | "Shadow" | "Light" | "Void" | "Cosmic"

export type TechniqueDefinition = {
	Id           : string,
	Name         : string,
	Type         : TechniqueType,
	Tier         : TechniqueTier,
	Element      : Element,
	EnergyCost   : number,
	Cooldown     : number,
	Power        : number,
	Range        : number,
	Duration     : number,
	Animation    : string,
	VFX          : string,
	SFX          : string,
	Description  : string,
	Cinematic    : boolean,
	Requirements : { [string]: any },
}

-- ─────────────────────────────────────────────
-- ENERGY / AWAKENING
-- ─────────────────────────────────────────────

export type EnergyState = {
	Current  : number,
	Max      : number,
	Regen    : number,   -- per second
}

export type AwakeningState = {
	Meter      : number,     -- 0–100
	IsActive   : boolean,
	TimeLeft   : number,
	Multiplier : number,     -- technique power multiplier while active
}

-- ─────────────────────────────────────────────
-- REMOTE PAYLOADS
-- (what clients send / receive via RemoteEvents)
-- ─────────────────────────────────────────────

export type InputAction =
	"Pass"
	| "Shoot"
	| "ChargedShoot"
	| "Tackle"
	| "Sprint"
	| "Move"
	| "ActivateTech"
	| "ActivateAwakening"

export type ClientInputPayload = {
	Action    : InputAction,
	Direction : Vector3?,
	Target    : Vector3?,
	TechId    : string?,
	Timestamp : number,
}

export type GoalEvent = {
	Scorer     : number,
	Assister   : number?,
	ScoringTeam: TeamId,
	MatchId    : string,
	GoalType   : string,   -- "Normal" | "Special" | "Ultimate"
	Timestamp  : number,
}

export type RewardPayload = {
	XP           : number,
	Coins        : number,
	RatingDelta  : number,
	GoalsScored  : number,
	AssistsGiven : number,
}

return Types
