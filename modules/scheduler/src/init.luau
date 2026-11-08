--!strict

local RunService = game:GetService("RunService")

export type System = ((dt: number) -> ()) | { Update: (self: any, dt: number) -> () }

export type SystemOptions = {
	Priority: number?,
	Interval: number?,
	Scaled: boolean?,
}

export type Stat = {
	Name: string,
	Average: number,
	Max: number,
	Calls: number,
	Errors: number,
}

export type Options = {
	Name: string?,
	Event: RBXScriptSignal?,
	Clock: { Speed: (self: any) -> number, IsPaused: (self: any) -> boolean }?,
	Budget: number?,
	Profile: boolean?,
}

export type Scheduler = {
	Add: (self: Scheduler, name: string, system: System, options: SystemOptions?) -> () -> (),
	Start: (self: Scheduler) -> (),
	Stop: (self: Scheduler) -> (),
	IsRunning: (self: Scheduler) -> boolean,
	Stats: (self: Scheduler) -> { Stat },
	Report: (self: Scheduler) -> string,
	ResetStats: (self: Scheduler) -> (),
}

type Entry = {
	Name: string,
	Run: (dt: number) -> (),
	Priority: number,
	Order: number,
	Interval: number?,
	Scaled: boolean,
	Pending: number,
	Average: number,
	Max: number,
	Calls: number,
	Errors: number,
	WarnedAt: number,
}

local Scheduler = {}

local SMOOTHING = 0.05
local ERROR_WARN_EVERY = 5
local BUDGET_WARN_EVERY = 10
local LOG_ATTRIBUTE = "Log"
local LOG_ONLY_ATTRIBUTE = "LogOnly"
local LOG_RESET_ATTRIBUTE = "LogReset"
local DEFAULT_LOG_EVERY = 5

local WARNINGS_ATTRIBUTE = "Warnings"
local LOG_REMOTE = "SetLog"
local LOG_KEYS = { LOG_ATTRIBUTE, LOG_ONLY_ATTRIBUTE, LOG_RESET_ATTRIBUTE, WARNINGS_ATTRIBUTE }
local SIDE = if RunService:IsServer() then "server" else "client"

local running: { [Scheduler]: string } = {}
local logThread: thread? = nil

local function warningsOn(): boolean
	return script:GetAttribute(WARNINGS_ATTRIBUTE) ~= false
end

local function restartLog(announce: boolean)
	local wasOn = logThread ~= nil
	if logThread then
		task.cancel(logThread)
		logThread = nil
	end
	local setting = script:GetAttribute(LOG_ATTRIBUTE)
	local every = if setting == true then DEFAULT_LOG_EVERY elseif type(setting) == "number" then setting else 0
	if every <= 0 then
		if announce then
			print(`[Scheduler] usage log {if wasOn then "off" else "is already off"} ({SIDE})`)
		end
		return
	end
	print(`[Scheduler] usage log every {every} s ({SIDE}) - stop: Scheduler:SetAttribute("{LOG_ATTRIBUTE}", false)`)
	logThread = task.spawn(function()
		while true do
			task.wait(every)
			local only = script:GetAttribute(LOG_ONLY_ATTRIBUTE)
			for scheduler, name in running do
				if type(only) ~= "string" or only == "" or only == name then
					print(scheduler:Report())
					if script:GetAttribute(LOG_RESET_ATTRIBUTE) == true then
						scheduler:ResetStats()
					end
				end
			end
		end
	end)
end

script:GetAttributeChangedSignal(LOG_ATTRIBUTE):Connect(function()
	restartLog(true)
end)
script:GetAttributeChangedSignal(WARNINGS_ATTRIBUTE):Connect(function()
	print(`[Scheduler] error/budget warnings {if warningsOn() then "on" else "off (errors still counted in the report)"} ({SIDE})`)
end)
restartLog(false)

if RunService:IsServer() and RunService:IsStudio() and not script:FindFirstChild(LOG_REMOTE) then
	local remote = Instance.new("RemoteEvent")
	remote.Name = LOG_REMOTE
	remote.OnServerEvent:Connect(function(_player: Player, key: any, value: any)
		if table.find(LOG_KEYS, key) and (value == nil or type(value) == "number" or type(value) == "boolean" or type(value) == "string") then
			script:SetAttribute(key, value)
		end
	end)
	remote.Parent = script
end

local function toFunction(system: System): (dt: number) -> ()
	if type(system) == "function" then
		return system
	end
	local object = system :: any
	assert(type(object) == "table" and type(object.Update) == "function", "[Scheduler] a system is a function or a table with :Update(dt)")
	return function(dt: number)
		object:Update(dt)
	end
end

