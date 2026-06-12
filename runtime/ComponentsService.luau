-- ComponentsService — DI-aware dispatcher that turns "Component:X" tags
-- into live component instances with their dependencies resolved.
--
-- Auto-bound AsSingle in the installer's compiler-emitted boot tail,
-- with one Register(definition) call per discovered Component subclass.
-- The user's installer code never mentions it; the user just writes
-- `class Health : Component` and tags an Instance in Studio.
--
-- Update / LateUpdate cadence (locked decision 5):
--   • Update runs on Heartbeat — fires on both server and client,
--     whichever side the Instance lives on.
--   • LateUpdate runs on RenderStepped — client only. Components
--     attached on the server simply never see LateUpdate fire.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Component = require(script.Parent.Component)
local InstanceRegistry = require(script.Parent.InstanceRegistry)

-- Tagged instances under ServerStorage / ReplicatedStorage are
-- templates (prefabs waiting to be cloned) — they must not tick.
-- CollectionService tags clone with the instance, so a clone parented
-- into Workspace fires GetInstanceAddedSignal and spawns normally.
local function isStorageTemplate(instance)
	return instance:IsDescendantOf(ServerStorage)
		or instance:IsDescendantOf(ReplicatedStorage)
end

local ComponentsService = setmetatable({}, {
	__tostring = function() return "ComponentsService" end,
})
ComponentsService.__index = ComponentsService

ComponentsService.__ctorParams = { "Container" }
ComponentsService.__interfaces = {}

function ComponentsService.new(...)
	local self = setmetatable({}, ComponentsService)
	return self:constructor(...) or self
end

function ComponentsService:constructor(container)
	self._container = container
	self._registered = {}  -- [definition] = true; dedupes Register calls.
	self._active = {}      -- [Instance][componentName] = live component.
	self._connections = {} -- Disconnectables collected for OnDestroy.

	-- Hand ourselves to the Component module so component-typed
	-- serialized fields (`[SerializedField] Health target`) can
	-- resolve back through GetComponent at read time.
	Component.setComponentsService(self)

	-- Backfill the Instance registry so [SerializedField] reference
	-- fields can resolve before the first component spawns.
	InstanceRegistry.scan(Workspace)
	InstanceRegistry.scan(ReplicatedStorage)

	-- Update tick — runs on every component each Heartbeat regardless of
	-- side. The pcall wrapper isolates a faulty Update from the rest of
	-- the tick; matches the previous init.luau behaviour.
	table.insert(self._connections, RunService.Heartbeat:Connect(function(dt)
		self:_tick("Update", dt)
	end))

	-- LateUpdate is RenderStepped — client-only. Skip the connection
	-- server-side so a server-attached component's LateUpdate just
	-- silently no-ops.
	if RunService:IsClient() then
		table.insert(self._connections, RunService.RenderStepped:Connect(function(dt)
			self:_tick("LateUpdate", dt)
		end))
	end
end

-- Looks up the live component table attached to `instance` for the
-- given component name. Returns nil if `instance` has no such
-- component (yet — components may attach in any order during boot).
-- Backs the runtime resolution of `[SerializedField] <Component>`
-- references and is the public equivalent of Unity's GetComponent<T>.
function ComponentsService:GetComponent(instance, componentName)
	local byName = self._active[instance]
	return byName and byName[componentName] or nil
end

-- Public entry point called by the compiler-emitted installer tail.
-- Wires the CollectionService watcher for this component's tag and
-- backfills any Instances already tagged at registration time.
function ComponentsService:Register(definition)
	if self._registered[definition] then return end
	self._registered[definition] = true

	local tag = Component.tagFor(definition.ComponentName)

	for _, existing in ipairs(CollectionService:GetTagged(tag)) do
		self:_trySpawn(definition, existing)
	end

	table.insert(self._connections,
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
			self:_trySpawn(definition, instance)
		end))
	table.insert(self._connections,
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
			self:_destroy(definition, instance)
		end))
end

