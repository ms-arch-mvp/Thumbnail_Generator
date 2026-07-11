-- Persistent render profiles: full preview snapshots (camera, lighting, ortho,
-- fit-to-frame, zoom/pan) saved from the preview's Save Profile popup and
-- applied to matching subjects when the MCM "Use Profiles" toggle is on.
-- One JSON file per profile under <output folder>\profiles (all.json /
-- type_<key>.json / search_<pattern>.json); saving a profile with the same
-- scope+key overwrites its file. Files are loaded once at require time --
-- delete a file to remove its profile. Scope precedence: search > type > all;
-- among equal scopes the most recently saved wins (savedAt timestamp).
local this = {}

local settings = require("ThumbnailGenerator.modules.thumbnail_settings")

-- Keys a profile's settings table stores. Values use the same units as
-- config.lua's render defaults (zoom 1.0 = neutral, not the preview-internal scale).
this.settingKeys = {
    "yaw", "pitch", "roll", "zoom", "panX", "panY", "perspectiveDistanceFactor",
    "keyDimmer", "keyX", "keyY", "keyZ", "fillDimmer", "ambientScale", "diffuseScale",
    "ortho", "fitToFrame",
}

local function profilesFolder()
    return settings.getOutputFolder() .. "\\profiles"
end

-- Stepwise mkdir; render.ensureDirectory would be a circular require from here.
local function ensureFolder(path)
    local current = ""
    for part in path:gsub("/", "\\"):gmatch("[^\\]+") do
        current = current == "" and part or (current .. "\\" .. part)
        if not lfs.directoryexists(current) then
            lfs.mkdir(current)
        end
    end
end

this.list = {}

-- profile table -> source filename; kept outside the profiles so the saved
-- JSON never carries it.
local fileFor = {}

-- Loads every profiles\*.json once at require time (like rotation_exceptions);
-- invalid files are skipped with a log line, never deleted.
local function loadAll()
    local dir = profilesFolder()
    if not lfs.directoryexists(dir) then return end
    for file in lfs.dir(dir) do
        if file:lower():match("%.json$") then
            local f = io.open(dir .. "\\" .. file, "r")
            if f then
                local ok, data = pcall(json.decode, f:read("*a"))
                f:close()
                if ok and type(data) == "table" and data.scope and type(data.settings) == "table" then
                    table.insert(this.list, data)
                    fileFor[data] = file
                else
                    mwse.log("[Thumbnail Generator] profiles: skipping invalid profile file '%s'", file)
                end
            end
        end
    end
    -- Recency order so "latest saved wins" survives arbitrary directory order.
    table.sort(this.list, function(a, b) return (a.savedAt or 0) < (b.savedAt or 0) end)
end
loadAll()

-- Compiled search matchers, keyed by pattern; kept out of the profile tables
-- so persistence never sees a function value.
local matcherCache = {}

local function matcherFor(pattern)
    local cached = matcherCache[pattern]
    if cached == nil then
        -- Lazy require: subject_resolver applies profiles inside resolve(), so a
        -- file-scope require here would be circular.
        cached = require("ThumbnailGenerator.modules.subject_resolver").compileMatcher(pattern) or false
        matcherCache[pattern] = cached
    end
    return cached or nil
end

local function sameIdentity(a, b)
    return a.scope == b.scope and a.typeKey == b.typeKey and a.pattern == b.pattern
end

local function sanitizeFilename(str)
    local safe = tostring(str or ""):gsub("[<>:\"/\\|%?%*%s%.]", "_")
    if safe == "" then safe = "empty" end
    return safe
end

-- all.json / type_<key>.json / search_<pattern>.json; a name already taken by a
-- *different* identity (e.g. two patterns sanitizing alike) gets a numeric suffix.
local function filenameFor(profile)
    local base
    if profile.scope == "all" then
        base = "all"
    elseif profile.scope == "type" then
        base = "type_" .. sanitizeFilename(profile.typeKey)
    else
        base = "search_" .. sanitizeFilename(profile.pattern)
    end
    local dir = profilesFolder()
    local name = base .. ".json"
    local n = 2
    while lfs.fileexists(dir .. "\\" .. name) do
        name = string.format("%s_%d.json", base, n)
        n = n + 1
    end
    return name
end

-- Writes the profile to its own file, overwriting the file of a same-identity
-- profile if one exists. Returns the relative file path, or nil + path on error.
function this.save(profile)
    profile.savedAt = os.time()

    local filename
    for i = #this.list, 1, -1 do
        if sameIdentity(this.list[i], profile) then
            filename = filename or fileFor[this.list[i]]
            fileFor[this.list[i]] = nil
            table.remove(this.list, i)
        end
    end

    local dir = profilesFolder()
    ensureFolder(dir)
    filename = filename or filenameFor(profile)
    local path = dir .. "\\" .. filename

    local f = io.open(path, "w")
    if not f then
        return nil, path
    end
    f:write(json.encode(profile, { indent = true }))
    f:close()

    table.insert(this.list, profile)
    fileFor[profile] = filename
    return "profiles\\" .. filename
end

-- Best profile for a subject: search > type > all; the list is in save order,
-- so >= lets a later save win over an earlier one of the same rank.
function this.match(subject)
    local best, bestRank = nil, 0
    for _, profile in ipairs(this.list) do
        local rank = 0
        if profile.scope == "all" then
            rank = 1
        elseif profile.scope == "type" then
            if profile.typeKey == subject.typeKey then rank = 2 end
        elseif profile.scope == "search" and subject.object and profile.pattern then
            local matcher = matcherFor(profile.pattern)
            if matcher and matcher(subject.object) then rank = 3 end
        end
        if rank > 0 and rank >= bestRank then
            best, bestRank = profile, rank
        end
    end
    return best
end

-- Merges the matching profile into subject.config and marks the subject, so
-- batch/preview know its ortho/fit toggles are per-record. rotationMode "add"
-- (default) keeps each record's own base view + rotation exceptions with the
-- saved yaw on top; "override" replaces both with the orientation captured at
-- save time (profile.direction, the previewed subject's resolved view), so
-- matched records render exactly as previewed.
function this.apply(subject)
    local profile = this.match(subject)
    if not profile or type(profile.settings) ~= "table" then return end

    for _, key in ipairs(this.settingKeys) do
        if profile.settings[key] ~= nil then
            subject.config[key] = profile.settings[key]
        end
    end

    if profile.rotationMode == "override" and subject.profile then
        subject.profile.rotationRules = {}
        if profile.direction then
            subject.profile.direction = profile.direction
        end
    end

    subject.appliedProfile = profile
end

return this
