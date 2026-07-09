-- Resolves a normalized subject descriptor from a tes3object or raw mesh path.
local this = {}

local thumbnail_settings = require("ThumbnailGenerator.modules.thumbnail_settings")
local typeToKey = thumbnail_settings.typeToKey
local camera_profiles = require("ThumbnailGenerator.modules.camera_profiles")

-- objectType -> singular display name, from constants.typeMetadata.
local objectTypeNames = {}
for _, meta in ipairs(thumbnail_settings.typeMetadata) do
    objectTypeNames[meta.type] = meta.name
end

local function normalizeMeshPath(meshPath)
    if not meshPath then return "" end
    local clean = meshPath:gsub("\\", "/"):lower()
    clean = clean:match("^%s*(.-)%s*$")
    clean = clean:gsub("%.[nN][iI][fF]$", "")
    return clean
end
this.normalizeMeshPath = normalizeMeshPath

local function sanitizeFilename(str)
    if not str then return "unknown" end
    local safe = str:gsub("[<>:\"/\\|%?%*]", "_")
    safe = safe:match("^[%s%.]*(.-)[%s%.]*$") -- trim leading/trailing spaces/periods
    if safe == "" then safe = "empty" end
    return safe
end
this.sanitizeFilename = sanitizeFilename

-- Resolves a normalized subject descriptor from a tes3object.
function this.resolve(obj)
    if not obj then return nil end

    local meshPath = obj.mesh or ""
    local subject = {
        object = obj,
        objectType = obj.objectType,
        typeKey = typeToKey[obj.objectType] or "default",
        recordId = sanitizeFilename(obj.id),
        displayName = obj.name or "Unnamed",
        typeName = objectTypeNames[obj.objectType] or "unknown",
        sourceMod = obj.sourceMod or "<unknown>",
        meshPath = meshPath,
        normalizedMeshPath = normalizeMeshPath(meshPath),
        config = thumbnail_settings.getDefaultConfig(obj.objectType),
    }
    subject.profile = camera_profiles.resolve(subject)
    return subject
end


-- Searches object records and resolves each into a subject. Matching is either
-- by pattern (against id, name, mesh path, or source mod) or, when params.sourceMod
-- is set, by exact source plugin. One entry per base record: auto-generated
-- per-placement actor instances are skipped, ids deduplicated.
function this.search(params)
    local pattern = (params.pattern or ""):lower()
    local pluginFilter = params.sourceMod
    if pattern == "" and not pluginFilter then return {} end
    local limit = params.limit or 100

    local matches = {}
    local seenIds = {}

    for _, objType in ipairs(params.types or {}) do
        for obj in tes3.iterateObjects(objType) do
            local isActorInstance = (objType == tes3.objectType.npc or objType == tes3.objectType.creature)
                and obj.isInstance == true
            local mesh = not isActorInstance and obj.mesh
            if mesh and mesh:lower():match("%.nif$") then
                local id = (obj.id or ""):lower()
                local matched
                if pluginFilter then
                    matched = (obj.sourceMod or "<unknown>") == pluginFilter
                else
                    local name = (obj.name or ""):lower()
                    local mPath = mesh:lower()
                    local sourceMod = (obj.sourceMod or ""):lower()
                    matched = name:find(pattern, 1, true) or id:find(pattern, 1, true)
                        or mPath:find(pattern, 1, true) or sourceMod:find(pattern, 1, true)
                end
                if matched and not seenIds[id] then
                    seenIds[id] = true
                    table.insert(matches, {
                        subject = this.resolve(obj),
                        id = obj.id,
                        typeName = objectTypeNames[objType] or "unknown",
                        name = obj.name or "",
                        mesh = mesh:gsub("%.[nN][iI][fF]$", ".nif"),
                    })
                    if #matches >= limit then return matches end
                end
            end
        end
    end

    return matches
end


-- Distinct source plugins that have at least one displayable record for the
-- given types, each with a record count. Same displayable criteria as search().
function this.listPlugins(params)
    local counts = {}
    local seenIds = {}

    for _, objType in ipairs(params.types or {}) do
        for obj in tes3.iterateObjects(objType) do
            local isActorInstance = (objType == tes3.objectType.npc or objType == tes3.objectType.creature)
                and obj.isInstance == true
            local mesh = not isActorInstance and obj.mesh
            if mesh and mesh:lower():match("%.nif$") then
                local id = (obj.id or ""):lower()
                if not seenIds[id] then
                    seenIds[id] = true
                    local plugin = obj.sourceMod or "<unknown>"
                    counts[plugin] = (counts[plugin] or 0) + 1
                end
            end
        end
    end

    local plugins = {}
    for plugin, count in pairs(counts) do
        table.insert(plugins, { plugin = plugin, count = count })
    end
    table.sort(plugins, function(a, b) return a.plugin:lower() < b.plugin:lower() end)
    return plugins
end


-- Resolves a fallback subject descriptor from a raw mesh path.
function this.resolveFallback(meshPath)
    local filename = (meshPath or "unknown"):gsub("\\", "/")
    filename = filename:match("([^/]+)$") or filename
    filename = filename:gsub("%.[nN][iI][fF]$", "")

    local subject = {
        object = nil,
        objectType = nil,
        typeKey = "default",
        recordId = sanitizeFilename(filename),
        displayName = "Fallback: " .. (meshPath or "unknown"),
        meshPath = meshPath or "",
        normalizedMeshPath = normalizeMeshPath(meshPath),
        config = thumbnail_settings.getDefaultConfig(nil),
    }
    subject.profile = camera_profiles.resolve(subject)
    return subject
end


return this