-- Spawn gate for storage templates. A tagged prefab still inside
-- ServerStorage / ReplicatedStorage doesn't spawn; instead we watch
-- its ancestry so a straight reparent into the live DataModel (which
-- does NOT re-fire the tag-added signal) still spawns it.
function ComponentsService:_trySpawn(definition, instance)
	if not isStorageTemplate(instance) then
		self:_spawn(definition, instance)
		return
	end

	local tag = Component.tagFor(definition.ComponentName)
	local conn
	conn = instance.AncestryChanged:Connect(function()
		if instance.Parent == nil then
			conn:Disconnect()
		elseif not isStorageTemplate(instance) then
			conn:Disconnect()
			-- The tag could have been stripped while the template sat in
			-- storage — only the tag's presence makes this a component.
			if CollectionService:HasTag(instance, tag) then
				self:_spawn(definition, instance)
			end
		end
	end)
	table.insert(self._connections, conn)
end

-- Creates the live component for `instance`, runs the DI constructor
-- with resolved deps, then fires the Awake / Start lifecycle. Errors
-- inside user code are pcall'd so one bad component doesn't take down
-- the whole spawn for that Instance.
function ComponentsService:_spawn(definition, instance)
	local componentName = definition.ComponentName
	local existingOnInstance = self._active[instance]
	if existingOnInstance and existingOnInstance[componentName] then
		return -- already spawned; tag re-add is a no-op.
	end

	-- Resolve __ctorParams via the container. Empty for parameterless
	-- components; populated for DI-injected ones. Container:Resolve
	-- handles cycles + missing-binding diagnostics on its own, so we
	-- don't shadow them here. `false` is the lowering's placeholder for
	-- a param DI can't inject (primitives, unresolved types) — the slot
	-- stays so later params keep their positions; the ctor sees nil.
	local params = definition.__ctorParams or {}
	local args = table.create(#params)
	for i, paramType in ipairs(params) do
		if paramType ~= false then
			args[i] = self._container:Resolve(paramType)
		end
	end

	-- Component.spawn produces the table with attribute-backed
	-- serialized fields and self.Instance wired up. Constructor (if
	-- present) runs the user's DI ctor body on that table.
	local component = Component.spawn(definition, instance)

	if definition.constructor then
		local ok, err = pcall(definition.constructor, component, table.unpack(args, 1, #params))
		if not ok then
			warn(string.format("[Components] %s constructor errored: %s", componentName, err))
			-- Same teardown as a tag removal: Component.spawn already
			-- wired attribute connections and indexed the component;
			-- without this they'd leak, since the component never
			-- enters _active and the regular destroy path can't reach it.
			Component.destroy(component)
			return
		end
	end

	self._active[instance] = self._active[instance] or {}
	self._active[instance][componentName] = component

	if component.Awake then
		local ok, err = pcall(component.Awake, component)
		if not ok then
			warn(string.format("[Components] %s Awake errored: %s", componentName, err))
		end
	end

	-- Start defers to next frame so component-to-component lookups
	-- (e.g. a Health asking Hitbox via GetComponent) can assume every
	-- sibling has finished Awake. Re-check active before firing — the
	-- Instance could have been untagged between Awake and the defer.
	task.defer(function()
		local still = self._active[instance] and self._active[instance][componentName] == component
		if still and component.Start then
			local ok, err = pcall(component.Start, component)
			if not ok then
				warn(string.format("[Components] %s Start errored: %s", componentName, err))
			end
		end
	end)
end

function ComponentsService:_destroy(definition, instance)
	local componentsOnInstance = self._active[instance]
	if not componentsOnInstance then return end

	local componentName = definition.ComponentName
	local component = componentsOnInstance[componentName]
	if not component then return end

	-- Component.destroy fires OnDestroy and disconnects the attribute
	-- listeners. We then clear our bookkeeping; the Instance entry
	-- itself is dropped when the last component on it is gone so the
	-- Update tick doesn't carry a stale empty bucket.
	Component.destroy(component)
	componentsOnInstance[componentName] = nil
	if next(componentsOnInstance) == nil then
		self._active[instance] = nil
	end
end

-- Drives every active component's named hook (Update or LateUpdate).
-- Tight loop because this fires every frame — pcall is per-component,
-- not per-tick, so a single component throwing doesn't abort siblings.
function ComponentsService:_tick(hookName, dt)
	for _, componentsOnInstance in pairs(self._active) do
		for _, component in pairs(componentsOnInstance) do
			local hook = component[hookName]
			if hook then
				local ok, err = pcall(hook, component, dt)
				if not ok then
					warn(string.format("[Components] %s errored: %s", hookName, err))
				end
			end
		end
	end
end

return ComponentsService
