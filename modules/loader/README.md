# Loader

Finds ModuleScripts, requires them in priority order and runs their lifecycle: `Init` on every module (one after
another), then `Start` on every module (each in its own thread). Works on the server and the client, no dependencies.
Can run modules inside Actors (parallel Luau).

```lua
local Loader = require(ReplicatedStorage.Loader)

Loader.Start({ ServerScriptService.Systems }, { Verbose = true })
```

A module:

```lua
local Enemies = {}
Enemies.Priority = 100              -- optional: higher loads first (or the LoaderPriority attribute)

function Enemies:Init() end         -- every module's Init runs before any Start
function Enemies:Start() end        -- may yield

return Enemies
```

## What gets loaded

Every ModuleScript under a container whose path to the container is made of Folders only (a module inside another
module is that module's business) and that is at most `SearchDepth` deep. A container can also be a ModuleScript.

**Where a module runs** - checked from the module up through its folders; the closest setting wins:

| How | Server only | Client only | Skip |
|---|---|---|---|
| attribute | `ServerOnly = true` | `ClientOnly = true` | `IgnoreLoader = true` |
| tag (CollectionService) | `ServerOnly` | `ClientOnly` | `IgnoreLoader` |
| name of the module | ends with `Server` (`EnemyServer`) | ends with `Client` (`HudClient`) | |
| name of a folder | `Server` | `Client` | |

`ServerOnly = false` / `IgnoreLoader = false` on a module stops a folder's setting from reaching it. Name rules are
configurable (`Naming`) or off (`Naming = false`).

**Priority:** attribute `LoaderPriority` (also on folders), else the module's own `Priority` / `LoaderPriority` field,
else 0. Same priority = sorted by path.

## Options

| Option | Default | What |
|---|---|---|
| `Verbose` | false | print every module with its priority and load time |
| `Tag` | none | also load ModuleScripts / Folders with this CollectionService tag, wherever they are |
| `SearchDepth` | unlimited | 1 = only the direct children of a container |
| `Naming` | see below | `{ ServerSuffixes, ClientSuffixes, ServerPrefixes, ClientPrefixes, ServerFolders, ClientFolders, ParallelSuffixes }` - missing keys use the defaults; `false` = no name rules |
| `ClientWaitForServer` | false | the client starts only after the server finished loading |
| `SlowWarning` | 0.25 | warn when an `Init` takes longer (seconds) |
| `YieldWarning` | 10 | warn when a `require` / `Init` is still running after this many seconds |
| `Filter` | none | `function(module) return true / false / nil end` - your own rule (nil = the normal rules) |

Default naming: suffixes `Server` / `Client`, folders `Server` / `Client`, parallel suffix `Parallel`, no prefixes.

## Actors (parallel Luau)

A module marked `Parallel` (attribute, tag, or a name ending with `Parallel`) is required inside its own Actor
(server: `ServerScriptService.LoaderActors`, client: `PlayerScripts.LoaderActors`), so it can use `ConnectParallel` /
`task.desynchronize`. Its `Init` and `Start` still run in priority order. Such a module lives in another Luau VM:
`Loader.Get` doesn't return it and its tables aren't shared - talk to it through Actor messages or instances.

## API

| | |
|---|---|
| `Loader.Start(containers, options?)` | once per side |
| `Loader.Get(name)` | the value a loaded module returned (not for parallel ones) |
| `Loader.OnStarted(callback)` / `Loader.IsStarted()` | after every Init ran and every Start was spawned |
| `Loader.IsServerLoaded()` | on either side; the server sets it when it finished |
| `Loader.Entries()` | every module with priority, times and failure reason |

Errors never stop the others: a failed `require` or `Init` is printed with its traceback and that module gets no
`Start`.