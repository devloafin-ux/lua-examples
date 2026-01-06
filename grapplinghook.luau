
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")
local camera = workspace.CurrentCamera

local GrapplingHook = {}
GrapplingHook.__index = GrapplingHook

local activeHook: any = nil
local isHookDeployed: boolean = false
local maxHookRange: number = 350
local hookPullStrength: number = 95
local swingDampingFactor: number = 0.89
local ropeSegmentCount: number = 28
local reelSpeedMultiplier: number = 4.2
local tensionThreshold: number = 0.85

type HookData = {
    anchorPosition: Vector3?,
    visualSegments: {Part},
    beamConnectors: {Beam},
    physicsBody: BodyVelocity?,
    updateLoop: RbxScriptConnection?,
    reelingActive: boolean,
    velocityBuffer: Vector3,
    previousPosition: Vector3,
    angularMomentum: Vector3,
    connectionStrength: number,
    lastUpdateTime: number
}

function GrapplingHook.new(): HookData
    local self = setmetatable({}, GrapplingHook)
    
    self.anchorPosition = nil
    self.visualSegments = {}
    self.beamConnectors = {}
    self.physicsBody = nil
    self.updateLoop = nil
    self.reelingActive = false
    self.velocityBuffer = Vector3.zero
    self.previousPosition = rootPart.Position
    self.angularMomentum = Vector3.zero
    self.connectionStrength = 1.0
    self.lastUpdateTime = tick()
    
    return self
end

function GrapplingHook:constructRopeVisualization()
    local baseHue = tick() % 5 / 5
    
    for segmentIndex = 1, ropeSegmentCount do
        local segment = Instance.new("Part")
        segment.Size = Vector3.new(0.18, 0.18, 0.18)
        segment.Material = Enum.Material.Neon
        
        local hueShift = (segmentIndex / ropeSegmentCount) * 0.1
        segment.Color = Color3.fromHSV(baseHue + hueShift, 0.8, 1)
        
        segment.Anchored = true
        segment.CanCollide = false
        segment.CastShadow = false
        segment.TopSurface = Enum.SurfaceType.Smooth
        segment.BottomSurface = Enum.SurfaceType.Smooth
        segment.Parent = workspace
        
        table.insert(self.visualSegments, segment)
        
        if segmentIndex > 1 then
            local beam = Instance.new("Beam")
            local attachment0 = Instance.new("Attachment")
            local attachment1 = Instance.new("Attachment")
            
            attachment0.Parent = self.visualSegments[segmentIndex - 1]
            attachment1.Parent = segment
            
            beam.Attachment0 = attachment0
            beam.Attachment1 = attachment1
            beam.Width0 = 0.25
            beam.Width1 = 0.25
            beam.Texture = "rbxasset://textures/particles/sparkles_main.dds"
            beam.TextureSpeed = 2
            beam.TextureLength = 0.5
            
            local colorSeq = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 220, 255)),
                ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 180, 255)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 230, 255))
            })
            beam.Color = colorSeq
            beam.FaceCamera = true
            beam.LightInfluence = 0
            beam.Parent = segment
            
            table.insert(self.beamConnectors, beam)
        end
    end
end

function GrapplingHook:simulateRopeDynamics(deltaTime: number)
    if not self.anchorPosition then return end
    
    local playerPosition = rootPart.Position
    local anchoredEnd = self.anchorPosition
    local connectionVector = anchoredEnd - playerPosition
    local totalDistance = connectionVector.Magnitude
    local normalizedDirection = connectionVector.Unit
    
    local tensionFactor = math.min(totalDistance / maxHookRange, 1)
    self.connectionStrength = math.max(tensionFactor, 0.3)
    
    for index, segment in ipairs(self.visualSegments) do
        local normalizedPosition = index / ropeSegmentCount
        local interpolatedBase = playerPosition:Lerp(anchoredEnd, normalizedPosition)
        
        local timeOffset = tick() * 1.5
        local waveAmplitude = math.sin(timeOffset + index * 0.4) * 0.4
        local secondaryWave = math.cos(timeOffset * 0.7 + index * 0.3) * 0.2
        
        local perpendicularAxis = Vector3.new(-normalizedDirection.Z, 0, normalizedDirection.X)
        if perpendicularAxis.Magnitude < 0.01 then
            perpendicularAxis = Vector3.new(0, 0, 1)
        end
        perpendicularAxis = perpendicularAxis.Unit
        
        local lateralOffset = perpendicularAxis * (waveAmplitude + secondaryWave) * 
                             (1 - normalizedPosition) * totalDistance * 0.015 * self.connectionStrength
        
        local gravityDrop = Vector3.new(0, -normalizedPosition * normalizedPosition * 2.5 * 
                                         (1 - self.connectionStrength * 0.5), 0)
        
        local windEffect = Vector3.new(
            math.sin(timeOffset * 0.5 + index) * 0.1,
            0,
            math.cos(timeOffset * 0.5 + index) * 0.1
        ) * (1 - normalizedPosition)
        
        local finalPosition = interpolatedBase + lateralOffset + gravityDrop + windEffect
        
        local nextNormalizedPos = math.min(normalizedPosition + 0.03, 1)
        local nextInterpolated = playerPosition:Lerp(anchoredEnd, nextNormalizedPos)
        local forwardVector = (nextInterpolated - finalPosition).Unit
        
        segment.CFrame = CFrame.new(finalPosition) * 
                        CFrame.Angles(0, 0, math.sin(timeOffset + index) * 0.2)
        segment.CFrame = CFrame.new(segment.Position, segment.Position + forwardVector)
        
        local glowIntensity = 0.5 + math.sin(timeOffset * 3 + index * 0.5) * 0.3
        segment.Transparency = 0.1 + (1 - self.connectionStrength) * 0.3
    end
