--!strict
--https://github.com/Adidsus/RoUtils

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

export type Event = {
	Name: string,
	Kind: string,
	Time: number,
	Server: string,
	Place: number,
	Version: number,
	UserId: number?,
	Session: string?,
	Value: number?,
	Fields: { [string]: any },
}

export type Sink = {
	Name: string?,
	Send: (batch: { Event }) -> (),
	Event: ((event: Event) -> ())?,
	Filter: ((event: Event) -> boolean)?,
	Batch: number?,
	Every: number?,
}

local Insight = {}

local IS_SERVER = RunService:IsServer()
local CLIENT_NAME = "InsightClient"

local settings = {
	Every = 10,
	Batch = 50,
	Queue = 2000,
	Retries = 3,
	IncludeName = false,
	Sessions = true,
	System = false,
	SystemEvery = 60,
	ClientRate = 10,
	PerformanceEvery = 300,
	Errors = false,
	SessionStore = "InsightSessions" :: string | false,
}

local sinks: { any } = {}
local globals: { [string]: any } = {}
local sampling: { [string]: number } = {}
local sessions: { [Player]: any } = {}
local allowed: { [string]: boolean } = {}
local buckets: { [Player]: { Tokens: number, At: number } } = {}
local server = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local function now(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

local function clean(fields: any, depth: number?): { [string]: any }
	local out = {}
	if type(fields) ~= "table" then
		return out
	end
	local level = depth or 0
	local count = 0
	for key, value in fields do
		count += 1
		if count > 50 then
			break
		end
		local k = tostring(key)
		local t = typeof(value)
		if t == "number" or t == "boolean" then
			out[k] = value
		elseif t == "string" then
			out[k] = string.sub(value, 1, 500)
		elseif t == "table" and level < 2 then
			out[k] = clean(value, level + 1)
		elseif t == "Vector3" or t == "Vector2" or t == "CFrame" or t == "Color3" or t == "EnumItem" then
			out[k] = tostring(value)
		elseif t == "Instance" then
			out[k] = value:GetFullName()
		end
	end
	return out
end

local function build(kind: string, name: string, player: Player?, value: number?, fields: any): any
	local merged = table.clone(globals)
	for key, v in clean(fields) do
		merged[key] = v
	end
	local session = player and sessions[player]
	local carrier: any = nil
	if not player and (kind == "Metric" or kind == "Error") then
		for other, otherSession in sessions do
			if other.Parent then
				carrier = {
					UserId = other.UserId,
					Session = otherSession.Id,
					SessionNumber = otherSession.Number,
					Device = otherSession.Device,
				}
				break
			end
		end
	end
	if player and settings.IncludeName then
		merged.PlayerName = player.Name
	end
	return {
		Name = name,
		Kind = kind,
		Time = now(),
		Server = server,
		Place = game.PlaceId,
		Version = game.PlaceVersion,
		UserId = if player then player.UserId else nil,
		Session = if session then session.Id else nil,
		SessionNumber = if session then session.Number else nil,
		Device = if session then session.Device else nil,
		Carrier = carrier,
		Value = value,
		Fields = merged,
		_player = player,
	}
end

local function sampled(name: string): boolean
	local rate = sampling[name]
	return rate == nil or math.random() < rate
end

local function emit(event: any)
	for _, sink in sinks do
		if sink.Filter and not sink.Filter(event) then
			continue
		end
		if sink.Event then
			task.spawn(function()
				local ok, err = pcall(sink.Event, event)
				if not ok then
					warn(`Insight: sink {sink.Name} failed: {err}`)
				end
			end)
		end
		if sink.Send then
			table.insert(sink._queue, event)
			if #sink._queue > settings.Queue then
				table.remove(sink._queue, 1)
				sink._dropped += 1
			end
			if #sink._queue >= (sink.Batch or settings.Batch) then
				Insight._flushSink(sink)
			end
		end
	end
end

local function strip(batch: { any }): { Event }
	local out = table.create(#batch)
	for i, event in batch do
		local copy = table.clone(event)
		copy._player = nil
		out[i] = copy
	end
	return out
end

function Insight._flushSink(sink: any)
	if #sink._queue == 0 or sink._sending then
		return
	end
	local size = sink.Batch or settings.Batch
	local batch = table.move(sink._queue, 1, math.min(size, #sink._queue), 1, {})
	for _ = 1, #batch do
		table.remove(sink._queue, 1)
	end
	sink._sending = true
	sink._last = os.clock()
	task.spawn(function()
		local attempt = 0
		while true do
			attempt += 1
			local ok, err = pcall(sink.Send, strip(batch))
			if ok then
				sink._sent += #batch
				break
			end
			if attempt > settings.Retries then
				sink._failed += #batch
				warn(`Insight: sink {sink.Name} dropped {#batch} events: {err}`)
				break
			end
			task.wait(2 ^ attempt)
		end
		sink._sending = false
	end)
end

function Insight.add(sink: Sink | (batch: { Event }) -> (), name: string?): () -> ()
	local entry: any = if type(sink) == "function" then { Send = sink } else table.clone(sink :: any)
	assert(
		type(entry.Send) == "function" or type(entry.Event) == "function",
		"Insight.add: a sink needs Send(batch) or Event(event)"
	)
	entry.Name = name or entry.Name or `sink{#sinks + 1}`
	entry._queue = {}
	entry._sent = 0
	entry._failed = 0
	entry._dropped = 0
	entry._last = os.clock()
	table.insert(sinks, entry)
	return function()
		local index = table.find(sinks, entry)
		if index then
			Insight._flushSink(entry)
			table.remove(sinks, index)
		end
	end
end

function Insight.track(player: Player?, name: string, fields: { [string]: any }?, value: number?)
	assert(type(name) == "string" and name ~= "", "Insight.track: needs an event name")
	if not sampled(name) then
		return
	end
	emit(build("Event", name, player, value, fields))
end

function Insight.design(player: Player?, parts: { any }, value: number?, fields: { [string]: any }?)
	local names = {}
	for _, part in parts do
		table.insert(names, (string.gsub(tostring(part), ":", "_")))
	end
	Insight.track(player, table.concat(names, ":"), fields, value)
end

function Insight.economy(
	player: Player,
	flow: "Source" | "Sink",
	currency: string,
	amount: number,
	balance: number,
	transaction: string?,
	item: string?,
	fields: { [string]: any }?
)
	assert(flow == "Source" or flow == "Sink", `Insight.economy: flow "{tostring(flow)}" - Source or Sink`)
	local data = table.clone(fields or {})
	data.Flow = flow
	data.Currency = currency
	data.Balance = balance
	data.Transaction = transaction or "Gameplay"
	data.Item = item
	emit(build("Economy", currency, player, amount, data))
end

function Insight.funnel(player: Player, funnel: string, step: number, stepName: string?, fields: { [string]: any }?)
	local data = table.clone(fields or {})
	data.Step = step
	data.StepName = stepName
	emit(build("Funnel", funnel, player, step, data))
end

function Insight.progress(
	player: Player,
	path: string,
	stage: string,
	result: "Start" | "Complete" | "Fail",
	fields: { [string]: any }?
)
	local data = table.clone(fields or {})
	data.Stage = stage
	data.Result = result
	emit(build("Progress", path, player, nil, data))
end

function Insight.metric(name: string, value: number, fields: { [string]: any }?)
	emit(build("Metric", name, nil, value, fields))
end

function Insight.error(
	message: string,
	severity: ("debug" | "info" | "warning" | "error" | "critical")?,
	source: string?
)
	local data = { Severity = severity or "error", Message = string.sub(message, 1, 2000) }
	emit(build("Error", source or "Server", nil, nil, data))
end

function Insight.watch(source: any, prefix: string?, options: { FlagEvery: number? }?): () -> ()
	local opts: any = options or {}
	local name = prefix or (if type(source.Name) == "string" then source.Name else "Guard")
	local connections = {}
	local last: { [string]: number } = {}
	local function isSignal(value: any): boolean
		return typeof(value) == "RBXScriptSignal" or (type(value) == "table" and type(value.Connect) == "function")
	end
	if isSignal(source.Action) then
		table.insert(
			connections,
			source.Action:Connect(function(player: Player, action: string, score: number)
				Insight.design(player, { name, "Action", action }, score)
			end)
		)
	end
	if isSignal(source.Flagged) then
		table.insert(
			connections,
			source.Flagged:Connect(function(player: Player, flag: any)
				local key = `{player.UserId}|{flag.Check}`
				local t = os.clock()
				if last[key] and t - last[key] < (opts.FlagEvery or 30) then
					return
				end
				last[key] = t
				Insight.design(player, { name, "Flag", flag.Check, flag.Certainty }, flag.Applied)
			end)
		)
	end
	assert(#connections > 0, "Insight.watch: the source has no Action or Flagged event")
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
	end
end

function Insight.set(key: string, value: any)
	globals[key] = value
end

function Insight.sample(name: string, rate: number)
	sampling[name] = math.clamp(rate, 0, 1)
end

function Insight.configure(options: { [string]: any })
	local target: any = settings
	for key, value in options do
		assert(target[key] ~= nil, `Insight.configure: unknown option "{key}"`)
		target[key] = value
	end
	local remote = script:FindFirstChild(CLIENT_NAME)
	if remote then
		remote:SetAttribute("Every", settings.PerformanceEvery)
	end
end

function Insight.flush()
	for _, sink in sinks do
		while #sink._queue > 0 and not sink._sending do
			Insight._flushSink(sink)
		end
	end
end

function Insight.stats(): { [string]: any }
	local out = {}
	for _, sink in sinks do
		out[sink.Name] = { Queued = #sink._queue, Sent = sink._sent, Failed = sink._failed, Dropped = sink._dropped }
	end
	return out
end

function Insight.session(player: Player): { Id: string, Started: number }?
	local session = sessions[player]
	return session and { Id = session.Id, Started = session.Started }
end

Insight.sinks = {}

function Insight.sinks.roblox(): Sink
	return {
		Name = "Roblox",
		Event = function(event: any)
			local player = event._player
			if not player or not player.Parent then
				return
			end
			if event.Kind == "Economy" then
				local f = event.Fields
				AnalyticsService:LogEconomyEvent(
					player,
					if f.Flow == "Source"
						then Enum.AnalyticsEconomyFlowType.Source
						else Enum.AnalyticsEconomyFlowType.Sink,
					event.Name,
					event.Value or 0,
					f.Balance or 0,
					f.Transaction or "Gameplay",
					f.Item
				)
			elseif event.Kind == "Funnel" then
				AnalyticsService:LogFunnelStepEvent(
					player,
					event.Name,
					event.Session,
					event.Fields.Step,
					event.Fields.StepName
				)
			elseif event.Kind == "Progress" then
				local result = event.Fields.Result
				local status = if result == "Complete"
					then Enum.AnalyticsProgressionType.Complete
					elseif result == "Fail" then Enum.AnalyticsProgressionType.Fail
					else Enum.AnalyticsProgressionType.Start
				AnalyticsService:LogProgressionEvent(player, event.Name, status, 1, event.Fields.Stage)
			elseif event.Kind == "Event" then
				AnalyticsService:LogCustomEvent(player, event.Name, event.Value or 1)
			end
		end,
	}
end

function Insight.sinks.http(
	url: string,
	options: {
		Headers: { [string]: string }?,
		Format: ((batch: { Event }) -> string)?,
		Batch: number?,
		Every: number?,
		Post: ((url: string, body: string, headers: { [string]: string }) -> ())?,
	}?
): Sink
	local opts: any = options or {}
	local headers = opts.Headers or {}
	local post = opts.Post
		or function(target: string, body: string, h: { [string]: string })
			local response = HttpService:RequestAsync({
				Url = target,
				Method = "POST",
				Headers = h,
				Body = body,
			})
			if not response.Success then
				error(`HTTP {response.StatusCode}: {string.sub(response.Body, 1, 200)}`)
			end
		end
	local allHeaders = table.clone(headers)
	allHeaders["Content-Type"] = allHeaders["Content-Type"] or "application/json"
	return {
		Name = "Http",
		Batch = opts.Batch,
		Every = opts.Every,
		Send = function(batch: { Event })
			local body = if opts.Format then opts.Format(batch) else HttpService:JSONEncode({ events = batch })
			post(url, body, allHeaders)
		end,
	}
end

function Insight.sinks.ga4(measurementId: string, apiSecret: string, options: { Post: any? }?): Sink
	local opts: any = options or {}
	local url = `https://www.google-analytics.com/mp/collect?measurement_id={measurementId}&api_secret={apiSecret}`
	local function name(event: Event): string
		local raw = string.lower(event.Kind .. "_" .. event.Name)
		return string.sub((string.gsub(raw, "[^%w_]", "_")), 1, 40)
	end
	return Insight.sinks.http(url, {
		Post = opts.Post,
		Format = function(batch: { Event }): string
			local byUser: { [string]: { any } } = {}
			for _, event in batch do
				local id = tostring(event.UserId or event.Server)
				byUser[id] = byUser[id] or {}
				local params: { [string]: any } = { value = event.Value, session_id = event.Session }
				for key, v in event.Fields do
					if type(v) ~= "table" then
						params[string.sub(string.lower(key), 1, 40)] = v
					end
				end
				table.insert(byUser[id], { name = name(event), params = params })
			end
			local id, list = next(byUser)
			return HttpService:JSONEncode({
				client_id = id,
				user_id = id,
				events = table.move(list :: any, 1, math.min(25, #(list :: any)), 1, {}),
			})
		end,
		Batch = 25,
	})
end

function Insight.sinks.output(filter: ((event: Event) -> boolean)?): Sink
	return {
		Name = "Output",
		Filter = filter,
		Event = function(event: any)
			local parts = {}
			for key, value in event.Fields do
				table.insert(parts, `{key}={tostring(value)}`)
			end
			table.sort(parts)
			print(
				`[Insight] {event.Kind} {event.Name}{if event.Value then " " .. tostring(event.Value) else ""}{if event.UserId
					then " user " .. event.UserId
					else ""} {table.concat(parts, " ")}`
			)
		end,
	}
end

local DEVICES = { Desktop = true, Phone = true, Tablet = true, Console = true, VR = true }

function Insight.allowClient(names: { string })
	assert(IS_SERVER, "Insight.allowClient runs on the server")
	for _, name in names do
		allowed[name] = true
	end
	if not script:FindFirstChild(CLIENT_NAME) then
		local remote = Instance.new("RemoteEvent")
		remote.Name = CLIENT_NAME
		remote:SetAttribute("Every", settings.PerformanceEvery)
		remote.Parent = script
		remote.OnServerEvent:Connect(function(player, name, fields)
			if name == 0 then
				local session = sessions[player]
				if session and type(fields) == "string" and DEVICES[fields] then
					session.Device = fields
				end
				return
			elseif name == 1 then
				local session = sessions[player]
				if session and type(fields) == "number" and fields == fields and fields >= 0 and fields < 1000 then
					session.FpsSum += fields
					session.PingSum += math.max(player:GetNetworkPing(), 0) * 1000
					session.PerfCount += 1
					session.AllFps += fields
					session.AllPing += math.max(player:GetNetworkPing(), 0) * 1000
					session.AllCount += 1
					if now() - session.PerfAt >= settings.PerformanceEvery then
						local device = session.Device or "Desktop"
						Insight.design(
							player,
							{ "Perf", "Fps", device },
							math.floor(session.FpsSum / session.PerfCount)
						)
						Insight.design(
							player,
							{ "Perf", "Ping", device },
							math.floor(session.PingSum / session.PerfCount)
						)
						session.FpsSum, session.PingSum, session.PerfCount = 0, 0, 0
						session.PerfAt = now()
					end
				end
				return
			end
			if type(name) ~= "string" or not allowed[name] then
				return
			end
			local t = os.clock()
			local bucket = buckets[player]
			if not bucket then
				bucket = { Tokens = settings.ClientRate, At = t }
				buckets[player] = bucket
			end
			bucket.Tokens = math.min(settings.ClientRate, bucket.Tokens + (t - bucket.At) * settings.ClientRate)
			bucket.At = t
			if bucket.Tokens < 1 then
				return
			end
			bucket.Tokens -= 1
			local data = clean(fields)
			data.FromClient = true
			Insight.track(player, name, data)
		end)
	end
end

function Insight.reportDevice()
	assert(not IS_SERVER, "Insight.reportDevice runs on the client")
	local remote = script:WaitForChild(CLIENT_NAME, 10) :: RemoteEvent?
	if not remote then
		return
	end
	local input = game:GetService("UserInputService")
	local device = "Desktop"
	if input.VREnabled then
		device = "VR"
	elseif game:GetService("GuiService"):IsTenFootInterface() then
		device = "Console"
	elseif input.TouchEnabled and not input.KeyboardEnabled then
		local camera = workspace.CurrentCamera
		local size = if camera then camera.ViewportSize else Vector2.new(800, 600)
		device = if math.min(size.X, size.Y) >= 600 then "Tablet" else "Phone"
	end
	remote:FireServer(0, device)
	local run = game:GetService("RunService")
	local frames = 0
	run.RenderStepped:Connect(function()
		frames += 1
	end)
	task.spawn(function()
		while remote.Parent do
			local every = remote:GetAttribute("Every")
			local wait = math.clamp(if type(every) == "number" then every / 5 else 60, 0.5, 60)
			frames = 0
			local started = os.clock()
			task.wait(wait)
			remote:FireServer(1, frames / (os.clock() - started))
		end
	end)
end

function Insight.client(name: string, fields: { [string]: any }?)
	assert(not IS_SERVER, "Insight.client runs on the client")
	local remote = script:FindFirstChild(CLIENT_NAME) :: RemoteEvent?
	if remote then
		remote:FireServer(name, fields)
	end
end

if IS_SERVER then
	Insight.allowClient({})
	local function ending(session: any): { [string]: any }
		return {
			Seconds = math.floor(now() - session.Started),
			AvgFps = if session.AllCount > 0 then math.floor(session.AllFps / session.AllCount) else nil,
			AvgPingMs = if session.AllCount > 0 then math.floor(session.AllPing / session.AllCount) else nil,
			Device = session.Device,
		}
	end
	local lastErrors: { [string]: number } = {}
	game:GetService("ScriptContext").Error:Connect(function(message, _trace, source)
		if not settings.Errors or string.sub(message, 1, 11) == "CommandBar:" then
			return
		end
		local key = string.sub(message, 1, 200)
		local t = os.clock()
		if lastErrors[key] and t - lastErrors[key] < 60 then
			return
		end
		lastErrors[key] = t
		Insight.error(message, "error", if source then source.Name else "Server")
	end)
	local function join(player: Player)
		if sessions[player] then
			return
		end
		local session = {
			Id = HttpService:GenerateGUID(false),
			Started = now(),
			Number = 1,
			Device = nil,
			FpsSum = 0,
			PingSum = 0,
			PerfCount = 0,
			AllFps = 0,
			AllPing = 0,
			AllCount = 0,
			PerfAt = now(),
		}
		sessions[player] = session
		if settings.SessionStore then
			pcall(function()
				local store = game:GetService("DataStoreService"):GetDataStore(settings.SessionStore :: string)
				session.Number = store:IncrementAsync(tostring(player.UserId), 1)
			end)
		end
		if sessions[player] ~= session then
			return
		end
		if settings.Sessions then
			Insight.track(player, "SessionStart", {
				AccountAge = player.AccountAge,
				Premium = player.MembershipType == Enum.MembershipType.Premium,
				Locale = player.LocaleId,
			})
		end
	end
	Players.PlayerAdded:Connect(function(player)
		join(player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(join, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local session = sessions[player]
		if session and settings.Sessions and not session.Ended then
			session.Ended = true
			Insight.track(player, "SessionEnd", ending(session))
		end
		sessions[player] = nil
		buckets[player] = nil
	end)

	local lastSystem = os.clock()
	local frames, frameTime = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		frames += 1
		frameTime += dt
		local t = os.clock()
		for _, sink in sinks do
			if #sink._queue > 0 and t - sink._last >= (sink.Every or settings.Every) then
				Insight._flushSink(sink)
			end
		end
		if settings.System and t - lastSystem >= settings.SystemEvery then
			lastSystem = t
			local pings = 0
			local players = Players:GetPlayers()
			for _, player in players do
				pings += player:GetNetworkPing()
			end
			Insight.metric("Server", #players, {
				Fps = math.floor(frames / math.max(frameTime, 1e-3)),
				MemoryMB = math.floor(Stats:GetTotalMemoryUsageMb()),
				AvgPingMs = if #players > 0 then math.floor(pings / #players * 1000) else 0,
			})
			frames, frameTime = 0, 0
		end
	end)

	game:BindToClose(function()
		for player, session in table.clone(sessions) do
			if settings.Sessions and not session.Ended then
				session.Ended = true
				Insight.track(player, "SessionEnd", ending(session))
			end
		end
		table.clear(sessions)
		for _, sink in sinks do
			if sink.Send and #sink._queue > 0 then
				pcall(sink.Send, strip(sink._queue))
				table.clear(sink._queue)
			end
		end
	end)
end

return Insight