-- Component Editor Studio plugin.
--
-- Walks the DataModel's compiler-emitted containers (ReplicatedStorage,
-- ServerScriptService, StarterPlayer.StarterPlayerScripts) for every
-- ModuleScript whose returned table has a `ComponentName` field — the
-- shape `Component.define(name)` produces. Shows an inspector for the
-- currently-selected Instance: list of attached components, the
-- ability to add/remove them, and a typed editor for each SerializedField.
--
-- Earlier versions read from a fixed `Plugins.Components.Definitions`
-- subtree, but the runtime refactor that made ComponentsService DI-driven
-- removed that subtree. Definitions now live wherever the user's source
-- lowered them to, so we scan for them by shape instead of by path.
--
-- Visually styled to match Studio's native Properties panel — same dark
-- chrome, same section-header look, same row layout. Colors come from
-- the live StudioTheme so the plugin tracks Dark/Light theme switches.
--
-- The Add Component button at the bottom mirrors Unity: clicking it
-- overlays a small picker with a search box and a filterable list of
-- definitions not yet attached to the selected Instance.
--
-- Install: paste this file's contents into a Script under any of
-- ServerStorage / Workspace in Studio, right-click → "Save as Local Plugin".
-- See ../README.md for full instructions and the dev loop.

local plugin = plugin

local Selection = game:GetService("Selection")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local TAG_PREFIX = "Component:"

----------------------------------------------------------------------
-- Module-level state
--
-- Declared up here so deeper UI builders (buildComponentSection,
-- openPicker) can close over them — Lua locals don't hoist, so a
-- forward declaration further down would resolve as a global lookup
-- and silently fail.
----------------------------------------------------------------------

-- Per-component-name expanded state. Mirrors how Unity remembers
-- whether a section is folded across selection changes — sticky for
-- the lifetime of the Studio session. Default is expanded.
local sectionExpanded = {}

-- Per-composite-field expanded state, keyed by the flat attribute prefix
-- (e.g. "Player_stats_sub"). Sticky across selection / rebuilds.
local compositeExpanded = {}

-- Forward declaration. Assigned near the bottom of the file once
-- `widget` and `build` exist. Click handlers reference this through
-- the closure so they see the assigned function at call time, not
-- the nil at definition time.
local refresh

-- Forward declaration. Assigned once `plugin:CreateDockWidgetPluginGui`
-- runs near the bottom. UI builders defined further up (e.g.
-- createEnumEditor's openDropdown) close over this name so dropdowns
-- can parent themselves to the dock widget and position relative to
-- its AbsolutePosition.
local widget

-- Currently-armed instance picker, or nil. While non-nil, the next
-- selection that satisfies the constraint is treated as the pick
-- (not as a normal "show the selection's components" rebuild).
--   { ownerInstance, attrName, constraint, button, label }
local armedPicker

----------------------------------------------------------------------
-- Theme
--
-- Studio exposes a palette via settings().Studio.Theme so plugins
-- automatically track Dark/Light theme switches. Wrap GetColor in a
-- small helper so every UI element is theme-aware and a ThemeChanged
-- event triggers a single rebuild.
----------------------------------------------------------------------

local studio = settings().Studio

local function color(name, modifier)
	return studio.Theme:GetColor(
		Enum.StudioStyleGuideColor[name],
		modifier and Enum.StudioStyleGuideModifier[modifier] or Enum.StudioStyleGuideModifier.Default
	)
end

----------------------------------------------------------------------
-- Definitions discovery
----------------------------------------------------------------------

-- The three containers the compiler routes Rojo context mounts into:
-- src/shared → ReplicatedStorage, src/server → ServerScriptService,
-- src/client → StarterPlayer.StarterPlayerScripts. A user's `: Component`
-- class lowers to a ModuleScript in whichever of these contexts its
-- source file lived under, so scanning all three covers every possible
-- definition site without descending into Workspace (where user-placed
-- ModuleScripts could produce false positives).
local function discoveryRoots()
	local roots = { ReplicatedStorage, game:GetService("ServerScriptService") }
	local starterPlayer = game:FindFirstChild("StarterPlayer")
	local starterScripts = starterPlayer and starterPlayer:FindFirstChild("StarterPlayerScripts")
	if starterScripts then table.insert(roots, starterScripts) end
	return roots
end

-- Component.define(name) returns a table with a string `ComponentName`
-- field — that's the only shape signal we need. pcall guards against
-- require errors (cyclic deps, runtime-only side effects firing in
-- Edit mode, ...) so a single broken module can't take down the
-- whole inspector.
--
-- Source pre-filter: we read each ModuleScript.Source and only
-- require modules that actually mention `Component.define` or
-- `ComponentName`. Without the filter, every refresh would require
-- every ModuleScript in ReplicatedStorage / ServerScriptService /
-- StarterPlayerScripts — including unrelated files whose top-level
-- side effects (network preludes creating RemoteEvents in Edit mode,
-- DataStore warmups, ...) would leave persistent garbage in the
-- place file.
local function looksLikeComponentSource(moduleScript)
	local ok, source = pcall(function() return moduleScript.Source end)
	if not ok or type(source) ~= "string" then return false end
	return string.find(source, "Component.define", 1, true) ~= nil
		or string.find(source, "ComponentName", 1, true) ~= nil
end

local function loadDefinitions()
	local defs = {}
	for _, root in ipairs(discoveryRoots()) do
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("ModuleScript") and looksLikeComponentSource(descendant) then
				local ok, mod = pcall(require, descendant)
				if ok and type(mod) == "table"
					and type(mod.ComponentName) == "string" then
					defs[mod.ComponentName] = mod
				end
			end
		end
	end
	return defs
end

-- Re-fires `refresh` whenever a Component definition's source changes
-- or a new ModuleScript appears / disappears under any discovery root.
-- Without this, editing a [SerializedField] in C# + recompiling would
-- leave the inspector showing stale fields until the user re-selected
-- the part. All listeners land on `tasks` and get disconnected on the
-- next rebuild's runCleanup.
local function wireSchemaWatchers(tasks)
	for _, root in ipairs(discoveryRoots()) do
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("ModuleScript") and looksLikeComponentSource(descendant) then
				local conn = descendant:GetPropertyChangedSignal("Source"):Connect(refresh)
				table.insert(tasks, function() conn:Disconnect() end)
			end
		end
		local addConn = root.DescendantAdded:Connect(function(d)
			if d:IsA("ModuleScript") then refresh() end
		end)
		local rmConn = root.DescendantRemoving:Connect(function(d)
			if d:IsA("ModuleScript") then refresh() end
		end)
		table.insert(tasks, function() addConn:Disconnect() end)
		table.insert(tasks, function() rmConn:Disconnect() end)
	end
end

----------------------------------------------------------------------
-- UI factory helpers
--
-- Tiny wrappers so the build code below reads like a hierarchy of
-- intent rather than a wall of Instance.new + property assignment.
----------------------------------------------------------------------

local function makeFrame(props)
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = props.color or color("MainBackground")
	frame.BackgroundTransparency = props.transparency or 0
	frame.Size = props.size or UDim2.new(1, 0, 0, 22)
	frame.Position = props.position or UDim2.new()
	frame.Parent = props.parent
	return frame
end

local function makeLabel(props)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = props.text or ""
	label.TextColor3 = props.color or color("MainText")
	label.TextXAlignment = props.align or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Font = props.font or Enum.Font.SourceSans
	label.TextSize = props.size or 14
	label.Size = props.frameSize or UDim2.new(1, 0, 1, 0)
	label.Position = props.position or UDim2.new()
	label.Parent = props.parent
	return label
end

local function makePadding(parent, left, right, top, bottom)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, left or 0)
	pad.PaddingRight = UDim.new(0, right or 0)
	pad.PaddingTop = UDim.new(0, top or 0)
	pad.PaddingBottom = UDim.new(0, bottom or 0)
	pad.Parent = parent
	return pad
end

local function makeStroke(parent, c)
	local stroke = Instance.new("UIStroke")
	stroke.Color = c or color("Border")
	stroke.Thickness = 1
	stroke.Parent = parent
	return stroke