end

function GrapplingHook:computeSwingPhysics(): Vector3
    local toAnchor = self.anchorPosition - rootPart.Position
    local distance = toAnchor.Magnitude
    local directionToAnchor = toAnchor.Unit
    
    local currentVelocity = (rootPart.Position - self.previousPosition) / 0.016
    self.previousPosition = rootPart.Position
    
    local radialComponent = currentVelocity:Dot(directionToAnchor)
    local tangentialVelocity = currentVelocity - (directionToAnchor * radialComponent)
    
    local centripetalMagnitude = (tangentialVelocity.Magnitude ^ 2) / math.max(distance, 1)
    local centripetalForce = directionToAnchor * centripetalMagnitude * 0.6
    
    local tensionForce = directionToAnchor * hookPullStrength * self.connectionStrength
    
    self.angularMomentum = (self.angularMomentum + tangentialVelocity * 0.08) * swingDampingFactor
    
    local gravityCompensation = Vector3.new(0, 15, 0)
    
    local springBackForce = Vector3.zero
    if distance > maxHookRange * tensionThreshold then
        local overshoot = distance - maxHookRange * tensionThreshold
        springBackForce = directionToAnchor * overshoot * 2
    end
    
    if self.reelingActive then
        local reelForce = directionToAnchor * reelSpeedMultiplier * 30
        return tensionForce + centripetalForce + self.angularMomentum * 12 + reelForce + springBackForce
    else
        return centripetalForce * 0.7 + self.angularMomentum * 9 + gravityCompensation + springBackForce * 0.5
    end
end

function GrapplingHook:executePhysicsStep(deltaTime: number)
    if not self.anchorPosition then return end
    
    local calculatedForce = self:computeSwingPhysics()
    
    local airResistance = rootPart.AssemblyLinearVelocity * -0.05
    calculatedForce = calculatedForce + airResistance
    
    if not self.physicsBody then
        self.physicsBody = Instance.new("BodyVelocity")
        self.physicsBody.MaxForce = Vector3.new(5000, 5000, 5000)
        self.physicsBody.P = 1500
        self.physicsBody.Parent = rootPart
    end
    
    self.physicsBody.Velocity = calculatedForce
    
    humanoid.PlatformStand = true
    humanoid:ChangeState(Enum.HumanoidStateType.Physics)
end

function GrapplingHook:deployHook(targetLocation: Vector3)
    if isHookDeployed then return end
    
    local originPoint = rootPart.Position + Vector3.new(0, 2, 0)
    local shootDirection = (targetLocation - originPoint).Unit
    
    local rayParameters = RaycastParams.new()
    rayParameters.FilterDescendantsInstances = {character}
    rayParameters.FilterType = Enum.RaycastFilterType.Exclude
    rayParameters.IgnoreWater = true
    
    local raycastResult = workspace:Raycast(originPoint, shootDirection * maxHookRange, rayParameters)
    
    if raycastResult and raycastResult.Instance then
        local hitPart = raycastResult.Instance
        
        if hitPart.Anchored or hitPart:GetMass() > 500 then
            isHookDeployed = true
            self.anchorPosition = raycastResult.Position
            
            self:constructRopeVisualization()
            self:generateImpactEffects(raycastResult.Position, raycastResult.Normal)
            
            self.updateLoop = RunService.Heartbeat:Connect(function(dt)
                self:simulateRopeDynamics(dt)
                self:executePhysicsStep(dt)
            end)
            
            activeHook = self
            
            self:emitLaunchSound()
        end
    end
end

