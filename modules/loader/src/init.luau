--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

export type Naming = {
	ServerSuffixes: { string }?,
	ClientSuffixes: { string }?,
	ServerPrefixes: { string }?,
	ClientPrefixes: { string }?,
	ServerFolders: { string }?,
	ClientFolders: { string }?,
	ParallelSuffixes: { string }?,
}

export type Options = {
	Verbose: boolean?,
	SlowWarning: number?,
	YieldWarning: number?,
	SearchDepth: number?,
	Tag: string?,
	Naming: (Naming | false)?,
	ClientWaitForServer: boolean?,
	Filter: ((module: ModuleScript) -> boolean?)?,
}

export type Entry = {
	Module: ModuleScript,
	Name: string,
	Path: string,
	Priority: number,
	Parallel: boolean,
	Value: any,
	RequireTime: number,
	InitTime: number,
	Failed: string?,
	Actor: Actor?,
}

type Realm = "Server" | "Client" | "Shared" | "Ignore"
type Results = { [string]: { Ok: boolean, Problem: string? } }

local Loader = {}

local DEFAULT_NAMING: Naming = {
	ServerSuffixes = { "Server" },
	ClientSuffixes = { "Client" },
	ServerPrefixes = {},
	ClientPrefixes = {},
	ServerFolders = { "Server" },
	ClientFolders = { "Client" },
	ParallelSuffixes = { "Parallel" },
}
local DEFAULT_SLOW = 0.25
local DEFAULT_YIELD = 10
local ACTOR_FOLDER = "LoaderActors"
local IS_SERVER = RunService:IsServer()
local HERE: Realm = if IS_SERVER then "Server" else "Client"

local started = false
local finished = false
local entries: { Entry } = {}
local byName: { [string]: any } = {}
local startedEvent = Instance.new("BindableEvent")

if IS_SERVER then
	script:SetAttribute("ServerLoaded", nil)
	script:SetAttribute("ServerLoadedAt", nil)
end

local function list(value: { string }?): { string }
	return value or {}
end