end

----------------------------------------------------------------------
-- Field editors
--
-- Each editor produces a row Frame matching the Properties panel
-- layout: a label on the left (~40% width) and the editor widget on
-- the right. Each returns a cleanup function so the rebuild can
-- disconnect AttributeChangedSignal listeners on every redraw.
----------------------------------------------------------------------

-- Fixed dark palette — explicitly chosen hex so the inspector reads
-- the same across Studio's Dark/Light theme switches. If we ever want
-- light-theme support we swap these for theme-color lookups again.
local FIELD_COLOR     = Color3.fromHex("#191A1F")
local HEADER_COLOR    = Color3.fromHex("#202227")
local SEPARATOR_COLOR = Color3.fromHex("#202227")
local FIELD_HOVER     = HEADER_COLOR
local ADD_BUTTON_COLOR = Color3.fromHex("#335FFF")

-- Roblox-uploaded Material Icons. Public marketplace assets — work
-- in every plugin without a per-creator upload. Swap any of these to
-- your own art if you'd rather.
local DROPDOWN_ARROW = "rbxassetid://6034818372" -- arrow_drop_down
local COMPONENT_ICON = "rbxassetid://76707619028941"

local function pageColor()    return color("MainBackground") end
local function cardColor()    return FIELD_COLOR end
local function inputBg()      return color("Dark") end
local function rowHoverColor() return FIELD_HOVER end

local function roundCorners(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 6)
	corner.Parent = parent
	return corner
end

-- Wraps a mutation so it lands on Studio's undo stack. TryBeginRecording
-- returns a session identifier or nil if another recording is in flight;
-- in the nil case we still run the mutation so the edit isn't lost — it
-- just won't be undoable. Errors inside `fn` cancel the recording instead
-- of committing a half-applied change.
local function recordChange(name, fn)
	local id = ChangeHistoryService:TryBeginRecording(name)
	if not id then
		fn()
		return
	end
	local ok, err = pcall(fn)
	if ok then
		ChangeHistoryService:FinishRecording(id, Enum.FinishRecordingOperation.Commit)
	else
		ChangeHistoryService:FinishRecording(id, Enum.FinishRecordingOperation.Cancel)
		warn("[Components] " .. name .. " errored: " .. tostring(err))
	end
end

-- Compo-style field row: 100px fixed-width label on the left, editor
-- slot on the right that claims the remaining width via UIFlexItem.
-- Composite-leaf rows pass depth>0 to widen the label column so nested
-- fields line up under their parent foldout instead of under the
-- chevron.
-- Studio Properties-style row: TableItem background, 40%/60% split
-- with a 1px vertical `Border` divider at the boundary. Label sits in
-- the left 40% with a small left indent (deepens with `depth` for
-- nested composite leaves). Value slot is the right 60%, transparent
-- so editor children see the row's background through.
-- Column geometry mirrors Studio's Properties panel: divider at 45%,
-- label column indented 18px on the left so labels align under their
-- section header's name (depth nesting widens the indent for composite
-- leaves). Row height 22px matches Studio's row pitch.
local LABEL_COLUMN_RATIO = 0.45
local LABEL_INDENT       = 18

local function buildFieldRow(parent, fieldName, _rowIndex, depth)
	depth = depth or 0
	local indent = LABEL_INDENT + depth * 12

	local row = Instance.new("Frame")
	row.BackgroundColor3 = FIELD_COLOR
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, 22)
	row.Parent = parent

	row.Active = true
	row.MouseEnter:Connect(function() row.BackgroundColor3 = FIELD_HOVER end)
	row.MouseLeave:Connect(function() row.BackgroundColor3 = FIELD_COLOR end)

	makeLabel({
		parent = row,
		text = fieldName,
		color = color("MainText"),
		frameSize = UDim2.new(LABEL_COLUMN_RATIO, -indent, 1, 0),
		position = UDim2.new(0, indent, 0, 0),
	})

	local divider = Instance.new("Frame")
	divider.BackgroundColor3 = SEPARATOR_COLOR
	divider.BorderSizePixel = 0
	divider.Size = UDim2.new(0, 1, 1, 0)
	divider.Position = UDim2.new(LABEL_COLUMN_RATIO, 0, 0, 0)
	divider.Parent = row

	local bottomLine = Instance.new("Frame")
	bottomLine.BackgroundColor3 = SEPARATOR_COLOR
	bottomLine.BorderSizePixel = 0
	bottomLine.AnchorPoint = Vector2.new(0, 1)
	bottomLine.Size = UDim2.new(1, 0, 0, 1)
	bottomLine.Position = UDim2.new(0, 0, 1, 0)
	bottomLine.Parent = row

	local valueSlot = Instance.new("Frame")
	valueSlot.BackgroundTransparency = 1
	valueSlot.BorderSizePixel = 0
	valueSlot.Size = UDim2.new(1 - LABEL_COLUMN_RATIO, -1, 1, 0)
	valueSlot.Position = UDim2.new(LABEL_COLUMN_RATIO, 1, 0, 0)
	valueSlot.Parent = row
	makePadding(valueSlot, 4, 4, 0, 0)

	return row, valueSlot
end

-- Studio Properties-style text input: transparent background so the
-- row's TableItem color shows through, left-aligned, no padding (the
-- 4px slot padding handles inset), no corner radius. Mirrors how
-- Studio's own Properties panel renders Number/String fields.
local function makeValueTextBox(parent, initialText)
	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Text = initialText
	box.TextColor3 = color("MainText")
	box.PlaceholderColor3 = color("DimmedText")
	box.Font = Enum.Font.SourceSans
	box.TextSize = 14
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Center
	box.Size = UDim2.fromScale(1, 1)
	box.ClearTextOnFocus = false
	box.Parent = parent
	return box
end

local function createNumberEditor(parent, fieldName, instance, attrName, rowIndex, _fieldDef, depth)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex, depth)
	local box = makeValueTextBox(slot, tostring(instance:GetAttribute(attrName) or 0))

	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			recordChange("Set " .. fieldName, function()
				instance:SetAttribute(attrName, n)
			end)
		else
			-- User typed garbage; snap back to the real value.
			box.Text = tostring(instance:GetAttribute(attrName) or 0)
		end
	end)

	local conn = instance:GetAttributeChangedSignal(attrName):Connect(function()
		if not box:IsFocused() then
			box.Text = tostring(instance:GetAttribute(attrName) or 0)
		end
	end)
	return function() conn:Disconnect() end
end

local function createStringEditor(parent, fieldName, instance, attrName, rowIndex, _fieldDef, depth)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex, depth)
	local box = makeValueTextBox(slot, tostring(instance:GetAttribute(attrName) or ""))

	box.FocusLost:Connect(function()
		recordChange("Set " .. fieldName, function()
			instance:SetAttribute(attrName, box.Text)
		end)
	end)
	local conn = instance:GetAttributeChangedSignal(attrName):Connect(function()
		if not box:IsFocused() then
			box.Text = tostring(instance:GetAttribute(attrName) or "")
		end
	end)
	return function() conn:Disconnect() end
end

-- Studio Properties-style checkbox: 14×14 square at the left of the
-- value column. CheckedFieldBackground + 1px CheckedFieldBorder
-- stroke; unicode ✓ when set, blank when not.
local function createBooleanEditor(parent, fieldName, instance, attrName, rowIndex, _fieldDef, depth)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex, depth)

	local toggle = Instance.new("TextButton")
	toggle.BackgroundColor3 = color("CheckedFieldBackground")
	toggle.BorderSizePixel = 0
	toggle.AutoButtonColor = false
	toggle.Text = ""
	toggle.TextColor3 = color("MainText")
	toggle.Font = Enum.Font.SourceSansBold
	toggle.TextSize = 14
	toggle.Size = UDim2.fromOffset(16, 16)
	toggle.AnchorPoint = Vector2.new(0, 0.5)
	toggle.Position = UDim2.new(0, 0, 0.5, 0)
	toggle.Parent = slot

	local toggleStroke = Instance.new("UIStroke")
	toggleStroke.Color = color("CheckedFieldBorder")
	toggleStroke.Thickness = 1
	toggleStroke.Parent = toggle

	local function refresh()
		toggle.Text = instance:GetAttribute(attrName) and "✓" or ""
	end
	refresh()

	toggle.MouseButton1Click:Connect(function()
		recordChange("Toggle " .. fieldName, function()
			instance:SetAttribute(attrName, not instance:GetAttribute(attrName))
		end)
	end)
	local conn = instance:GetAttributeChangedSignal(attrName):Connect(refresh)
	return function() conn:Disconnect() end
