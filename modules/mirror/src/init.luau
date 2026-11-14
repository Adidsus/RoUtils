--!strict
--https://github.com/Adidsus/RoUtils
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

local CREATE, SET, INSERT, REMOVE, DESTROY = 0, 1, 2, 3, 4

export type Path = string | number | { any }

export type Options = {
	To: ("All" | { Player } | (player: Player) -> boolean)?,
}

export type Mirror = {
	Name: string,
	Changed: any,
	Destroyed: any,
	Get: (self: Mirror, path: Path?) -> any,
	Observe: (self: Mirror, path: Path?, callback: (value: any) -> ()) -> () -> (),
	OnChange: (self: Mirror, path: Path?, callback: (value: any) -> ()) -> () -> (),
	IsDestroyed: (self: Mirror) -> boolean,
	Set: (self: Mirror, path: Path?, value: any) -> (),
	Update: (self: Mirror, path: Path, updater: (value: any) -> any) -> any,
	Increment: (self: Mirror, path: Path, by: number?) -> number,
	Patch: (self: Mirror, path: Path?, values: { [any]: any }) -> (),
	Insert: (self: Mirror, path: Path, value: any, index: number?) -> (),
	Remove: (self: Mirror, path: Path, index: number?) -> any,
	AddViewer: (self: Mirror, player: Player) -> (),
	RemoveViewer: (self: Mirror, player: Player) -> (),
	SetTo: (self: Mirror, to: "All" | { Player } | (player: Player) -> boolean) -> (),
	CanSee: (self: Mirror, player: Player) -> boolean,
	Viewers: (self: Mirror) -> { Player },
	Destroy: (self: Mirror) -> (),
}

