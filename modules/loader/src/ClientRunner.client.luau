local actor = script:GetActor()
if actor then
	require((script:WaitForChild("Runner") :: ObjectValue).Value :: ModuleScript)(actor)
end