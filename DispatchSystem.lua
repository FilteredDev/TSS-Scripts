local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptFolder = game:GetService("ServerScriptService").tssServer

local CTRL = require(ScriptFolder.Modules.Generic.CTRL_Objects)
local TrainClass = require(ScriptFolder.Modules.Generic.TrainClass)
local Schedules = require(ScriptFolder.Modules.Generic.ScheduleListSystem)
local TimeKeeper = require(ScriptFolder.Modules.Generic.TimeKeeper)
local PresenceInterface = require(ScriptFolder.Modules.Generic.roActivityInterface)

local TrainThreads = {}
local AnimationStorage = {}

local function PlayAnimationAsync(a) --animation thread used to run animations asynchronously
	coroutine.wrap(function(animation)
		  animation:Play()
	end)(a)
end

local function timeFormat(unix) --formats time in a nice 00:00:00 format
	local t=os.date("!*t", unix)
	return string.format("%02d:%02d", t.hour, t.min)
end
	
local DispatchBlocks = require(ServerStorage.Datafiles.ServerData).DispatchBlocks
local PaddleAnimationSignal

--[[
Arrival Instructions:
Await Platform Assignal (Automatic usually)
Arrive
Do Loading
Await TRTS
Await Dispatch (requires Green Signal)
]]

local function TLen(t) --gets table len for non-numeric arrays
	local l = 0
	for _, v in pairs(t) do
		l += 1
	end
	return l
end

local function SetClientLoopback(event, func) --asynchronous bindable event setup
	event.OnServerEvent:Connect(function(p, ...)
		local data = func(p, ...)
		if p then
			event:FireClient(p, unpack(data))
		end
	end)
end

local function MatchKeyInDictionarySet(dictionary, key, match) --finds a key in a dictionary
	for k, v in pairs(dictionary) do
		if v[key] == match then
			return k
		end
	end
end

----------------------------------------------------------
local function EnterTrain(s, index) --inserts a Train using TrainClass and then tweens it in
	local train = TrainClass.fromServiceData(s)
	
	TrainThreads[s.Headcode] = train
	train:Spawn(index)
	
	s.Status = "Arriving"
	
	local d=math.random(0,2)
	if d~= 0 then wait(d) end
	
	Schedules:SetPlatform(s, index)
	train:Arrive(s.Passing)
	
	s.Status = "WaitingForTRTS"
end

local function ExitTrain(s, b) --Tweens out a train and then removes it
	local train = TrainThreads[s.Headcode]
	s.Status = "Departing"
	
	if not s.Passing then
		local d=math.random(0,3)
		if d~= 0 then wait(d) end
	end
	
	train:Depart(PaddleAnimationSignal, s.Passing)
	
	CTRL:SetSignal(train.NodeIndex, "2")
	b.Platforms[train.NodeIndex].Occupied = false
	b.TRTS = nil
	b.Services[s.Headcode] = nil
	Schedules:FlushService(s.Headcode)
	
	train:Destroy()
	TrainThreads[s.Headcode] = nil
end

local function TRTS(service, block) --Internal TRTS signal.
	print(service.Headcode, "TRTS Signalled. Departure:", timeFormat(service.Departure))
	block.TRTS = service.Headcode
	service.Status = "WaitingForDepartures"
	
	local train = TrainThreads[service.Headcode]
	CTRL:SetSignal(train.NodeIndex, "1")
	CTRL:AddToDepartures(block, service)
end

local function Depart(service, block, dispatch) --Internal Depart signal.
	print("Departing:", service.Headcode, timeFormat(service.Departure))
	dispatch.ActiveData[service.Headcode] = nil
	ExitTrain(service, block)
end

function HandleArrivals() --creates a thread to handle arrivals for each block, this is where the mess starts.
	return coroutine.wrap(function(block, dispatch)
		while TimeKeeper.Tick:Wait() do
			--TRAINS MUT BE IN WAITINGFORDEPARTURE STATE, NOT WAITINGFORTRTS
			while TLen(block.ArrivalQueue) > 0 and dispatch.AutomaticArrival do
				--Do Next Prioritised Service in queue
				local Service = CTRL:GetServiceArrival(block.Name)
				if Service then
					local Platform = CTRL:GetPlatform(block.Name)
					if Platform then
						print("Entering:", Service.Headcode, timeFormat(Service.ExpectedArrival), "Is Passing: ", Service.Passing or false)
						dispatch.ActiveData[Service.Headcode] = {Departure = Service.Departure, IsPassing = Service.Passing}
						
						if dispatch.Dispatcher then
							ReplicatedStorage.DispatchEvents.TrainArrived:FireClient(Players[dispatch.Dispatcher], Service.Headcode, {Departure = Service.Departure, IsPassing = Service.Passing})
						end
						
						EnterTrain(Service, Platform)
					end
					--this thread now blocks thank god
				end		
			end
		end	
	end)
