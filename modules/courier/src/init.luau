--!strict
--https://github.com/Adidsus/RoUtils

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local IS_STUDIO = RunService:IsStudio()
local UNRELIABLE_SIZE = 800
local QUEUE_SIZE = 256
local MAX_PACKETS = 16383
local DEFAULT_TIMEOUT = 15
local LOG_KEYS = { Log = true }

export type Type = {
	Name: string,
	Spec: any?,
	Write: (value: any) -> (),
	Read: () -> any,
}

export type Direction = "ToClient" | "ToServer" | "Both"

export type Options = {
	Unreliable: boolean?,
	Limit: (number | false)?,
	Timeout: number?,
	Direction: Direction?,
}

export type Settings = {
	DefaultLimit: (number | false)?,
	MaxBatch: number?,
	MaxRefs: number?,
	PlayerBudget: (number | false)?,
	KickAfter: (number | false)?,
}

export type Stats = {
	Name: string,
	Sent: number,
	SentBytes: number,
	Received: number,
	ReceivedBytes: number,
	Dropped: number,
}

type Stream = {
	Buffer: buffer,
	Size: number,
	Refs: { any },
	RefCount: number,
	Ready: { { any } },
}

local wbuf = buffer.create(1024)
local wpos = 0
local wrefs: { any } = {}
local wrefCount = 0

local rbuf = buffer.create(0)
local rpos = 0
local rrefs: { any } = {}
local rrefPos = 0
local strict = false

local function need(size: number)
	local length = buffer.len(wbuf)
	if wpos + size > length then
		repeat
			length *= 2
		until wpos + size <= length
		local grown = buffer.create(length)
		buffer.copy(grown, 0, wbuf, 0, wpos)
		wbuf = grown
	end
end

local function writeVarint(value: number)
	need(5)
	while value >= 128 do
		buffer.writeu8(wbuf, wpos, bit32.bor(bit32.band(value, 127), 128))
		wpos += 1
		value = bit32.rshift(value, 7)
	end
	buffer.writeu8(wbuf, wpos, value)
	wpos += 1
end

local function readVarint(): number
	local value = 0
	local scale = 1
	for _ = 1, 5 do
		local byte = buffer.readu8(rbuf, rpos)
		rpos += 1
		if byte < 128 then
			return value + byte * scale
		end
		value += (byte - 128) * scale
		scale *= 128
	end
	error("bad length", 0)
end

local function readFloat(value: number): number
	if strict and value ~= value then
		error("NaN", 0)
	end
	return value
end

local function writeRef(value: any)
	need(1)
	if value == nil then
		buffer.writeu8(wbuf, wpos, 0)
		wpos += 1
		return
	end
	buffer.writeu8(wbuf, wpos, 1)
	wpos += 1
	wrefCount += 1
	wrefs[wrefCount] = value
end

local function readRef(): any
	local flag = buffer.readu8(rbuf, rpos)
	rpos += 1
	if flag == 0 then
		return nil
	end
	rrefPos += 1
	return rrefs[rrefPos]
end

local function writeString(value: string, max: number?)
	local length = #value
	if max and length > max then
		error(`string longer than {max}`, 0)
	end
	writeVarint(length)
	need(length)
	buffer.writestring(wbuf, wpos, value)
	wpos += length
end

local function readString(max: number?): string
	local length = readVarint()
	if max and length > max then
		error("string too long", 0)
	end
	local value = buffer.readstring(rbuf, rpos, length)
	rpos += length
	return value
end

local Types = {}

local function numberType(
	name: string,
	size: number,
	write: (buffer, number, number) -> (),
	read: (buffer, number) -> number,
	float: boolean?
): Type
	return {
		Name = name,
		Write = function(value: number)
			need(size)
			write(wbuf, wpos, value)
			wpos += size
		end,
		Read = function(): number
			local value = read(rbuf, rpos)
			rpos += size
			if float then
				return readFloat(value)
			end
			return value
		end,
	}
end

Types.u8 = numberType("u8", 1, buffer.writeu8, buffer.readu8)
Types.u16 = numberType("u16", 2, buffer.writeu16, buffer.readu16)
Types.u32 = numberType("u32", 4, buffer.writeu32, buffer.readu32)
Types.i8 = numberType("i8", 1, buffer.writei8, buffer.readi8)
Types.i16 = numberType("i16", 2, buffer.writei16, buffer.readi16)
Types.i32 = numberType("i32", 4, buffer.writei32, buffer.readi32)
Types.f32 = numberType("f32", 4, buffer.writef32, buffer.readf32, true)
Types.f64 = numberType("f64", 8, buffer.writef64, buffer.readf64, true)
Types.number = Types.f64

Types.bool = {
	Name = "bool",
	Write = function(value: boolean)
		need(1)
		buffer.writeu8(wbuf, wpos, if value then 1 else 0)
		wpos += 1
	end,
	Read = function(): boolean
		local value = buffer.readu8(rbuf, rpos)
		rpos += 1
		return value ~= 0
	end,
} :: Type

Types.string = {
	Name = "string",
	Write = function(value: string)
		writeString(value)
	end,
	Read = function(): string
		return readString()
	end,
} :: Type

function Types.stringMax(max: number): Type
	return {
		Name = `string({max})`,
		Spec = { "stringMax", max },
		Write = function(value: string)
			writeString(value, max)
		end,
		Read = function(): string
			return readString(max)
		end,
	}
