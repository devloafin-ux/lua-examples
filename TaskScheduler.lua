local TaskScheduler = {}
TaskScheduler.__index = TaskScheduler

local RunService = game:GetService("RunService")

local taskQueue = {}
local runningTasks = {}
local taskIdCounter = 0
local maxConcurrentTasks = 10
local taskPriorities = {}
local taskDependencies = {}
local taskResults = {}
local taskCallbacks = {}

function TaskScheduler.new()
	local self = setmetatable({}, TaskScheduler)
	self.queue = {}
	self.running = {}
	self.maxConcurrent = maxConcurrentTasks
	self.priorities = {}
	self.dependencies = {}
	self.results = {}
	self.callbacks = {}
	self.idCounter = 0
	return self
end

function TaskScheduler:createTask(func, priority, dependencies)
	priority = priority or 0
	dependencies = dependencies or {}
	
	self.idCounter = self.idCounter + 1
	local taskId = self.idCounter
	
	local task = {
		id = taskId,
		func = func,
		priority = priority,
		dependencies = dependencies,
		status = "pending",
		createdAt = os.clock(),
		startedAt = nil,
		completedAt = nil,
		result = nil,
		error = nil
	}
	
	table.insert(self.queue, task)
	self.priorities[taskId] = priority
	self.dependencies[taskId] = dependencies
	
	table.sort(self.queue, function(a, b)
		return a.priority > b.priority
	end)
	
	self:processQueue()
	
	return taskId
end

function TaskScheduler:createAsyncTask(func, priority, dependencies)
	return self:createTask(function()
		return task.spawn(func)
	end, priority, dependencies)
end

function TaskScheduler:createDelayedTask(func, delay, priority, dependencies)
	priority = priority or 0
	dependencies = dependencies or {}
	
	return self:createTask(function()
		task.wait(delay)
		return func()
	end, priority, dependencies)
end

function TaskScheduler:createRepeatingTask(func, interval, count, priority, dependencies)
	priority = priority or 0
	dependencies = dependencies or {}
	count = count or math.huge
	
	local iteration = 0
	
	return self:createTask(function()
		while iteration < count do
			func(iteration)
			iteration = iteration + 1
			if iteration < count then
				task.wait(interval)
			end
		end
		return iteration
	end, priority, dependencies)
end

function TaskScheduler:waitForTask(taskId, timeout)
	timeout = timeout or math.huge
	local startTime = os.clock()
	
	while self.results[taskId] == nil and (os.clock() - startTime) < timeout do
		local task = self:getTask(taskId)
		if task and task.status == "failed" then
			return nil, task.error
		end
		task.wait()
	end
	
	return self.results[taskId]
end

function TaskScheduler:getTask(taskId)
	for _, task in ipairs(self.queue) do
		if task.id == taskId then
			return task
		end
	end
	
	for _, task in ipairs(self.running) do
		if task.id == taskId then
			return task
		end
	end
	
	return nil
end

function TaskScheduler:getTaskResult(taskId)
	return self.results[taskId]
end

function TaskScheduler:cancelTask(taskId)
	for i, task in ipairs(self.queue) do
		if task.id == taskId then
			task.status = "cancelled"
			table.remove(self.queue, i)
			return true
		end
	end
	
	for i, task in ipairs(self.running) do
		if task.id == taskId then
			task.status = "cancelled"
			table.remove(self.running, i)
			return true
		end
	end
	
	return false
end

function TaskScheduler:setTaskCallback(taskId, callback)
	self.callbacks[taskId] = callback
end

function TaskScheduler:canRunTask(task)
	if #self.running >= self.maxConcurrent then
		return false
	end
	
	if #task.dependencies > 0 then
		for _, depId in ipairs(task.dependencies) do
			local depResult = self.results[depId]
			if depResult == nil then
				local depTask = self:getTask(depId)
				if depTask and depTask.status ~= "completed" and depTask.status ~= "failed" then
					return false
				end
			end
		end
	end
	
	return true
end

function TaskScheduler:processQueue()
	while #self.queue > 0 and #self.running < self.maxConcurrent do
		local taskIndex = nil
		
		for i, task in ipairs(self.queue) do
			if task.status == "pending" and self:canRunTask(task) then
				taskIndex = i
				break
			end
		end
		
		if not taskIndex then
			break
		end
		
		local task = table.remove(self.queue, taskIndex)
		task.status = "running"
		task.startedAt = os.clock()
		table.insert(self.running, task)
		
		task.spawn(function()
			local success, result = pcall(function()
				return task.func()
			end)
			
			task.completedAt = os.clock()
			
			if success then
				task.status = "completed"
				task.result = result
				self.results[task.id] = result
			else
				task.status = "failed"
				task.error = result
				self.results[task.id] = nil
			end
			
			if self.callbacks[task.id] then
				self.callbacks[task.id](task.status == "completed", task.result, task.error)
			end
			
			for i, runningTask in ipairs(self.running) do
				if runningTask.id == task.id then
					table.remove(self.running, i)
					break
				end
			end
			
			self:processQueue()
		end)
	end
end

function TaskScheduler:setMaxConcurrent(max)
	self.maxConcurrent = max
	self:processQueue()
end

function TaskScheduler:getQueueSize()
	return #self.queue
end

function TaskScheduler:getRunningCount()
	return #self.running
end

function TaskScheduler:clearQueue()
	for _, task in ipairs(self.queue) do
		task.status = "cancelled"
	end
	self.queue = {}
end

function TaskScheduler:getStatistics()
	local stats = {
		queued = #self.queue,
		running = #self.running,
		completed = 0,
		failed = 0,
		cancelled = 0
	}
	
	for _, task in ipairs(self.queue) do
		if task.status == "cancelled" then
			stats.cancelled = stats.cancelled + 1
		end
	end
	
	for taskId, result in pairs(self.results) do
		local task = self:getTask(taskId)
		if task and task.status == "completed" then
			stats.completed = stats.completed + 1
		elseif task and task.status == "failed" then
			stats.failed = stats.failed + 1
		end
	end
	
	return stats
end

local scheduler = TaskScheduler.new()

RunService.Heartbeat:Connect(function()
	scheduler:processQueue()
end)

return scheduler