end

-- Shared helper for Vector3/Color3 multi-component editors. Builds a
-- horizontal row of [label, transparent textbox] pairs inside the
-- value slot; each pair invokes `onCommit(axisIndex, newNumber)` on
-- FocusLost. Returns a `paint(values)` closure the caller invokes
-- whenever the stored value changes so the textboxes reflect it.
local function makeAxisRow(slot, axes)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.fromScale(1, 1)
	row.Parent = slot

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	local boxes = {}
	for i, axis in ipairs(axes) do
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Text = axis
		label.TextColor3 = color("DimmedText")
		label.Font = Enum.Font.SourceSans
		label.TextSize = 14
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.Size = UDim2.fromOffset(10, 22)
		label.LayoutOrder = i * 2 - 1
		label.Parent = row

		local box = Instance.new("TextBox")
		box.BackgroundTransparency = 1
		box.BorderSizePixel = 0
		box.Text = ""
		box.TextColor3 = color("MainText")
		box.PlaceholderColor3 = color("DimmedText")
		box.Font = Enum.Font.SourceSans
		box.TextSize = 14
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.TextYAlignment = Enum.TextYAlignment.Center
		box.ClearTextOnFocus = false
		box.Size = UDim2.new(1 / #axes, -14, 1, 0)
		box.LayoutOrder = i * 2
		box.Parent = row

		boxes[i] = box
	end

	return boxes
end

local function createVector3Editor(parent, fieldName, instance, attrName, rowIndex, _fieldDef, depth)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex, depth)
	local boxes = makeAxisRow(slot, { "X", "Y", "Z" })

	local function paint()
		local v = instance:GetAttribute(attrName)
		if typeof(v) ~= "Vector3" then v = Vector3.zero end
		for i, axisValue in ipairs({ v.X, v.Y, v.Z }) do
			if not boxes[i]:IsFocused() then
				boxes[i].Text = tostring(axisValue)
			end
		end
	end
	paint()

	local function commit()
		local x = tonumber(boxes[1].Text) or 0
		local y = tonumber(boxes[2].Text) or 0
		local z = tonumber(boxes[3].Text) or 0
		recordChange("Set " .. fieldName, function()
			instance:SetAttribute(attrName, Vector3.new(x, y, z))
		end)
	end

	for _, box in ipairs(boxes) do
		box.FocusLost:Connect(commit)
	end
	local conn = instance:GetAttributeChangedSignal(attrName):Connect(paint)
	return function() conn:Disconnect() end
end

-- Color3 stored as a native Color3 attribute. Editor shows a small
-- swatch at the left of the value slot then a single hex textbox
-- (#RRGGBB) on the right — matches the way Studio's color picker
-- summarises a Color3 and lines up with most designers' workflow.
local function colorToHex(c)
	return string.format("#%02X%02X%02X",
		math.clamp(math.floor(c.R * 255 + 0.5), 0, 255),
		math.clamp(math.floor(c.G * 255 + 0.5), 0, 255),
		math.clamp(math.floor(c.B * 255 + 0.5), 0, 255))
end

local function createColor3Editor(parent, fieldName, instance, attrName, rowIndex, _fieldDef, depth)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex, depth)

	local swatch = Instance.new("Frame")
	swatch.BorderSizePixel = 0
	swatch.AnchorPoint = Vector2.new(0, 0.5)
	swatch.Position = UDim2.new(0, 0, 0.5, 0)
	swatch.Size = UDim2.fromOffset(16, 16)
	swatch.Parent = slot
	roundCorners(swatch, 3)

	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Text = ""
	box.TextColor3 = color("MainText")
	box.PlaceholderColor3 = color("DimmedText")
	box.Font = Enum.Font.SourceSans
	box.TextSize = 14
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Center
	box.ClearTextOnFocus = false
	box.Position = UDim2.fromOffset(20, 0)
	box.Size = UDim2.new(1, -20, 1, 0)
	box.Parent = slot

	local function paint()
		local c = instance:GetAttribute(attrName)
		if typeof(c) ~= "Color3" then c = Color3.new() end
		swatch.BackgroundColor3 = c
		if not box:IsFocused() then
			box.Text = colorToHex(c)
		end
	end
	paint()

	box.FocusLost:Connect(function()
		local ok, c = pcall(Color3.fromHex, box.Text)
		if ok and typeof(c) == "Color3" then
			recordChange("Set " .. fieldName, function()
				instance:SetAttribute(attrName, c)
			end)
		else
			paint() -- snap back to last good value
		end
	end)
	local conn = instance:GetAttributeChangedSignal(attrName):Connect(paint)
	return function() conn:Disconnect() end
end

-- Instance-ref helpers. Mirror runtime/InstanceRegistry.luau but
-- scoped to the plugin so edit-time picks don't depend on the runtime
-- service being booted. The "_uid" attribute is the same on-Instance
-- handle the runtime uses, so picks made here are visible at play.
local function bindUid(inst)
	local uid = inst:GetAttribute("_uid")
	if typeof(uid) ~= "string" or uid == "" then
		uid = HttpService:GenerateGUID(false)
		inst:SetAttribute("_uid", uid)
	end
	return uid
end

local function resolveByUid(uid)
	if typeof(uid) ~= "string" or uid == "" then return nil end
	for _, root in ipairs({ Workspace, ReplicatedStorage }) do
		if root:GetAttribute("_uid") == uid then return root end
		for _, d in ipairs(root:GetDescendants()) do
			if d:GetAttribute("_uid") == uid then return d end
		end
	end
	return nil
end

local function disarmPicker()
	if not armedPicker then return end
	local p = armedPicker
	armedPicker = nil
	if p.button.Parent then
		p.button.Text = "Pick"
		p.button.BackgroundColor3 = color("Button")
	end
end

