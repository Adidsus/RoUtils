# Mirror

State replication: a table on the server, the same table on the clients that may see it, and every change sent to them
as it happens. Listeners on any path, on both sides. No dependencies.

```lua
-- server
local match = Mirror.new("Match", { Phase = "Intermission", Wave = 0, Votes = {} })
match:Set("Phase", "WaveActive")
match:Set({ "Votes", player.UserId }, true)
match:Increment("Wave")

local profile = Mirror.new(`Profile_{player.UserId}`, data, { To = { player } })   -- only this player

-- client
local match = Mirror.wait("Match")
match:Get("Phase")
match:Observe("Phase", function(phase) end)            -- now and on every change
match:OnChange("Votes", function(votes) end)
```

The server must require Mirror (clients wait for its RemoteEvent). Use it instead of attributes when the state is
more than a few values, has nested tables, or is only for some players.

## Paths

A path is one key (`"Phase"`, `3`) or a list of keys (`{ "Votes", 123456 }`); `nil` is the whole table. Any key type
works, including number keys in dictionaries (Roblox remotes break those on their own - Mirror packs tables so they
arrive exactly as they are).

## Server

| Method | What |
|---|---|
| `Mirror.new(name, data?, { To })` | `To`: `"All"` (default), a list of players, or `function(player) return boolean end` |
| `Get(path?)` | the value - read only, change it through the methods below |
| `Set(path, value)` | missing tables on the way are created; tables are copied; the same plain value sends nothing; `nil` removes |
| `Update(path, fn)` | `Set(path, fn(current))`, returns the new value |
| `Increment(path, by?)` | numbers, `by` defaults to 1 |
| `Patch(path?, { key = value })` | several keys at once |
| `Insert(path, value, index?)` / `Remove(path, index?)` | lists - only the change goes out, not the whole list |
| `AddViewer(player)` / `RemoveViewer(player)` / `SetTo(to)` | who sees it; a player who stops seeing it gets it destroyed |
| `CanSee(player)` / `Viewers()` | |
| `Mirror.refresh(player?)` | runs `To` functions again (e.g. after a player's rank changed) |
| `Mirror.get(name)` | |
| `Destroy()` | removed on every client too; the name can be used again |

## Both sides

| | What |
|---|---|
| `Get(path?)` | |
| `OnChange(path, fn(value))` | the path changed, something inside it changed, or a table above it was replaced; returns a disconnect function |
| `Observe(path, fn(value))` | calls now, then like `OnChange` |
| `Changed` | event `(path, value, old)` for every change - `Connect`, `Once`, `Wait` |
| `Destroyed` | event |
| `IsDestroyed()` | |

## Client

| | What |
|---|---|
| `Mirror.wait(name, timeout?)` | yields until it arrives (`nil` after `timeout`); warns after 5 s without a timeout |
| `Mirror.get(name)` | `nil` when not here (yet) |
| `Mirror.onCreated(fn(mirror))` | every mirror here now and every new one, e.g. for per-player names |

Changing a mirror on the client is an error, and the packet only goes from the server to clients.

## How it works

All operations of every mirror go through one RemoteEvent, queued per player and sent once per frame
(`Mirror.flush()` sends right away), so creating, changing and destroying always arrive in the order they happened. A client asks for its mirrors when it starts; until then the server
sends it nothing, so no change can arrive before the full table.