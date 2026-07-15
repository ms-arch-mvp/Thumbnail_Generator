local this = {}

local thumbnail_settings = require("ThumbnailGenerator.modules.thumbnail_settings")
local settings = thumbnail_settings

function this.registerModConfig()
    local template = mwse.mcm.createTemplate("Thumbnail Generator")
    template:saveOnClose("Thumbnail Generator", settings.current)

    local typesPage = template:createSideBarPage({
        label = "Object Types",
        description = "Choose which object type categories are included when rendering a batch.",
    })

    local group = typesPage:createCategory("Object Types to Render")

    local typeToggles = {}
    for _, meta in ipairs(thumbnail_settings.typeMetadataSorted) do
        typeToggles[meta.key] = group:createYesNoButton({
            label = meta.label,
            description = "Whether " .. meta.label .. " are included when rendering a batch.",
            variable = mwse.mcm.createTableVariable({ id = meta.key, table = settings.current.enabledTypes }),
        })
    end

    local function setAllEnabledTypes(value)
        for key, toggle in pairs(typeToggles) do
            settings.current.enabledTypes[key] = value
            toggle:update()
        end
    end

    local group = typesPage:createCategory("Bulk Selection")

    group:createButton({
        label = "Select All",
        buttonText = "Select All",
        description = "Enable every object type category above.",
        callback = function() setAllEnabledTypes(true) end,
    })

    group:createButton({
        label = "Clear All",
        buttonText = "Clear All",
        description = "Disable every object type category above.",
        callback = function() setAllEnabledTypes(false) end,
    })

    local settingsPage = template:createSideBarPage({
        label = "Render Settings",
        description = "Configure output, rendering quality, projection, and batch filters.",
    })

    local resolutionOptions = {}
    for _, value in ipairs(settings.resolutionOptions) do
        table.insert(resolutionOptions, { label = string.format("%dx%d", value, value), value = value })
    end

    local formatOptions = {
        { label = "PNG", value = "png" },
        { label = "TGA", value = "tga" },
        { label = "DDS", value = "dds" },
    }

    local group = settingsPage:createCategory("Output")

    group:createTextField({
        label = "Folder Path",
        description = "Folder name that rendered thumbnails are written under, inside Data Files (e.g. \"Thumbnail Generator\").\n\z
            Shared by batch and preview renders.",
        buttonText = "Apply",
        variable = mwse.mcm.createTableVariable({ id = "outputFolder", table = settings.current }),
    })

    local group = settingsPage:createCategory("Camera")

    group:createSlider({
        label = "Global Rotation",
        description = "Additional global rotation clockwise.",
        min = -180,
        max = 180,
        step = 1,
        jump = 15,
        variable = mwse.mcm.createTableVariable({ id = "globalRotation", table = settings.current }),
    })

    group:createYesNoButton({
        label = "Orthographic",
        description = "Force orthographic in batch and preview.",
        variable = mwse.mcm.createTableVariable({ id = "forceOrtho", table = settings.current }),
    })

    group:createYesNoButton({
        label = "Fit to Frame",
        description = "When enabled, renders tighten the crop to the subject's visible pixels.\n\z
            When disabled, renders keep the looser first-pass framing with margin (and preview zoom/pan can carry into the output).",
        variable = mwse.mcm.createTableVariable({ id = "fitToFrame", table = settings.current }),
    })

    local group = settingsPage:createCategory("Batch")

    group:createDropdown({
        label = "Mode",
        description = "Thumbnails: render images into the output folder (default).\nExport: save each matched subject as a .nif under <output folder>\\exports instead of rendering images.",
        options = {
            { label = "Thumbnails", value = "thumbnails" },
            { label = "Export",     value = "export" },
        },
        variable = mwse.mcm.createTableVariable({ id = "batchMode", table = settings.current }),
    })

    group:createDropdown({
        label = "Render Resolution",
        description = "Offscreen render target size used for batch rendering.",
        options = resolutionOptions,
        variable = mwse.mcm.createTableVariable({ id = "renderResolution", table = settings.current }),
    })

    group:createDropdown({
        label = "Output Resolution",
        description = "Final image size batch renders are downscaled to.",
        options = resolutionOptions,
        variable = mwse.mcm.createTableVariable({ id = "outputResolution", table = settings.current }),
    })

    group:createDropdown({
        label = "Output Format",
        description = "PNG (compressed), TGA (uncompressed), or DDS (uncompressed).",
        options = formatOptions,
        variable = mwse.mcm.createTableVariable({ id = "outputFormat", table = settings.current }),
    })

    group:createYesNoButton({
        label = "Skip Empty Renders",
        description = "Don't write files that contain nothing visible (e.g. magic-effect records with no drawable content).\n\z
            Skipped items are listed in logs/empty.txt when logging is enabled.",
        variable = mwse.mcm.createTableVariable({ id = "skipEmptyRenders", table = settings.current }),
    })

    group:createYesNoButton({
        label = "Skip Existing Thumbnails",
        description = "Don't re-render an item whose output file already exists in the output folder.\n\z
            Useful for resuming a large batch without redoing finished thumbnails.",
        variable = mwse.mcm.createTableVariable({ id = "skipExistingThumbnails", table = settings.current }),
    })

    group:createYesNoButton({
        label = "Render Only Rotation Exceptions",
        description = "When enabled, batch rendering skips every mesh that has no entry in rotation_exceptions.txt.\n\z
            Useful for re-rendering just the items that needed a manual rotation correction after editing that file.",
        variable = mwse.mcm.createTableVariable({ id = "renderOnlyRotationExceptions", table = settings.current }),
    })

    group:createYesNoButton({
        label = "NPC Filtering",
        description = "When enabled, batch rendering only includes NPCs that respawn and have no attached script (and skips a small blacklist of duplicate guard/ordinator records).\n\z
            When disabled, every NPC record is rendered.",
        variable = mwse.mcm.createTableVariable({ id = "npcFiltering", table = settings.current }),
    })

    group:createYesNoButton({
        label = "Write Log Files",
        description = "After a batch, write logs/failed.txt and logs/empty.txt (one entry per line) into the output folder.\n\z
            Logs from a run with no failures/empties are removed.",
        variable = mwse.mcm.createTableVariable({ id = "writeLogs", table = settings.current }),
    })

    group = settingsPage:createCategory("Preview")

    group:createDropdown({
        label = "Render Resolution",
        description = "Offscreen render target size used by the preview window's render button.",
        options = resolutionOptions,
        variable = mwse.mcm.createTableVariable({ id = "previewRenderResolution", table = settings.current }),
    })

    group:createDropdown({
        label = "Output Resolution",
        description = "Final image size for the preview window's render button.",
        options = resolutionOptions,
        variable = mwse.mcm.createTableVariable({ id = "previewOutputResolution", table = settings.current }),
    })

    group:createDropdown({
        label = "Output Format",
        description = "PNG (compressed), TGA (uncompressed), or DDS (uncompressed).",
        options = formatOptions,
        variable = mwse.mcm.createTableVariable({ id = "previewOutputFormat", table = settings.current }),
    })

    group:createDropdown({
        label = "Export Filename",
        description = "Filename used by the preview window's Export button:\n\z
            the record's display name, its record id, or the mesh file's base name (NPCs fall back to their id).",
        options = {
            { label = "ID", value = "id" },
            { label = "Name", value = "name" },
            { label = "Mesh", value = "mesh" },
        },
        variable = mwse.mcm.createTableVariable({ id = "exportFilename", table = settings.current }),
    })

    group = settingsPage:createCategory("Profiles")

    group:createYesNoButton({
        label = "Use Profiles",
        description = "Apply profiles saved from the preview's Save Profile button: matching records inherit the profile's camera, lighting, ortho/fit, and zoom/pan in both batch renders and previews.\n\z
            Scope precedence: search > type > all; latest saved wins.\n\z
            Each profile is its own file under the output folder's \"profiles\" subfolder; delete a file to remove its profile (loaded at startup).",
        variable = mwse.mcm.createTableVariable({ id = "useProfiles", table = settings.current }),
    })

    mwse.mcm.register(template)
end

return this
