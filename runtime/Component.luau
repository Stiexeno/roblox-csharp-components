-- Base for the Component system: a Unity-MonoBehaviour-lite tied to a
-- Roblox Instance. Subclasses are produced via Component.define(name),
-- which returns a definition table the registry / runtime use to
-- spawn per-Instance live components.
--
-- A component instance has two backing stores:
--   - regular `self.X = Y` fields (any non-serialized state)
--   - serialized fields backed by Roblox Instance Attributes
--     (so they survive save/load AND show up in the inspector)
--
-- Serialized fields are declared on the definition:
--
--     Health.SerializedFields = {
--         Max = { type = "number", default = 100 },
--         Current = { type = "number", default = 100 },
--     }
--
-- Reads of `self.Max` return the live attribute value; writes (`self.Max = 200`)
-- push back to the attribute so the inspector sees the change. External
-- attribute edits (e.g. dragging a slider in the Studio plugin during play)
-- also propagate into the component via an AttributeChangedSignal listener.

local InstanceRegistry = require(script.Parent.InstanceRegistry)

local Component = {}
Component.__index = Component

-- Set by ComponentsService.constructor so component-typed serialized
-- fields (`[SerializedField] Health target`) can resolve the live
-- component table from the referenced Instance + component name.
-- Module-level slot dodges a cyclic require between Component and
-- ComponentsService.
local _componentsService = nil

function Component.setComponentsService(svc)
	_componentsService = svc
end

-- Recursively writes the default for every leaf attribute under `prefix`
-- that isn't already set. Composite fields don't have an attribute of
-- their own — only their leaves do. Lists get an empty Count;
-- per-element attributes are created on add.
local function initLeafDefaults(instance, prefix, fields)
	for fieldName, fieldDef in pairs(fields) do
		local attrName = prefix .. "_" .. fieldName
		if fieldDef.type == "composite" then
			initLeafDefaults(instance, attrName, fieldDef.fields)
		elseif fieldDef.type == "list" then
			local countAttr = attrName .. "_Count"
			if instance:GetAttribute(countAttr) == nil then
				instance:SetAttribute(countAttr, 0)
			end
		else
			if instance:GetAttribute(attrName) == nil then
				instance:SetAttribute(attrName, fieldDef.default)
			end
		end
	end
end

-- Reads <prefix>_Count and <prefix>_1..N into a real Luau array. Per-
-- element value depends on the element's type — composites yield a
-- proxy at the deeper prefix, instances resolve through the registry,
-- primitives/enums are the attribute value verbatim.
local makeCompositeProxy -- forward decl; populated below.
local function buildListArray(instance, prefix, elementDef)
	local count = instance:GetAttribute(prefix .. "_Count") or 0
	local arr = {}
	for i = 1, count do
		local itemPrefix = prefix .. "_" .. i
		if elementDef.type == "composite" then
			arr[i] = makeCompositeProxy(instance, itemPrefix, elementDef.fields)
		elseif elementDef.type == "instance" then
			arr[i] = InstanceRegistry.resolve(instance:GetAttribute(itemPrefix))
		else
			arr[i] = instance:GetAttribute(itemPrefix)
		end
	end
	return arr
end

-- Returns a proxy table whose reads/writes route to flat-named
-- attributes under `prefix`. Nested composites yield deeper proxies on
-- demand. Replacing a composite (proxy[k] = newComposite) batch-writes
-- each leaf from `v[subName]`.
function makeCompositeProxy(instance, prefix, fields)
	return setmetatable({}, {
		__index = function(_, k)
			local fieldDef = fields[k]
			if not fieldDef then return nil end
			local attrName = prefix .. "_" .. k
			if fieldDef.type == "composite" then
				return makeCompositeProxy(instance, attrName, fieldDef.fields)
			elseif fieldDef.type == "instance" then
				return InstanceRegistry.resolve(instance:GetAttribute(attrName))
			else
				return instance:GetAttribute(attrName)
			end
		end,
		__newindex = function(_, k, v)
			local fieldDef = fields[k]
			if not fieldDef then return end
			local attrName = prefix .. "_" .. k
			if fieldDef.type == "composite" then
				local sub = makeCompositeProxy(instance, attrName, fieldDef.fields)
				for subName in pairs(fieldDef.fields) do
					sub[subName] = v[subName]
				end
			elseif fieldDef.type == "instance" then
				local uid = v and InstanceRegistry.bind(v) or ""
				instance:SetAttribute(attrName, uid)
			else
				instance:SetAttribute(attrName, v)
			end
		end,
	})
end

-- Constructs a definition table. The user fills in SerializedFields and
-- lifecycle methods after this call.
function Component.define(name)
	local def = {
		ComponentName = name,
		SerializedFields = {},
	}
	def.__index = def
	setmetatable(def, { __index = Component })
	return def
end

-- Returns the tag string used by CollectionService for this component
-- name. Keep this in lockstep with the runtime's TAG_PREFIX.
function Component.tagFor(componentName)
	return "Component:" .. componentName
end

-- Returns the attribute name for a given serialized field. Underscore
-- prefix keeps Studio's Properties panel grouped by component.
function Component.attrFor(componentName, fieldName)
	return componentName .. "_" .. fieldName
end

