-- Stable Instance handles for [SerializedField] reference fields.
--
-- Roblox Instance Attributes can't hold Instance values, so a ref field
-- like `[SerializedField] BasePart target;` is stored as a GUID string
-- and resolved back to the live Instance via this registry. The GUID
-- itself lives on the referenced Instance as an attribute named "_uid",
-- which survives reparenting, renaming, and save/load.

local HttpService = game:GetService("HttpService")

local InstanceRegistry = {}

local byUid = {}
local scanned = setmetatable({}, { __mode = "k" })

local function track(inst)
	local uid = inst:GetAttribute("_uid")
	if typeof(uid) ~= "string" or uid == "" then return end
	byUid[uid] = inst
end

local function untrack(inst)
	local uid = inst:GetAttribute("_uid")
	if typeof(uid) == "string" and byUid[uid] == inst then
		byUid[uid] = nil
	end
end

-- Assigns a GUID to `inst` if it doesn't already have one, indexes it,
-- and returns the GUID. Picker / setter code calls this when writing a
-- ref so the target is guaranteed addressable.
function InstanceRegistry.bind(inst)
	local uid = inst:GetAttribute("_uid")
	if typeof(uid) ~= "string" or uid == "" then
		uid = HttpService:GenerateGUID(false)
		inst:SetAttribute("_uid", uid)
	end
	byUid[uid] = inst
	return uid
end

-- Returns the Instance with the given uid, or nil if unknown / destroyed.
function InstanceRegistry.resolve(uid)
	if typeof(uid) ~= "string" or uid == "" then return nil end
	local inst = byUid[uid]
	if inst and inst.Parent == nil and inst ~= game then
		byUid[uid] = nil
		return nil
	end
	return inst
end

-- Backfills the registry from `root` and starts watching for descendant
-- adds/removes. Idempotent per root — calling twice is a no-op.
function InstanceRegistry.scan(root)
	if scanned[root] then return end
	scanned[root] = true

	track(root)
	for _, d in ipairs(root:GetDescendants()) do
		track(d)
	end

	root.DescendantAdded:Connect(track)
	root.DescendantRemoving:Connect(untrack)
end

return InstanceRegistry
