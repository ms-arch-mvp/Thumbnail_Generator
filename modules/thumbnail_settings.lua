-- The settings module: the general mod config (loaded from config.lua's editable
-- defaults) plus the shared camera/lighting defaults.
local this = {}

local constants = require("ThumbnailGenerator.constants")

this.typeMetadata = constants.typeMetadata

local typeMetadataSorted = {}
for _, meta in ipairs(constants.typeMetadata) do
    table.insert(typeMetadataSorted, meta)
end
table.sort(typeMetadataSorted, function(a, b) return a.label < b.label end)
this.typeMetadataSorted = typeMetadataSorted

local typeToKey = {}
for _, meta in ipairs(constants.typeMetadata) do
    typeToKey[meta.type] = meta.key
end
this.typeToKey = typeToKey

-- General settings, loaded from config.lua's editable defaults. mwse.loadConfig
-- back-fills missing keys; with useSavedConfig false this is just the defaults.
local defaults = require("ThumbnailGenerator.config")
this.resolutionOptions = defaults.resolutionOptions
if defaults.useSavedConfig then
    this.current = mwse.loadConfig("Thumbnail Generator", defaults)
else
    this.current = defaults
end

-- Migration: older configs stored fit-to-frame under previewFitToFrame only.
-- Promote it to the global fitToFrame if the new key is missing.
if this.current.fitToFrame == nil then
    if this.current.previewFitToFrame ~= nil then
        this.current.fitToFrame = this.current.previewFitToFrame
    else
        this.current.fitToFrame = true
    end
end

-- Strips a leading "data files\" (any case / slash style) so getOutputFolder can
-- re-add exactly one, regardless of what was typed into the folder setting.
local function stripDataFilesPrefix(folder)
    folder = folder:gsub("[\\/]+$", "")
    folder = folder:gsub("^[Dd][Aa][Tt][Aa]%s+[Ff][Ii][Ll][Ee][Ss][\\/]+", "")
    return folder
end

-- Output folder resolved under Data Files with exactly one "data files\" prefix.
-- Callers should use this instead of reading `this.current.outputFolder` directly.
function this.getOutputFolder()
    return "data files\\" .. stripDataFilesPrefix(this.current.outputFolder or "Thumbnail Generator")
end

-- Object types currently enabled in the per-category settings toggles.
function this.getEnabledTypes()
    local types = {}
    for _, meta in ipairs(constants.typeMetadata) do
        if this.current.enabledTypes[meta.key] then
            table.insert(types, meta.type)
        end
    end
    return types
end

-- objectType unused: the camera profile supplies the base view, these are shared nudges.
function this.getDefaultConfig(objectType)
    local c = this.current
    return {
        yaw = c.yaw,
        pitch = c.pitch,
        roll = c.roll,
        zoom = c.zoom,
        panX = c.panX or 0,
        panY = c.panY or 0,
        perspectiveDistanceFactor = c.perspectiveDistanceFactor,
        keyDimmer = c.keyDimmer,
        keyX = c.keyX,
        keyY = c.keyY,
        keyZ = c.keyZ,
        fillDimmer = c.fillDimmer,
        ambientScale = c.ambientScale,
        diffuseScale = c.diffuseScale,
        ortho = c.ortho,
    }
end

-- Shared camera/lighting values the preview's "Save to session" overwrites. A
-- snapshot is taken as-loaded so "Reset session" can restore them (this.current
-- may be the config table itself, so a save mutates it in place).
this.sessionCameraKeys = { "yaw", "pitch", "roll", "zoom", "panX", "panY", "perspectiveDistanceFactor",
    "keyDimmer", "keyX", "keyY", "keyZ", "fillDimmer", "ambientScale", "diffuseScale", "forceOrtho", "fitToFrame" }

local pristineCamera = {}
for _, key in ipairs(this.sessionCameraKeys) do pristineCamera[key] = this.current[key] end

function this.resetSessionCamera()
    for _, key in ipairs(this.sessionCameraKeys) do this.current[key] = pristineCamera[key] end
end


return this
