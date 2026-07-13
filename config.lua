local constants = require("ThumbnailGenerator.constants")

-- All object categories enabled by default.
local enabledTypes = {}
for _, meta in ipairs(constants.typeMetadata) do
    enabledTypes[meta.key] = true
end

local config = {

    -- =============================================================================
    -- GENERAL
    -- =============================================================================

    outputFolder = "Thumbnail Generator",
    flaggedMeshesFile = "flagged_meshes.txt",
    useSavedConfig = false,

    resolutionOptions = { 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384 },

    -- =============================================================================
    -- CAMERA
    -- =============================================================================

    globalRotation = 0,
    forceOrtho = true,
    fitToFrame = true,

    orthoDistanceFactor = 200, -- higher = flatter
    perspectiveDistanceFactor = 8, -- lower = wider-angle look

    -- Base view per category, MW world axes (+X east, +Y north, +Z up);
    -- unlisted types use "standard".
    viewDirections = {
        bodypart = { 0, -1, 0 },
        creature = { -1, 1, 1 },
        hair     = { 1, -1, 1 },
        npc      = { 0, 1, 0 },
        standard = { 1, -1, 1 },
    },

    -- =============================================================================
    -- BATCH
    -- =============================================================================

    enabledTypes = enabledTypes,
    renderResolution = 2048,
    outputResolution = 1024,
    outputFormat = "png", -- "png", "tga" or "dds"

    -- "thumbnails" (default): render PNGs/TGAs/DDSs into the output folder.
    -- "export": save each subject as a .nif under <output>\exports instead.
    batchMode = "thumbnails",

    skipEmptyRenders = true,
    skipExistingThumbnails = false,
    renderOnlyRotationExceptions = false,

    npcFiltering = true,
    npcRequireRespawn = true,
    npcIncludePattern = "outfit", -- ids containing this always pass (empty to disable)

    writeLogs = true,

    -- =============================================================================
    -- PREVIEW
    -- =============================================================================

    previewRenderResolution = 2048,
    previewOutputResolution = 1024,
    previewOutputFormat = "png",
    panSpeed = 0.75, -- subject radii per second

    -- Filename used by the preview window's Export button: "name" (display name),
    -- "id" (record id), or "mesh" (the mesh file's base name; NPCs fall back to id
    -- since they have no single mesh).
    exportFilename = "mesh",

    -- Config-only (no MCM)
    previewForceVertexLighting = false,
    previewDollyFit = false,

    -- =============================================================================
    -- PROFILES
    -- =============================================================================

    useProfiles = true,

    -- =============================================================================
    -- RENDER DEFAULTS
    -- =============================================================================

    yaw = 0,
    pitch = 0,
    roll = 0,
    zoom = 1.0,
    panX = 0,
    panY = 0,
    ortho = true,
    lodAdjust = 0.001,
    particlePrimeTime = 0, -- seconds of pre-simulation; 0 = capture live state

    keyDimmer = 1.2,
    keyX = -1.2,
    keyY = 1.2,
    keyZ = 2.0,
    fillDimmer = 0.7,
    ambientScale = 1.0,
    diffuseScale = 1.3,
}

return config
