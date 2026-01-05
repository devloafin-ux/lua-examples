local GameManager = {}
GameManager.__index = GameManager

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DataManager = require(script.Parent:WaitForChild("DataManager"))
local StateMachine = require(script.Parent:WaitForChild("StateMachine"))
local Networking = require(ReplicatedStorage:WaitForChild("Networking"))
local EventBus = require(ReplicatedStorage:WaitForChild("EventBus"))
local TaskScheduler = require(script.Parent:WaitForChild("TaskScheduler"))

function GameManager.new()
	local self = setmetatable({}, GameManager)
	self.players = {}
	self.gameState = StateMachine.new("Lobby")
	self.roundNumber = 0
	self.maxPlayers = 12
	self.minPlayers = 2
	self.roundDuration = 300
	self.intermissionDuration = 30
	self.playerData = {}
	return self
end

function GameManager:initialize()
	self:setupGameStates()
	self:setupNetworking()
	self:setupEvents()
	self.gameState:transition("Lobby")
end

function GameManager:setupGameStates()
	self.gameState:addState("Lobby", {
		onEnter = function()
			self:onLobbyEnter()
		end,
		onUpdate = function(deltaTime)
			self:onLobbyUpdate(deltaTime)
		end,
		canEnter = function()
			return true
		end
	})
	
	self.gameState:addState("Intermission", {
		onEnter = function()
			self:onIntermissionEnter()
		end,
		onUpdate = function(deltaTime)
			self:onIntermissionUpdate(deltaTime)
		end,
		timeout = self.intermissionDuration,
		timeoutCallback = function()
			if #Players:GetPlayers() >= self.minPlayers then
				self.gameState:transition("Playing")
			else
				self.gameState:transition("Lobby")
			end
		end
	})
	
	self.gameState:addState("Playing", {
		onEnter = function()
			self:onPlayingEnter()
		end,
		onUpdate = function(deltaTime)
			self:onPlayingUpdate(deltaTime)
		end,
		timeout = self.roundDuration,
		timeoutCallback = function()
			self.gameState:transition("Intermission")
		end
	})
	
	self.gameState:addTransition("Lobby", "Intermission", function()
		return #Players:GetPlayers() >= self.minPlayers
	end)
	
	self.gameState:addTransition("Intermission", "Playing", function()
		return #Players:GetPlayers() >= self.minPlayers
	end)
	
	self.gameState:addTransition("Playing", "Intermission", function()
		return true
	end)
	
	self.gameState:addTransition("Intermission", "Lobby", function()
		return #Players:GetPlayers() < self.minPlayers
	end)
end

function GameManager:setupNetworking()
	Networking:onServerEvent("PlayerReady", function(player)
		self:onPlayerReady(player)
	end)
	
	Networking:onServerEvent("PlayerAction", function(player, action, data)
		self:onPlayerAction(player, action, data)
	end)
end

function GameManager:setupEvents()
	EventBus:subscribe("PlayerJoined", function(player)
		self:onPlayerJoined(player)
	end)
	
	EventBus:subscribe("PlayerLeft", function(player)
		self:onPlayerLeft(player)
	end)
	
	Players.PlayerAdded:Connect(function(player)
		EventBus:publish("PlayerJoined", player)
	end)
	
	Players.PlayerRemoving:Connect(function(player)
		EventBus:publish("PlayerLeft", player)
	end)
end

function GameManager:onPlayerJoined(player)
	local dataManager = DataManager.new(player)
	dataManager:load()
	self.playerData[player.UserId] = dataManager
	
	Networking:fireClient(player, "GameStateChanged", self.gameState:getCurrentState())
end

function GameManager:onPlayerLeft(player)
	if self.playerData[player.UserId] then
		self.playerData[player.UserId]:save()
		self.playerData[player.UserId] = nil
	end
end

function GameManager:onPlayerReady(player)
	if self.gameState:getCurrentState() == "Lobby" then
		Networking:fireClient(player, "LobbyUpdate", {
			players = #Players:GetPlayers(),
			minPlayers = self.minPlayers,
			maxPlayers = self.maxPlayers
		})
	end
end

function GameManager:onPlayerAction(player, action, data)
	local currentState = self.gameState:getCurrentState()
	
	if currentState == "Playing" then
		if action == "score" then
			self:handlePlayerScore(player, data)
		elseif action == "death" then
			self:handlePlayerDeath(player, data)
		end
	end
end

function GameManager:handlePlayerScore(player, data)
	local dataManager = self.playerData[player.UserId]
	if dataManager then
		dataManager:increment("stats.kills", data.amount or 1)
		dataManager:increment("experience", data.experience or 10)
		
		EventBus:publish("PlayerScored", player, data)
	end
end

function GameManager:handlePlayerDeath(player, data)
	local dataManager = self.playerData[player.UserId]
	if dataManager then
		dataManager:increment("stats.deaths", 1)
		
		EventBus:publish("PlayerDied", player, data)
	end
end

function GameManager:onLobbyEnter()
	self.roundNumber = 0
	Networking:fireAllClients("GameStateChanged", "Lobby")
	
	TaskScheduler:createDelayedTask(function()
		if #Players:GetPlayers() >= self.minPlayers then
			self.gameState:transition("Intermission")
		end
	end, 5)
end

function GameManager:onLobbyUpdate(deltaTime)
	if #Players:GetPlayers() >= self.minPlayers then
		if self.gameState:getCurrentState() == "Lobby" then
			self.gameState:transition("Intermission")
		end
	end
end

function GameManager:onIntermissionEnter()
	self.roundNumber = self.roundNumber + 1
	Networking:fireAllClients("GameStateChanged", "Intermission", {
		roundNumber = self.roundNumber,
		duration = self.intermissionDuration
	})
end

function GameManager:onIntermissionUpdate(deltaTime)
end

function GameManager:onPlayingEnter()
	Networking:fireAllClients("GameStateChanged", "Playing", {
		roundNumber = self.roundNumber,
		duration = self.roundDuration
	})
	
	EventBus:publish("RoundStarted", self.roundNumber)
end

function GameManager:onPlayingUpdate(deltaTime)
	local alivePlayers = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character and player.Character:FindFirstChild("Humanoid") then
			if player.Character.Humanoid.Health > 0 then
				alivePlayers = alivePlayers + 1
			end
		end
	end
	
	if alivePlayers <= 1 and #Players:GetPlayers() > 1 then
		self.gameState:transition("Intermission")
	end
end

RunService.Heartbeat:Connect(function(deltaTime)
	local manager = GameManager.new()
	if not manager.initialized then
		manager:initialize()
		manager.initialized = true
	end
	
	manager.gameState:update(deltaTime)
end)

return GameManager.new()

