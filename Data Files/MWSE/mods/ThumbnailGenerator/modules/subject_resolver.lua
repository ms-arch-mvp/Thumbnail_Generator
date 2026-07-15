-- Resolves a normalized subject descriptor from a tes3object or raw mesh path.
local this = {}

local thumbnail_settings = require("ThumbnailGenerator.modules.thumbnail_settings")
local typeToKey = thumbnail_settings.typeToKey
local camera_profiles = require("ThumbnailGenerator.modules.camera_profiles")
-- profiles lazy-requires this module back for compileMatcher; this direction is
-- the file-scope one, so keep profiles free of file-scope requires into us.
local profiles = require("ThumbnailGenerator.modules.profiles")

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

local function resolveSourceMod(obj)
    if not obj then return "<unknown>" end
    local sourceMod = obj.sourceMod
    if not sourceMod then
        -- 1. Try base object for dynamically created objects (e.g. Tamriel Data hats)
        if obj.id:match("H$") then
            local baseObj = tes3.getObject(obj.id:sub(1, -2))
            if baseObj and baseObj.sourceMod then
                sourceMod = baseObj.sourceMod
            end
        end
        -- 2. Fallback to ID prefix detection for common province mods
        if not sourceMod then
            local idUpper = obj.id:upper()
            if idUpper:match("^T_") then
                sourceMod = "Tamriel_Data.esm"
            elseif idUpper:match("^TR_") then
                sourceMod = "TR_Mainland.esm"
            elseif idUpper:match("^SKY_") then
                sourceMod = "Sky_Main.esm"
            elseif idUpper:match("^CYR_") then
                sourceMod = "Cyr_Main.esm"
            end
        end
    end
    return sourceMod or "<unknown>"
end

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
        sourceMod = resolveSourceMod(obj),
        meshPath = meshPath,
        normalizedMeshPath = normalizeMeshPath(meshPath),
        config = thumbnail_settings.getDefaultConfig(obj.objectType),
    }
    subject.profile = camera_profiles.resolve(subject)
    -- Saved profiles override the shared defaults per matching record (opt-in).
    if thumbnail_settings.current.useProfiles then
        profiles.apply(subject)
    end
    return subject
end


-- Translates a glob term (with `*` and `?` wildcards) into a whole-field-anchored
-- Lua pattern: every magic char is escaped, then the escaped wildcards reopened.
local function globToPattern(term)
    local pat = term:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    pat = pat:gsub("%%%*", ".*"):gsub("%%%?", ".")
    return "^" .. pat .. "$"
end

-- Builds a matcher for one search term over the id/name/mesh/sourceMod fields.
-- A term with `*`/`?` is a glob matched against the whole field; otherwise it is
-- a plain substring. Returns nil for empty terms (they impose no constraint).
local function makeTermMatcher(term)
    -- Normalize both slash styles to `/` so mesh-path terms match regardless of
    -- which the user types (mesh fields are normalized to match, below).
    term = term:match("^%s*(.-)%s*$"):lower():gsub("\\", "/")
    if term == "" then return nil end
    if term:find("[%*%?]") then
        local pat = globToPattern(term)
        return function(id, name, mPath, sourceMod)
            return id:match(pat) or name:match(pat) or mPath:match(pat) or sourceMod:match(pat)
        end
    end
    return function(id, name, mPath, sourceMod)
        return name:find(term, 1, true) or id:find(term, 1, true)
            or mPath:find(term, 1, true) or sourceMod:find(term, 1, true)
    end
end

-- Compiles a search pattern into a predicate `matcher(obj) -> bool`, the shared
-- matching used by the preview search and the batch scan. The pattern is split on
-- commas into AND-terms (an object must satisfy every term); any term may use
-- `*`/`?` glob wildcards; each term is tested against the object's id, name, mesh
-- path, and source mod. Returns nil when the pattern imposes no constraint (empty
-- or all-whitespace) so callers can treat that as "match all".
function this.compileMatcher(pattern)
    pattern = pattern or ""
    local termMatchers = {}
    for term in (pattern .. ","):gmatch("([^,]*),") do
        local matcher = makeTermMatcher(term)
        if matcher then table.insert(termMatchers, matcher) end
    end
    if #termMatchers == 0 then return nil end

    return function(obj)
        local id = (obj.id or ""):lower()
        local name = (obj.name or ""):lower()
        local mPath = (obj.mesh or ""):lower():gsub("\\", "/")
        local sourceMod = resolveSourceMod(obj):lower()
        for _, matcher in ipairs(termMatchers) do
            if not matcher(id, name, mPath, sourceMod) then return false end
        end
        return true
    end
end

-- Searches object records and resolves each into a subject. When params.sourceMod
-- is set, matching is by exact source plugin. Otherwise the pattern is matched via
-- compileMatcher (comma AND-terms + glob wildcards). One entry per base record:
-- auto-generated per-placement actor instances are skipped, ids deduplicated.
function this.search(params)
    local pattern = params.pattern or ""
    local pluginFilter = params.sourceMod
    if pattern:match("^%s*$") and not pluginFilter then return {} end
    local limit = params.limit or 100

    local matcher = not pluginFilter and this.compileMatcher(pattern)
    if not pluginFilter and not matcher then return {} end

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
                    matched = resolveSourceMod(obj) == pluginFilter
                else
                    matched = matcher(obj)
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
                    local plugin = resolveSourceMod(obj)
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
    if thumbnail_settings.current.useProfiles then
        profiles.apply(subject)
    end
    return subject
end


return this
