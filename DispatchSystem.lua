local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptFolder = game:GetService("ServerScriptService").tssServer

local CTRL = require(ScriptFolder.Modules.Generic.CTRL_Objects)
local TrainClass = require(ScriptFolder.Modules.Generic.TrainClass)
local Schedules = require(ScriptFolder.Modules.Generic.ScheduleListSystem)
local TimeKeeper = require(ScriptFolder.Modules.Generic.TimeKeeper)
local PresenceInterface = require(ScriptFolder.Modules.Generic.roActivityInterface)

local TrainThreads = {} --array for holding threads
local AnimationStorage = {} --array for holding animations

local function PlayAnimationAsync(a) --animation thread used to run animations asynchronously
	coroutine.wrap(function(animation) --create coroutine
		  animation:Play() --play animation
	end)(a) --end coroutine and run it
end

local function timeFormat(unix) --formats time in a nice 00:00:00 format
	local t=os.date("!*t", unix) --get time dictionary from 'unix'
	return string.format("%02d:%02d", t.hour, t.min) --return formatted string (00:00)
end
	
local DispatchBlocks = require(ServerStorage.Datafiles.ServerData).DispatchBlocks --dispatch block data
local PaddleAnimationSignal --scoping variable for animation signal (this may have been part of the problem for a bug we never fixed)

--[[
Arrival Instructions:
Await Platform Assignal (Automatic usually)
Arrive
Do Loading
Await TRTS
Await Dispatch (requires Green Signal)
]]

local function TLen(t) --gets table len for non-numeric arrays
	local l = 0 --internal counter
	for _, v in pairs(t) do --iterate over array
		l += 1 --increase counter
	end
	return l --return counter
end

local function SetClientLoopback(event, func) --asynchronous bindable event setup
	event.OnServerEvent:Connect(function(p, ...) --setup event
		local data = func(p, ...) --run callback
		if p then --if player exists
			event:FireClient(p, unpack(data)) --unpack return and send it back
		end
	end)
end

local function MatchKeyInDictionarySet(dictionary, key, match) --finds a key in a dictionary
	for k, v in pairs(dictionary) do --iterate over dictionary
		if v[key] == match then --find a match
			return k --return match stopping the for loop
		end
	end
end

----------------------------------------------------------
local function EnterTrain(s, index) --inserts a Train using TrainClass and then tweens it in
	local train = TrainClass.fromServiceData(s) --create a new Train using service data
	
	TrainThreads[s.Headcode] = train --set the headcode to a new train in the thread holder
	train:Spawn(index) --insert the train
	
	s.Status = "Arriving" --set status to Arriving for internal usage
	
	local d=math.random(0,2) --random delay
	if d~= 0 then wait(d) end --wait if d > 0 
	
	Schedules:SetPlatform(s, index) --internal, sets the platform of the service (im actually unsure what this was for again)
	train:Arrive(s.Passing) --insert the train
	
	s.Status = "WaitingForTRTS" --set the status to a TRTS state
end

local function ExitTrain(s, b) --Tweens out a train and then removes it
	local train = TrainThreads[s.Headcode] --fetch train by headcode
	s.Status = "Departing" --set status to Departing
	
	if not s.Passing then --random delay calculation, same as above
		local d=math.random(0,3)
		if d~= 0 then wait(d) end
	end
	
	train:Depart(PaddleAnimationSignal, s.Passing) --depart block
	
	CTRL:SetSignal(train.NodeIndex, "2") --sets the signal to red
	b.Platforms[train.NodeIndex].Occupied = false --blanks the platform
	b.TRTS = nil --clears trts
	b.Services[s.Headcode] = nil --clears service
	Schedules:FlushService(s.Headcode) --removes service from system
	
	train:Destroy() --removes the train
	TrainThreads[s.Headcode] = nil --removes final reference to train, allowing the gc to remove it from memory
end

local function TRTS(service, block) --Internal TRTS signal.
	print(service.Headcode, "TRTS Signalled. Departure:", timeFormat(service.Departure)) --debug output
	block.TRTS = service.Headcode --sets TRTS to headcode
	service.Status = "WaitingForDepartures" --sets status for Departure thread
	
	local train = TrainThreads[service.Headcode] --gets train
	CTRL:SetSignal(train.NodeIndex, "1") --sets signal
	CTRL:AddToDepartures(block, service) --(internal) adds train to departure queue
end

local function Depart(service, block, dispatch) --Internal Depart signal.
	print("Departing:", service.Headcode, timeFormat(service.Departure)) --debug output
	dispatch.ActiveData[service.Headcode] = nil --removes train from dispatch
	ExitTrain(service, block) --tweens out the train
end

function HandleArrivals() --creates a thread to handle arrivals for each block, this is where the mess starts.
	return coroutine.wrap(function(block, dispatch) --create coroutine
		while TimeKeeper.Tick:Wait() do --wait every TimeKeeper tick (1 second)
			--TRAINS MUT BE IN WAITINGFORDEPARTURE STATE, NOT WAITINGFORTRTS
			while TLen(block.ArrivalQueue) > 0 and dispatch.AutomaticArrival do --make sure the array is longer than 0 and that automatic mode is on
				--Do Next Prioritised Service in queue
				local Service = CTRL:GetServiceArrival(block.Name) --get priority service
				if Service then --run if service found
					local Platform = CTRL:GetPlatform(block.Name) --gets an available platform
					if Platform then --if found platform
						print("Entering:", Service.Headcode, timeFormat(Service.ExpectedArrival), "Is Passing: ", Service.Passing or false) --debug output
						dispatch.ActiveData[Service.Headcode] = {Departure = Service.Departure, IsPassing = Service.Passing} --sets dispatch to know train exists
						
						if dispatch.Dispatcher then --tell Dispatcher this train exists
							ReplicatedStorage.DispatchEvents.TrainArrived:FireClient(Players[dispatch.Dispatcher], Service.Headcode, {Departure = Service.Departure, IsPassing = Service.Passing})
						end
						
						EnterTrain(Service, Platform) --tween in train
					end
					--this thread now blocks thank god
				end		
			end
		end	
	end)
end

function HandleDepartures()  --creates a thread to handle departures for each block
	return coroutine.wrap(function(block, dispatch) --create coroutine
		while TimeKeeper.Tick:Wait() do --wait every TimeKeeper tick (1 second)
			while TLen(block.DepartureQueue) > 0 and dispatch.AutomaticDeparture do
				--Do Next Prioritised Service in queue
				local Service = CTRL:GetServiceDeparture(block.Name) --get priority service
				if Service then --if found service
					Depart(Service, block, dispatch) --tweens out train
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