local function startsWithAny(name: string, prefixes: { string }): boolean
	for _, prefix in prefixes do
		if prefix ~= "" and string.sub(name, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function endsWithAny(name: string, suffixes: { string }): boolean
	for _, suffix in suffixes do
		if suffix ~= "" and #name > #suffix and string.sub(name, -#suffix) == suffix then
			return true
		end
	end
	return false
end

local function flag(instance: Instance, name: string): boolean?
	local value = instance:GetAttribute(name)
	if type(value) == "boolean" then
		return value
	end
	if CollectionService:HasTag(instance, name) then
		return true
	end
	return nil
end

local function nameRealm(instance: Instance, naming: Naming?): Realm?
	if not naming then
		return nil
	end
	local name = instance.Name
	if instance:IsA("ModuleScript") then
		if endsWithAny(name, list(naming.ServerSuffixes)) or startsWithAny(name, list(naming.ServerPrefixes)) then
			return "Server"
		end
		if endsWithAny(name, list(naming.ClientSuffixes)) or startsWithAny(name, list(naming.ClientPrefixes)) then
			return "Client"
		end
		return nil
	end
	if table.find(list(naming.ServerFolders), name) then
		return "Server"
	end
	if table.find(list(naming.ClientFolders), name) then
		return "Client"
	end
	return nil
end

local function chain(module: ModuleScript, container: Instance): { Instance }
	local instances: { Instance } = {}
	local current: Instance? = module
	while current do
		table.insert(instances, current)
		if current == container then
			break
		end
		current = current.Parent
	end
	return instances
end

local function realmOf(module: ModuleScript, container: Instance, naming: Naming?): Realm
	local instances = chain(module, container)
	for _, instance in instances do
		local ignore = flag(instance, "IgnoreLoader")
		if ignore ~= nil then
			if ignore then
				return "Ignore"
			end
			break
		end
	end
	for _, instance in instances do
		local serverOnly = flag(instance, "ServerOnly")
		local clientOnly = flag(instance, "ClientOnly")
		if serverOnly == true then
			return "Server"
		elseif clientOnly == true then
			return "Client"
		elseif serverOnly == false or clientOnly == false then
			return "Shared"
		end
		local byName_ = nameRealm(instance, naming)
		if byName_ then
			return byName_
		end
	end
	return "Shared"
end

local function parallelOf(module: ModuleScript, container: Instance, naming: Naming?): boolean
	for _, instance in chain(module, container) do
		local value = flag(instance, "Parallel")
		if value ~= nil then
			return value
		end
	end
	return naming ~= nil and endsWithAny(module.Name, list(naming.ParallelSuffixes))
end

local function attributePriority(module: ModuleScript, container: Instance): number?
	for _, instance in chain(module, container) do
		local value = instance:GetAttribute("LoaderPriority")
		if type(value) == "number" then
			return value
		end
	end
	return nil
end

local function pathOf(module: Instance, container: Instance): string
	local parts = {}
	local current: Instance? = module
	while current and current ~= container do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end
	table.insert(parts, 1, container.Name)
	return table.concat(parts, ".")
end

local function depthIn(module: Instance, container: Instance): number?
	local depth = 1
	local current = module.Parent
	while current and current ~= container do
		if not current:IsA("Folder") then
			return nil
		end
		depth += 1
		current = current.Parent
	end
	return if current == container then depth else nil
end

local function collect(containers: { Instance }, options: Options, naming: Naming?): { Entry }
	local found: { Entry } = {}
	local seen: { [ModuleScript]: boolean } = {}
	local maxDepth = options.SearchDepth or math.huge
	local filter = options.Filter

	local function add(module: ModuleScript, container: Instance)
		if seen[module] then
			return
		end
		seen[module] = true
		local custom = if filter then filter(module) else nil
		if custom == false then
			return
		end
		if custom ~= true then
			local realm = realmOf(module, container, naming)
			if realm == "Ignore" or (realm ~= "Shared" and realm ~= HERE) then
				return
			end
		end
		local parallel = parallelOf(module, container, naming)
		table.insert(found, {
			Module = module,
			Name = module.Name,
			Path = pathOf(module, container),
			Priority = attributePriority(module, container) or 0,
			Parallel = parallel,
			Value = nil,
			RequireTime = 0,
			InitTime = 0,
			Failed = nil,
			Actor = nil,
		})
	end

	local function scan(container: Instance)
		if container:IsA("ModuleScript") then
			add(container, container)
			return
		end
		for _, descendant in container:GetDescendants() do
			if descendant:IsA("ModuleScript") then
				local depth = depthIn(descendant, container)
				if depth and depth <= maxDepth then
					add(descendant, container)
				end
			end
		end
	end

	for _, container in containers do
		scan(container)
	end
	local tag = options.Tag
	if tag and tag ~= "" then
		for _, tagged in CollectionService:GetTagged(tag) do
			if tagged:IsA("ModuleScript") or tagged:IsA("Folder") then
				scan(tagged)
			end
		end
	end
	return found
end

local function watch(label: string, seconds: number): () -> ()
	local done = false
	task.delay(seconds, function()
		if not done then
			warn(`[Loader] {label} is still running after {seconds} s (yielding?)`)
		end
	end)
	return function()
		done = true
	end
end

local function actorParent(): Instance
	local root: Instance
	if IS_SERVER then
		root = ServerScriptService
	else
		root = (Players.LocalPlayer :: Player):WaitForChild("PlayerScripts")
	end
	local folder = root:FindFirstChild(ACTOR_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = ACTOR_FOLDER
		folder.Parent = root
	end
	return folder :: Instance
end

local actorResults: { [Entry]: Results } = {}

local function waitFor(entry: Entry, phase: string, yieldWarning: number): (boolean, string?)
	local results = actorResults[entry]
	local stopWatch = watch(`{entry.Path} ({phase}, parallel)`, yieldWarning)
	while not results[phase] do
		task.wait()
	end
	stopWatch()
	local result = results[phase]
	return result.Ok, result.Problem
end

local function spawnActor(entry: Entry, yieldWarning: number)
	local actor = Instance.new("Actor")
	actor.Name = entry.Name
	local target = Instance.new("ObjectValue")
	target.Name = "Target"
	target.Value = entry.Module
	target.Parent = actor
	local report = Instance.new("BindableEvent")
	report.Name = "Report"
	report.Parent = actor
	local results: Results = {}
	actorResults[entry] = results
	report.Event:Connect(function(phase: string, ok: boolean, problem: string?)
		results[phase] = { Ok = ok, Problem = problem }
	end)
	local runner = (if IS_SERVER then script.ServerRunner else script.ClientRunner):Clone()
	local runnerModule = Instance.new("ObjectValue")
	runnerModule.Name = "Runner"
	runnerModule.Value = script.ActorRunner
	runnerModule.Parent = runner
	runner.Parent = actor
	actor.Parent = actorParent()
	entry.Actor = actor
	local ok, problem = waitFor(entry, "Loaded", yieldWarning)
	if not ok then
		entry.Failed = `require: {problem}`
		warn(`[Loader] require({entry.Path}) failed in its Actor\n{problem}`)
	end
end

local function requireEntry(entry: Entry, yieldWarning: number)
	local at = os.clock()
	if entry.Parallel then
		spawnActor(entry, yieldWarning)
	else
		local stopWatch = watch(`require({entry.Path})`, yieldWarning)
		local ok, value = xpcall(require, debug.traceback, entry.Module)
		stopWatch()
		if ok then
			entry.Value = value
			if type(value) == "table" then
				local own = value.LoaderPriority or value.Priority
				if type(own) == "number" and entry.Priority == 0 then
					entry.Priority = own
				end
			end
			if byName[entry.Name] == nil then
				byName[entry.Name] = value
			end
		else
			entry.Failed = `require: {value}`
			warn(`[Loader] require({entry.Path}) failed\n{value}`)
		end
	end
	entry.RequireTime = os.clock() - at
end

local function callMethod(entry: Entry, method: string, yieldWarning: number): boolean
	if entry.Parallel then
		local actor = entry.Actor :: Actor
		actor:SendMessage(method)
		if method == "Start" then
			return true
		end
		local ok, problem = waitFor(entry, method, yieldWarning)
		if not ok then
			entry.Failed = `{method}: {problem}`
			warn(`[Loader] {entry.Path}:{method}() failed in its Actor\n{problem}`)
		end
		return ok
	end
	local value = entry.Value
	local fn = type(value) == "table" and value[method]
	if type(fn) ~= "function" then
		return true
	end
	local stopWatch = if method == "Init" then watch(`{entry.Path}:Init()`, yieldWarning) else nil
	local ok, problem = xpcall(fn, debug.traceback, value)
	if stopWatch then
		stopWatch()
	end
	if not ok then
		entry.Failed = `{method}: {problem}`
		warn(`[Loader] {entry.Path}:{method}() failed\n{problem}`)
	end
	return ok
end

function Loader.Start(containers: { Instance }, options: Options?)
	if started then
		error("[Loader] Start was already called (put every container into one call)", 2)
	end
	started = true
	local settings: Options = options or {}
	local naming: Naming? = if settings.Naming == false then nil else (settings.Naming :: Naming?) or DEFAULT_NAMING
	if naming and settings.Naming then
		for key, value in DEFAULT_NAMING do
			if (naming :: any)[key] == nil then
				(naming :: any)[key] = value
			end
		end
	end
	local verbose = settings.Verbose == true
	local slow = settings.SlowWarning or DEFAULT_SLOW
	local yieldWarning = settings.YieldWarning or DEFAULT_YIELD

	if not IS_SERVER and settings.ClientWaitForServer then
		while script:GetAttribute("ServerLoaded") ~= true do
			script:GetAttributeChangedSignal("ServerLoaded"):Wait()
		end
	end

	local beganAt = os.clock()
	entries = collect(containers, settings, naming)

	for _, entry in entries do
		requireEntry(entry, yieldWarning)
	end

	table.sort(entries, function(a, b)
		if a.Priority ~= b.Priority then
			return a.Priority > b.Priority
		end
		return a.Path < b.Path
	end)

	local initialized: { [any]: boolean } = {}
	local runnable: { Entry } = {}
	for _, entry in entries do
		if entry.Failed then
			continue
		end
		local value = entry.Value
		if not entry.Parallel and type(value) == "table" then
			if initialized[value] then
				continue
			end
			initialized[value] = true
		end
		local at = os.clock()
		local ok = callMethod(entry, "Init", yieldWarning)
		entry.InitTime = os.clock() - at
		if entry.InitTime > slow then
			warn(`[Loader] {entry.Path}:Init() took {math.round(entry.InitTime * 1000)} ms`)
		end
		if ok then
			table.insert(runnable, entry)
		end
	end

	for _, entry in runnable do
		task.spawn(callMethod, entry, "Start", yieldWarning)
	end

	if verbose then
		local lines = { `[Loader] {#entries} modules ({HERE}) in {math.round((os.clock() - beganAt) * 1000)} ms:` }
		for _, entry in entries do
			local timing = math.round((entry.RequireTime + entry.InitTime) * 10000) / 10
			local marks = if entry.Parallel then "  [parallel]" else ""
			table.insert(lines, `  {if entry.Failed then "FAILED" else "ok"}  {entry.Path}  (priority {entry.Priority}, {timing} ms){marks}`)
		end
		print(table.concat(lines, "\n"))
	end

	if IS_SERVER then
		script:SetAttribute("ServerLoadedAt", os.time())
		script:SetAttribute("ServerLoaded", true)
	end
	finished = true
	startedEvent:Fire()
end

function Loader.IsStarted(): boolean
	return finished
end

function Loader.OnStarted(callback: () -> ())
	if finished then
		task.spawn(callback)
	else
		startedEvent.Event:Once(callback)
	end
end

function Loader.IsServerLoaded(): boolean
	return script:GetAttribute("ServerLoaded") == true
end

function Loader.Get(name: string): any
	return byName[name]
end

function Loader.Entries(): { Entry }
	return table.clone(entries)
end

return Loader