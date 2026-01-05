local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initialState)
	local self = setmetatable({}, StateMachine)
	self.currentState = initialState
	self.states = {}
	self.transitions = {}
	self.stateHistory = {}
	self.maxHistorySize = 10
	self.onStateChanged = nil
	self.stateData = {}
	return self
end

function StateMachine:addState(name, config)
	if not config then
		config = {}
	end
	
	self.states[name] = {
		onEnter = config.onEnter or function() end,
		onExit = config.onExit or function() end,
		onUpdate = config.onUpdate or function() end,
		canEnter = config.canEnter or function() return true end,
		canExit = config.canExit or function() return true end,
		timeout = config.timeout or nil,
		timeoutCallback = config.timeoutCallback or nil
	}
	
	self.stateData[name] = {}
end

function StateMachine:addTransition(fromState, toState, condition)
	if not self.transitions[fromState] then
		self.transitions[fromState] = {}
	end
	
	condition = condition or function() return true end
	table.insert(self.transitions[fromState], {
		target = toState,
		condition = condition
	})
end

function StateMachine:canTransition(toState)
	if not self.states[toState] then
		return false, "State does not exist"
	end
	
	if not self.states[self.currentState] then
		return false, "Current state does not exist"
	end
	
	if not self.states[self.currentState].canExit() then
		return false, "Cannot exit current state"
	end
	
	if not self.states[toState].canEnter() then
		return false, "Cannot enter target state"
	end
	
	if self.transitions[self.currentState] then
		for _, transition in ipairs(self.transitions[self.currentState]) do
			if transition.target == toState then
				if transition.condition() then
					return true
				else
					return false, "Transition condition not met"
				end
			end
		end
	end
	
	return false, "No valid transition found"
end

function StateMachine:transition(toState, data)
	local canTransition, reason = self:canTransition(toState)
	if not canTransition then
		warn("Cannot transition from", self.currentState, "to", toState, ":", reason)
		return false
	end
	
	local previousState = self.currentState
	self.states[previousState].onExit()
	
	self:addToHistory(previousState)
	
	self.currentState = toState
	self.stateData[toState] = data or {}
	
	self.states[toState].onEnter(self.stateData[toState])
	
	if self.onStateChanged then
		self.onStateChanged(previousState, toState, self.stateData[toState])
	end
	
	if self.states[toState].timeout then
		task.delay(self.states[toState].timeout, function()
			if self.currentState == toState and self.states[toState].timeoutCallback then
				self.states[toState].timeoutCallback()
			end
		end)
	end
	
	return true
end

function StateMachine:update(deltaTime)
	if self.states[self.currentState] and self.states[self.currentState].onUpdate then
		self.states[self.currentState].onUpdate(deltaTime, self.stateData[self.currentState])
	end
end

function StateMachine:getCurrentState()
	return self.currentState
end

function StateMachine:getStateData(stateName)
	stateName = stateName or self.currentState
	return self.stateData[stateName] or {}
end

function StateMachine:setStateData(stateName, data)
	stateName = stateName or self.currentState
	if self.stateData[stateName] then
		for k, v in pairs(data) do
			self.stateData[stateName][k] = v
		end
	end
end

function StateMachine:addToHistory(state)
	table.insert(self.stateHistory, {
		state = state,
		timestamp = os.clock()
	})
	
	if #self.stateHistory > self.maxHistorySize then
		table.remove(self.stateHistory, 1)
	end
end

function StateMachine:getHistory()
	return self.stateHistory
end

function StateMachine:revertToPrevious()
	if #self.stateHistory > 0 then
		local previousState = self.stateHistory[#self.stateHistory].state
		table.remove(self.stateHistory, #self.stateHistory)
		return self:transition(previousState)
	end
	return false
end

function StateMachine:setOnStateChanged(callback)
	self.onStateChanged = callback
end

return StateMachine

