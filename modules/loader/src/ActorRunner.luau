--!strict

local function run(actor: Actor)
	local target = actor:WaitForChild("Target") :: ObjectValue
	local report = actor:WaitForChild("Report") :: BindableEvent
	local module = target.Value :: ModuleScript
	local ok, value = xpcall(require, debug.traceback, module)
	report:Fire("Loaded", ok, if ok then nil else tostring(value))
	if not ok then
		return
	end

	local function call(method: string): (boolean, string?)
		local fn = type(value) == "table" and value[method]
		if type(fn) ~= "function" then
			return true, nil
		end
		local called, problem = xpcall(fn, debug.traceback, value)
		return called, if called then nil else tostring(problem)
	end

	actor:BindToMessage("Init", function()
		local called, problem = call("Init")
		report:Fire("Init", called, problem)
	end)
	actor:BindToMessage("Start", function()
		local called, problem = call("Start")
		report:Fire("Start", called, problem)
	end)
end

return run