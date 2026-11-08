# Scheduler

One frame loop for your game systems instead of many `Heartbeat` connections: a fixed order, systems that run every
N seconds, game time (speed / pause from [GameClock](../game-clock)), the cost of every system in milliseconds and a
frame budget warning. No dependencies.

```lua
local scheduler = Scheduler.new({ Name = "Server", Clock = clock, Budget = 4 })

scheduler:Add("Enemies", EnemyServer, { Priority = 100, Scaled = true })      -- a table with :Update(dt)
scheduler:Add("Waves", function(dt) ... end, { Interval = 0.5, Scaled = true })  -- or a function
scheduler:Add("UI sync", function(dt) ... end)                                  -- real time

scheduler:Start()
print(scheduler:Report())
```

| `Scheduler.new` option | What |
|---|---|
| `Name` | shown in reports and warnings |
| `Event` | default `RunService.Heartbeat` (client UI: `RenderStepped`) |
| `Clock` | anything with `:Speed()` and `:IsPaused()` - e.g. a GameClock |
| `Budget` | ms per frame; above it a warning names the slowest system (at most every 10 s) |
| `Profile` | default true: every system is a named label in the MicroProfiler |

| `:Add` option | What |
|---|---|
| `Priority` | higher runs first in the frame |
| `Interval` | run every N seconds; gets the time since its last run as `dt` |
| `Scaled` | `dt` is game time (x2 speed = double `dt`, paused = not called) |

`:Add` returns a function that removes the system. Adding or removing during a frame is safe. A system that errors
keeps the others running; it is warned about at most every 5 s with an error count.

`:Stats()` - `{ Name, Average, Max, Calls, Errors }` (ms), slowest first. `:Report()` - the same as text.
`:ResetStats()`, `:Stop()`, `:IsRunning()`.

## Logs from the Command Bar

The Command Bar has its own copy of every module, so switches are attributes on this ModuleScript (attributes are
shared by everyone):

```lua
local s = game.ReplicatedStorage.Scheduler          -- wherever you put it
s:SetAttribute("Log", 5)            -- print every running scheduler's report every 5 s (true = 5 s)
s:SetAttribute("Log", false)
s:SetAttribute("LogOnly", "Server") -- only the scheduler with this name
s:SetAttribute("LogReset", true)    -- every report counts from zero
s:SetAttribute("Warnings", false)   -- mute error / budget warnings (errors are still counted)
```

Run them on the side you want (Studio: Client / Server switch). In Studio the server version also has a
`SetLog` RemoteEvent, so a client Command Bar can switch the server: `s.SetLog:FireServer("Log", 5)`.