function GrapplingHook:generateImpactEffects(position: Vector3, normal: Vector3)
    local impactMarker = Instance.new("Part")
    impactMarker.Size = Vector3.new(1.2, 1.2, 0.3)
    impactMarker.Material = Enum.Material.Neon
    impactMarker.Color = Color3.fromRGB(100, 220, 255)
    impactMarker.Anchored = true
    impactMarker.CanCollide = false
    impactMarker.Shape = Enum.PartType.Cylinder
    impactMarker.CFrame = CFrame.new(position, position + normal) * CFrame.Angles(0, math.pi/2, 0)
    impactMarker.Parent = workspace
    
    local glowLight = Instance.new("PointLight")
    glowLight.Brightness = 4
    glowLight.Range = 25
    glowLight.Color = Color3.fromRGB(100, 220, 255)
    glowLight.Parent = impactMarker
    
    local expandTween = TweenService:Create(impactMarker, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = Vector3.new(2.5, 2.5, 0.6),
        Transparency = 0.4
    })
    expandTween:Play()
    
    for i = 1, 8 do
        local particle = Instance.new("Part")
        particle.Size = Vector3.new(0.3, 0.3, 0.3)
        particle.Material = Enum.Material.Neon
        particle.Color = Color3.fromRGB(150, 230, 255)
        particle.Anchored = false
        particle.CanCollide = false
        particle.Position = position
        particle.Parent = workspace
        
        local randomDirection = Vector3.new(
            math.random(-100, 100) / 100,
            math.random(0, 100) / 100,
            math.random(-100, 100) / 100
        ).Unit * math.random(5, 15)
        
        particle.AssemblyLinearVelocity = randomDirection
        
        Debris:AddItem(particle, 0.8)
    end
    
    task.delay(0.3, function()
        local shrinkTween = TweenService:Create(impactMarker, TweenInfo.new(0.15), {
            Size = Vector3.new(0.8, 0.8, 0.2),
            Transparency = 0.7
        })
        shrinkTween:Play()
    end)
    
    Debris:AddItem(impactMarker, 0.5)
end

function GrapplingHook:emitLaunchSound()
    local launchSound = Instance.new("Sound")
    launchSound.SoundId = "rbxassetid://12221967"
    launchSound.Volume = 0.6
    launchSound.PlaybackSpeed = 1.3
    launchSound.Parent = rootPart
    launchSound:Play()
    
    Debris:AddItem(launchSound, 2)
end

function GrapplingHook:detachHook()
    if not isHookDeployed then return end
    
    isHookDeployed = false
    self.anchorPosition = nil
    self.reelingActive = false
    
    if self.updateLoop then
        self.updateLoop:Disconnect()
        self.updateLoop = nil
    end
    
    if self.physicsBody then
        local momentumPreserved = self.physicsBody.Velocity * 0.65
        self.physicsBody:Destroy()
        self.physicsBody = nil
        
        local impulseBody = Instance.new("BodyVelocity")
        impulseBody.MaxForce = Vector3.new(4500, 4500, 4500)
        impulseBody.Velocity = momentumPreserved
        impulseBody.Parent = rootPart
        
        task.delay(0.12, function()
            if impulseBody and impulseBody.Parent then 
                impulseBody:Destroy() 
            end
        end)
    end
    
    humanoid.PlatformStand = false
    humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
    
    for _, segment in ipairs(self.visualSegments) do
        local dissolveTween = TweenService:Create(segment, TweenInfo.new(0.18), {
            Transparency = 1,
            Size = segment.Size * 0.3
        })
        dissolveTween:Play()
    end
    
    for _, beam in ipairs(self.beamConnectors) do
        TweenService:Create(beam, TweenInfo.new(0.18), {
            Transparency = 1
        }):Play()
    end
    
    task.delay(0.2, function()
        for _, segment in ipairs(self.visualSegments) do
            segment:Destroy()
        end
        self.visualSegments = {}
        self.beamConnectors = {}
    end)
    
    activeHook = nil
end

function GrapplingHook:initiateReeling()
    if isHookDeployed then
        self.reelingActive = true
    end
end

function GrapplingHook:terminateReeling()
    self.reelingActive = false
end

local inputBindings = {}

inputBindings.mousePress = UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if not isHookDeployed then
            local mouseLocation = UserInputService:GetMouseLocation()
            local viewportRay = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
            local aimTarget = viewportRay.Origin + viewportRay.Direction * maxHookRange
            
            local hookInstance = GrapplingHook.new()
            hookInstance:deployHook(aimTarget)
        end
    end
    
    if input.KeyCode == Enum.KeyCode.Space and isHookDeployed then
        if activeHook then
            activeHook:initiateReeling()
        end
    end
    
    if input.KeyCode == Enum.KeyCode.Q and isHookDeployed then
        if activeHook then
            activeHook:detachHook()
        end
    end
end)

inputBindings.inputRelease = UserInputService.InputEnded:Connect(function(input, processed)
    if input.KeyCode == Enum.KeyCode.Space and isHookDeployed then
        if activeHook then
            activeHook:terminateReeling()
        end
    end
    
    if input.UserInputType == Enum.UserInputType.MouseButton2 and isHookDeployed then
        if activeHook then
            activeHook:detachHook()
        end
    end
end)

player.CharacterAdded:Connect(function(newCharacter)
    character = newCharacter
    humanoid = character:WaitForChild("Humanoid")
    rootPart = character:WaitForChild("HumanoidRootPart")
    
    if activeHook then
        activeHook:detachHook()
    end
    
    task.wait(0.5)
end)

print("Advanced Grappling Hook System Initialized")