local function newEvent(): any
	local event = { _callbacks = {} }
	function event.Connect(self: any, callback: (...any) -> ()): any
		local connection: any = { Connected = true }
		function connection.Disconnect(conn: any)
			if conn.Connected then
				conn.Connected = false
				local index = table.find(self._callbacks, callback)
				if index then
					table.remove(self._callbacks, index)
				end
			end
		end
		table.insert(self._callbacks, callback)
		return connection
	end
	function event.Once(self: any, callback: (...any) -> ()): any
		local connection
		connection = self:Connect(function(...)
			connection:Disconnect()
			callback(...)
		end)
		return connection
	end
	function event.Wait(self: any): ...any
		local thread = coroutine.running()
		self:Once(function(...)
			task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end
	function event.Fire(self: any, ...: any)
		for _, callback in table.clone(self._callbacks) do
			task.spawn(callback, ...)
		end
	end
	function event.DisconnectAll(self: any)
		table.clear(self._callbacks)
	end
	return event
end

local function pack(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local count, strings, list = 0, true, true
	for key in value do
		count += 1
		if type(key) ~= "string" then
			strings = false
		end
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			list = false
		end
	end
	if list and count == #value then
		local out = table.create(count)
		for i = 1, count do
			out[i] = pack(value[i])
		end
		return { a = out }
	elseif strings then
		local out = {}
		for key, child in value do
			out[key] = pack(child)
		end
		return { d = out }
	end
	local keys, values = table.create(count), table.create(count)
	for key, child in value do
		table.insert(keys, pack(key))
		table.insert(values, pack(child))
	end
	return { k = keys, v = values }
end

local function unpack(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	if value.a then
		for i, child in value.a do
			out[i] = unpack(child)
		end
	elseif value.d then
		for key, child in value.d do
			out[key] = unpack(child)
		end
	elseif value.k then
		for i, key in value.k do
			out[unpack(key)] = unpack(value.v[i])
		end
	end
	return out
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[deepCopy(key)] = deepCopy(child)
	end
	return out
end

local function toPath(path: Path?): { any }
	if path == nil then
		return {}
	elseif type(path) == "table" then
		return table.clone(path)
	end
	return { path }
end

local function isPrefix(prefix: { any }, path: { any }): boolean
	if #prefix > #path then
		return false
	end
	for i, key in prefix do
		if path[i] ~= key then
			return false
		end
	end
	return true
end

local function describe(path: { any }): string
	local parts = table.create(#path)
	for i, key in path do
		parts[i] = tostring(key)
	end
	return if #parts == 0 then "(root)" else table.concat(parts, ".")
end

local Class = {}
Class.__index = Class

local function newMirror(name: string, data: { [any]: any }): any
	return setmetatable({
		Name = name,
		Changed = newEvent(),
		Destroyed = newEvent(),
		_data = data,
		_listeners = {},
		_nextListener = 0,
		_destroyed = false,
	}, Class)
end

local function walk(data: any, path: { any }, length: number, create: boolean): any
	local node = data
	for i = 1, length do
		local child = node[path[i]]
		if child == nil and create then
			child = {}
			node[path[i]] = child
		end
		if type(child) ~= "table" then
			return if i == length then child else nil
		end
		node = child
	end
	return node
end

function Class.Get(self: any, path: Path?): any
	local keys = toPath(path)
	local node = self._data
	for _, key in keys do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return node
end

local function notify(self: any, changed: { any }, old: any)
	for _, listener in self._listeners do
		if isPrefix(listener.Path, changed) or isPrefix(changed, listener.Path) then
			task.spawn(listener.Callback, Class.Get(self, listener.Path))
		end
	end
	self.Changed:Fire(changed, Class.Get(self, changed), old)
end

local function apply(self: any, op: number, path: { any }, value: any): any
	local depth = #path
	if op == SET then
		if depth == 0 then
			local old = self._data
			self._data = if type(value) == "table" then value else {}
			notify(self, path, old)
			return old
		end
		local parent = walk(self._data, path, depth - 1, true)
		local old = parent[path[depth]]
		parent[path[depth]] = value
		notify(self, path, old)
		return old
	end
	local listPath = table.move(path, 1, depth - 1, 1, {})
	local list = walk(self._data, listPath, depth - 1, op == INSERT)
	if type(list) ~= "table" then
		return nil
	end
	local index = path[depth]
	local result
	if op == INSERT then
		table.insert(list, math.clamp(index, 1, #list + 1), value)
	else
		result = table.remove(list, index)
	end
	notify(self, listPath, nil)
	return result
end

function Class.OnChange(self: any, path: Path?, callback: (value: any) -> ()): () -> ()
	self._nextListener += 1
	local id = self._nextListener
	self._listeners[id] = { Path = toPath(path), Callback = callback }
	return function()
		self._listeners[id] = nil
	end
end

function Class.Observe(self: any, path: Path?, callback: (value: any) -> ()): () -> ()
	task.spawn(callback, Class.Get(self, path))
	return Class.OnChange(self, path, callback)
end

function Class.IsDestroyed(self: any): boolean
	return self._destroyed
end

local function markDestroyed(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	table.clear(self._listeners)
	self.Destroyed:Fire()
	self.Changed:DisconnectAll()
	self.Destroyed:DisconnectAll()
end

local MirrorModule = {}

if IS_SERVER then
	local mirrors: { [string]: any } = {}
	local ready: { [Player]: boolean } = {}
	local queues: { [Player]: { any } } = {}

	local remote = Instance.new("RemoteEvent")
	remote.Name = "Remote"
	remote.Parent = script

	local function push(player: Player, op: number, name: string, a: any, b: any)
		local queue = queues[player]
		if not queue then
			queue = {}
			queues[player] = queue
		end
		table.insert(queue, { op, name, a, b })
	end

	function MirrorModule.flush()
		for player, queue in queues do
			if player.Parent then
				remote:FireClient(player, queue)
			end
		end
		table.clear(queues)
	end

	RunService.Heartbeat:Connect(MirrorModule.flush)

	local function viewerList(self: any): { Player }
		local list = self._viewerList
		if not list then
			list = {}
			for player in self._viewers do
				table.insert(list, player)
			end
			self._viewerList = list
		end
		return list
	end

	local function send(self: any, op: number, path: { any }, value: any)
		local list = viewerList(self)
		if #list > 0 then
			local packedPath, packedValue = pack(path), pack(value)
			for _, player in list do
				push(player, op, self.Name, packedPath, packedValue)
			end
		end
	end

	local function canSee(self: any, player: Player): boolean
		local to = self._to
		if to == "All" then
			return true
		elseif type(to) == "table" then
			return table.find(to, player) ~= nil
		end
		local ok, result = pcall(to, player)
		if not ok then
			warn(`Mirror "{self.Name}": To failed for {player.Name}: {result}`)
		end
		return ok and result == true
	end

	local function show(self: any, player: Player)
		if self._viewers[player] or not ready[player] then
			return
		end
		self._viewers[player] = true
		self._viewerList = nil
		push(player, CREATE, self.Name, pack(self._data), nil)
	end

	local function hide(self: any, player: Player)
		if not self._viewers[player] then
			return
		end
		self._viewers[player] = nil
		self._viewerList = nil
		push(player, DESTROY, self.Name, nil, nil)
	end

	local function refresh(self: any, player: Player)
		if canSee(self, player) then
			show(self, player)
		else
			hide(self, player)
		end
	end

	function MirrorModule.new(name: string, data: { [any]: any }?, options: Options?): Mirror
		assert(type(name) == "string" and name ~= "", "Mirror.new: needs a name")
		assert(not mirrors[name], `Mirror "{name}" exists already - Destroy it first`)
		assert(data == nil or type(data) == "table", "Mirror.new: data must be a table")
		local to = options and options.To or "All"
		assert(
			to == "All" or type(to) == "table" or type(to) == "function",
			`Mirror "{name}": To must be "All", a list of players or a function`
		)
		local self = newMirror(name, deepCopy(data or {}))
		self._to = to
		self._viewers = {}
		mirrors[name] = self
		for player in ready do
			refresh(self, player)
		end
		return self
	end

	function MirrorModule.get(name: string): Mirror?
		return mirrors[name]
	end

	local function guard(self: any)
		assert(not self._destroyed, `Mirror "{self.Name}" is destroyed`)
	end

	function Class.Set(self: any, path: Path?, value: any)
		guard(self)
		local keys = toPath(path)
		if #keys == 0 then
			assert(type(value) == "table", `Mirror "{self.Name}": the root must be a table`)
		end
		if type(value) ~= "table" and Class.Get(self, keys) == value then
			return
		end
		local copy = deepCopy(value)
		apply(self, SET, keys, copy)
		send(self, SET, keys, copy)
	end

	function Class.Update(self: any, path: Path, updater: (value: any) -> any): any
		local value = updater(Class.Get(self, path))
		Class.Set(self, path, value)
		return value
	end

	function Class.Increment(self: any, path: Path, by: number?): number
		local current = Class.Get(self, path)
		assert(
			current == nil or type(current) == "number",
			`Mirror "{self.Name}": {describe(toPath(path))} is not a number`
		)
		local value = (current or 0) + (by or 1)
		Class.Set(self, path, value)
		return value
	end

	function Class.Patch(self: any, path: Path?, values: { [any]: any })
		local base = toPath(path)
		for key, value in values do
			local keys = table.clone(base)
			table.insert(keys, key)
			Class.Set(self, keys, value)
		end
	end

	function Class.Insert(self: any, path: Path, value: any, index: number?)
		guard(self)
		local keys = toPath(path)
		local list = Class.Get(self, keys)
		assert(list == nil or type(list) == "table", `Mirror "{self.Name}": {describe(keys)} is not a list`)
		local position = index or #(list or {}) + 1
		assert(
			position >= 1 and position <= #(list or {}) + 1,
			`Mirror "{self.Name}": index {position} is out of range`
		)
		table.insert(keys, position)
		local copy = deepCopy(value)
		apply(self, INSERT, keys, copy)
		send(self, INSERT, keys, copy)
	end

	function Class.Remove(self: any, path: Path, index: number?): any
		guard(self)
		local keys = toPath(path)
		local list = Class.Get(self, keys)
		if type(list) ~= "table" or #list == 0 then
			return nil
		end
		local position = index or #list
		if position < 1 or position > #list then
			return nil
		end
		table.insert(keys, position)
		local removed = apply(self, REMOVE, keys, nil)
		send(self, REMOVE, keys, nil)
		return removed
	end

	function Class.AddViewer(self: any, player: Player)
		guard(self)
		if self._to == "All" then
			return
		end
		if type(self._to) ~= "table" then
			self._to = {}
		end
		if not table.find(self._to, player) then
			table.insert(self._to, player)
		end
		show(self, player)
	end

	function Class.RemoveViewer(self: any, player: Player)
		guard(self)
		if type(self._to) ~= "table" then
			self._to = {}
			for viewer in self._viewers do
				table.insert(self._to, viewer)
			end
		end
		local index = table.find(self._to, player)
		if index then
			table.remove(self._to, index)
		end
		hide(self, player)
	end

	function Class.SetTo(self: any, to: any)
		guard(self)
		self._to = to
		for player in ready do
			refresh(self, player)
		end
	end

	function Class.CanSee(self: any, player: Player): boolean
		return self._viewers[player] == true
	end

	function Class.Viewers(self: any): { Player }
		return table.clone(viewerList(self))
	end

	function Class.Destroy(self: any)
		if self._destroyed then
			return
		end
		send(self, DESTROY, {}, nil)
		mirrors[self.Name] = nil
		markDestroyed(self)
	end

	function MirrorModule.refresh(player: Player?)
		for _, mirror in mirrors do
			if player then
				refresh(mirror, player)
			else
				for viewer in ready do
					refresh(mirror, viewer)
				end
			end
		end
	end

	remote.OnServerEvent:Connect(function(player: Player)
		if ready[player] then
			return
		end
		ready[player] = true
		for _, mirror in mirrors do
			refresh(mirror, player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		ready[player] = nil
		queues[player] = nil
		for _, mirror in mirrors do
			if mirror._viewers[player] then
				mirror._viewers[player] = nil
				mirror._viewerList = nil
			end
			if type(mirror._to) == "table" then
				local index = table.find(mirror._to, player)
				if index then
					table.remove(mirror._to, index)
				end
			end
		end
	end)
else
	local mirrors: { [string]: any } = {}
	local created = newEvent()

	local function readOnly(self: any)
		error(`Mirror "{self.Name}": only the server can change it`, 3)
	end

	function Class.Set(self: any)
		readOnly(self)
	end
	Class.Update = Class.Set :: any
	Class.Increment = Class.Set :: any
	Class.Patch = Class.Set :: any
	Class.Insert = Class.Set :: any
	Class.Remove = Class.Set :: any
	Class.AddViewer = Class.Set :: any
	Class.RemoveViewer = Class.Set :: any
	Class.SetTo = Class.Set :: any
	Class.Destroy = Class.Set :: any

	function MirrorModule.get(name: string): Mirror?
		return mirrors[name]
	end

	function MirrorModule.wait(name: string, timeout: number?): Mirror?
		local mirror = mirrors[name]
		if mirror then
			return mirror
		end
		local thread = coroutine.running()
		local done = false
		local warnAt = task.delay(5, function()
			if not done and not timeout then
				warn(`Mirror: still waiting for "{name}" - is it created on the server and visible to this player?`)
			end
		end)
		local disconnect
		disconnect = created:Connect(function(new)
			if new.Name == name and not done then
				done = true
				disconnect:Disconnect()
				task.spawn(thread, new)
			end
		end)
		if timeout then
			task.delay(timeout, function()
				if not done then
					done = true
					disconnect:Disconnect()
					task.spawn(thread, nil)
				end
			end)
		end
		local result = coroutine.yield()
		task.cancel(warnAt)
		return result
	end

	function MirrorModule.onCreated(callback: (mirror: Mirror) -> ()): () -> ()
		for _, mirror in mirrors do
			task.spawn(callback, mirror)
		end
		local connection = created:Connect(callback)
		return function()
			connection:Disconnect()
		end
	end

	local function receive(op: number, name: string, a: any, b: any)
		local mirror = mirrors[name]
		if op == CREATE then
			local data = unpack(a)
			if mirror then
				apply(mirror, SET, {}, data)
			else
				mirror = newMirror(name, data)
				mirrors[name] = mirror
				created:Fire(mirror)
			end
		elseif op == DESTROY then
			if mirror then
				mirrors[name] = nil
				markDestroyed(mirror)
			end
		elseif mirror then
			apply(mirror, op, unpack(a), unpack(b))
		end
	end

	local remote = script:WaitForChild("Remote") :: RemoteEvent
	remote.OnClientEvent:Connect(function(batch: { any })
		for _, message in batch do
			receive(message[1], message[2], message[3], message[4])
		end
	end)
	remote:FireServer()
end

return MirrorModule