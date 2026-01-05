local DataManager = {}
DataManager.__index = DataManager

local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local DEFAULT_DATA = {
	coins = 0,
	level = 1,
	experience = 0,
	inventory = {},
	stats = {
		wins = 0,
		losses = 0,
		kills = 0,
		deaths = 0
	},
	settings = {
		soundEnabled = true,
		musicVolume = 0.5,
		graphicsQuality = "Medium"
	},
	timestamp = os.time()
}

local dataStore = DataStoreService:GetDataStore("PlayerData")
local cache = {}
local saveQueue = {}
local saveCooldown = 30
local lastSaveTime = {}

function DataManager.new(player)
	local self = setmetatable({}, DataManager)
	self.player = player
	self.userId = player.UserId
	self.data = nil
	self.loaded = false
	self.dirty = false
	self.saveInProgress = false
	return self
end

function DataManager:load()
	if self.loaded then
		return self.data
	end
	
	local success, result = pcall(function()
		local data = dataStore:GetAsync(self.userId)
		if data then
			return self:deserialize(data)
		else
			return self:deepCopy(DEFAULT_DATA)
		end
	end)
	
	if success then
		self.data = result
		self.data.timestamp = os.time()
		self.loaded = true
		cache[self.userId] = self.data
		return self.data
	else
		warn("Failed to load data for", self.player.Name, ":", result)
		self.data = self:deepCopy(DEFAULT_DATA)
		self.loaded = true
		return self.data
	end
end

function DataManager:save()
	if not self.loaded or self.saveInProgress then
		return false
	end
	
	if not self.dirty then
		return true
	end
	
	self.saveInProgress = true
	local currentTime = os.time()
	
	if lastSaveTime[self.userId] and (currentTime - lastSaveTime[self.userId]) < saveCooldown then
		table.insert(saveQueue, self.userId)
		self.saveInProgress = false
		return false
	end
	
	local success, error = pcall(function()
		local serialized = self:serialize(self.data)
		dataStore:SetAsync(self.userId, serialized)
		lastSaveTime[self.userId] = currentTime
		self.dirty = false
	end)
	
	self.saveInProgress = false
	
	if not success then
		warn("Failed to save data for", self.player.Name, ":", error)
		return false
	end
	
	return true
end

function DataManager:get(path)
	if not self.loaded then
		self:load()
	end
	
	local keys = self:parsePath(path)
	local value = self.data
	
	for _, key in ipairs(keys) do
		if type(value) == "table" and value[key] ~= nil then
			value = value[key]
		else
			return nil
		end
	end
	
	return value
end

function DataManager:set(path, value)
	if not self.loaded then
		self:load()
	end
	
	local keys = self:parsePath(path)
	local target = self.data
	
	for i = 1, #keys - 1 do
		local key = keys[i]
		if type(target[key]) ~= "table" then
			target[key] = {}
		end
		target = target[key]
	end
	
	target[keys[#keys]] = value
	self.dirty = true
end

function DataManager:increment(path, amount)
	amount = amount or 1
	local current = self:get(path) or 0
	self:set(path, current + amount)
end

function DataManager:update(path, updater)
	if not self.loaded then
		self:load()
	end
	
	local keys = self:parsePath(path)
	local target = self.data
	
	for _, key in ipairs(keys) do
		if type(target[key]) ~= "table" then
			target[key] = {}
		end
		target = target[key]
	end
	
	if type(updater) == "function" then
		target = updater(target)
	else
		for k, v in pairs(updater) do
			target[k] = v
		end
	end
	
	self.dirty = true
end

function DataManager:serialize(data)
	return HttpService:JSONEncode(data)
end

function DataManager:deserialize(json)
	return HttpService:JSONDecode(json)
end

function DataManager:deepCopy(original)
	local lookup = {}
	
	local function copy(obj)
		if type(obj) ~= "table" then
			return obj
		elseif lookup[obj] then
			return lookup[obj]
		end
		
		local newTable = {}
		lookup[obj] = newTable
		
		for key, value in pairs(obj) do
			newTable[copy(key)] = copy(value)
		end
		
		return setmetatable(newTable, getmetatable(obj))
	end
	
	return copy(original)
end

function DataManager:parsePath(path)
	local keys = {}
	for key in string.gmatch(path, "[^.]+") do
		table.insert(keys, key)
	end
	return keys
end

function DataManager:validate()
	if not self.loaded then
		return false
	end
	
	for key, defaultValue in pairs(DEFAULT_DATA) do
		if self.data[key] == nil then
			if type(defaultValue) == "table" then
				self.data[key] = self:deepCopy(defaultValue)
			else
				self.data[key] = defaultValue
			end
			self.dirty = true
		end
	end
	
	return true
end

Players.PlayerAdded:Connect(function(player)
	local manager = DataManager.new(player)
	manager:load()
	manager:validate()
	
	player.CharacterAdded:Connect(function()
		manager:save()
	end)
	
	player.CharacterRemoving:Connect(function()
		manager:save()
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local manager = DataManager.new(player)
	if manager.loaded then
		manager:save()
	end
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		local manager = DataManager.new(player)
		if manager.loaded then
			manager:save()
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(60)
		for _, player in ipairs(Players:GetPlayers()) do
			local manager = DataManager.new(player)
			if manager.loaded and manager.dirty then
				manager:save()
			end
		end
	end
end)

return DataManager

