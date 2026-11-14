--!strict
--https://github.com/Adidsus/RoUtils

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	FireDeferred: (self: Signal<T...>, T...) -> (),
	Count: (self: Signal<T...>) -> number,
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

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

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	local signal = self._signal
	local previous, nextNode = self._previous, self._next
	if previous then
		previous._next = nextNode
	else
		signal._head = nextNode
	end
	if nextNode then
		nextNode._previous = previous
	else
		signal._tail = previous
	end
	signal._count -= 1
end

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	return setmetatable({ _head = nil, _tail = nil, _count = 0, _sequence = 0 }, Signal) :: any
end

function Signal.Connect(self: any, handler: (...any) -> ()): Connection
	self._sequence += 1
	local connection = setmetatable({
		Connected = true,
		_id = self._sequence,
		_signal = self,
		_handler = handler,
		_previous = self._tail,
		_next = nil,
	}, Connection)
	if self._tail then
		self._tail._next = connection
	else
		self._head = connection
	end
	self._tail = connection
	self._count += 1
	return connection :: any
end

function Signal.Once(self: any, handler: (...any) -> ()): Connection
	local connection: Connection
	connection = Signal.Connect(self, function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function Signal.Wait(self: any): ...any
	local thread = coroutine.running()
	Signal.Once(self, function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.Fire(self: any, ...: any)
	local node = self._head
	local last = self._sequence
	while node and node._id <= last do
		if node.Connected then
			if not freeThread then
				freeThread = coroutine.create(runLoop)
				coroutine.resume(freeThread :: thread)
			end
			task.spawn(freeThread :: thread, node._handler, ...)
		end
		node = node._next
	end
end

function Signal.FireDeferred(self: any, ...: any)
	local node = self._head
	local last = self._sequence
	while node and node._id <= last do
		if node.Connected then
			local connection = node
			task.defer(function(...)
				if connection.Connected then
					connection._handler(...)
				end
			end, ...)
		end
		node = node._next
	end
end

function Signal.Count(self: any): number
	return self._count
end

function Signal.DisconnectAll(self: any)
	local node = self._head
	while node do
		node.Connected = false
		node = node._next
	end
	self._head = nil
	self._tail = nil
	self._count = 0
end

Signal.Destroy = Signal.DisconnectAll

return Signal