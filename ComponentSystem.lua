local ComponentSystem = {}
ComponentSystem.__index = ComponentSystem

local RunService = game:GetService("RunService")

local components = {}
local componentInstances = {}
local componentUpdateQueue = {}
local updatePriority = {}
local updateInterval = 1/60

function ComponentSystem.new()
	local self = setmetatable({}, ComponentSystem)
	self.components = {}
	self.instances = {}
	return self
end

function ComponentSystem:registerComponent(name, componentClass)
	components[name] = componentClass
end

function ComponentSystem:createComponent(instance, componentName, config)
	if not components[componentName] then
		warn("Component", componentName, "not registered")
		return nil
	end
	
	if not instance:IsA("Instance") then
		warn("Invalid instance provided")
		return nil
	end
	
	local componentId = instance:GetFullName() .. "_" .. componentName
	if componentInstances[componentId] then
		return componentInstances[componentId]
	end
	
	local componentClass = components[componentName]
	local component = componentClass.new(instance, config or {})
	
	componentInstances[componentId] = component
	componentInstances[component]._id = componentId
	componentInstances[component]._name = componentName
	
	if not self.components[componentName] then
		self.components[componentName] = {}
	end
	table.insert(self.components[componentName], component)
	
	if component.onInit then
		component:onInit()
	end
	
	return component
end

function ComponentSystem:getComponent(instance, componentName)
	local componentId = instance:GetFullName() .. "_" .. componentName
	return componentInstances[componentId]
end

function ComponentSystem:getComponents(componentName)
	return self.components[componentName] or {}
end

function ComponentSystem:removeComponent(instance, componentName)
	local componentId = instance:GetFullName() .. "_" .. componentName
	local component = componentInstances[componentId]
	
	if component then
		if component.onDestroy then
			component:onDestroy()
		end
		
		if self.components[componentName] then
			for i, comp in ipairs(self.components[componentName]) do
				if comp == component then
					table.remove(self.components[componentName], i)
					break
				end
			end
		end
		
		componentInstances[componentId] = nil
	end
end

function ComponentSystem:updateComponent(componentName, deltaTime)
	if not self.components[componentName] then
		return
	end
	
	for _, component in ipairs(self.components[componentName]) do
		if component.onUpdate then
			local success, error = pcall(function()
				component:onUpdate(deltaTime)
			end)
			
			if not success then
				warn("Error updating component", componentName, ":", error)
			end
		end
	end
end

function ComponentSystem:setUpdatePriority(componentName, priority)
	updatePriority[componentName] = priority
end

function ComponentSystem:startUpdateLoop()
	if self.updateConnection then
		return
	end
	
	local lastUpdateTime = os.clock()
	
	self.updateConnection = RunService.Heartbeat:Connect(function()
		local currentTime = os.clock()
		local deltaTime = currentTime - lastUpdateTime
		lastUpdateTime = currentTime
		
		local sortedComponents = {}
		for name, _ in pairs(self.components) do
			table.insert(sortedComponents, {
				name = name,
				priority = updatePriority[name] or 0
			})
		end
		
		table.sort(sortedComponents, function(a, b)
			return a.priority > b.priority
		end)
		
		for _, componentInfo in ipairs(sortedComponents) do
			self:updateComponent(componentInfo.name, deltaTime)
		end
	end)
end

function ComponentSystem:stopUpdateLoop()
	if self.updateConnection then
		self.updateConnection:Disconnect()
		self.updateConnection = nil
	end
end

local BaseComponent = {}
BaseComponent.__index = BaseComponent

function BaseComponent.new(instance, config)
	local self = setmetatable({}, BaseComponent)
	self.instance = instance
	self.config = config or {}
	self.enabled = true
	self.dependencies = {}
	return self
end

function BaseComponent:onInit()
end

function BaseComponent:onUpdate(deltaTime)
end

function BaseComponent:onDestroy()
end

function BaseComponent:setEnabled(enabled)
	self.enabled = enabled
end

function BaseComponent:getDependency(componentName)
	return ComponentSystem:getComponent(self.instance, componentName)
end

function BaseComponent:requireDependency(componentName)
	local dependency = self:getDependency(componentName)
	if not dependency then
		warn("Required dependency", componentName, "not found for", self.instance.Name)
	end
	return dependency
end

ComponentSystem.BaseComponent = BaseComponent

local system = ComponentSystem.new()
system:startUpdateLoop()

return system