end

Types.buffer = {
	Name = "buffer",
	Write = function(value: buffer)
		local length = buffer.len(value)
		writeVarint(length)
		need(length)
		buffer.copy(wbuf, wpos, value, 0, length)
		wpos += length
	end,
	Read = function(): buffer
		local length = readVarint()
		local value = buffer.create(length)
		buffer.copy(value, 0, rbuf, rpos, length)
		rpos += length
		return value
	end,
} :: Type

Types.vector2 = {
	Name = "vector2",
	Write = function(value: Vector2)
		need(8)
		buffer.writef32(wbuf, wpos, value.X)
		buffer.writef32(wbuf, wpos + 4, value.Y)
		wpos += 8
	end,
	Read = function(): Vector2
		local x = readFloat(buffer.readf32(rbuf, rpos))
		local y = readFloat(buffer.readf32(rbuf, rpos + 4))
		rpos += 8
		return Vector2.new(x, y)
	end,
} :: Type

Types.vector3 = {
	Name = "vector3",
	Write = function(value: Vector3)
		need(12)
		buffer.writef32(wbuf, wpos, value.X)
		buffer.writef32(wbuf, wpos + 4, value.Y)
		buffer.writef32(wbuf, wpos + 8, value.Z)
		wpos += 12
	end,
	Read = function(): Vector3
		local x = readFloat(buffer.readf32(rbuf, rpos))
		local y = readFloat(buffer.readf32(rbuf, rpos + 4))
		local z = readFloat(buffer.readf32(rbuf, rpos + 8))
		rpos += 12
		return Vector3.new(x, y, z)
	end,
} :: Type

Types.cframe = {
	Name = "cframe",
	Write = function(value: CFrame)
		local axis, angle = value:ToAxisAngle()
		local rotation = axis * angle
		local position = value.Position
		need(24)
		buffer.writef32(wbuf, wpos, position.X)
		buffer.writef32(wbuf, wpos + 4, position.Y)
		buffer.writef32(wbuf, wpos + 8, position.Z)
		buffer.writef32(wbuf, wpos + 12, rotation.X)
		buffer.writef32(wbuf, wpos + 16, rotation.Y)
		buffer.writef32(wbuf, wpos + 20, rotation.Z)
		wpos += 24
	end,
	Read = function(): CFrame
		local position = Vector3.new(
			readFloat(buffer.readf32(rbuf, rpos)),
			readFloat(buffer.readf32(rbuf, rpos + 4)),
			readFloat(buffer.readf32(rbuf, rpos + 8))
		)
		local rotation = Vector3.new(
			readFloat(buffer.readf32(rbuf, rpos + 12)),
			readFloat(buffer.readf32(rbuf, rpos + 16)),
			readFloat(buffer.readf32(rbuf, rpos + 20))
		)
		rpos += 24
		local angle = rotation.Magnitude
		if angle < 1e-6 then
			return CFrame.new(position)
		end
		return CFrame.fromAxisAngle(rotation / angle, angle) + position
	end,
} :: Type

Types.color3 = {
	Name = "color3",
	Write = function(value: Color3)
		need(3)
		buffer.writeu8(wbuf, wpos, math.clamp(math.round(value.R * 255), 0, 255))
		buffer.writeu8(wbuf, wpos + 1, math.clamp(math.round(value.G * 255), 0, 255))
		buffer.writeu8(wbuf, wpos + 2, math.clamp(math.round(value.B * 255), 0, 255))
		wpos += 3
	end,
	Read = function(): Color3
		local value =
			Color3.fromRGB(buffer.readu8(rbuf, rpos), buffer.readu8(rbuf, rpos + 1), buffer.readu8(rbuf, rpos + 2))
		rpos += 3
		return value
	end,
} :: Type

Types.instance = {
	Name = "instance",
	Write = function(value: Instance?)
		writeRef(value)
	end,
	Read = function(): Instance?
		local value = readRef()
		if strict and value ~= nil and typeof(value) ~= "Instance" then
			error("expected an Instance", 0)
		end
		return value
	end,
} :: Type

Types.any = {
	Name = "any",
	Write = writeRef,
	Read = readRef,
} :: Type

function Types.optional(inner: Type): Type
	return {
		Name = `{inner.Name}?`,
		Spec = { "optional", inner.Spec },
		Write = function(value: any)
			need(1)
			if value == nil then
				buffer.writeu8(wbuf, wpos, 0)
				wpos += 1
				return
			end
			buffer.writeu8(wbuf, wpos, 1)
			wpos += 1
			inner.Write(value)
		end,
		Read = function(): any
			local flag = buffer.readu8(rbuf, rpos)
			rpos += 1
			if flag == 0 then
				return nil
			end
			return inner.Read()
		end,
	}
end

function Types.array(inner: Type, max: number?): Type
	return {
		Name = `{inner.Name}[{max or ""}]`,
		Spec = { "array", inner.Spec, max or false },
		Write = function(list: { any })
			local count = #list
			if max and count > max then
				error(`array longer than {max}`, 0)
			end
			writeVarint(count)
			for i = 1, count do
				inner.Write(list[i])
			end
		end,
		Read = function(): { any }
			local count = readVarint()
			if (max and count > max) or count > buffer.len(rbuf) - rpos then
				error("bad array length", 0)
			end
			local list = table.create(count)
			for i = 1, count do
				list[i] = inner.Read()
			end
			return list
		end,
	}