function Scheduler.new(options: Options?): Scheduler
	local name = options and options.Name or "Scheduler"
	local event = options and options.Event or RunService.Heartbeat
	local clock = options and options.Clock
	local budget = options and options.Budget
	local profile = not options or options.Profile ~= false
	local entries: { Entry } = {}
	local nextOrder = 0
	local connection: RBXScriptConnection? = nil
	local budgetWarnedAt = 0

	local function sort(list: { Entry })
		table.sort(list, function(a, b)
			if a.Priority ~= b.Priority then
				return a.Priority > b.Priority
			end
			return a.Order < b.Order
		end)
	end

	local function step(realDt: number)
		local scale = 1
		if clock then
			scale = if clock:IsPaused() then 0 else clock:Speed()
		end
		local frameStart = os.clock()
		local slowest: Entry? = nil
		local slowestTime = 0
		local list = entries
		for _, entry in list do
			local dt = if entry.Scaled then realDt * scale else realDt
			if entry.Scaled and dt <= 0 then
				continue
			end
			local interval = entry.Interval
			if interval then
				entry.Pending += dt
				if entry.Pending < interval then
					continue
				end
				dt = entry.Pending
				entry.Pending = 0
			end
			if profile then
				debug.profilebegin(entry.Name)
			end
			local at = os.clock()
			local ok, problem = pcall(entry.Run, dt)
			local took = os.clock() - at
			if profile then
				debug.profileend()
			end
			entry.Calls += 1
			entry.Average += (took - entry.Average) * SMOOTHING
			if took > entry.Max then
				entry.Max = took
			end
			if took > slowestTime then
				slowest, slowestTime = entry, took
			end
			if not ok then
				entry.Errors += 1
				local now = os.clock()
				if now - entry.WarnedAt > ERROR_WARN_EVERY and warningsOn() then
					entry.WarnedAt = now
					warn(`[{name}] {entry.Name} failed ({entry.Errors}x so far): {problem}`)
				end
			end
		end
		if budget then
			local total = (os.clock() - frameStart) * 1000
			local now = os.clock()
			if total > budget and now - budgetWarnedAt > BUDGET_WARN_EVERY and warningsOn() then
				budgetWarnedAt = now
				local worst = if slowest then ` - slowest: {slowest.Name} {string.format("%.2f", slowestTime * 1000)} ms` else ""
				warn(`[{name}] frame took {string.format("%.2f", total)} ms (budget {budget} ms){worst}`)
			end
		end
	end

	local scheduler: Scheduler
	scheduler = {
		Add = function(_self, systemName: string, system: System, systemOptions: SystemOptions?)
			nextOrder += 1
			local entry: Entry = {
				Name = systemName,
				Run = toFunction(system),
				Priority = systemOptions and systemOptions.Priority or 0,
				Order = nextOrder,
				Interval = systemOptions and systemOptions.Interval,
				Scaled = systemOptions ~= nil and systemOptions.Scaled == true,
				Pending = 0,
				Average = 0,
				Max = 0,
				Calls = 0,
				Errors = 0,
				WarnedAt = 0,
			}
			local added = table.clone(entries)
			table.insert(added, entry)
			sort(added)
			entries = added
			return function()
				local index = table.find(entries, entry)
				if index then
					local removed = table.clone(entries)
					table.remove(removed, index)
					entries = removed
				end
			end
		end,
		Start = function(self)
			if connection then
				return
			end
			connection = event:Connect(step)
			running[self] = name
		end,
		Stop = function(self)
			if connection then
				connection:Disconnect()
				connection = nil
			end
			running[self] = nil
		end,
		IsRunning = function(_self)
			return connection ~= nil
		end,
		Stats = function(_self)
			local stats: { Stat } = {}
			for _, entry in entries do
				table.insert(stats, {
					Name = entry.Name,
					Average = entry.Average * 1000,
					Max = entry.Max * 1000,
					Calls = entry.Calls,
					Errors = entry.Errors,
				})
			end
			table.sort(stats, function(a, b)
				return a.Average > b.Average
			end)
			return stats
		end,
		Report = function(self)
			local lines = { `[{name}] systems by average cost (ms):` }
			for _, stat in self:Stats() do
				table.insert(lines, string.format("  %-24s avg %6.3f  max %7.3f  calls %d%s", stat.Name, stat.Average, stat.Max, stat.Calls, if stat.Errors > 0 then `  errors {stat.Errors}` else ""))
			end
			return table.concat(lines, "\n")
		end,
		ResetStats = function(_self)
			for _, entry in entries do
				entry.Average, entry.Max, entry.Calls, entry.Errors = 0, 0, 0, 0
			end
		end,
	}
	return scheduler
end

return Scheduler