end

function HandleDepartures()  --creates a thread to handle departures for each block
	return coroutine.wrap(function(block, dispatch)
		while TimeKeeper.Tick:Wait() do
			while TLen(block.DepartureQueue) > 0 and dispatch.AutomaticDeparture do
				--Do Next Prioritised Service in queue
				local Service = CTRL:GetServiceDeparture(block.Name)
				if Service then
					Depart(Service, block, dispatch)
					--this thread now blocks thank god
				end
			end
		end
	end)
end

function AutoTRTS() --creates a thread to handle trts for each block
	return coroutine.wrap(function(block, dispatch)
		while TimeKeeper.Tick:Wait() do
			
			local t = os.time()
			--Looks among current services within the block to find valid TRTS Calls
			for _, service in pairs(block.Services) do
				if service.Departure <= t and service.Status == "WaitingForTRTS" and dispatch.AutomaticTRTS and not block.TRTS then
					TRTS(service, block)
				end
			end
		end
	end)
end

for n, block in pairs(CTRL.Blocks) do --sets up the threads
	local DispatchBlockData = DispatchBlocks[n]
		
	--Start Threads
	HandleArrivals()(block, DispatchBlockData)
	HandleDepartures()(block, DispatchBlockData)
	AutoTRTS()(block, DispatchBlockData)
end

TimeKeeper.Tick:Connect(function(UNIX) --automatic tick read
	local List = Schedules:GetAllTrains()
	local m = (UNIX - (UNIX % 60))
	CTRL:BulkAddArrivals(m, List)
end)

--Manual Dispatch Engine

SetClientLoopback(ReplicatedStorage.DispatchEvents.TRTS, function(p, headcode, block) --Client TRTS
	local dispatchBlock = DispatchBlocks[block]
	if not dispatchBlock then return {false, "Dispatch Block not found"} end
	if dispatchBlock.Dispatcher ~= p.Name then return {false, "You do not control this block"} end
	
	local service = Schedules:GetService(headcode)
	local block = CTRL.Blocks[block]
	
	if not service then return {false, "Service not found"} end
	if not block then return {false, "Block not found"} end

	if service.Departure > TimeKeeper.Time then return {false, "Cannot signal TRTS on a train that is not ready to depart"} end
	if service.Status ~= "WaitingForTRTS" then return {false, "Please wait for the train to stop"} end
	if block.TRTS then return {false, "TRTS Occupied, please wait"} end
	
	TRTS(service, block)
	
	return {true}
end)

SetClientLoopback(ReplicatedStorage.DispatchEvents.SignalDeparture, function(p, headcode, block) --Use: Departing a train
	local dispatchBlock = DispatchBlocks[block]
	if not dispatchBlock then return {false, "Dispatch Block not found"} end
	if dispatchBlock.Dispatcher ~= p.Name then return {false, "You do not control this block"} end
	
	local service = Schedules:GetService(headcode)
	local block = CTRL.Blocks[block]
	
	if not service then return {false, "Service not found"} end
	if not block then return {false, "Block not found"} end
	
	if block.TRTS ~= service.Headcode then return {false, "Service does not have TRTS"} end
	
	block.DepartureQueue[headcode] = nil
	PaddleAnimationSignal = Instance.new("BindableEvent")
	
	spawn(function() Depart(service, block, dispatchBlock) end)
	
	if not service.Passing then
		PlayAnimationAsync(AnimationStorage[p.Character].WhistleAnimation)
		
		AnimationStorage[p.Character].WhistleAnimation.KeyframeReached:Connect(function()
			p.Character.DispatchParts.Whistle.Sound:Play()
		end)
	end
	PaddleAnimationSignal.Event:Wait()

	if AnimationStorage[p.Character] then
		PlayAnimationAsync(AnimationStorage[p.Character].PaddleAnimation)
	end	
	
	PaddleAnimationSignal:Destroy()
	return {true}
end)