end

function Types.map(key: Type, value: Type, max: number?): Type
	return {
		Name = `map<{key.Name},{value.Name}>`,
		Spec = { "map", key.Spec, value.Spec, max or false },
		Write = function(map: { [any]: any })
			local count = 0
			for _ in map do
				count += 1
			end
			if max and count > max then
				error(`map larger than {max}`, 0)
			end
			writeVarint(count)
			for k, v in map do
				key.Write(k)
				value.Write(v)
			end
		end,
		Read = function(): { [any]: any }
			local count = readVarint()
			if (max and count > max) or count * 2 > buffer.len(rbuf) - rpos then
				error("bad map size", 0)
			end
			local map = {}
			for _ = 1, count do
				local k = key.Read()
				local v = value.Read()
				if k == nil then
					error("nil map key", 0)
				end
				map[k] = v
			end
			return map
		end,
	}
end

function Types.struct(fields: { [string]: Type }): Type
	local keys = {}
	for name in fields do
		table.insert(keys, name)
	end
	table.sort(keys)
	assert(#keys > 0, "Courier: a struct needs at least one field")
	local count = #keys
	local types = table.create(count)
	local names = table.create(count)
	local specs = {}
	for i, name in keys do
		types[i] = fields[name]
		names[i] = `{name}:{fields[name].Name}`
		specs[name] = fields[name].Spec
	end
	return {
		Name = `\{{table.concat(names, ",")}\}`,
		Spec = { "struct", specs },
		Write = function(value: { [string]: any })
			for i = 1, count do
				types[i].Write(value[keys[i]])
			end
		end,
		Read = function(): { [string]: any }
			local value = {}
			for i = 1, count do
				value[keys[i]] = types[i].Read()
			end
			return value
		end,
	}
end

function Types.enum(values: { any }): Type
	assert(#values > 0 and #values <= 256, "Courier: an enum needs 1 to 256 values")
	local index = {}
	local names = table.create(#values)
	local encoded = table.create(#values)
	for i, value in values do
		index[value] = i - 1
		names[i] = tostring(value)
		encoded[i] = if typeof(value) == "EnumItem" then { e = tostring(value) } else value
	end
	return {
		Name = `enum({table.concat(names, ",")})`,
		Spec = { "enum", encoded },
		Write = function(value: any)
			local i = index[value]
			if i == nil then
				error(`{tostring(value)} is not in the enum`, 0)
			end
			need(1)
			buffer.writeu8(wbuf, wpos, i)
			wpos += 1
		end,
		Read = function(): any
			local value = values[buffer.readu8(rbuf, rpos) + 1]
			rpos += 1
			if value == nil then
				error("bad enum value", 0)
			end
			return value
		end,
	}
end

Types.values = {
	Name = "values",
	Write = function(list: { any })
		local count = (list :: any).n or #list
		writeVarint(count)
		for i = 1, count do
			writeRef(list[i])
		end
	end,
	Read = function(): { any }
		local count = readVarint()
		if count > buffer.len(rbuf) - rpos then
			error("bad length", 0)
		end
		local list: any = table.create(count)
		for i = 1, count do
			list[i] = readRef()
		end
		list.n = count
		return list
	end,
} :: Type

for name, t in Types :: { [string]: any } do
	if type(t) == "table" and t.Spec == nil then
		t.Spec = name
	end
end

local function decodeEnumValue(value: any): any
	if type(value) == "table" and type(value.e) == "string" then
		local enumName, itemName = string.match(value.e, "^Enum%.(%w+)%.(%w+)$")
		return ((Enum :: any)[enumName :: string] :: any)[itemName :: string]
	end
	return value
end

function Types.fromSpec(spec: any): Type
	if type(spec) == "string" then
		local t = (Types :: any)[spec]
		assert(type(t) == "table" and t.Read, `Courier: unknown type "{spec}"`)
		return t
	end
	local kind = spec[1]
	if kind == "stringMax" then
		return Types.stringMax(spec[2])
	elseif kind == "optional" then
		return Types.optional(Types.fromSpec(spec[2]))
	elseif kind == "array" then
		return Types.array(Types.fromSpec(spec[2]), spec[3] or nil)
	elseif kind == "map" then
		return Types.map(Types.fromSpec(spec[2]), Types.fromSpec(spec[3]), spec[4] or nil)
	elseif kind == "struct" then
		local fields = {}
		for name, fieldSpec in spec[2] do
			fields[name] = Types.fromSpec(fieldSpec)
		end
		return Types.struct(fields)
	elseif kind == "enum" then
		local values = table.create(#spec[2])
		for i, value in spec[2] do
			values[i] = decodeEnumValue(value)
		end
		return Types.enum(values)
	end
	error(`Courier: unknown type spec {tostring(kind)}`)
end

local function signatureOf(types: { Type }): string
	local names = table.create(#types)
	for i, t in types do
		names[i] = t.Name
	end
	return table.concat(names, ",")
end

local function writeArgs(types: { Type }, index: number, ...: any)
	local t = types[index]
	if t then
		t.Write((...))
		writeArgs(types, index + 1, select(2, ...))
	end
end

local function begin(id: number)
	wpos = 0
	if wrefCount > 0 then
		table.clear(wrefs)
		wrefCount = 0
	end
	writeVarint(id)
end

local function newStream(): Stream
	return { Buffer = buffer.create(256), Size = 0, Refs = {}, RefCount = 0, Ready = {} }
end

local function cut(stream: Stream)
	local out = buffer.create(stream.Size)
	buffer.copy(out, 0, stream.Buffer, 0, stream.Size)
	table.insert(stream.Ready, { out, table.move(stream.Refs, 1, stream.RefCount, 1, {}), stream.RefCount })
	stream.Size = 0
	if stream.RefCount > 0 then
		table.clear(stream.Refs)
		stream.RefCount = 0
	end
end

local function append(stream: Stream, limit: number?)
	if limit and stream.Size > 0 and stream.Size + wpos > limit then
		cut(stream)
	end
	local length = buffer.len(stream.Buffer)
	if stream.Size + wpos > length then
		repeat
			length *= 2
		until stream.Size + wpos <= length
		local grown = buffer.create(length)
		buffer.copy(grown, 0, stream.Buffer, 0, stream.Size)
		stream.Buffer = grown
	end
	buffer.copy(stream.Buffer, stream.Size, wbuf, 0, wpos)
	stream.Size += wpos
	for i = 1, wrefCount do
		stream.RefCount += 1
		stream.Refs[stream.RefCount] = wrefs[i]
	end
end

local reliable: RemoteEvent
local unreliable: UnreliableRemoteEvent
if IS_SERVER then
	reliable = Instance.new("RemoteEvent")
	reliable.Name = "Reliable"
	reliable.Parent = script
	unreliable = Instance.new("UnreliableRemoteEvent")
	unreliable.Name = "Unreliable"
	unreliable.Parent = script
else
	reliable = script:WaitForChild("Reliable") :: RemoteEvent
	unreliable = script:WaitForChild("Unreliable") :: UnreliableRemoteEvent
end

local function drain(stream: Stream, remote: any, player: Player?)
	if stream.Size > 0 then
		cut(stream)
	end
	if #stream.Ready == 0 then
		return
	end
	for _, chunk in stream.Ready do
		if player then
			remote:FireClient(player, chunk[1], table.unpack(chunk[2], 1, chunk[3]))
		else
			remote:FireServer(chunk[1], table.unpack(chunk[2], 1, chunk[3]))
		end
	end
	table.clear(stream.Ready)
end

local freeThread: thread? = nil

local function runHandler(handler: (...any) -> (), ...: any)
	local thread = freeThread
	freeThread = nil
	handler(...)
	freeThread = thread
end

local function runLoop()
	while true do
		runHandler(coroutine.yield())
	end
end

local function call(handler: (...any) -> (), ...: any)
	if not freeThread then
		freeThread = coroutine.create(runLoop)
		coroutine.resume(freeThread :: thread)
	end
	task.spawn(freeThread :: thread, handler, ...)
end

local suspiciousHandlers: { (player: Player, packet: string, reason: string) -> () } = {}
local suspiciousAt: { [Player]: { [string]: number } } = {}

local function suspicious(player: Player, packet: string, reason: string, throttle: boolean?)
	if throttle then
		local byPlayer = suspiciousAt[player]
		if not byPlayer then
			byPlayer = {}
			suspiciousAt[player] = byPlayer
			player.AncestryChanged:Connect(function(_, parent)
				if parent == nil then
					suspiciousAt[player] = nil
				end
			end)
		end
		local key = packet .. reason
		local now = os.clock()
		if byPlayer[key] and now - byPlayer[key] < 1 then
			return
		end
		byPlayer[key] = now
	end
	for _, handler in table.clone(suspiciousHandlers) do
		task.spawn(handler, player, packet, reason)
	end
end

local function suspiciousEvent(): any
	return {
		Connect = function(_, handler: (player: Player, packet: string, reason: string) -> ()): any
			table.insert(suspiciousHandlers, handler)
			local connection = { Connected = true }
			function connection.Disconnect()
				connection.Connected = false
				local index = table.find(suspiciousHandlers, handler)
				if index then
					table.remove(suspiciousHandlers, index)
				end
			end
			return connection
		end,
	}
end

local Courier = {}
Courier.Types = Types
Courier.Name = "Courier"
Courier.Suspicious = suspiciousEvent()

local Packet = {}
Packet.__index = Packet

local byName: { [string]: any } = {}
local byId: { [number]: any } = {}
local nextId = 0
local streams: { [Player]: { Stream } } = {}
local own = { newStream(), newStream() }
local calls: { [number]: thread } = {}
local nextCall = 0
local args: { any } = {}
local settings = {
	DefaultLimit = 60 :: number | false,
	MaxBatch = 8192,
	MaxRefs = 64,
	PlayerBudget = 65536 :: number | false,
	KickAfter = false :: number | false,
}

local function push(packet: any, pair: { Stream })
	if packet.Unreliable then
		if wpos > UNRELIABLE_SIZE and not packet.Warned then
			packet.Warned = true
			warn(
				`Courier: "{packet.Name}" sent {wpos} bytes - unreliable messages over {UNRELIABLE_SIZE} bytes are dropped by Roblox`
			)
		end
		append(pair[2], UNRELIABLE_SIZE)
	else
		append(pair[1])
	end
	packet.Stats.Sent += 1
	packet.Stats.SentBytes += wpos
end

local function allow(packet: any, player: Player): boolean
	local limit = packet.Limit
	if limit == nil then
		limit = settings.DefaultLimit
	end
	if not limit then
		return true
	end
	local now = os.clock()
	local bucket = packet.Buckets[player]
	if not bucket then
		bucket = { limit, now }
		packet.Buckets[player] = bucket
	end
	local tokens = math.min(limit, bucket[1] + (now - bucket[2]) * limit)
	bucket[2] = now
	if tokens < 1 then
		bucket[1] = tokens
		return false
	end
	bucket[1] = tokens - 1
	return true
end

local function deliver(packet: any, sender: Player?, count: number)
	local connections = packet.Connections
	if #connections == 0 then
		local queue = packet.Queue
		if #queue >= QUEUE_SIZE then
			table.remove(queue, 1)
			if not packet.QueueWarned then
				packet.QueueWarned = true
				warn(`Courier: "{packet.Name}" has no Connect - only the last {QUEUE_SIZE} messages are kept`)
			end
		end
		table.insert(queue, { sender, table.move(args, 1, count, 1, {}), count })
		return
	end
	for _, handler in connections do
		if sender then
			call(handler, sender, table.unpack(args, 1, count))
		else
			call(handler, table.unpack(args, 1, count))
		end
	end
end

local function respond(packet: any, player: Player, callId: number, ok: boolean, ...: any)
	local pair = streams[player]
	if not pair then
		return
	end
	local problem = if ok then nil else tostring((...))
	if ok then
		local values = table.pack(...)
		local written, writeError = pcall(function()
			begin(packet.Id)
			Types.u16.Write(callId)
			Types.bool.Write(true)
			writeArgs(packet.Returns, 1, table.unpack(values, 1, values.n))
		end)
		if not written then
			problem = `returned values don't match the types: {writeError}`
			warn(`Courier: request "{packet.Name}" {problem}`)
		end
	end
	if problem then
		begin(packet.Id)
		Types.u16.Write(callId)
		Types.bool.Write(false)
		Types.string.Write(if IS_STUDIO or problem == "rate limited" then problem else "request failed")
	end
	push(packet, pair)
end

local function answer(packet: any, player: Player, callId: number, values: { any }, count: number)
	local results = table.pack(pcall(packet.Handler, player, table.unpack(values, 1, count)))
	if not results[1] then
		warn(`Courier: request "{packet.Name}" failed: {results[2]}`)
		respond(packet, player, callId, false, results[2])
		return
	end
	respond(packet, player, callId, true, table.unpack(results, 2, results.n))
end

local function readEvent(packet: any, sender: Player?)
	local types = packet.Types
	local count = #types
	for i = 1, count do
		args[i] = types[i].Read()
	end
	if sender and not allow(packet, sender) then
		packet.Stats.Dropped += 1
		suspicious(sender, packet.Name, "rate limited", true)
		return
	end
	deliver(packet, sender, count)
end

local function readRequest(packet: any, sender: Player?)
	if not sender then
		local callId = Types.u16.Read()
		local ok = Types.bool.Read()
		local thread = calls[callId]
		calls[callId] = nil
		if ok then
			local returns = packet.Returns
			local count = #returns
			for i = 1, count do
				args[i] = returns[i].Read()
			end
			if thread then
				task.spawn(thread, true, table.unpack(args, 1, count))
			end
		else
			local problem = Types.string.Read()
			if thread then
				task.spawn(thread, false, problem)
			end
		end
		return
	end
	local callId = Types.u16.Read()
	local types = packet.Types
	local count = #types
	for i = 1, count do
		args[i] = types[i].Read()
	end
	if not allow(packet, sender) then
		packet.Stats.Dropped += 1
		suspicious(sender, packet.Name, "rate limited", true)
		respond(packet, sender, callId, false, "rate limited")
		return
	end
	local values = table.move(args, 1, count, 1, {})
	if packet.Handler then
		task.spawn(answer, packet, sender, callId, values, count)
		return
	end
	if #packet.Queue >= QUEUE_SIZE then
		local dropped = table.remove(packet.Queue, 1)
		respond(packet, dropped[1], dropped[2], false, "no handler")
	end
	table.insert(packet.Queue, { sender, callId, values, count })
end

local function readAll(sender: Player?): number?
	local length = buffer.len(rbuf)
	while rpos < length do
		local start = rpos
		local id = readVarint()
		local packet = byId[id]
		if not packet then
			if sender then
				error(`unknown packet {id}`, 0)
			end
			return start
		end
		if sender and packet.Direction == "ToClient" then
			error(`"{packet.Name}" is server-to-client only`, 0)
		end
		if packet.Kind == "Request" then
			readRequest(packet, sender)
		else
			readEvent(packet, sender)
		end
		packet.Stats.Received += 1
		packet.Stats.ReceivedBytes += rpos - start
	end
	return nil
end

local onDefined = function() end

local function signatureFor(kind: string, types: { Type }, returns: { Type }?): string
	return kind .. ":" .. signatureOf(types) .. (if returns then "->" .. signatureOf(returns) else "")
end

local function specsOf(types: { Type }): { any }
	local specs = table.create(#types)
	for i, t in types do
		specs[i] = t.Spec
	end
	return specs
end

local function typesOf(specs: { any }): { Type }
	local types = table.create(#specs)
	for i, spec in specs do
		types[i] = Types.fromSpec(spec)
	end
	return types
end

local function newPacket(
	name: string,
	kind: string,
	types: { Type },
	returns: { Type }?,
	isUnreliable: boolean,
	limit: (number | false)?,
	direction: string,
	timeout: number
): any
	return setmetatable({
		Name = name,
		Kind = kind,
		Id = 0,
		Signature = signatureFor(kind, types, returns),
		Types = types,
		Returns = returns,
		Unreliable = isUnreliable,
		Limit = limit,
		Direction = direction,
		Timeout = timeout,
		Connections = {},
		Queue = {},
		Buckets = {},
		Stats = { Name = name, Sent = 0, SentBytes = 0, Received = 0, ReceivedBytes = 0, Dropped = 0 },
	}, Packet)
end

local function defineRemote(name: string, value: any): any
	local existing = byName[name]
	if existing or type(value) ~= "string" then
		return existing
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, value)
	if not ok or type(data) ~= "table" or type(data.i) ~= "number" then
		return nil
	end
	local returns = if data.k == "Request" then typesOf(data.r or {}) else nil
	local packet = newPacket(name, data.k, typesOf(data.t or {}), returns, data.u == true, nil, data.d, data.o)
	packet.Id = data.i
	byName[name] = packet
	byId[data.i] = packet
	onDefined()
	return packet
end

function Courier.find(name: string): any
	local packet = byName[name]
	if packet or IS_SERVER then
		return packet
	end
	local waiting = true
	task.delay(5, function()
		if waiting then
			warn(`Courier: waiting for the server to define "{name}" - is the module with it required on the server?`)
		end
	end)
	repeat
		packet = defineRemote(name, reliable:GetAttribute(name))
		if not packet then
			reliable:GetAttributeChangedSignal(name):Wait()
		end
	until packet
	waiting = false
	return packet
end

local function register(name: string, kind: string, types: { Type }, returns: { Type }?, options: Options?): any
	assert(
		type(name) == "string" and string.match(name, "^[%a_][%w_]*$") and #name <= 100,
		`Courier: bad packet name "{name}" (letters, digits and _ only)`
	)
	assert(string.sub(name, 1, 3) ~= "RBX", "Courier: packet names can't start with RBX")
	local opts: Options = options or {}
	assert(not (kind == "Request" and opts.Unreliable), "Courier: a request can't be unreliable")
	local limit = opts.Limit
	assert(limit == nil or limit == false or limit > 0, "Courier: Limit must be above 0 (or false for no limit)")
	local direction = opts.Direction or if kind == "Request" then "ToServer" else "Both"
	assert(
		direction == "ToClient" or direction == "ToServer" or direction == "Both",
		`Courier: Direction must be "ToClient", "ToServer" or "Both"`
	)
	assert(kind ~= "Request" or direction == "ToServer", "Courier: requests always go to the server")
	if not IS_SERVER then
		local packet = Courier.find(name)
		local signature = signatureFor(kind, types, returns)
		if packet.Signature ~= signature then
			warn(
				`Courier: "{name}" has different types on the server ({packet.Signature}) and the client ({signature})`
			)
		end
		return packet
	end
	assert(not byName[name], `Courier: packet "{name}" is defined twice`)
	assert(nextId < MAX_PACKETS, `Courier: more than {MAX_PACKETS} packets`)
	for _, t in types do
		assert(type(t) == "table" and t.Write, `Courier: "{name}" has a value that is not a Courier type`)
	end
	nextId += 1
	local packet = newPacket(
		name,
		kind,
		types,
		returns,
		opts.Unreliable == true,
		limit,
		direction,
		opts.Timeout or DEFAULT_TIMEOUT
	)
	packet.Id = nextId
	byName[name] = packet
	byId[nextId] = packet
	reliable:SetAttribute(
		name,
		HttpService:JSONEncode({
			i = nextId,
			k = kind,
			t = specsOf(types),
			r = if returns then specsOf(returns) else nil,
			u = packet.Unreliable,
			d = direction,
			o = packet.Timeout,
		})
	)
	return packet
end

function Courier.event(name: string, types: { Type }?, options: Options?): any
	return register(name, "Event", types or {}, nil, options)
end

function Courier.request(name: string, types: { Type }?, returns: { Type }?, options: Options?): any
	return register(name, "Request", types or {}, returns or {}, options)
end

function Packet.Fire(self: any, player: Player, ...: any)
	assert(IS_SERVER, "Courier: Fire is server only - use FireServer")
	assert(self.Direction ~= "ToServer", `Courier: "{self.Name}" is client-to-server only`)
	local pair = streams[player]
	if not pair then
		return
	end
	begin(self.Id)
	writeArgs(self.Types, 1, ...)
	push(self, pair)
end

function Packet.FireAll(self: any, ...: any)
	assert(IS_SERVER, "Courier: FireAll is server only")
	assert(self.Direction ~= "ToServer", `Courier: "{self.Name}" is client-to-server only`)
	begin(self.Id)
	writeArgs(self.Types, 1, ...)
	for _, pair in streams do
		push(self, pair)
	end
end

function Packet.FireExcept(self: any, except: Player, ...: any)
	assert(IS_SERVER, "Courier: FireExcept is server only")
	assert(self.Direction ~= "ToServer", `Courier: "{self.Name}" is client-to-server only`)
	begin(self.Id)
	writeArgs(self.Types, 1, ...)
	for player, pair in streams do
		if player ~= except then
			push(self, pair)
		end
	end
end

function Packet.FireList(self: any, players: { Player }, ...: any)
	assert(IS_SERVER, "Courier: FireList is server only")
	assert(self.Direction ~= "ToServer", `Courier: "{self.Name}" is client-to-server only`)
	begin(self.Id)
	writeArgs(self.Types, 1, ...)
	for _, player in players do
		local pair = streams[player]
		if pair then
			push(self, pair)
		end
	end
end

function Packet.FireServer(self: any, ...: any)
	assert(not IS_SERVER, "Courier: FireServer is client only")
	assert(self.Direction ~= "ToClient", `Courier: "{self.Name}" is server-to-client only`)
	begin(self.Id)
	writeArgs(self.Types, 1, ...)
	push(self, own)
end

function Packet.Connect(self: any, handler: (...any) -> ()): () -> ()
	assert(self.Kind == "Event", "Courier: a request uses SetHandler / Invoke, not Connect")
	local connections = table.clone(self.Connections)
	table.insert(connections, handler)
	self.Connections = connections
	if #self.Queue > 0 then
		local queue = self.Queue
		self.Queue = {}
		task.defer(function()
			for _, entry in queue do
				if entry[1] then
					call(handler, entry[1], table.unpack(entry[2], 1, entry[3]))
				else
					call(handler, table.unpack(entry[2], 1, entry[3]))
				end
			end
		end)
	end
	return function()
		local index = table.find(self.Connections, handler)
		if index then
			local remaining = table.clone(self.Connections)
			table.remove(remaining, index)
			self.Connections = remaining
		end
	end
end

function Packet.SetHandler(self: any, handler: (player: Player, ...any) -> ...any)
	assert(IS_SERVER and self.Kind == "Request", "Courier: SetHandler is for requests on the server")
	self.Handler = handler
	local queue = self.Queue
	self.Queue = {}
	for _, entry in queue do
		task.spawn(answer, self, entry[1], entry[2], entry[3], entry[4])
	end
end

local function finish(name: string, ok: boolean, ...: any): ...any
	if not ok then
		error(`Courier: request "{name}" failed: {...}`, 3)
	end
	return ...
end

function Packet.Invoke(self: any, ...: any): ...any
	assert(not IS_SERVER and self.Kind == "Request", "Courier: Invoke is for requests on the client")
	nextCall = nextCall % 65535 + 1
	local callId = nextCall
	local thread = coroutine.running()
	begin(self.Id)
	Types.u16.Write(callId)
	writeArgs(self.Types, 1, ...)
	push(self, own)
	calls[callId] = thread
	task.delay(self.Timeout, function()
		if calls[callId] == thread then
			calls[callId] = nil
			task.spawn(thread, false, `timed out after {self.Timeout} s`)
		end
	end)
	return finish(self.Name, coroutine.yield())
end

function Courier.Flush()
	if IS_SERVER then
		for player, pair in streams do
			drain(pair[1], reliable, player)
			drain(pair[2], unreliable, player)
		end
	else
		drain(own[1], reliable)
		drain(own[2], unreliable)
	end
end

function Courier.Stats(): { Stats }
	local list = {}
	for _, packet in byName do
		table.insert(list, table.clone(packet.Stats))
	end
	table.sort(list, function(a, b)
		return a.SentBytes + a.ReceivedBytes > b.SentBytes + b.ReceivedBytes
	end)
	return list
end

function Courier.ResetStats()
	for _, packet in byName do
		local stats = packet.Stats
		stats.Sent, stats.SentBytes, stats.Received, stats.ReceivedBytes, stats.Dropped = 0, 0, 0, 0, 0
	end
end

local function kb(bytes: number): string
	return string.format("%.1f KB", bytes / 1024)
end

local statsSince = os.clock()

function Courier.Report(): string
	local seconds = math.max(os.clock() - statsSince, 0.001)
	local lines = { `Courier ({if IS_SERVER then "server" else "client"}), last {string.format("%.1f", seconds)} s:` }
	for _, stats in Courier.Stats() do
		if stats.Sent + stats.Received + stats.Dropped > 0 then
			table.insert(
				lines,
				string.format(
					"  %-20s sent %6d (%s, %s/s)   received %6d (%s)%s",
					stats.Name,
					stats.Sent,
					kb(stats.SentBytes),
					kb(stats.SentBytes / seconds),
					stats.Received,
					kb(stats.ReceivedBytes),
					if stats.Dropped > 0 then `   dropped {stats.Dropped}` else ""
				)
			)
		end
	end
	if #lines == 1 then
		table.insert(lines, "  no traffic")
	end
	return table.concat(lines, "\n")
end

local function onReceiveError(sender: Player?, problem: any)
	warn(`Courier: bad data{if sender then ` from {sender.Name}` else ""}: {problem}`)
end

local badDataHandlers: { (player: Player, reason: string, strikes: number) -> () } = {}

function Courier.Configure(options: Settings)
	assert(IS_SERVER, "Courier: Configure is server only")
	for key, value in options :: { [string]: any } do
		assert(settings[key] ~= nil, `Courier: unknown setting "{key}"`)
		settings[key] = value
	end
end

function Courier.OnBadData(handler: (player: Player, reason: string, strikes: number) -> ()): () -> ()
	assert(IS_SERVER, "Courier: OnBadData is server only")
	local handlers = table.clone(badDataHandlers)
	table.insert(handlers, handler)
	badDataHandlers = handlers
	return function()
		local index = table.find(badDataHandlers, handler)
		if index then
			local remaining = table.clone(badDataHandlers)
			table.remove(remaining, index)
			badDataHandlers = remaining
		end
	end
end

if IS_SERVER then
	local warnedAt: { [Player]: number } = {}
	local strikes: { [Player]: number } = {}
	local budgets: { [Player]: { number } } = {}

	local function badData(player: Player, reason: string)
		local count = (strikes[player] or 0) + 1
		strikes[player] = count
		if (warnedAt[player] or -math.huge) + 5 < os.clock() then
			warnedAt[player] = os.clock()
			onReceiveError(player, `{reason} (strike {count})`)
		end
		for _, handler in badDataHandlers do
			call(handler, player, reason, count)
		end
		suspicious(player, "?", `invalid data: {reason}`)
		local kickAfter = settings.KickAfter
		if kickAfter and count >= kickAfter and player.Parent == Players then
			player:Kick("Invalid network data")
		end
	end

	local function withinBudget(player: Player, size: number): boolean
		local budget = settings.PlayerBudget
		if not budget then
			return true
		end
		local now = os.clock()
		local bucket = budgets[player]
		if not bucket then
			bucket = { budget, now }
			budgets[player] = bucket
		end
		local tokens = math.min(budget, bucket[1] + (now - bucket[2]) * budget)
		bucket[2] = now
		if tokens < size then
			bucket[1] = tokens
			return false
		end
		bucket[1] = tokens - size
		return true
	end

	local function addPlayer(player: Player)
		if not streams[player] then
			streams[player] = { newStream(), newStream() }
		end
	end

	Players.PlayerAdded:Connect(addPlayer)
	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		streams[player] = nil
		warnedAt[player] = nil
		strikes[player] = nil
		budgets[player] = nil
		for _, packet in byName do
			packet.Buckets[player] = nil
		end
	end)

	local function receive(player: Player, data: any, ...: any)
		if typeof(data) ~= "buffer" then
			badData(player, `expected a buffer, got {typeof(data)}`)
			return
		end
		local size = buffer.len(data)
		if size > settings.MaxBatch then
			badData(player, `batch of {size} bytes is over MaxBatch ({settings.MaxBatch})`)
			return
		end
		local refCount = select("#", ...)
		if refCount > settings.MaxRefs then
			badData(player, `{refCount} instance / any values is over MaxRefs ({settings.MaxRefs})`)
			return
		end
		if not withinBudget(player, size) then
			badData(player, `over PlayerBudget ({settings.PlayerBudget} bytes per second)`)
			return
		end
		rbuf, rpos, rrefs, rrefPos, strict = data, 0, { ... }, 0, true
		local ok, problem = pcall(readAll, player)
		strict = false
		if not ok then
			badData(player, tostring(problem))
		end
	end

	reliable.OnServerEvent:Connect(receive)
	unreliable.OnServerEvent:Connect(receive)
else
	local pending: { { any } } = {}
	local stuckWarned = false

	local function process()
		while #pending > 0 do
			local entry = pending[1]
			rbuf, rpos, rrefs, rrefPos = entry[1], entry[2], entry[3], entry[4]
			local ok, stopped = pcall(readAll, nil)
			if not ok then
				onReceiveError(nil, stopped)
			elseif stopped then
				entry[2], entry[4] = stopped, rrefPos
				if not stuckWarned and os.clock() - entry[5] > 10 then
					stuckWarned = true
					warn(
						`Courier: the server sends packet {buffer.readu8(entry[1], stopped)} which this client never defined`
					)
				end
				return
			end
			table.remove(pending, 1)
		end
	end

	local function receive(data: any, ...: any)
		if typeof(data) ~= "buffer" then
			return
		end
		table.insert(pending, { data, 0, { ... }, 0, os.clock() })
		process()
	end

	reliable.OnClientEvent:Connect(receive)
	unreliable.OnClientEvent:Connect(receive)

	onDefined = function()
		task.defer(process)
	end

	for name, value in reliable:GetAttributes() do
		defineRemote(name, value)
	end
	reliable.AttributeChanged:Connect(function(name)
		defineRemote(name, reliable:GetAttribute(name))
	end)
end

RunService.Heartbeat:Connect(Courier.Flush)

local logToken = 0

local function applyLog()
	logToken += 1
	local token = logToken
	local value = script:GetAttribute("Log")
	local interval = if value == true then 5 elseif type(value) == "number" and value > 0 then value else nil
	if not interval then
		print(`Courier ({if IS_SERVER then "server" else "client"}): traffic log off`)
		return
	end
	print(`Courier ({if IS_SERVER then "server" else "client"}): traffic log every {interval} s`)
	Courier.ResetStats()
	statsSince = os.clock()
	task.spawn(function()
		while true do
			task.wait(interval)
			if logToken ~= token then
				return
			end
			print(Courier.Report())
			Courier.ResetStats()
			statsSince = os.clock()
		end
	end)
end

script:GetAttributeChangedSignal("Log"):Connect(applyLog)
if script:GetAttribute("Log") ~= nil then
	task.defer(applyLog)
end

if IS_SERVER and IS_STUDIO then
	local setLog = Instance.new("RemoteEvent")
	setLog.Name = "SetLog"
	setLog.OnServerEvent:Connect(function(_, key: any, value: any)
		if LOG_KEYS[key] then
			script:SetAttribute(key, value)
		end
	end)
	setLog.Parent = script
end

return Courier