-- Live component instance constructor. Wires up the two-way attribute
-- sync described above. Returns the table the user's lifecycle methods
-- see as `self`.
function Component.spawn(definition, instance)
	local serialized = {}
	local connections = {}

	-- Backfill any missing leaf attributes with their declared default,
	-- then populate `serialized` per kind:
	--   composite → cache one proxy table that lazily reads/writes
	--               its leaf attributes through the metatable.
	--   instance  → cache the resolved Instance; refresh on attribute
	--               change so external picks propagate.
	--   primitive → cache the scalar value; refresh on attribute change.
	initLeafDefaults(instance, definition.ComponentName, definition.SerializedFields)

	for fieldName, fieldDef in pairs(definition.SerializedFields) do
		local attrName = Component.attrFor(definition.ComponentName, fieldName)

		if fieldDef.type == "composite" then
			serialized[fieldName] = makeCompositeProxy(instance, attrName, fieldDef.fields)
		elseif fieldDef.type == "list" then
			-- A list is exposed as a real Luau array (rebuilt from
			-- storage). table.insert / table.remove from C# user code
			-- mutate the array directly and are runtime-only — to
			-- persist, edit via the inspector or set the attributes
			-- yourself.
			serialized[fieldName] = buildListArray(instance, attrName, fieldDef.element)
			local listPrefix = attrName .. "_"
			local conn = instance.AttributeChanged:Connect(function(name)
				if string.sub(name, 1, #listPrefix) == listPrefix then
					serialized[fieldName] = buildListArray(instance, attrName, fieldDef.element)
				end
			end)
			table.insert(connections, conn)
		elseif fieldDef.type == "instance" then
			serialized[fieldName] = InstanceRegistry.resolve(instance:GetAttribute(attrName))
			local conn = instance:GetAttributeChangedSignal(attrName):Connect(function()
				serialized[fieldName] = InstanceRegistry.resolve(instance:GetAttribute(attrName))
			end)
			table.insert(connections, conn)
		elseif fieldDef.type == "component" then
			-- Resolved live on read via __index — see below. The cached
			-- slot stays nil because the referenced component may spawn
			-- after this one (declaration order isn't dependency order).
			serialized[fieldName] = nil
		else
			serialized[fieldName] = instance:GetAttribute(attrName)
			local conn = instance:GetAttributeChangedSignal(attrName):Connect(function()
				serialized[fieldName] = instance:GetAttribute(attrName)
			end)
			table.insert(connections, conn)
		end
	end

	local self = {
		Instance = instance,
		_definition = definition,
		_serialized = serialized,
		_connections = connections,
	}

	-- The metatable does three things on read:
	--   1. Return the live serialized value for declared fields.
	--   2. Otherwise return whatever the user stashed on self.
	--   3. Otherwise return methods from the definition.
	--
	-- On write: if the key is a serialized field, push to the attribute
	-- (which fires the change signal, which updates _serialized — so
	-- this is the single source of truth). Otherwise rawset.
	return setmetatable(self, {
		__index = function(t, k)
			local def = rawget(t, "_definition")
			local fieldDef = def.SerializedFields and def.SerializedFields[k]
			-- Component-typed fields resolve live: the referenced
			-- component might spawn after this one, so caching at spawn
			-- time would return stale nils forever.
			if fieldDef and fieldDef.type == "component" then
				local uid = rawget(t, "Instance"):GetAttribute(Component.attrFor(def.ComponentName, k))
				local target = InstanceRegistry.resolve(uid)
				if not target or not _componentsService then return nil end
				return _componentsService:GetComponent(target, fieldDef.constraint)
			end
			local s = rawget(t, "_serialized")
			if s[k] ~= nil then return s[k] end
			return def[k]
		end,
		__newindex = function(t, k, v)
			local def = rawget(t, "_definition")
			local fieldDef = def.SerializedFields[k]
			if fieldDef then
				local attrName = Component.attrFor(def.ComponentName, k)
				if fieldDef.type == "instance" then
					local uid = v and InstanceRegistry.bind(v) or ""
					t.Instance:SetAttribute(attrName, uid)
				elseif fieldDef.type == "component" then
					-- Accept either a sibling component table (use its
					-- .Instance) or a bare Instance — both round-trip
					-- through the same uid storage.
					local inst = v and (typeof(v) == "Instance" and v or v.Instance)
					local uid = inst and InstanceRegistry.bind(inst) or ""
					t.Instance:SetAttribute(attrName, uid)
				elseif fieldDef.type == "composite" then
					-- Whole-composite replace: route each leaf through
					-- the cached proxy so nested composites recurse.
					local proxy = rawget(t, "_serialized")[k]
					for subName in pairs(fieldDef.fields) do
						proxy[subName] = v[subName]
					end
				elseif fieldDef.type == "list" then
					-- List assignment is runtime-only (Unity-like). The
					-- cache holds the new array; storage is untouched.
					-- Use the inspector to persist.
					rawget(t, "_serialized")[k] = v
				else
					t.Instance:SetAttribute(attrName, v)
				end
			else
				rawset(t, k, v)
			end
		end,
	})
end

-- Tears down a component instance. Disconnects attribute listeners and
-- gives subclasses a chance to clean up via OnDestroy. The Roblox tag
-- itself is removed by the runtime that called us — we don't touch
-- CollectionService here to keep this function side-effect-free
-- relative to the caller.
function Component.destroy(component)
	if component.OnDestroy then
		local ok, err = pcall(component.OnDestroy, component)
		if not ok then
			warn("[Components] OnDestroy errored:", err)
		end
	end
	for _, conn in ipairs(component._connections) do
		conn:Disconnect()
	end
end

return Component
