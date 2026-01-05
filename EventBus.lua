local EventBus = {}
EventBus.__index = EventBus

local RunService = game:GetService("RunService")

local events = {}
local eventSubscribers = {}
local eventMiddleware = {}
local eventHistory = {}
local maxHistorySize = 100
local eventStats = {}

function EventBus.new()
	local self = setmetatable({}, EventBus)
	self.events = {}
	self.subscribers = {}
	self.middleware = {}
	self.history = {}
	self.stats = {}
	return self
end

function EventBus:subscribe(eventName, callback, priority)
	priority = priority or 0
	
	if not self.subscribers[eventName] then
		self.subscribers[eventName] = {}
	end
	
	local subscription = {
		callback = callback,
		priority = priority,
		id = #self.subscribers[eventName] + 1
	}
	
	table.insert(self.subscribers[eventName], subscription)
	
	table.sort(self.subscribers[eventName], function(a, b)
		return a.priority > b.priority
	end)
	
	return subscription.id
end

function EventBus:unsubscribe(eventName, subscriptionId)
	if not self.subscribers[eventName] then
		return false
	end
	
	for i, subscription in ipairs(self.subscribers[eventName]) do
		if subscription.id == subscriptionId then
			table.remove(self.subscribers[eventName], i)
			return true
		end
	end
	
	return false
end

function EventBus:publish(eventName, ...)
	local args = {...}
	local eventData = {
		name = eventName,
		args = args,
		timestamp = os.clock(),
		id = #self.history + 1
	}
	
	if not self.stats[eventName] then
		self.stats[eventName] = {
			count = 0,
			lastFired = 0
		}
	end
	
	self.stats[eventName].count = self.stats[eventName].count + 1
	self.stats[eventName].lastFired = os.clock()
	
	if self.middleware[eventName] then
		for _, middlewareFunc in ipairs(self.middleware[eventName]) do
			local success, result = pcall(function()
				return middlewareFunc(eventData)
			end)
			
			if not success or result == false then
				return false
			end
		end
	end
	
	if self.subscribers[eventName] then
		for _, subscription in ipairs(self.subscribers[eventName]) do
			local success, error = pcall(function()
				subscription.callback(unpack(args))
			end)
			
			if not success then
				warn("Error in event subscriber for", eventName, ":", error)
			end
		end
	end
	
	table.insert(self.history, eventData)
	if #self.history > maxHistorySize then
		table.remove(self.history, 1)
	end
	
	return true
end

function EventBus:once(eventName, callback, priority)
	priority = priority or 0
	local subscriptionId = nil
	
	subscriptionId = self:subscribe(eventName, function(...)
		self:unsubscribe(eventName, subscriptionId)
		callback(...)
	end, priority)
	
	return subscriptionId
end

function EventBus:waitFor(eventName, timeout, condition)
	timeout = timeout or math.huge
	condition = condition or function() return true end
	
	local startTime = os.clock()
	local result = nil
	
	local subscriptionId = self:subscribe(eventName, function(...)
		if condition(...) then
			result = {...}
		end
	end)
	
	while not result and (os.clock() - startTime) < timeout do
		task.wait()
	end
	
	self:unsubscribe(eventName, subscriptionId)
	
	return unpack(result or {})
end

function EventBus:addMiddleware(eventName, middlewareFunc)
	if not self.middleware[eventName] then
		self.middleware[eventName] = {}
	end
	
	table.insert(self.middleware[eventName], middlewareFunc)
end

function EventBus:getHistory(eventName, limit)
	limit = limit or maxHistorySize
	local filtered = {}
	
	for _, event in ipairs(self.history) do
		if not eventName or event.name == eventName then
			table.insert(filtered, event)
			if #filtered >= limit then
				break
			end
		end
	end
	
	return filtered
end

function EventBus:getStatistics(eventName)
	if eventName then
		return self.stats[eventName] or {
			count = 0,
			lastFired = 0
		}
	else
		return self.stats
	end
end

function EventBus:clearHistory(eventName)
	if eventName then
		for i = #self.history, 1, -1 do
			if self.history[i].name == eventName then
				table.remove(self.history, i)
			end
		end
	else
		self.history = {}
	end
end

function EventBus:clearSubscribers(eventName)
	if eventName then
		self.subscribers[eventName] = {}
	else
		self.subscribers = {}
	end
end

function EventBus:createEventGroup(groupName)
	local group = {
		name = groupName,
		events = {},
		subscribe = function(self, eventName, callback, priority)
			return EventBus:subscribe(self.name .. "." .. eventName, callback, priority)
		end,
		publish = function(self, eventName, ...)
			return EventBus:publish(self.name .. "." .. eventName, ...)
		end,
		once = function(self, eventName, callback, priority)
			return EventBus:once(self.name .. "." .. eventName, callback, priority)
		end,
		waitFor = function(self, eventName, timeout, condition)
			return EventBus:waitFor(self.name .. "." .. eventName, timeout, condition)
		end
	}
	
	return group
end

local bus = EventBus.new()

return bus

