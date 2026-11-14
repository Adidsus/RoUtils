# Courier

Networking on buffers. Everything sent in one frame goes to each player as one batch, packed into a `buffer` by
types you declare - an enemy move with an id and a distance is 7 bytes. Typed events and requests, rate limits and
protection against bad data from exploiters. No dependencies.

Define packets in one shared module that both the server and the client require:

```lua
local Courier = require(ReplicatedStorage.Courier)
local T = Courier.Types

return {
	Spawn = Courier.event("EnemySpawn", { T.u16, T.enum({ "Zombie", "Boss" }), T.f32 }, { Direction = "ToClient" }),
	Move = Courier.event("EnemyMove", { T.u16, T.f32 }, { Unreliable = true, Direction = "ToClient" }),
	Place = Courier.event("PlaceTower", { T.u8, T.cframe }, { Limit = 5, Direction = "ToServer" }),
	Snapshot = Courier.request("Snapshot", {}, { T.array(T.u16) }),
}
```

```lua
-- server
Packets.Move:FireAll(id, distance)          -- also Fire(player, ...), FireExcept(player, ...), FireList(players, ...)
Packets.Place:Connect(function(player, slot, cframe) end)   -- returns a disconnect function
Packets.Snapshot:SetHandler(function(player) return ids end)

-- client
Packets.Move:Connect(function(id, distance) end)
Packets.Place:FireServer(slot, cframe)
local ids = Packets.Snapshot:Invoke()       -- yields; errors on failure or timeout
```

The server writes every packet's types to an attribute, and the client builds all of them by itself - a client doesn't
need the packet module at all and can get any packet with `Courier.find(name)` (it waits until the server defined it,
with a warning after 5 s). When the client does require the shared module, `Courier.event` / `Courier.request` return the
same packet and warn if the types differ from the server's. Packet ids are varints: 1 byte for the first 127 packets,
at most 16383 packets.

## Packet options

| Option | Default | What |
|---|---|---|
| `Unreliable` | false | `UnreliableRemoteEvent`: may be lost or arrive out of order - for state the next message overwrites (positions, health bars) |
| `Direction` | `"Both"` | `"ToClient"` / `"ToServer"`; the server rejects a `ToClient` packet sent by a client. Requests are always `"ToServer"` |
| `Limit` | `DefaultLimit` | messages per second per player from clients (burst = 1 s worth); over it a message is dropped, a request answered with "rate limited". `false` = no limit |
| `Timeout` | 15 | requests: seconds before `Invoke` errors |

## Types

| Type | Bytes |
|---|---|
| `u8` `i8` / `u16` `i16` / `u32` `i32` | 1 / 2 / 4 |
| `f32` / `f64` (`number`) | 4 / 8 |
| `bool` | 1 |
| `string`, `stringMax(n)`, `buffer` | length (1 byte below 128) + data |
| `vector2` / `vector3` | 8 / 12 (f32) |
| `cframe` | 24 (position + axis * angle) |
| `color3` | 3 |
| `enum({ ... })` | 1 - any values, e.g. strings or EnumItems, at most 256 |
| `optional(t)` | 1 + t |
| `array(t, max?)`, `map(k, v, max?)` | length + items |
| `struct({ name = t, ... })` | the fields, sorted by name |
| `instance`, `any` | 1 - the value itself goes as a separate remote argument |
| `values` | length + 1 per value - any values as a list with `.n` (like `table.pack`), `nil` in the middle stays |

An instance the receiver doesn't have arrives as `nil` (the others stay in place). `any` is whatever Roblox remotes
can send - from clients it can be anything, so avoid it in client packets.

## Batching

Batches go out on `Heartbeat`. Something sent in `Heartbeat` after that goes one frame later - call `Courier.Flush()` at
the end of your frame loop to send right away. Unreliable batches are cut into chunks of up to 800 bytes (Roblox drops
bigger unreliable messages). Messages that arrive before anything is connected wait in a queue (up to 256), like with a
normal RemoteEvent.

## Protection (server)

Data from clients is read inside a `pcall`: wrong types, NaN, lengths longer than the data, unknown packets and
packets in the wrong direction drop the batch. Types only guarantee the shape (`u8` is 0-255, not "a slot the player
owns") - handlers still check the game rules.

```lua
Courier.Configure({
	DefaultLimit = 60,      -- Limit of every client packet that has none
	MaxBatch = 8192,        -- bytes in one client batch
	MaxRefs = 64,           -- instance / any values in one batch
	PlayerBudget = 65536,   -- bytes per second from one player, all packets together (false = off)
	KickAfter = false,      -- kick after this many bad batches
})

Courier.OnBadData(function(player, reason, strikes) end)   -- every bad batch; returns a disconnect function
```

A message over a packet's `Limit` is not bad data (a lagging player can send a burst) - it is only dropped and counted.
The console warning is printed at most every 5 s per player.

`Courier.Suspicious(player, packet, reason)` fires on every bad data strike (`invalid data: ...`) and when a player goes over a packet's limit (`rate limited`, at most once a second per packet). `Guard.use(Courier)` turns these into [Guard](../guard) reports.

## Stats

`Courier.Stats()` - `{ Name, Sent, SentBytes, Received, ReceivedBytes, Dropped }` per packet, `Courier.Report()` - the
same as text, `Courier.ResetStats()`. From the Command Bar (the side it runs on):

```lua
game.ReplicatedStorage.Courier:SetAttribute("Log", 5)   -- print the report every 5 s (true = 5, false = off)
```

In Studio the server also has a `SetLog` RemoteEvent: `Courier.SetLog:FireServer("Log", 5)` from a client Command Bar.
