-- Component Editor Studio plugin.
--
-- Reads component definitions from ReplicatedStorage.Plugins.Components.Definitions
-- (synced there by the roblox-csharp compile step) and shows an inspector
-- for the currently-selected Instance: list of attached components, the
-- ability to add/remove them, and a typed editor for each SerializedField.
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

local TAG_PREFIX = "Component:"
local DEFINITIONS_PATH = { "Plugins", "Components", "Definitions" }

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

-- Forward declaration. Assigned near the bottom of the file once
-- `widget` and `build` exist. Click handlers reference this through
-- the closure so they see the assigned function at call time, not
-- the nil at definition time.
local refresh

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

-- Walks ReplicatedStorage by the configured path. Returns nil if the
-- runtime hasn't been synced yet so the inspector can show a helpful
-- "compile your project first" hint instead of silently failing.
local function findDefinitionsFolder()
	local node = ReplicatedStorage
	for _, segment in ipairs(DEFINITIONS_PATH) do
		if not node then return nil end
		node = node:FindFirstChild(segment)
	end
	return node
end

local function loadDefinitions()
	local folder = findDefinitionsFolder()
	if not folder then return nil end

	local defs = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ModuleScript") then
			local ok, mod = pcall(require, child)
			if ok and type(mod) == "table" and mod.ComponentName then
				defs[mod.ComponentName] = mod
			end
		end
	end
	return defs
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

-- Native Properties uses a single flat row colour (no banding) and a
-- faint vertical divider at the label / value column boundary. The
-- rowIndex argument is retained for API compatibility with callers
-- that still pass it; the value is unused.
--
-- Row / header colours are hardcoded to the dark-theme hex values that
-- match the native pane exactly. We don't theme-track these because
-- the dark palette is the design target.
local ROW_COLOR = Color3.fromHex("#191A1F")
local HEADER_COLOR = Color3.fromHex("#202227")
local ROW_HOVER_COLOR = Color3.fromHex("#353741")

local function buildFieldRow(parent, fieldName, _rowIndex)
	local row = makeFrame({
		parent = parent,
		color = ROW_COLOR,
		size = UDim2.new(1, 0, 0, 22),
	})

	-- Hover highlight. Active = true is required on Frame for the
	-- mouse events to fire; it doesn't block child widgets (TextBox,
	-- TextButton) from receiving clicks themselves.
	row.Active = true
	row.MouseEnter:Connect(function()
		row.BackgroundColor3 = ROW_HOVER_COLOR
	end)
	row.MouseLeave:Connect(function()
		row.BackgroundColor3 = ROW_COLOR
	end)

	-- Left column: field label. Indented to align with the section
	-- header text (which sits past the chevron at ~24px).
	makeLabel({
		parent = row,
		text = fieldName,
		color = color("MainText"),
		frameSize = UDim2.new(0.45, -24, 1, 0),
		position = UDim2.new(0, 24, 0, 0),
	})

	-- Hairline divider between the label and value columns — matches
	-- the subtle vertical line in the native pane.
	makeFrame({
		parent = row,
		color = color("Border"),
		size = UDim2.new(0, 1, 1, 0),
		position = UDim2.new(0.45, 0, 0, 0),
	})

	-- Right column: value slot. Transparent so the row background
	-- shows through — the native pane doesn't wrap values in a
	-- distinct input-field rectangle.
	local valueSlot = makeFrame({
		parent = row,
		color = ROW_COLOR,
		transparency = 1,
		size = UDim2.new(0.55, -1, 1, 0),
		position = UDim2.new(0.45, 1, 0, 0),
	})
	makePadding(valueSlot, 8, 6, 0, 0)
	return row, valueSlot
end

local function makeValueTextBox(parent, initialText)
	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.Text = initialText
	box.TextColor3 = color("MainText")
	box.PlaceholderColor3 = color("DimmedText")
	box.Font = Enum.Font.SourceSans
	box.TextSize = 14
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Size = UDim2.fromScale(1, 1)
	box.ClearTextOnFocus = false
	box.Parent = parent
	return box
end

local function createNumberEditor(parent, fieldName, instance, attrName, rowIndex)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex)
	local box = makeValueTextBox(slot, tostring(instance:GetAttribute(attrName) or 0))

	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			instance:SetAttribute(attrName, n)
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

local function createStringEditor(parent, fieldName, instance, attrName, rowIndex)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex)
	local box = makeValueTextBox(slot, tostring(instance:GetAttribute(attrName) or ""))

	box.FocusLost:Connect(function()
		instance:SetAttribute(attrName, box.Text)
	end)
	local conn = instance:GetAttributeChangedSignal(attrName):Connect(function()
		if not box:IsFocused() then
			box.Text = tostring(instance:GetAttribute(attrName) or "")
		end
	end)
	return function() conn:Disconnect() end
end

