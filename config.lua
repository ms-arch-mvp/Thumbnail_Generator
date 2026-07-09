-- Editable defaults; modules/thumbnail_settings.lua loads (and optionally persists) them.
local constants = require("ThumbnailGenerator.constants")

-- All object categories enabled by default.
local enabledTypes = {}
for _, meta in ipairs(constants.typeMetadata) do
    enabledTypes[meta.key] = true
end

return {
    -- Output (inside Data Files)
    outputFolder = "Thumbnail Generator",
    flaggedMeshesFile = "flagged_meshes.txt", -- one mesh path per line, in the output folder; read by the Flagged button
    resolutionOptions = { 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384 },

    -- Camera (applied to every render: preview and batch)
    globalRotation = 0, -- azimuth (deg) about world Z added to every render
    forceOrtho = true, -- Orthographic toggle; the preview follows this on open
    fitToFrame = true, -- when enabled, tighten the crop to visible pixels; when disabled, keep the looser first-pass framing
    orthoDistanceFactor = 200, -- ortho emulation dolly distance; higher = flatter

    -- Batch
    renderResolution = 2048,
    outputResolution = 1024,
    outputFormat = "png", -- "png", "tga" or "dds"
    enabledTypes = enabledTypes,
    skipEmptyRenders = true,
    skipExistingThumbnails = false, -- don't re-render an item whose output file already exists
    renderOnlyRotationExceptions = false,
    npcFiltering = true, -- MCM toggle for the rules below
    npcRequireRespawn = true, -- only keep NPCs with the RESPAWN flag set
    npcIncludePattern = "outfit", -- ids containing this are always kept (empty to disable)
    writeLogs = true,
    particlePrimeTime = 0, -- shared; seconds of particle pre-simulation; 0 = capture live state

    -- Preview
    previewRenderResolution = 2048,
    previewOutputResolution = 1024,
    previewOutputFormat = "png", -- "png", "tga" or "dds"
    -- Legacy (pre-global) setting. Kept for backward compatibility with saved configs.
    previewFitToFrame = nil,
    previewForcePerPixel = false, -- force MGE per-pixel lighting in the preview so candle flames render (preview looks brighter than the output)
    panSpeed = 0.75, -- WASD pan speed, in subject radii per second

    -- Camera view direction per category, MW world axes (+X east, +Y north, +Z up).
    -- A record type listed here (by its type key) gets its own base view;
    -- everything else uses "standard". Hair body parts use "hair".
    viewDirections = {
        bodypart = { 0, -1, 0 },
        creature = { -1, 1, 1 },
        hair     = { 1, -1, 1 },
        npc      = { 0, 1, 0 },
        standard = { 1, -1, 1 },
    },

    -- Defaults
    yaw = 0,
    pitch = 0,
    roll = 0,
    zoom = 1.0,
    panX = 0, -- subject-radius offset along camera right; only applied when fitToFrame is off
    panY = 0, -- subject-radius offset along camera up; only applied when fitToFrame is off
    ortho = true,
    lodAdjust = 0.001, -- tiny value forces highest-detail LOD level
    perspectiveDistanceFactor = 8, -- lower = closer = wider-angle look
    keyDimmer = 1.2,
    keyX = -1.2,
    keyY = 1.2,
    keyZ = 2.0,
    fillDimmer = 0.7,
    ambientScale = 1.0,
    diffuseScale = 1.3,

    -- false: every session starts from this file; true: reload saved MCM edits
    useSavedConfig = false,
}
