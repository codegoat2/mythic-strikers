--[[
	MythicStrikers — TeamService
	Manages team assignment, colours, spawn points, and team queries.

	DESIGN:
	  - Two persistent Roblox Team objects are created in Teams service.
	  - Players are assigned to a team on join or at match start.
	  - Spawn points are tagged Parts in Workspace.Stadium:
	      SpawnTeamA_1 … SpawnTeamA_6
	      SpawnTeamB_1 … SpawnTeamB_6
	      SpawnSpectator_1 … SpawnSpectator_4
	  - TeamService does NOT move characters — it sets the SpawnLocation
	    so Roblox handles respawn automatically, and exposes
	    TeleportToSpawn() for immediate repositioning.
	  - All team data is server-side only. Clients are told their team
	    via the TeamAssigned remote.
--]]

local Players           = game:GetService("Players")
local Teams             = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local Remotes   = require(ReplicatedStorage.Remotes)

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local TeamService = {}

-- ─────────────────────────────────────────────
-- Internal state
-- ─────────────────────────────────────────────
local _teamA: Team
local _teamB: Team
local _spectatorTeam: Team

-- userId → teamId  ("TeamA" | "TeamB" | "Spectator")
local _assignments: { [number]: string } = {}

-- Spawn point cache:  teamId → { SpawnLocation }
local _spawnPoints: { [string]: { SpawnLocation } } = {
	TeamA     = {},
	TeamB     = {},
	Spectator = {},
}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local TEAM_COLORS = {
	TeamA     = BrickColor.new("Bright blue"),
	TeamB     = BrickColor.new("Bright red"),
	Spectator = BrickColor.new("Medium stone grey"),
}

local function getOrCreateTeam(name: string, color: BrickColor): Team
	local existing = Teams:FindFirstChild(name)
	if existing and existing:IsA("Team") then
		existing.TeamColor = color
		return existing :: Team
	end
	local team = Instance.new("Team")
	team.Name      = name
	team.TeamColor = color
	team.AutoAssignable = false
	team.Parent    = Teams
	return team
end

--- Collect SpawnLocation objects from Workspace.Stadium that match a prefix.
local function collectSpawnPoints(prefix: string): { SpawnLocation }
	local list: { SpawnLocation } = {}
	local stadium = workspace:FindFirstChild("Stadium")
	if not stadium then return list end

	for _, desc in ipairs(stadium:GetDescendants()) do
		if desc:IsA("SpawnLocation") and string.find(desc.Name, prefix, 1, true) then
			table.insert(list, desc :: SpawnLocation)
		end
	end

	-- Sort by name for deterministic ordering
	table.sort(list, function(a, b) return a.Name < b.Name end)
	return list
end