SetClientLoopback(ReplicatedStorage.DispatchEvents.GetDepartureTime, function(p, headcode) --Use: Getting departure time
	local t = Schedules:GetService(headcode)
	if not t then return {false, "Service not found"} end
	
	return {true, t.Departure}
end)

SetClientLoopback(ReplicatedStorage.DispatchEvents.GetTRTS, function(p, block) --Use: when reclicking a train that has TRTS
	local dispatchBlock = DispatchBlocks[block]
	if not dispatchBlock then return {false, "Dispatch Block not found"} end
	if dispatchBlock.Dispatcher ~= p then return {false, "You do not control this block"} end

	local block = CTRL.Blocks[block]
	
	return {true, block.TRTS}
end)

SetClientLoopback(ReplicatedStorage.DispatchEvents.ClaimBlock, function(p, block)
	local dispatchBlock = DispatchBlocks[block]
	if not dispatchBlock then return {false, "Dispatch Block not found"} end
	
	if dispatchBlock.Dispatcher then return {false, "Block In Use"} end
	dispatchBlock.Dispatcher = p.Name
	
	dispatchBlock.AutomaticTRTS = false
	dispatchBlock.AutomaticDeparture = false
	
	--weld the dispatch parts to the dispatcher
	local newDispatchParts = ServerStorage.AssetPackage.DispatchParts:Clone()
	newDispatchParts.Parent = p.Character
	
	-->Whistle
	local RightGrip = Instance.new("Motor6D")
	RightGrip.Name = "RightGrip"
	
	RightGrip.Part0 = p.Character.RightHand
	RightGrip.Part1 = newDispatchParts.DispatchPaddle.Handle
	RightGrip.C1 = newDispatchParts.DispatchPaddle.Handle.C1.Value
	
	RightGrip.Parent = p.Character.RightHand
	
	-->Paddle Board
	local LeftGrip = Instance.new("Motor6D")
	LeftGrip.Name = "LeftGrip"
	
	LeftGrip.Part0 = p.Character.LeftHand
	LeftGrip.Part1 = newDispatchParts.Whistle
	LeftGrip.C1 = newDispatchParts.Whistle.C1.Value
	LeftGrip.Parent = p.Character.LeftHand
	
	AnimationStorage[p.Character] = {}
	AnimationStorage[p.Character].WhistleAnimation = p.Character.Humanoid:LoadAnimation(p.Character.DispatchParts.WhistleAnimation)
	AnimationStorage[p.Character].PaddleAnimation = p.Character.Humanoid:LoadAnimation(p.Character.DispatchParts.PaddleAnimation)
	--returns a list of 'DispatchData' from the block
	
	PresenceInterface:SetActivity(p.UserId, "DispatcherSetPlatform", dispatchBlock.DisplayName)
	return {true, dispatchBlock.ActiveData}
end)

SetClientLoopback(ReplicatedStorage.DispatchEvents.GetAvailableBlocks, function(p)
	local out = {}

	for ID, Block in pairs(DispatchBlocks) do
		out[Block.NumericID] = {ID = ID, Available = (Block.Dispatcher == nil), DisplayName = Block.DisplayName}
	end
	
	return {true, out}
end)

SetClientLoopback(ReplicatedStorage.DispatchEvents.UnclaimBlock, function(p, block)
	local dispatchBlock = DispatchBlocks[block]
	if not dispatchBlock then return {false, "Dispatch Block not found"} end
	if dispatchBlock.Dispatcher ~= p.Name then return {false, "You do not control this block"} end
	
	dispatchBlock.Dispatcher = nil
	
	dispatchBlock.AutomaticTRTS = true
	dispatchBlock.AutomaticDeparture = true
	
	return {true}
end)

Players.PlayerRemoving:Connect(function(p)
	--clean incase of failed cleanup
	local blockID = MatchKeyInDictionarySet(DispatchBlocks, "Dispatcher", p.Name)
	
	if blockID then
		local block = DispatchBlocks[blockID]
		
		block.Dispatcher = nil
		block.AutomaticTRTS = true
		block.AutomaticDeparture = true
	end
end)