local function createInstanceEditor(parent, fieldName, instance, attrName, rowIndex, fieldDef, depth)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex, depth)
	local constraint = fieldDef.constraint or "Instance"
	-- "instance" picks any Instance whose ClassName IsA(constraint).
	-- "component" picks an Instance carrying the Component:<constraint>
	-- tag (validated in the SelectionChanged handler).
	local pickerKind = fieldDef.type == "component" and "component" or "instance"

	-- Class icon left of the name, sourced from Studio's own Explorer
	-- iconography via StudioService:GetClassIcon — Part shows the Part
	-- icon, Folder the Folder icon, etc. Hidden when the field is unset
	-- / dangling. ZIndex 2 keeps it on top of the click-target button.
	local classImg = Instance.new("ImageLabel")
	classImg.BackgroundTransparency = 1
	classImg.AnchorPoint = Vector2.new(0, 0.5)
	classImg.Position = UDim2.new(0, 0, 0.5, 0)
	classImg.Size = UDim2.fromOffset(16, 16)
	classImg.ZIndex = 2
	classImg.Visible = false
	classImg.Parent = slot

	-- Display label is a TextButton so clicking the field pings the
	-- referenced instance: Selection:Set() auto-scrolls Studio's
	-- Explorer to it and highlights it (Roblox's closest equivalent to
	-- Unity's "ping in hierarchy"). Covers the icon area too so a click
	-- on the icon counts; ImageLabel isn't interactive so clicks pass
	-- through to this button underneath.
	local display = Instance.new("TextButton")
	display.BackgroundTransparency = 1
	display.AutoButtonColor = false
	display.TextColor3 = color("MainText")
	display.Font = Enum.Font.SourceSans
	display.TextSize = 14
	display.TextXAlignment = Enum.TextXAlignment.Left
	display.TextTruncate = Enum.TextTruncate.AtEnd
	display.Size = UDim2.new(1, -110, 1, 0)
	display.Parent = slot

	local displayPad = Instance.new("UIPadding")
	displayPad.PaddingLeft = UDim.new(0, 20)
	displayPad.Parent = display

	local StudioService = game:GetService("StudioService")

	local function paintDisplay()
		local uid = instance:GetAttribute(attrName)
		local resolved = resolveByUid(uid)
		if resolved then
			local ok, info = pcall(function() return StudioService:GetClassIcon(resolved.ClassName) end)
			if ok and type(info) == "table" and info.Image then
				classImg.Image = info.Image
				if info.ImageRectOffset then classImg.ImageRectOffset = info.ImageRectOffset end
				if info.ImageRectSize then classImg.ImageRectSize = info.ImageRectSize end
				classImg.Visible = true
			else
				classImg.Visible = false
			end
			display.Text = resolved.Name
			display.TextColor3 = color("MainText")
		elseif typeof(uid) == "string" and uid ~= "" then
			classImg.Visible = false
			display.Text = "Missing"
			display.TextColor3 = color("ErrorText")
		else
			classImg.Visible = false
			display.Text = "(none)"
			display.TextColor3 = color("DimmedText")
		end
	end
	paintDisplay()

	-- Ping the referenced instance: disarm any pending picker first so
	-- the SelectionChanged handler doesn't reinterpret our Set() as a
	-- pick, then hand Selection the resolved instance. Studio's Explorer
	-- auto-scrolls + highlights, and our own SelectionChanged handler
	-- rebuilds the inspector for the new selection.
	display.MouseButton1Click:Connect(function()
		local uid = instance:GetAttribute(attrName)
		local resolved = resolveByUid(uid)
		if not resolved then return end
		disarmPicker()
		Selection:Set({ resolved })
	end)

	local pick = Instance.new("TextButton")
	pick.BackgroundColor3 = color("Button")
	pick.BorderColor3 = color("Border")
	pick.BorderSizePixel = 1
	pick.Text = "Pick"
	pick.TextColor3 = color("ButtonText")
	pick.Font = Enum.Font.SourceSans
	pick.TextSize = 13
	pick.Size = UDim2.new(0, 50, 0, 18)
	pick.Position = UDim2.new(1, -106, 0.5, -9)
	pick.AutoButtonColor = true
	pick.Parent = slot

	local clear = Instance.new("TextButton")
	clear.BackgroundColor3 = color("Button")
	clear.BorderColor3 = color("Border")
	clear.BorderSizePixel = 1
	clear.Text = "Clear"
	clear.TextColor3 = color("ButtonText")
	clear.Font = Enum.Font.SourceSans
	clear.TextSize = 13
	clear.Size = UDim2.new(0, 50, 0, 18)
	clear.Position = UDim2.new(1, -52, 0.5, -9)
	clear.AutoButtonColor = true
	clear.Parent = slot

	pick.MouseButton1Click:Connect(function()
		if armedPicker and armedPicker.button == pick then
			disarmPicker()
			return
		end
		disarmPicker()
		armedPicker = {
			ownerInstance = instance,
			attrName = attrName,
			constraint = constraint,
			kind = pickerKind,
			button = pick,
			label = display,
		}
		pick.Text = "Cancel"
		pick.BackgroundColor3 = color("DialogMainButton")
	end)

	clear.MouseButton1Click:Connect(function()
		disarmPicker()
		recordChange("Clear " .. fieldName, function()
			instance:SetAttribute(attrName, "")
		end)
	end)

	local conn = instance:GetAttributeChangedSignal(attrName):Connect(paintDisplay)
	return function() conn:Disconnect() end
end

-- Property-drawer registry. Each drawer is a function with the
-- signature:
--   draw(parent, fieldName, instance, attrName, rowIndex, fieldDef, depth)
--     -> cleanupFn
-- Built-ins are registered below. Custom drawers picked up from user
-- ModuleScripts override built-ins (later registration wins).
--
-- Resolution: a fieldDef with `constraint` first tries the specific
-- key `<type>:<constraint>` (e.g. "enum:MoveState"), then falls back
-- to the base type (`"enum"`). This lets a user drop in a drawer just
-- for one enum without redefining the default enum picker.
local drawerRegistry = {}

local function registerDrawer(key, fn)
	drawerRegistry[key] = fn
end

local function resolveDrawer(fieldDef)
	if fieldDef.constraint then
		local specific = drawerRegistry[fieldDef.type .. ":" .. fieldDef.constraint]
		if specific then return specific end
	end
	return drawerRegistry[fieldDef.type]
end

registerDrawer("number", createNumberEditor)
registerDrawer("string", createStringEditor)
registerDrawer("boolean", createBooleanEditor)
registerDrawer("vector3", createVector3Editor)
registerDrawer("color3", createColor3Editor)
registerDrawer("instance", createInstanceEditor)
registerDrawer("component", createInstanceEditor)

-- Scans user code roots for ModuleScripts shaped like:
--   return { DrawerFor = "<key>", Draw = function(...) ... end }
-- and registers each one. Source pre-filter avoids requiring random
-- modules. Called once per build() so newly-saved drawer files pick
-- up at the next refresh (within the limits of ModuleScript caching).
local function looksLikeDrawerSource(moduleScript)
	local ok, source = pcall(function() return moduleScript.Source end)
	if not ok or type(source) ~= "string" then return false end
	return string.find(source, "DrawerFor", 1, true) ~= nil
end

local function loadCustomDrawers()
	for _, root in ipairs(discoveryRoots()) do
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("ModuleScript") and looksLikeDrawerSource(descendant) then
				local ok, mod = pcall(require, descendant)
				if ok and type(mod) == "table"
					and type(mod.DrawerFor) == "string"
					and type(mod.Draw) == "function" then
					registerDrawer(mod.DrawerFor, mod.Draw)
				end
			end
		end
	end
end

-- Composite (nested-POCO) editor. Renders a foldout header at this
-- depth; expanded, recurses into each child via EDITORS at depth+1.
-- Children's attribute names extend the parent prefix with "_<child>",
-- matching the flat layout the lowering emits.
local function createCompositeEditor(parent, fieldName, instance, attrName, _rowIndex, fieldDef, depth)
	depth = depth or 0
	local labelX = 24 + depth * 12

	local key = attrName
	local expanded = compositeExpanded[key]
	if expanded == nil then expanded = true end

	local row = Instance.new("TextButton")
	row.BackgroundColor3 = cardColor()
	row.BorderSizePixel = 0
	row.Text = ""
	row.AutoButtonColor = false
	row.Size = UDim2.new(1, 0, 0, 22)
	row.Parent = parent

	local rowBottomLine = Instance.new("Frame")
	rowBottomLine.BackgroundColor3 = SEPARATOR_COLOR
	rowBottomLine.BorderSizePixel = 0
	rowBottomLine.AnchorPoint = Vector2.new(0, 1)
	rowBottomLine.Size = UDim2.new(1, 0, 0, 1)
	rowBottomLine.Position = UDim2.new(0, 0, 1, 0)
	rowBottomLine.Parent = row

	row.MouseEnter:Connect(function() row.BackgroundColor3 = rowHoverColor() end)
	row.MouseLeave:Connect(function() row.BackgroundColor3 = cardColor() end)

	makeLabel({
		parent = row,
		text = expanded and "▾" or "▸",
		color = color("MainText"),
		size = 14,
		frameSize = UDim2.new(0, 14, 1, 0),
		position = UDim2.new(0, labelX - 18, 0, 0),
	})
	makeLabel({
		parent = row,
		text = fieldName,
		color = color("MainText"),
		font = Enum.Font.SourceSansItalic,
		frameSize = UDim2.new(1, -labelX, 1, 0),
		position = UDim2.new(0, labelX, 0, 0),
	})

	row.MouseButton1Click:Connect(function()
		compositeExpanded[key] = not expanded
		refresh()
	end)

	if not expanded then return function() end end

	local childNames = {}
	for name in pairs(fieldDef.fields) do
		table.insert(childNames, name)
	end
	table.sort(childNames)

	local cleanups = {}
	for i, childName in ipairs(childNames) do
		local childDef = fieldDef.fields[childName]
		local childEditor = resolveDrawer(childDef)
		if childEditor then
			local childAttr = attrName .. "_" .. childName
			table.insert(cleanups,
				childEditor(parent, childName, instance, childAttr, i, childDef, depth + 1))
		end
	end

	return function()
		for _, fn in ipairs(cleanups) do
			pcall(fn)
		end
	end
end

registerDrawer("composite", createCompositeEditor)

-- Enum drawer: a closed-state button shows the current member name;
-- click opens a searchable dropdown anchored to the row. Storage is
-- the int ordinal (matches the converter's enum lowering — Idle = 0,
-- Running = 1, ...), so user code comparing `self.state == State.Idle`
-- works without translation.
local function createEnumEditor(parent, fieldName, instance, attrName, rowIndex, fieldDef, depth)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex, depth)
	local values = fieldDef.values or {}

	local nameByValue = {}
	for _, item in ipairs(values) do
		nameByValue[item.value] = item.name
	end

	-- Transparent button overlay: the row's FIELD_COLOR shows through
	-- so the dropdown reads as the row itself, not a separate boxed
	-- control. Name label sits at the slot's left edge, caret hugs the
	-- right; the row's hover still fires because Mouse{Enter,Leave}
	-- bubble through descendants.
	local button = Instance.new("TextButton")
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.Size = UDim2.fromScale(1, 1)
	button.Parent = slot

	local nameLabel = makeLabel({
		parent = button,
		text = "",
		color = color("MainText"),
		frameSize = UDim2.new(1, -18, 1, 0),
		position = UDim2.new(0, 0, 0, 0),
	})

	local caret = Instance.new("ImageLabel")
	caret.BackgroundTransparency = 1
	caret.Image = DROPDOWN_ARROW
	caret.ImageColor3 = color("MainText")
	caret.ScaleType = Enum.ScaleType.Fit
	caret.AnchorPoint = Vector2.new(1, 0.5)
	caret.Position = UDim2.new(1, 0, 0.5, 0)
	caret.Size = UDim2.fromOffset(14, 14)
	caret.Parent = button

	local function paintName()
		local cur = instance:GetAttribute(attrName)
		nameLabel.Text = nameByValue[cur] or "?"
	end
	paintName()

	local dropdown
	local backdrop
	local function closeDropdown()
		if dropdown then dropdown:Destroy() dropdown = nil end
		if backdrop then backdrop:Destroy() backdrop = nil end
	end

	local function openDropdown()
		closeDropdown()

		local btnAbsPos = button.AbsolutePosition
		local btnAbsSize = button.AbsoluteSize
		local widgetAbsPos = widget.AbsolutePosition

		-- Backdrop catches clicks outside the popup to close it; pure
		-- input target, invisible.
		backdrop = Instance.new("TextButton")
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.BackgroundTransparency = 1
		backdrop.Text = ""
		backdrop.AutoButtonColor = false
		backdrop.ZIndex = 49
		backdrop.Parent = widget
		backdrop.MouseButton1Click:Connect(closeDropdown)

		dropdown = Instance.new("Frame")
		dropdown.BackgroundColor3 = cardColor()
		dropdown.BorderSizePixel = 0
		dropdown.ZIndex = 50
		dropdown.Size = UDim2.new(0, btnAbsSize.X, 0, math.min(220, 36 + #values * 22))
		dropdown.Position = UDim2.new(
			0, btnAbsPos.X - widgetAbsPos.X,
			0, btnAbsPos.Y - widgetAbsPos.Y + btnAbsSize.Y + 2)
		dropdown.Parent = widget
		roundCorners(dropdown, 6)
		makeStroke(dropdown, color("Border"))

		local searchHost = makeFrame({
			parent = dropdown,
			color = cardColor(),
			size = UDim2.new(1, -8, 0, 24),
			position = UDim2.new(0, 4, 0, 4),
		})
		searchHost.ZIndex = 51
		roundCorners(searchHost, 4)
		makePadding(searchHost, 8, 8, 0, 0)

		local searchBox = Instance.new("TextBox")
		searchBox.BackgroundTransparency = 1
		searchBox.PlaceholderText = "Search…"
		searchBox.PlaceholderColor3 = color("DimmedText")
		searchBox.Text = ""
		searchBox.TextColor3 = color("MainText")
		searchBox.Font = Enum.Font.SourceSans
		searchBox.TextSize = 14
		searchBox.TextXAlignment = Enum.TextXAlignment.Left
		searchBox.Size = UDim2.fromScale(1, 1)
		searchBox.ZIndex = 51
		searchBox.ClearTextOnFocus = false
		searchBox.Parent = searchHost

		local list = Instance.new("ScrollingFrame")
		list.Size = UDim2.new(1, -8, 1, -36)
		list.Position = UDim2.new(0, 4, 0, 32)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.CanvasSize = UDim2.new()
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.ZIndex = 51
		list.Parent = dropdown

		local listLayout = Instance.new("UIListLayout")
		listLayout.Padding = UDim.new(0, 1)
		listLayout.Parent = list

		local function rebuildItems()
			for _, c in ipairs(list:GetChildren()) do
				if c:IsA("TextButton") then c:Destroy() end
			end
			local query = searchBox.Text:lower()
			for _, item in ipairs(values) do
				if query == "" or item.name:lower():find(query, 1, true) then
					local row = Instance.new("TextButton")
					row.BackgroundColor3 = cardColor()
					row.BackgroundTransparency = 1
					row.BorderSizePixel = 0
					row.Text = item.name
					row.TextColor3 = color("MainText")
					row.Font = Enum.Font.SourceSans
					row.TextSize = 14
					row.TextXAlignment = Enum.TextXAlignment.Left
					row.Size = UDim2.new(1, 0, 0, 20)
					row.AutoButtonColor = false
					row.ZIndex = 51
					row.Parent = list

					local rowPad = Instance.new("UIPadding")
					rowPad.PaddingLeft = UDim.new(0, 8)
					rowPad.Parent = row

					row.MouseEnter:Connect(function() row.BackgroundTransparency = 0 end)
					row.MouseLeave:Connect(function() row.BackgroundTransparency = 1 end)

					row.MouseButton1Click:Connect(function()
						recordChange("Set " .. fieldName .. " = " .. item.name, function()
							instance:SetAttribute(attrName, item.value)
						end)
						closeDropdown()
					end)
				end
			end
		end

		searchBox:GetPropertyChangedSignal("Text"):Connect(rebuildItems)
		rebuildItems()
		searchBox:CaptureFocus()
	end

	button.MouseButton1Click:Connect(function()
		if dropdown then closeDropdown() else openDropdown() end
	end)

	local conn = instance:GetAttributeChangedSignal(attrName):Connect(paintName)
	return function()
		conn:Disconnect()
		closeDropdown()
	end
end

registerDrawer("enum", createEnumEditor)

-- Walks a list element's shape, calling `cb(relPath)` once per leaf
-- attribute under the element. For a primitive/instance/enum element
-- the only leaf is "" (the element's own prefix); composite elements
-- recurse through their fields.
local function forEachLeafRelPath(elementDef, accPath, cb)
	if elementDef.type == "composite" then
		for fieldName, fieldDef in pairs(elementDef.fields) do
			forEachLeafRelPath(fieldDef, accPath .. "_" .. fieldName, cb)
		end
	else
		cb(accPath)
	end
end

local function initElementDefaults(instance, prefix, elementDef)
	if elementDef.type == "composite" then
		for fieldName, fieldDef in pairs(elementDef.fields) do
			initElementDefaults(instance, prefix .. "_" .. fieldName, fieldDef)
		end
	else
		instance:SetAttribute(prefix, elementDef.default)
	end
end

local function initFieldDefaults(instance, prefix, fieldDef)
	if fieldDef.type == "composite" then
		for childName, childDef in pairs(fieldDef.fields) do
			initFieldDefaults(instance, prefix .. "_" .. childName, childDef)
		end
	elseif fieldDef.type == "list" then
		instance:SetAttribute(prefix .. "_Count", 0)
	else
		instance:SetAttribute(prefix, fieldDef.default)
	end
end

-- Recursively unsets every attribute that backs a serialized field —
-- including composite leaves (any depth) and list elements (1..Count).
-- Used when a component is removed so no orphan attributes linger to
-- pollute a future re-add.
local function clearFieldAttributes(instance, prefix, fieldDef)
	if fieldDef.type == "composite" then
		for childName, childDef in pairs(fieldDef.fields) do
			clearFieldAttributes(instance, prefix .. "_" .. childName, childDef)
		end
	elseif fieldDef.type == "list" then
		local count = instance:GetAttribute(prefix .. "_Count") or 0
		for i = 1, count do
			clearFieldAttributes(instance, prefix .. "_" .. i, fieldDef.element)
		end
		instance:SetAttribute(prefix .. "_Count", nil)
	else
		instance:SetAttribute(prefix, nil)
	end
end

-- List drawer: foldout header with "+", per-element row delegated to
-- the element type's own drawer, plus a "×" button overlaid per element
-- for removal. Removal shifts later elements down and clears the now-
-- orphan last slot. Add appends with defaults.
local function createListEditor(parent, fieldName, instance, attrName, _rowIndex, fieldDef, depth)
	depth = depth or 0
	local labelX = 14 + depth * 14
	local elementDef = fieldDef.element

	local key = attrName
	local expanded = compositeExpanded[key]
	if expanded == nil then expanded = false end

	local count = instance:GetAttribute(attrName .. "_Count") or 0

	local header = Instance.new("TextButton")
	header.BackgroundColor3 = cardColor()
	header.BorderSizePixel = 0
	header.Text = ""
	header.AutoButtonColor = false
	header.Size = UDim2.new(1, 0, 0, 24)
	header.Parent = parent

	local headerBottomLine = Instance.new("Frame")
	headerBottomLine.BackgroundColor3 = SEPARATOR_COLOR
	headerBottomLine.BorderSizePixel = 0
	headerBottomLine.AnchorPoint = Vector2.new(0, 1)
	headerBottomLine.Size = UDim2.new(1, 0, 0, 1)
	headerBottomLine.Position = UDim2.new(0, 0, 1, 0)
	headerBottomLine.Parent = header

	header.MouseEnter:Connect(function() header.BackgroundColor3 = rowHoverColor() end)
	header.MouseLeave:Connect(function() header.BackgroundColor3 = cardColor() end)

	makeLabel({
		parent = header,
		text = expanded and "▼" or "▶",
		color = color("MainText"),
		size = 10,
		frameSize = UDim2.new(0, 14, 1, 0),
		position = UDim2.new(0, labelX - 10, 0, 0),
		align = Enum.TextXAlignment.Center,
	})

	makeLabel({
		parent = header,
		text = fieldName .. "  [" .. count .. "]",
		color = color("MainText"),
		font = Enum.Font.SourceSansSemibold,
		frameSize = UDim2.new(1, -labelX - 40, 1, 0),
		position = UDim2.new(0, labelX + 8, 0, 0),
	})

	local addBtn = Instance.new("TextButton")
	addBtn.BackgroundColor3 = cardColor()
	addBtn.BorderSizePixel = 0
	addBtn.Text = "+"
	addBtn.TextColor3 = color("MainText")
	addBtn.Font = Enum.Font.SourceSansBold
	addBtn.TextSize = 16
	addBtn.Size = UDim2.new(0, 22, 0, 18)
	addBtn.Position = UDim2.new(1, -28, 0.5, -9)
	addBtn.AutoButtonColor = true
	addBtn.Parent = header
	roundCorners(addBtn, 4)

	addBtn.MouseButton1Click:Connect(function()
		recordChange("Add to " .. fieldName, function()
			local newCount = count + 1
			initElementDefaults(instance, attrName .. "_" .. newCount, elementDef)
			instance:SetAttribute(attrName .. "_Count", newCount)
		end)
		refresh()
	end)

	header.MouseButton1Click:Connect(function()
		compositeExpanded[key] = not expanded
		refresh()
	end)

	if not expanded or count == 0 then
		return function() end
	end

	local cleanups = {}
	for i = 1, count do
		-- Per-element slot: a layout-less outer Frame holds the element
		-- drawer (nested in `inner` so its UIListLayout doesn't try to
		-- stack the remove button) and the abs-positioned × button on
		-- the right. `inner` reserves 28px on the right via UIPadding so
		-- the drawer's row doesn't slip under the button.
		local slot = Instance.new("Frame")
		slot.BackgroundTransparency = 1
		slot.Size = UDim2.new(1, 0, 0, 24)
		slot.AutomaticSize = Enum.AutomaticSize.Y
		slot.Parent = parent

		local inner = Instance.new("Frame")
		inner.BackgroundTransparency = 1
		inner.Size = UDim2.new(1, 0, 0, 0)
		inner.AutomaticSize = Enum.AutomaticSize.Y
		inner.Parent = slot

		local innerLayout = Instance.new("UIListLayout")
		innerLayout.SortOrder = Enum.SortOrder.LayoutOrder
		innerLayout.Parent = inner

		local innerPad = Instance.new("UIPadding")
		innerPad.PaddingRight = UDim.new(0, 28)
		innerPad.Parent = inner

		local elementDrawer = resolveDrawer(elementDef)
		if elementDrawer then
			table.insert(cleanups,
				elementDrawer(inner, tostring(i), instance,
					attrName .. "_" .. i, i, elementDef, depth + 1))
		end

		local removeBtn = Instance.new("TextButton")
		removeBtn.BackgroundColor3 = cardColor()
		removeBtn.BorderSizePixel = 0
		removeBtn.Text = "×"
		removeBtn.TextColor3 = color("DimmedText")
		removeBtn.Font = Enum.Font.SourceSansBold
		removeBtn.TextSize = 16
		removeBtn.AnchorPoint = Vector2.new(1, 0)
		removeBtn.Size = UDim2.new(0, 20, 0, 18)
		removeBtn.Position = UDim2.new(1, -4, 0, 3)
		removeBtn.AutoButtonColor = true
		removeBtn.ZIndex = 5
		removeBtn.Parent = slot
		roundCorners(removeBtn, 4)

		local idx = i
		removeBtn.MouseButton1Click:Connect(function()
			recordChange("Remove from " .. fieldName, function()
				local last = count
				for j = idx, last - 1 do
					forEachLeafRelPath(elementDef, "", function(relPath)
						local from = attrName .. "_" .. (j + 1) .. relPath
						local to = attrName .. "_" .. j .. relPath
						instance:SetAttribute(to, instance:GetAttribute(from))
					end)
				end
				forEachLeafRelPath(elementDef, "", function(relPath)
					instance:SetAttribute(attrName .. "_" .. last .. relPath, nil)
				end)
				instance:SetAttribute(attrName .. "_Count", last - 1)
			end)
			refresh()
		end)
	end

	return function()
		for _, fn in ipairs(cleanups) do
			pcall(fn)
		end
	end
end

registerDrawer("list", createListEditor)

----------------------------------------------------------------------
-- Component section
--
-- Each attached component renders as a Properties-panel-style section:
-- a header bar with the name and a small remove control, followed by
-- the field rows.
----------------------------------------------------------------------

local function buildComponentSection(parent, instance, componentName, def, cleanupTasks)
	-- Sticky per-name expanded state. Default to expanded so a user
	-- adding a component for the first time sees its fields.
	local expanded = sectionExpanded[componentName]
	if expanded == nil then expanded = true end

	-- Studio Properties-panel look: a flat container that holds the
	-- section header band on top and the field rows beneath. No card
	-- chrome, no rounded corners, no UIStroke.
	local container = Instance.new("Frame")
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Size = UDim2.new(1, 0, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.Parent = parent

	local containerLayout = Instance.new("UIListLayout")
	containerLayout.FillDirection = Enum.FillDirection.Vertical
	containerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	containerLayout.Parent = container

	-- Section header band: 22px tall, darker `Titlebar`-toned strip
	-- with a triangle caret on the left and the component name to the
	-- right of it. × Remove control hugs the right edge.
	local header = Instance.new("TextButton")
	header.BackgroundColor3 = HEADER_COLOR
	header.BorderSizePixel = 0
	header.AutoButtonColor = false
	header.Text = ""
	header.Size = UDim2.new(1, 0, 0, 22)
	header.LayoutOrder = 0
	header.Parent = container

	makeLabel({
		parent = header,
		text = expanded and "▼" or "▶",
		color = color("MainText"),
		size = 10,
		frameSize = UDim2.new(0, 14, 1, 0),
		position = UDim2.new(0, 4, 0, 0),
		align = Enum.TextXAlignment.Center,
	})

	local componentIcon = Instance.new("ImageLabel")
	componentIcon.BackgroundTransparency = 1
	componentIcon.Image = COMPONENT_ICON
	componentIcon.ImageColor3 = color("MainText")
	componentIcon.ScaleType = Enum.ScaleType.Fit
	componentIcon.AnchorPoint = Vector2.new(0, 0.5)
	componentIcon.Position = UDim2.new(0, 20, 0.5, 0)
	componentIcon.Size = UDim2.fromOffset(14, 14)
	componentIcon.Parent = header

	makeLabel({
		parent = header,
		text = componentName,
		color = color("MainText"),
		font = Enum.Font.SourceSansSemibold,
		frameSize = UDim2.new(1, -60, 1, 0),
		position = UDim2.new(0, 38, 0, 0),
	})

	local removeBtn = Instance.new("TextButton")
	removeBtn.BackgroundTransparency = 1
	removeBtn.AutoButtonColor = false
	removeBtn.Text = "×"
	removeBtn.TextColor3 = color("DimmedText")
	removeBtn.Font = Enum.Font.SourceSans
	removeBtn.TextSize = 18
	removeBtn.Size = UDim2.fromOffset(20, 22)
	removeBtn.AnchorPoint = Vector2.new(1, 0)
	removeBtn.Position = UDim2.new(1, 0, 0, 0)
	removeBtn.Parent = header

	header.MouseButton1Click:Connect(function()
		sectionExpanded[componentName] = not expanded
		refresh()
	end)

	removeBtn.MouseButton1Click:Connect(function()
		recordChange("Remove " .. componentName, function()
			CollectionService:RemoveTag(instance, TAG_PREFIX .. componentName)
			for fieldName, fieldDef in pairs(def.SerializedFields or {}) do
				clearFieldAttributes(instance, componentName .. "_" .. fieldName, fieldDef)
			end
		end)
		refresh()
	end)

	if not expanded then return end

	-- Expanded body: no indent (Studio's properties panel runs full
	-- width), no inter-row gap (rows abut each other and rely on the
	-- 1px column divider + row background for visual separation).
	local body = Instance.new("Frame")
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.LayoutOrder = 1
	body.Parent = container

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.FillDirection = Enum.FillDirection.Vertical
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Parent = body

	-- Field rows. Iterate in a stable order so the layout doesn't shuffle
	-- between rebuilds; pairs() is hash-ordered which would jitter.
	local fieldNames = {}
	for name in pairs(def.SerializedFields or {}) do
		table.insert(fieldNames, name)
	end
	table.sort(fieldNames)

	for i, fieldName in ipairs(fieldNames) do
		local fieldDef = def.SerializedFields[fieldName]
		local editor = resolveDrawer(fieldDef)
		if editor then
			local attrName = componentName .. "_" .. fieldName
			table.insert(cleanupTasks, editor(body, fieldName, instance, attrName, i, fieldDef))
		else
			local row = makeFrame({
				parent = body,
				color = cardColor(),
				transparency = 1,
				size = UDim2.new(1, 0, 0, 22),
			})
			makeLabel({
				parent = row,
				text = fieldName .. " — unsupported type '" .. tostring(fieldDef.type) .. "'",
				color = color("DimmedText"),
			})
		end
	end
end

----------------------------------------------------------------------
-- Add Component picker (overlay)
--
-- Mirrors Unity's "Add Component" button: a single CTA at the bottom
-- opens a small popup with a search box and a filterable list of
-- definitions not yet attached.
----------------------------------------------------------------------

local pickerOverlay

local function closePicker()
	if pickerOverlay then
		pickerOverlay:Destroy()
		pickerOverlay = nil
	end
end

local function openPicker(host, instance, defs, attached)
	closePicker()

	local attachedSet = {}
	for _, name in ipairs(attached) do
		attachedSet[name] = true
	end

	-- Full-widget overlay with a centered card. Click on the dim background
	-- to dismiss; click-through to anything underneath would feel wrong.
	pickerOverlay = Instance.new("Frame")
	pickerOverlay.Size = UDim2.fromScale(1, 1)
	pickerOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	pickerOverlay.BackgroundTransparency = 0.4
	pickerOverlay.BorderSizePixel = 0
	pickerOverlay.ZIndex = 10
	pickerOverlay.Parent = host

	local dim = Instance.new("TextButton")
	dim.BackgroundTransparency = 1
	dim.Text = ""
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 10
	dim.Parent = pickerOverlay
	dim.MouseButton1Click:Connect(closePicker)

	local card = makeFrame({
		parent = pickerOverlay,
		color = color("MainBackground"),
		size = UDim2.new(1, -24, 0, 240),
		position = UDim2.new(0, 12, 1, -252),
	})
	card.ZIndex = 11
	makeStroke(card, color("Border"))

	-- Card header with title.
	local header = makeFrame({
		parent = card,
		color = color("CategoryItem"),
		size = UDim2.new(1, 0, 0, 24),
	})
	header.ZIndex = 11
	makeLabel({
		parent = header,
		text = "Add Component",
		color = color("BrightText"),
		font = Enum.Font.SourceSansBold,
		frameSize = UDim2.new(1, -12, 1, 0),
		position = UDim2.new(0, 8, 0, 0),
	}).ZIndex = 11

	-- Search input.
	local searchHost = makeFrame({
		parent = card,
		color = color("InputFieldBackground"),
		size = UDim2.new(1, -16, 0, 24),
		position = UDim2.new(0, 8, 0, 30),
	})
	searchHost.ZIndex = 11
	makeStroke(searchHost, color("Border"))
	makePadding(searchHost, 6, 6, 0, 0)

	local searchBox = Instance.new("TextBox")
	searchBox.BackgroundTransparency = 1
	searchBox.PlaceholderText = "Search…"
	searchBox.PlaceholderColor3 = color("DimmedText")
	searchBox.Text = ""
	searchBox.TextColor3 = color("MainText")
	searchBox.Font = Enum.Font.SourceSans
	searchBox.TextSize = 14
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.Size = UDim2.fromScale(1, 1)
	searchBox.ZIndex = 11
	searchBox.Parent = searchHost
	searchBox.ClearTextOnFocus = false

	-- Scrollable result list below the search box.
	local list = Instance.new("ScrollingFrame")
	list.Size = UDim2.new(1, -16, 1, -68)
	list.Position = UDim2.new(0, 8, 0, 60)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 4
	list.ZIndex = 11
	list.Parent = card

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = list

	-- Builds the filtered button list. Called on every search keystroke.
	local function renderList()
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("TextButton") then child:Destroy() end
		end

		local query = searchBox.Text:lower()
		local names = {}
		for name in pairs(defs) do
			if not attachedSet[name] then
				if query == "" or name:lower():find(query, 1, true) then
					table.insert(names, name)
				end
			end
		end
		table.sort(names)

		if #names == 0 then
			local empty = Instance.new("TextLabel")
			empty.BackgroundTransparency = 1
			empty.Text = query == ""
				and "(no other components available)"
				or string.format('No match for "%s"', searchBox.Text)
			empty.TextColor3 = color("DimmedText")
			empty.Font = Enum.Font.SourceSans
			empty.TextSize = 14
			empty.TextXAlignment = Enum.TextXAlignment.Left
			empty.Size = UDim2.new(1, 0, 0, 22)
			empty.ZIndex = 11
			empty.Parent = list
			return
		end

		for _, name in ipairs(names) do
			local row = Instance.new("TextButton")
			row.BackgroundColor3 = color("Button")
			row.BorderColor3 = color("Border")
			row.BorderSizePixel = 1
			row.Text = name
			row.TextColor3 = color("ButtonText")
			row.Font = Enum.Font.SourceSans
			row.TextSize = 14
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.Size = UDim2.new(1, 0, 0, 22)
			row.AutoButtonColor = true
			row.ZIndex = 11
			row.Parent = list

			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 8)
			pad.Parent = row

			row.MouseButton1Click:Connect(function()
				recordChange("Add " .. name, function()
					CollectionService:AddTag(instance, TAG_PREFIX .. name)
					local def = defs[name]
					for fieldName, fieldDef in pairs(def.SerializedFields or {}) do
						initFieldDefaults(instance, name .. "_" .. fieldName, fieldDef)
					end
				end)
				closePicker()
				refresh()
			end)
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(renderList)
	searchBox:CaptureFocus()
	renderList()
end

----------------------------------------------------------------------
-- Top-level render
----------------------------------------------------------------------

local cleanupTasks = {}

local function runCleanup()
	for _, fn in ipairs(cleanupTasks) do
		pcall(fn)
	end
	cleanupTasks = {}
end

local function attachedComponentNames(instance)
	local names = {}
	for _, tag in ipairs(CollectionService:GetTags(instance)) do
		if tag:sub(1, #TAG_PREFIX) == TAG_PREFIX then
			table.insert(names, tag:sub(#TAG_PREFIX + 1))
		end
	end
	table.sort(names)
	return names
end

-- Compo-style accent pill: ADD_BUTTON_COLOR background, white text,
-- UICorner(0,5), 30px lateral + 5px vertical inner padding, auto-
-- sized so the pill hugs its label. Sits as the last scroll child
-- with a small top spacer; HorizontalAlignment on the scroll layout
-- centers the pill within the dock widget.
local function buildAddComponentButton(parent, selected, defs, attached)
	local spacer = Instance.new("Frame")
	spacer.BackgroundTransparency = 1
	spacer.Size = UDim2.new(1, 0, 0, 8)
	spacer.LayoutOrder = 9998
	spacer.Parent = parent

	local btn = Instance.new("TextButton")
	btn.BackgroundColor3 = ADD_BUTTON_COLOR
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = true
	btn.Text = "+ Add Component"
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.SourceSansSemibold
	btn.TextSize = 14
	btn.AutomaticSize = Enum.AutomaticSize.XY
	btn.Size = UDim2.new()
	btn.LayoutOrder = 9999
	btn.Parent = parent
	roundCorners(btn, 5)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 30)
	pad.PaddingRight = UDim.new(0, 30)
	pad.PaddingTop = UDim.new(0, 5)
	pad.PaddingBottom = UDim.new(0, 5)
	pad.Parent = btn

	btn.MouseButton1Click:Connect(function()
		openPicker(parent.Parent, selected, defs, attached)
	end)
end

local function build()
	closePicker()
	runCleanup()
	for _, child in ipairs(widget:GetChildren()) do
		child:Destroy()
	end

	-- Outer page — single scrolling frame with 6px outer padding and
	-- 5px gap between sections. The Add Component pill is the last
	-- scroll child, not a pinned footer (matches Compo).
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = pageColor()
	root.BorderSizePixel = 0
	root.Parent = widget

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = color("ScrollBar")
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = root

	-- Studio's Properties panel runs sections edge-to-edge with no
	-- inter-section gap; the 22px Titlebar-toned header band carries
	-- the visual separation. No outer padding either — content fills
	-- the dock widget.
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 0)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	-- Pick up any user-supplied property drawers (re-registers every
	-- build so newly-saved drawer modules take effect at the next
	-- refresh). Then load component definitions; emptiness signals the
	-- project doesn't have any `: Component` subclasses yet.
	loadCustomDrawers()
	local defs = loadDefinitions()
	wireSchemaWatchers(cleanupTasks)
	if not next(defs) then
		makeLabel({
			parent = scroll,
			text = "No components defined.",
			color = color("DimmedText"),
			frameSize = UDim2.new(1, 0, 0, 22),
		})
		makeLabel({
			parent = scroll,
			text = "Declare a `: Component` class and compile with `roblox-csharp`.",
			color = color("DimmedText"),
			frameSize = UDim2.new(1, 0, 0, 22),
		})
		return
	end

	local selected = Selection:Get()[1]
	if not selected then
		makeLabel({
			parent = scroll,
			text = "Select an Instance to edit its components.",
			color = color("DimmedText"),
			frameSize = UDim2.new(1, 0, 0, 22),
		})
		return
	end

	local attached = attachedComponentNames(selected)
	for _, name in ipairs(attached) do
		local def = defs[name]
		if def then
			buildComponentSection(scroll, selected, name, def, cleanupTasks)
		else
			-- Component exists by tag but no definition — usually means
			-- the user renamed/removed the definition without removing
			-- the tag. Show the orphan with a hint.
			local row = makeFrame({
				parent = scroll,
				color = color("Titlebar"),
				size = UDim2.new(1, 0, 0, 22),
			})
			makeLabel({
				parent = row,
				text = "  " .. name .. " — no definition found",
				color = color("ErrorText"),
			})
		end
	end

	buildAddComponentButton(scroll, selected, defs, attached)
end

----------------------------------------------------------------------
-- Bootstrap
----------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("Components")
local toggle = toolbar:CreateButton(
	"Components Editor",
	"Toggle the component inspector",
	""
)

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false, -- not initially enabled
	false, -- don't override saved state
	320, 460,
	240, 320
)
widget = plugin:CreateDockWidgetPluginGui("ComponentsEditor", widgetInfo)
widget.Title = "Components"

toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

refresh = function()
	if widget.Enabled then
		build()
	end
end

widget:GetPropertyChangedSignal("Enabled"):Connect(refresh)
Selection.SelectionChanged:Connect(function()
	-- When a picker is armed, treat the next selection as the pick
	-- instead of a normal "show this Instance's components" rebuild.
	-- Selecting the field's own owner (i.e. clicking back at the
	-- component) cancels the pick.
	if armedPicker then
		local picked = Selection:Get()[1]
		local p = armedPicker
		local matches = false
		if picked and picked ~= p.ownerInstance then
			if p.kind == "component" then
				matches = CollectionService:HasTag(picked, TAG_PREFIX .. p.constraint)
			else
				matches = picked:IsA(p.constraint)
			end
		end
		if matches then
			recordChange("Pick " .. picked.Name, function()
				local uid = bindUid(picked)
				p.ownerInstance:SetAttribute(p.attrName, uid)
			end)
			disarmPicker()
			Selection:Set({ p.ownerInstance })
			return
		end
		disarmPicker()
	end
	refresh()
end)
-- Note: there's no per-Instance tag-changed signal in Roblox. The
-- global CollectionService.TagAdded only fires the first time a tag
-- name appears anywhere in the place, so we can't lean on it. Add /
-- remove flows we drive ourselves call refresh() inline; tag edits
-- from the Tag Editor or third-party scripts won't trigger a refresh
-- until selection changes.

-- Theme tracking — rebuild on Studio Dark/Light switch so all colors
-- refresh in one pass.
studio.ThemeChanged:Connect(refresh)

-- ESC key dismisses the picker overlay or disarms an instance picker.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape then
		if pickerOverlay then
			closePicker()
		elseif armedPicker then
			disarmPicker()
		end
	end
end)

refresh()