local function createBooleanEditor(parent, fieldName, instance, attrName, rowIndex)
	local _, slot = buildFieldRow(parent, fieldName, rowIndex)
	-- For booleans we draw a small checkbox-style square left-aligned
	-- in the value well instead of a text widget.
	local toggle = Instance.new("TextButton")
	toggle.BackgroundColor3 = color("CheckedFieldBackground")
	toggle.BorderColor3 = color("CheckedFieldBorder")
	toggle.BorderSizePixel = 1
	toggle.Font = Enum.Font.SourceSans
	toggle.TextSize = 14
	toggle.TextColor3 = color("MainText")
	toggle.Size = UDim2.new(0, 14, 0, 14)
	toggle.Position = UDim2.new(0, 0, 0.5, -7)
	toggle.AutoButtonColor = true
	toggle.Parent = slot

	local function refresh()
		toggle.Text = instance:GetAttribute(attrName) and "✓" or ""
	end
	refresh()

	toggle.MouseButton1Click:Connect(function()
		instance:SetAttribute(attrName, not instance:GetAttribute(attrName))
	end)
	local conn = instance:GetAttributeChangedSignal(attrName):Connect(refresh)
	return function() conn:Disconnect() end
end

-- Dispatch table by SerializedField type. Add new types here as the
-- system grows; the inspector silently skips fields it doesn't know
-- how to edit so partial type support is OK.
local EDITORS = {
	number = createNumberEditor,
	string = createStringEditor,
	boolean = createBooleanEditor,
}

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

	-- Header is itself a TextButton so the whole bar toggles expand /
	-- collapse — matches Studio's Properties-panel section behavior.
	-- The Remove button inside it catches its own clicks (Roblox doesn't
	-- bubble UI input), so it won't accidentally toggle the section.
	-- No UIStroke: the native Properties pane uses a flat CategoryItem
	-- bar with no visible border, distinguished from row chrome only by
	-- its slightly lighter colour.
	local header = Instance.new("TextButton")
	header.BackgroundColor3 = HEADER_COLOR
	header.BorderSizePixel = 0
	header.Text = ""
	header.AutoButtonColor = false
	header.Size = UDim2.new(1, 0, 0, 22)
	header.Parent = parent

	makeLabel({
		parent = header,
		text = expanded and "▾" or "▸",
		color = color("MainText"),
		size = 14,
		frameSize = UDim2.new(0, 14, 1, 0),
		position = UDim2.new(0, 6, 0, 0),
	})

	makeLabel({
		parent = header,
		text = componentName,
		color = color("BrightText"),
		size = 14,
		font = Enum.Font.SourceSansBold,
		frameSize = UDim2.new(1, -100, 1, 0),
		position = UDim2.new(0, 24, 0, 0),
	})

	-- Remove control on the right. Calls refresh inline because Roblox
	-- doesn't give us a per-instance tag-changed signal to react to.
	local remove = Instance.new("TextButton")
	remove.BackgroundColor3 = color("Button")
	remove.BorderColor3 = color("Border")
	remove.BorderSizePixel = 1
	remove.Text = "Remove"
	remove.TextColor3 = color("ButtonText")
	remove.Font = Enum.Font.SourceSans
	remove.TextSize = 13
	remove.Size = UDim2.new(0, 60, 0, 18)
	remove.Position = UDim2.new(1, -66, 0.5, -9)
	remove.AutoButtonColor = true
	remove.Parent = header

	remove.MouseButton1Click:Connect(function()
		CollectionService:RemoveTag(instance, TAG_PREFIX .. componentName)
		for fieldName in pairs(def.SerializedFields or {}) do
			instance:SetAttribute(componentName .. "_" .. fieldName, nil)
		end
		refresh()
	end)

	header.MouseButton1Click:Connect(function()
		sectionExpanded[componentName] = not expanded
		refresh()
	end)

	if not expanded then return end

	-- Field rows. Iterate in a stable order so the layout doesn't shuffle
	-- between rebuilds; pairs() is hash-ordered which would jitter.
	local fieldNames = {}
	for name in pairs(def.SerializedFields or {}) do
		table.insert(fieldNames, name)
	end
	table.sort(fieldNames)

	for i, fieldName in ipairs(fieldNames) do
		local fieldDef = def.SerializedFields[fieldName]
		local editor = EDITORS[fieldDef.type]
		if editor then
			local attrName = componentName .. "_" .. fieldName
			table.insert(cleanupTasks, editor(parent, fieldName, instance, attrName, i))
		else
			local row = makeFrame({
				parent = parent,
				color = color("TableItem"),
				size = UDim2.new(1, 0, 0, 22),
			})
			makeLabel({
				parent = row,
				text = "  " .. fieldName .. " — unsupported type '" .. tostring(fieldDef.type) .. "'",
				color = color("DimmedText"),
				frameSize = UDim2.new(1, -24, 1, 0),
				position = UDim2.new(0, 24, 0, 0),
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
				CollectionService:AddTag(instance, TAG_PREFIX .. name)
				local def = defs[name]
				for fieldName, fieldDef in pairs(def.SerializedFields or {}) do
					local attrName = name .. "_" .. fieldName
					if instance:GetAttribute(attrName) == nil then
						instance:SetAttribute(attrName, fieldDef.default)
					end
				end
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

local widget
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

local function build()
	closePicker()
	runCleanup()
	for _, child in ipairs(widget:GetChildren()) do
		child:Destroy()
	end

	-- Outer panel matches Studio's main backdrop.
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = color("MainBackground")
	root.BorderSizePixel = 0
	root.Parent = widget

	-- Top area scrolls; the Add Component button is pinned to the bottom.
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 1, -36)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = root

	-- UIListLayout's default SortOrder is `Name`, which would sort our
	-- Frame-typed field rows and the TextButton-typed section header
	-- alphabetically ("Frame" < "TextButton") — putting all field rows
	-- above the header. Force LayoutOrder so children render in the
	-- order they were parented instead.
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	-- Definitions check first.
	local defs = loadDefinitions()
	if not defs then
		local block = makeFrame({
			parent = scroll,
			color = color("MainBackground"),
			size = UDim2.new(1, 0, 0, 80),
		})
		makePadding(block, 12, 12, 12, 0)
		makeLabel({
			parent = block,
			text = "Components runtime not found.",
			color = color("ErrorText"),
			frameSize = UDim2.new(1, 0, 0, 22),
		})
		makeLabel({
			parent = block,
			text = "Compile your project with `roblox-csharp` so the",
			color = color("DimmedText"),
			frameSize = UDim2.new(1, 0, 0, 18),
			position = UDim2.new(0, 0, 0, 26),
		})
		makeLabel({
			parent = block,
			text = "Components plugin syncs to ReplicatedStorage.",
			color = color("DimmedText"),
			frameSize = UDim2.new(1, 0, 0, 18),
			position = UDim2.new(0, 0, 0, 44),
		})
		return
	end

	local selected = Selection:Get()[1]
	if not selected then
		local hint = makeFrame({
			parent = scroll,
			color = color("MainBackground"),
			size = UDim2.new(1, 0, 0, 40),
		})
		makePadding(hint, 12, 12, 12, 0)
		makeLabel({
			parent = hint,
			text = "Select an Instance to edit its components.",
			color = color("DimmedText"),
		})
		return
	end

	-- Component sections fill the scroll area.
	local attached = attachedComponentNames(selected)
	if #attached == 0 then
		local hint = makeFrame({
			parent = scroll,
			color = color("MainBackground"),
			size = UDim2.new(1, 0, 0, 28),
		})
		makePadding(hint, 12, 12, 8, 0)
		makeLabel({
			parent = hint,
			text = "(no components attached)",
			color = color("DimmedText"),
		})
	else
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
					color = color("CategoryItem"),
					size = UDim2.new(1, 0, 0, 22),
				})
				makePadding(row, 8, 8, 0, 0)
				makeLabel({
					parent = row,
					text = name .. " — no definition found",
					color = color("ErrorText"),
				})
			end
		end
	end

	-- Selection path footer just above the Add Component button. Sits
	-- inside the scroll area so it scrolls with the content, separated
	-- by a small spacer.
	local spacer = makeFrame({
		parent = scroll,
		color = color("MainBackground"),
		size = UDim2.new(1, 0, 0, 12),
		transparency = 1,
	})
	spacer.BackgroundTransparency = 1

	local pathBlock = makeFrame({
		parent = scroll,
		color = color("MainBackground"),
		size = UDim2.new(1, 0, 0, 22),
		transparency = 1,
	})
	pathBlock.BackgroundTransparency = 1
	makePadding(pathBlock, 12, 12, 0, 0)
	makeLabel({
		parent = pathBlock,
		text = selected:GetFullName(),
		color = color("DimmedText"),
		size = 13,
	})

	-- Pinned bottom bar: the "Add Component" button.
	local bottomBar = makeFrame({
		parent = root,
		color = color("MainBackground"),
		size = UDim2.new(1, 0, 0, 36),
		position = UDim2.new(0, 0, 1, -36),
	})
	makePadding(bottomBar, 12, 12, 6, 6)

	local addButton = Instance.new("TextButton")
	addButton.BackgroundColor3 = color("DialogMainButton")
	addButton.BorderColor3 = color("Border")
	addButton.BorderSizePixel = 1
	addButton.Text = "Add Component"
	addButton.TextColor3 = color("DialogMainButtonText")
	addButton.Font = Enum.Font.SourceSansSemibold
	addButton.TextSize = 14
	addButton.Size = UDim2.fromScale(1, 1)
	addButton.AutoButtonColor = true
	addButton.Parent = bottomBar

	addButton.MouseButton1Click:Connect(function()
		openPicker(root, selected, defs, attached)
	end)
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
Selection.SelectionChanged:Connect(refresh)
-- Note: there's no per-Instance tag-changed signal in Roblox. The
-- global CollectionService.TagAdded only fires the first time a tag
-- name appears anywhere in the place, so we can't lean on it. Add /
-- remove flows we drive ourselves call refresh() inline; tag edits
-- from the Tag Editor or third-party scripts won't trigger a refresh
-- until selection changes.

-- Theme tracking — rebuild on Studio Dark/Light switch so all colors
-- refresh in one pass.
studio.ThemeChanged:Connect(refresh)

-- ESC key dismisses the picker overlay if it's up.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape and pickerOverlay then
		closePicker()
	end
end)

refresh()
