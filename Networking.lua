local Networking = {}
Networking.__index = Networking

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local isServer = RunService:IsServer()
local remoteEvents = {}
local remoteFunctions = {}
local rateLimiters = {}
local requestHandlers = {}
local responseHandlers = {}
local middleware = {}
local defaultRateLimit = 10
local defaultRateWindow = 1

function Networking.new()
	local self = setmetatable({}, Networking)
	self.remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
	self.remotesFolder.Name = "Remotes"
	self.remotesFolder.Parent = ReplicatedStorage
	return self
end

function Networking:createRemoteEvent(name)
	if remoteEvents[name] then
		return remoteEvents[name]
	end
	
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = self.remotesFolder
	remoteEvents[name] = remote
	return remote
end

function Networking:createRemoteFunction(name)
	if remoteFunctions[name] then
		return remoteFunctions[name]
	end
	
	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = self.remotesFolder
	remoteFunctions[name] = remote
	return remote
end

function Networking:onClientEvent(name, callback)
	local remote = self:createRemoteEvent(name)
	remote.OnClientEvent:Connect(function(...)
		local args = {...}
		if self:checkRateLimit(name, args[1]) then
			callback(unpack(args))
		end
	end)
end

function Networking:onServerEvent(name, callback)
	local remote = self:createRemoteEvent(name)
	remote.OnServerEvent:Connect(function(player, ...)
		local args = {...}
		if self:checkRateLimit(name, player) then
			if self:runMiddleware(name, player, args) then
				callback(player, unpack(args))
			end
		end
	end)
end

function Networking:fireClient(player, name, ...)
	local remote = remoteEvents[name]
	if remote then
		remote:FireClient(player, ...)
	end
end

function Networking:fireAllClients(name, ...)
	local remote = remoteEvents[name]
	if remote then
		remote:FireAllClients(...)
	end
end

function Networking:fireClientExcept(excludePlayer, name, ...)
	local remote = remoteEvents[name]
	if remote then
		for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
			if player ~= excludePlayer then
				remote:FireClient(player, ...)
			end
		end
	end
end

function Networking:fireServer(name, ...)
	local remote = remoteEvents[name]
	if remote then
		remote:FireServer(...)
	end
end

function Networking:invokeClient(player, name, ...)
	local remote = remoteFunctions[name]
	if remote then
		return remote:InvokeClient(player, ...)
	end
end

function Networking:invokeServer(name, ...)
	local remote = remoteFunctions[name]
	if remote then
		return remote:InvokeServer(...)
	end
end

function Networking:onClientInvoke(name, callback)
	local remote = self:createRemoteFunction(name)
	remote.OnClientInvoke = function(...)
		local args = {...}
		if self:checkRateLimit(name, nil) then
			return callback(unpack(args))
		end
		return nil
	end
end

function Networking:onServerInvoke(name, callback)
	local remote = self:createRemoteFunction(name)
	remote.OnServerInvoke = function(player, ...)
		local args = {...}
		if self:checkRateLimit(name, player) then
			if self:runMiddleware(name, player, args) then
				return callback(player, unpack(args))
			end
		end
		return nil
	end
end

function Networking:checkRateLimit(name, identifier)
	identifier = identifier or "global"
	local key = name .. "_" .. tostring(identifier)
	
	if not rateLimiters[key] then
		rateLimiters[key] = {
			requests = {},
			limit = defaultRateLimit,
			window = defaultRateWindow
		}
	end
	
	local limiter = rateLimiters[key]
	local currentTime = os.clock()
	
	for i = #limiter.requests, 1, -1 do
		if currentTime - limiter.requests[i] > limiter.window then
			table.remove(limiter.requests, i)
		end
	end
	
	if #limiter.requests >= limiter.limit then
		warn("Rate limit exceeded for", name, "by", identifier)
		return false
	end
	
	table.insert(limiter.requests, currentTime)
	return true
end

function Networking:setRateLimit(name, limit, window, identifier)
	identifier = identifier or "global"
	local key = name .. "_" .. tostring(identifier)
	
	if not rateLimiters[key] then
		rateLimiters[key] = {
			requests = {},
			limit = limit,
			window = window
		}
	else
		rateLimiters[key].limit = limit
		rateLimiters[key].window = window
	end
end

function Networking:addMiddleware(name, middlewareFunc)
	if not middleware[name] then
		middleware[name] = {}
	end
	table.insert(middleware[name], middlewareFunc)
end

function Networking:runMiddleware(name, player, args)
	if not middleware[name] then
		return true
	end
	
	for _, middlewareFunc in ipairs(middleware[name]) do
		local success, result = pcall(function()
			return middlewareFunc(player, args)
		end)
		
		if not success or result == false then
			return false
		end
	end
	
	return true
end

function Networking:createRequestResponse(name, timeout)
	timeout = timeout or 5
	
	local requestId = HttpService:GenerateGUID(false)
	local requestEvent = self:createRemoteEvent(name .. "_Request")
	local responseEvent = self:createRemoteEvent(name .. "_Response")
	
	return {
		send = function(...)
			local args = {...}
			requestEvent:FireServer(requestId, unpack(args))
			
			local responseReceived = false
			local response = nil
			
			local connection
			connection = responseEvent.OnClientEvent:Connect(function(id, ...)
				if id == requestId then
					response = {...}
					responseReceived = true
					connection:Disconnect()
				end
			end)
			
			local startTime = os.clock()
			while not responseReceived and (os.clock() - startTime) < timeout do
				task.wait()
			end
			
			connection:Disconnect()
			return unpack(response or {})
		end,
		
		handle = function(callback)
			requestEvent.OnServerEvent:Connect(function(player, id, ...)
				local result = callback(player, ...)
				if type(result) ~= "table" then
					result = {result}
				end
				responseEvent:FireClient(player, id, unpack(result))
			end)
		end
	}
end

function Networking:serialize(data)
	return HttpService:JSONEncode(data)
end

function Networking:deserialize(json)
	return HttpService:JSONDecode(json)
end

return Networking.new()

