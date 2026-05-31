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

local Component = {}
Component.__index = Component

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

	-- Read each field from its attribute; write the default first if
	-- the instance doesn't have a value yet so the inspector shows
	-- something sensible.
	for fieldName, fieldDef in pairs(definition.SerializedFields) do
		local attrName = Component.attrFor(definition.ComponentName, fieldName)
		local current = instance:GetAttribute(attrName)
		if current == nil then
			instance:SetAttribute(attrName, fieldDef.default)
			current = fieldDef.default
		end
		serialized[fieldName] = current

		-- External attribute edits (e.g. inspector drag during play)
		-- push back into `self` via the metatable. The component itself
		-- can read `self.X` and always see the latest value.
		local conn = instance:GetAttributeChangedSignal(attrName):Connect(function()
			serialized[fieldName] = instance:GetAttribute(attrName)
		end)
		table.insert(connections, conn)
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
			local s = rawget(t, "_serialized")
			if s[k] ~= nil then return s[k] end
			return rawget(t, "_definition")[k]
		end,
		__newindex = function(t, k, v)
			local def = rawget(t, "_definition")
			if def.SerializedFields[k] then
				local attrName = Component.attrFor(def.ComponentName, k)
				t.Instance:SetAttribute(attrName, v)
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
