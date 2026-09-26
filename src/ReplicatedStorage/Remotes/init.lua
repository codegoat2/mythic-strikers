--[[
	MythicStrikers — Remotes
	Single source of truth for all RemoteEvents and RemoteFunctions.

	USAGE:
	  Server:  local Remotes = require(game.ReplicatedStorage.Remotes)
	  Client:  local Remotes = require(game.ReplicatedStorage.Remotes)

	  Both sides call Remotes.Get("EventName") which returns the
	  RemoteEvent / RemoteFunction instance, creating it on the server
	  if it does not yet exist.

	RULES:
	  - Server creates all remotes at startup via Remotes.Init().
	  - Clients wait for remotes to exist before calling .Get().
	  - Never fire a remote whose name is not listed in Constants.Remotes.
	  - Never trust client-supplied values without server-side validation.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Constants         = require(ReplicatedStorage.Shared.Config.Constants)

local IS_SERVER = RunService:IsServer()

-- ─────────────────────────────────────────────
-- Internal container folders
-- ─────────────────────────────────────────────
local function getOrCreateFolder(parent, name)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

-- ─────────────────────────────────────────────
-- Remote type declarations
-- Server → Client  =  RemoteEvent  (fire from server, listen on client)
-- Client → Server  =  RemoteEvent  (fire from client, listen on server)
-- Client ↔ Server  =  RemoteFunction (invoke/onInvoke)
-- ─────────────────────────────────────────────

-- Names that should be RemoteFunctions rather than RemoteEvents
local FUNCTION_NAMES = {
	GetMatchData      = true,
	GetPlayerProfile  = true,
	GetLeaderboard    = true,
	GetTechniques     = true,
}

-- All event names sourced from Constants.Remotes (prevents typos)
local EVENT_NAMES: { string } = {}
for _, name in pairs(Constants.Remotes) do
	if not FUNCTION_NAMES[name] then
		table.insert(EVENT_NAMES, name)
	end
end

local FUNCTION_NAME_LIST: { string } = {}
for name in pairs(FUNCTION_NAMES) do
	table.insert(FUNCTION_NAME_LIST, name)
end

-- ─────────────────────────────────────────────
-- Module
-- ─────────────────────────────────────────────
local Remotes = {}

local eventsFolder:   Folder
local functionsFolder: Folder

--- Creates all RemoteEvents and RemoteFunctions.
--- Must be called once from ServerMain before any service fires events.
function Remotes.Init()
	assert(IS_SERVER, "Remotes.Init() must only be called on the server.")

	eventsFolder    = getOrCreateFolder(ReplicatedStorage, "RemoteEvents")
	functionsFolder = getOrCreateFolder(ReplicatedStorage, "RemoteFunctions")

	for _, name in ipairs(EVENT_NAMES) do
		if not eventsFolder:FindFirstChild(name) then
			local re = Instance.new("RemoteEvent")
			re.Name   = name
			re.Parent = eventsFolder
		end
	end

	for _, name in ipairs(FUNCTION_NAME_LIST) do
		if not functionsFolder:FindFirstChild(name) then
			local rf = Instance.new("RemoteFunction")
			rf.Name   = name
			rf.Parent = functionsFolder
		end
	end

	print("[Remotes] Initialised —", #EVENT_NAMES, "events,", #FUNCTION_NAME_LIST, "functions.")
end

--- Returns a RemoteEvent by name.
--- On the client, waits up to 10 seconds for the instance to appear.
function Remotes.Get(name: string): RemoteEvent
	if IS_SERVER then
		eventsFolder = eventsFolder or ReplicatedStorage:FindFirstChild("RemoteEvents")
		assert(eventsFolder, "Remotes.Init() has not been called yet.")
		local re = eventsFolder:FindFirstChild(name)
		assert(re, string.format("[Remotes] RemoteEvent '%s' not found. Was it registered?", name))
		return re :: RemoteEvent
	else
		local folder = ReplicatedStorage:WaitForChild("RemoteEvents", 10)
		assert(folder, "[Remotes] RemoteEvents folder did not appear in 10 seconds.")
		local re = folder:WaitForChild(name, 10)
		assert(re, string.format("[Remotes] RemoteEvent '%s' did not appear in 10 seconds.", name))
		return re :: RemoteEvent
	end
end

--- Returns a RemoteFunction by name.
function Remotes.GetFunction(name: string): RemoteFunction
	if IS_SERVER then
		functionsFolder = functionsFolder or ReplicatedStorage:FindFirstChild("RemoteFunctions")
		assert(functionsFolder, "Remotes.Init() has not been called yet.")
		local rf = functionsFolder:FindFirstChild(name)
		assert(rf, string.format("[Remotes] RemoteFunction '%s' not found.", name))
		return rf :: RemoteFunction
	else
		local folder = ReplicatedStorage:WaitForChild("RemoteFunctions", 10)
		assert(folder, "[Remotes] RemoteFunctions folder did not appear in 10 seconds.")
		local rf = folder:WaitForChild(name, 10)
		assert(rf, string.format("[Remotes] RemoteFunction '%s' did not appear in 10 seconds.", name))
		return rf :: RemoteFunction
	end
end

-- ─────────────────────────────────────────────
-- Convenience wrappers (server-side fire helpers)
-- ─────────────────────────────────────────────

--- Fire a RemoteEvent to a single player.
function Remotes.FireClient(name: string, player: Player, ...)
	Remotes.Get(name):FireClient(player, ...)
end

--- Fire a RemoteEvent to all players.
function Remotes.FireAllClients(name: string, ...)
	Remotes.Get(name):FireAllClients(...)
end

--- Fire a RemoteEvent to all players in a list.
function Remotes.FireClients(name: string, players: { Player }, ...)
	local re = Remotes.Get(name)
	for _, player in ipairs(players) do
		re:FireClient(player, ...)
	end
end

--- Fire a RemoteEvent to all players EXCEPT one (e.g. the originator).
function Remotes.FireAllExcept(name: string, except: Player, ...)
	local re = Remotes.Get(name)
	for _, player in ipairs(game.Players:GetPlayers()) do
		if player ~= except then
			re:FireClient(player, ...)
		end
	end
end

-- ─────────────────────────────────────────────
-- Convenience wrappers (client-side fire helper)
-- ─────────────────────────────────────────────

--- Fire a RemoteEvent to the server (client only).
function Remotes.FireServer(name: string, ...)
	assert(not IS_SERVER, "Remotes.FireServer() called from server — use FireClient instead.")
	Remotes.Get(name):FireServer(...)
end

--- Connect a server-side listener to a RemoteEvent.
--- Returns the RBXScriptConnection.
function Remotes.OnServerEvent(name: string, callback: (player: Player, ...any) -> ())
	assert(IS_SERVER, "OnServerEvent must be connected on the server.")
	return Remotes.Get(name).OnServerEvent:Connect(callback)
end

--- Connect a client-side listener to a RemoteEvent.
--- Returns the RBXScriptConnection.
function Remotes.OnClientEvent(name: string, callback: (...any) -> ())
	assert(not IS_SERVER, "OnClientEvent must be connected on the client.")
	return Remotes.Get(name).OnClientEvent:Connect(callback)
end

--- Bind a server-side handler to a RemoteFunction.
function Remotes.BindFunction(name: string, handler: (player: Player, ...any) -> ...any)
	assert(IS_SERVER, "BindFunction must be called on the server.")
	Remotes.GetFunction(name).OnServerInvoke = handler
end

--- Invoke a RemoteFunction from the client.
function Remotes.InvokeServer(name: string, ...): ...any
	assert(not IS_SERVER, "InvokeServer must be called from the client.")
	return Remotes.GetFunction(name):InvokeServer(...)
end

return Remotes