--- Return the n-th spawn point for a team (wraps around if fewer points exist).
local function getSpawnPoint(teamId: string, index: number): SpawnLocation?
	local list = _spawnPoints[teamId]
	if not list or #list == 0 then return nil end
	return list[((index - 1) % #list) + 1]
end

--- Count players currently on a team.
local function teamSize(teamId: string): number
	local count = 0
	for _, id in pairs(_assignments) do
		if id == teamId then count += 1 end
	end
	return count
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

--- Create Team objects and cache spawn points.
--- Must be called once from ServerMain before any player joins.
function TeamService.Init()
	_teamA         = getOrCreateTeam("TeamA",     TEAM_COLORS.TeamA)
	_teamB         = getOrCreateTeam("TeamB",     TEAM_COLORS.TeamB)
	_spectatorTeam = getOrCreateTeam("Spectator", TEAM_COLORS.Spectator)

	-- Spawn points are populated after the stadium model loads.
	-- RefreshSpawnPoints() is safe to call multiple times.
	TeamService.RefreshSpawnPoints()

	print("[TeamService] Initialised.")
end

--- Re-scan workspace for spawn points (call after stadium loads or resets).
function TeamService.RefreshSpawnPoints()
	_spawnPoints.TeamA     = collectSpawnPoints("SpawnTeamA")
	_spawnPoints.TeamB     = collectSpawnPoints("SpawnTeamB")
	_spawnPoints.Spectator = collectSpawnPoints("SpawnSpectator")

	print(string.format(
		"[TeamService] SpawnPoints — TeamA: %d  TeamB: %d  Spectator: %d",
		#_spawnPoints.TeamA, #_spawnPoints.TeamB, #_spawnPoints.Spectator
	))
end

--- Assign a player to a specific team.
function TeamService.AssignToTeam(player: Player, teamId: string)
	assert(teamId == "TeamA" or teamId == "TeamB" or teamId == "Spectator",
		"[TeamService] Invalid teamId: " .. tostring(teamId))

	_assignments[player.UserId] = teamId

	-- Apply Roblox Team membership
	if teamId == "TeamA" then
		player.Team = _teamA
		player.TeamColor = TEAM_COLORS.TeamA
	elseif teamId == "TeamB" then
		player.Team = _teamB
		player.TeamColor = TEAM_COLORS.TeamB
	else
		player.Team = _spectatorTeam
		player.TeamColor = TEAM_COLORS.Spectator
	end

	-- Notify client
	Remotes.FireClient(Constants.Remotes.TeamAssigned, player, {
		TeamId    = teamId,
		TeamName  = teamId == "TeamA" and _teamA.Name or
		            teamId == "TeamB" and _teamB.Name or "Spectator",
		Color     = teamId == "TeamA" and Color3.fromRGB(0, 120, 215) or
		            teamId == "TeamB" and Color3.fromRGB(210, 40, 40)  or
		            Color3.fromRGB(128, 128, 128),
	})
end

--- Auto-assign a player to the smaller team (balance fill).
--- Returns the teamId they were assigned to.
function TeamService.AutoAssign(player: Player): string
	local sizeA = teamSize("TeamA")
	local sizeB = teamSize("TeamB")
	local teamId = (sizeA <= sizeB) and "TeamA" or "TeamB"
	TeamService.AssignToTeam(player, teamId)
	return teamId
end

--- Assign all unassigned players in the server, balancing teams.
--- Optionally respects a maxPerTeam limit.
function TeamService.AssignAllPlayers(maxPerTeam: number?)
	local max = maxPerTeam or 6
	local unassigned: { Player } = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if not _assignments[player.UserId] then
			table.insert(unassigned, player)
		end
	end

	-- Shuffle for fairness
	for i = #unassigned, 2, -1 do
		local j = math.random(i)
		unassigned[i], unassigned[j] = unassigned[j], unassigned[i]
	end

	for _, player in ipairs(unassigned) do
		local sizeA = teamSize("TeamA")
		local sizeB = teamSize("TeamB")
		if sizeA < max and sizeA <= sizeB then
			TeamService.AssignToTeam(player, "TeamA")
		elseif sizeB < max then
			TeamService.AssignToTeam(player, "TeamB")
		else
			TeamService.AssignToTeam(player, "Spectator")
		end
	end
end

--- Teleport a player's character to their team's next available spawn point.
--- index: optional spawn slot (1-based). If nil, uses player count on that team.
function TeamService.TeleportToSpawn(player: Player, index: number?)
	local teamId = _assignments[player.UserId]
	if not teamId then return end

	local slotIndex = index or teamSize(teamId)
	local spawn     = getSpawnPoint(teamId, slotIndex)
	if not spawn then
		warn(string.format(
			"[TeamService] No spawn point found for %s slot %d",
			teamId, slotIndex
		))
		return
	end

	local char = player.Character
	if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end

	-- Offset slightly above spawn surface
	root.CFrame = spawn.CFrame + Vector3.new(0, 3, 0)
end

--- Teleport every player on a team to their spawn points.
function TeamService.TeleportTeamToSpawn(teamId: string)
	local slot = 1
	for userId, assignedTeam in pairs(_assignments) do
		if assignedTeam == teamId then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				TeamService.TeleportToSpawn(player, slot)
				slot += 1
			end
		end
	end
end

--- Return the teamId for a player, or nil.
function TeamService.GetTeam(player: Player): string?
	return _assignments[player.UserId]
end

--- Return all UserIds on a given team.
function TeamService.GetTeamPlayerIds(teamId: string): { number }
	local list: { number } = {}
	for userId, assignedTeam in pairs(_assignments) do
		if assignedTeam == teamId then
			table.insert(list, userId)
		end
	end
	return list
end

--- Return all Player objects on a given team.
function TeamService.GetTeamPlayers(teamId: string): { Player }
	local list: { Player } = {}
	for userId, assignedTeam in pairs(_assignments) do
		if assignedTeam == teamId then
			local p = Players:GetPlayerByUserId(userId)
			if p then table.insert(list, p) end
		end
	end
	return list
end

--- Return the opposing teamId, or nil for spectators.
function TeamService.GetOpposingTeam(teamId: string): string?
	if teamId == "TeamA" then return "TeamB" end
	if teamId == "TeamB" then return "TeamA" end
	return nil
end

--- Check if two players are on the same team.
function TeamService.AreSameTeam(playerA: Player, playerB: Player): boolean
	local tA = _assignments[playerA.UserId]
	local tB = _assignments[playerB.UserId]
	return tA ~= nil and tA == tB
end

--- Clear all team assignments (called between matches).
function TeamService.ClearAssignments()
	_assignments = {}
	for _, player in ipairs(Players:GetPlayers()) do
		player.Team = _spectatorTeam
		player.TeamColor = TEAM_COLORS.Spectator
	end
end

--- Remove a single player's assignment (on disconnect).
function TeamService.RemovePlayer(player: Player)
	_assignments[player.UserId] = nil
end

--- Return team sizes for UI / matchmaking queries.
function TeamService.GetTeamSizes(): { TeamA: number, TeamB: number, Spectator: number }
	return {
		TeamA     = teamSize("TeamA"),
		TeamB     = teamSize("TeamB"),
		Spectator = teamSize("Spectator"),
	}
end

return TeamService
