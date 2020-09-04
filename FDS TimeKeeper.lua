--//FDS TimeKeeper 2
--[[TimeKeeper
Easy Time tracking and loop synchronisation.

wait() is unpredictable, this will fire everything at the same time
]]--
--Create a variable named "TimeKeeperTick" in ReplicatedStorage before installing this

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local timekeeper = {}
timekeeper.__index = timekeeper

function timekeeper:getTimeSignal(UNIX)
	if UNIX <= self.Time then error("Cannot generate in the past") end
	
	local E = self._TickEvents[UNIX]
	if not E then
		E = Instance.new("BindableEvent")
		self._TickEvents[UNIX] = E
	end
	
	return E.Event
end

function timekeeper:tick()
	local oldTime = self.Time
	self.Time = os.time()
	
	if oldTime ~= self.Time then
		self.TickValue.Value = self.Time
		self._TickEvent:Fire(self.Time)
		local e = self._TickEvents[self.Time]
		if e then
			e:Fire()
			e:Destroy()
		end
	end
end

function timekeeper:start()
	if self._rse then return end
	self._rse=RunService.Heartbeat:Connect(function()
		self:tick()
	end)
end

local tk = {}
function tk.new()
	local o = setmetatable({}, timekeeper)
	
	o.TickValue = ReplicatedStorage.TimeKeeperTick
	
	o.Time = os.time()
	o._TickEvents = {}
	
	o._TickEvent = Instance.new("BindableEvent")
	o.Tick = o._TickEvent.Event
	
	return o
end

return tk.new()
