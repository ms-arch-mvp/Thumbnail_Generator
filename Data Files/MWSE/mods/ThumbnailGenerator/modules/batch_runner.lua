-- Async batch rendering queue: polls the image_resize thread pool and drives
-- itself via the enterFrame event.
local this = {}

local renderer = require("ThumbnailGenerator.render")
local thumbnail_settings = require("ThumbnailGenerator.modules.thumbnail_settings")
local subject_resolver = require("ThumbnailGenerator.modules.subject_resolver")
local rotation_exceptions = require("ThumbnailGenerator.modules.rotation_exceptions")
local scene_builder = require("ThumbnailGenerator.modules.scene_builder")
local settings = thumbnail_settings
local ir = require("image_resize.image_resize")

local poolSize = 4

-- NPC keep rule: keep an NPC only if its id isn't blacklisted, its RESPAWN flag
-- is set, and it has no script. Gated behind the "NPC Filtering" MCM setting;
-- the respawn requirement and the always-include pattern come from config.
local excludedNpcIds = {
    ["imperial guard_prisoner"] = true,
    ["imperial guard_m_sadri"] = true,
    ["ordinator_mh_sadri"] = true,
    ["ordinator_high fane"] = true,
    ["ordinator_wander_hvault"] = true,
    ["ordinator_wander_tvault"] = true,
}

local function npcPassesFilter(obj)
    local id = (obj.id or ""):lower()
    if excludedNpcIds[id] then return false end
    -- An id containing the include pattern is kept unconditionally.
    local includePattern = settings.current.npcIncludePattern
    if includePattern and includePattern ~= "" and id:find(includePattern, 1, true) then return true end
    if settings.current.npcRequireRespawn and not obj.isRespawn then return false end
    if obj.script ~= nil then return false end
    return true
end

local pixelPool = nil

local currentPoolResolution = nil

local function getPixelPool(resolution)
    if not pixelPool or currentPoolResolution ~= resolution then
        pixelPool = ir.newPool(poolSize, resolution)
        currentPoolResolution = resolution
    end
    return pixelPool
end

local activeBatch = nil

function this.isBatchActive()
    return activeBatch ~= nil
end

-- True if this subject's output file already exists (extension follows the
-- batch output format, matching what render() writes).
local function thumbnailExists(subject, meshPath)
    local outputPath = renderer.getOutputPath(subject, meshPath)
    local format = settings.current.outputFormat
    if format ~= "tga" and format ~= "dds" then format = "png" end
    outputPath = outputPath:gsub("%.%a+$", "") .. "." .. format
    return lfs.fileexists(outputPath)
end

-- Reads the flagged list (one pattern per line) from the output folder and
-- compiles it into a single predicate: a record is flagged if any line matches it
-- under the shared search semantics (substring / glob / comma AND-terms), so an
-- entry like "f\furn_com_bar_0" flags every numbered variant and the trailing
-- ".nif" is optional. Blank lines and "#" comments are ignored. Returns the
-- matcher, the file path, and the pattern count (nil matcher if the file is absent).
local function readFlaggedMatcher()
    local path = settings.getOutputFolder() .. "\\" .. (settings.current.flaggedMeshesFile or "flagged_meshes.txt")
    local file = io.open(path, "r")
    if not file then return nil, path end

    local matchers = {}
    for line in file:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            -- Entries may carry a leading "meshes\"; record mesh paths don't.
            line = line:gsub("^[Mm][Ee][Ss][Hh][Ee][Ss][\\/]", "")
            local matcher = subject_resolver.compileMatcher(line)
            if matcher then table.insert(matchers, matcher) end
        end
    end
    file:close()

    local flaggedMatcher = function(obj)
        for _, matcher in ipairs(matchers) do
            if matcher(obj) then return true end
        end
        return false
    end
    return flaggedMatcher, path, #matchers
end

local function logEntry(subject)
    if subject.objectType == tes3.objectType.npc then
        return "npc: " .. (subject.recordId or "?")
    end
    return subject.meshPath or subject.recordId or "?"
end

-- One path per line; a run with no entries removes the stale file so the logs
-- always reflect the latest batch.
local function writePathLog(path, entries)
    if #entries > 0 then
        renderer.ensureDirectory(path)
        local file = io.open(path, "w")
        if file then
            file:write(table.concat(entries, "\n"), "\n")
            file:close()
        end
    else
        pcall(os.remove, path)
    end
end

local function writeBatchLogs(batch)
    if not settings.current.writeLogs then return end
    local logsDir = settings.getOutputFolder() .. "\\logs"
    writePathLog(logsDir .. "\\failed.txt", batch.failedEntries)
    writePathLog(logsDir .. "\\empty.txt", batch.emptyEntries)
end


-- Exports a single subject as a .nif file into <output>\exports, mirroring the
-- preview's Export button. Returns the written path, or errors on failure.
local function exportSubject(subject)
    local obj = subject.object
    local exportRoot

    if obj and (obj.objectType == tes3.objectType.npc
            or obj.objectType == tes3.objectType.creature) then
        local wrapper = scene_builder.createActorScene(obj)
        exportRoot = wrapper.children[1]
        wrapper:detachChild(exportRoot)
    else
        local mesh = tes3.loadMesh(subject.meshPath)
        if not mesh then
            error("Failed to load mesh: " .. tostring(subject.meshPath))
        end
        exportRoot = mesh:clone()
    end

    exportRoot.translation = tes3vector3.new(0, 0, 0)

    local mode = settings.current.exportFilename
    local rawName
    if mode == "id" then
        rawName = subject.recordId or subject.displayName
    elseif mode == "mesh" then
        if obj and obj.objectType == tes3.objectType.npc then
            rawName = subject.recordId
        else
            local meshPath = subject.normalizedMeshPath
            if meshPath and meshPath ~= "" then
                rawName = meshPath:match("[^/]+$") or meshPath
            end
            rawName = rawName or subject.recordId or subject.displayName
        end
    else
        rawName = subject.displayName or subject.recordId
    end
    rawName = rawName or "export"
    local safeName = rawName:gsub("[^%w %._-]", "_")
    exportRoot.name = safeName

    local exportDir = settings.getOutputFolder() .. "\\exports"
    renderer.ensureDirectory(exportDir .. "\\")
    local fullPath = (exportDir .. "\\" .. safeName .. ".nif"):gsub("[/\\]+", "\\")

    exportRoot:update()
    exportRoot:saveBinary(fullPath)
    return fullPath
end

-- Two phases per frame: reclaim completed compression jobs, then submit new
-- render jobs up to poolSize. Unregisters itself once the batch completes.
local function onFrame()
    if not activeBatch then
        event.unregister("enterFrame", onFrame)
        return
    end

    local batch = activeBatch
    local pool = batch.batchMode ~= "export" and getPixelPool(batch.resolution) or nil

    local completed = pool and pool:pollCompleted()
    while completed do
        local key = tostring(completed.job_id)
        local item = batch.activeJobs[key]
        if item then
            batch.activeJobs[key] = nil
            batch.activeJobsCount = batch.activeJobsCount - 1
            batch.completedCount = batch.completedCount + 1

            if completed.status == 0 then
                batch.successCount = batch.successCount + 1
            else
                mwse.log("Thumbnail generation failed for jobId %s (errorCode: %d)", key, completed.error_code)
                table.insert(batch.failedEntries, logEntry(item))
            end
        end
        completed = pool and pool:pollCompleted()
    end

    local lastSubmittedIndexThisFrame = nil

    -- Export mode: process synchronously, no pool needed.
    if batch.batchMode == "export" then
        -- Process up to ~20 exports per frame to keep the game responsive.
        local perFrame = 20
        local processed = 0
        while batch.nextIndex <= #batch.items
                and batch.completedCount < batch.remainingToRender
                and processed < perFrame do
            local subject = batch.items[batch.nextIndex]
            local ok, result = pcall(exportSubject, subject)
            if ok then
                batch.successCount = batch.successCount + 1
            else
                mwse.log("[Thumbnail Generator] Export failed for %s: %s",
                    logEntry(subject), tostring(result))
                table.insert(batch.failedEntries, logEntry(subject))
            end
            batch.completedCount = batch.completedCount + 1
            batch.nextIndex = batch.nextIndex + 1
            processed = processed + 1
        end
    else

    while batch.activeJobsCount < poolSize and batch.nextIndex <= #batch.items and batch.completedCount + batch.activeJobsCount < batch.remainingToRender do
        local slotIndex, slotObject = pool:acquire()
        if not slotIndex then
            break -- All buffer slots are currently busy, wait for next frame
        end

        local subject = batch.items[batch.nextIndex]
        local mPath = subject.meshPath
        local outputPath = renderer.getOutputPath(subject, mPath)
        local cfg = subject.config
        local fitToFrame = settings.current.fitToFrame ~= false
        local ortho = batch.forceOrtho
        -- A matched profile's saved toggles win over the batch-wide MCM values.
        if subject.appliedProfile then
            fitToFrame = cfg.fitToFrame == true
            ortho = cfg.ortho == true
        end
        -- Match preview behavior: when fitting to frame, zoom/pan are moot (refit
        -- re-crops to content), so force neutral values for consistency.
        local zoom = fitToFrame and 1.0 or cfg.zoom
        local panX = fitToFrame and 0 or cfg.panX
        local panY = fitToFrame and 0 or cfg.panY

        local dirOk, dirErr = pcall(function()
            renderer.ensureDirectory(outputPath)
        end)

        if dirOk then
            local renderOk, slotOrErr, pathOrErr = pcall(function()
                return renderer.render({
                    subject = subject,
                    meshPath = mPath,
                    outputPath = outputPath,
                    yaw = cfg.yaw,
                    pitch = cfg.pitch,
                    roll = cfg.roll,
                    zoom = zoom,
                    panX = panX,
                    panY = panY,
                    perspectiveDistanceFactor = cfg.perspectiveDistanceFactor,
                    keyDimmer = cfg.keyDimmer,
                    keyX = cfg.keyX,
                    keyY = cfg.keyY,
                    keyZ = cfg.keyZ,
                    fillDimmer = cfg.fillDimmer,
                    ambientScale = cfg.ambientScale,
                    diffuseScale = cfg.diffuseScale,
                    fitToFrame = fitToFrame,
                    -- The MCM toggle is authoritative for the whole batch (not
                    -- `or cfg.ortho` -- that defaults true and would defeat
                    -- toggling off); profiled records carry their own (above).
                    ortho = ortho,
                    skipEmpty = settings.current.skipEmptyRenders,
                    outputFormat = batch.outputFormat,
                    resolution = batch.resolution,
                    pixelData = slotObject,
                    async = true,
                    keepSceneActive = true, -- Optimization: avoid flipping back/forth for every item this frame
                    recordId = subject.recordId,
                })
            end)

            if renderOk and slotOrErr == nil then
                -- Nothing visible rendered; skipped by skipEmptyRenders.
                batch.completedCount = batch.completedCount + 1
                batch.emptyCount = batch.emptyCount + 1
                table.insert(batch.emptyEntries, logEntry(subject))
            elseif renderOk then
                local dstWidth = batch.dstWidth or 1024
                local dstHeight = batch.dstHeight or 1024
                local flipY = false
                local pngCompression = ir.PNG_COMPRESSION_BALANCED

                -- The pool selects PNG/TGA/DDS from the path's extension.
                local jobId, err = pool:submit(slotIndex, batch.resolution, batch.resolution, dstWidth, dstHeight, flipY,
                    pngCompression, pathOrErr)
                if jobId then
                    batch.activeJobs[tostring(jobId)] = subject
                    batch.activeJobsCount = batch.activeJobsCount + 1
                    lastSubmittedIndexThisFrame = batch.nextIndex
                else
                    -- retry this index next frame
                    batch.nextIndex = batch.nextIndex - 1
                    break
                end
            else
                mwse.log("Failed to render mesh %s: %s", mPath, tostring(slotOrErr))
                batch.completedCount = batch.completedCount + 1
                table.insert(batch.failedEntries, logEntry(subject))
            end
        else
            mwse.log("Failed to create directory for %s: %s", outputPath, tostring(dirErr))
            batch.completedCount = batch.completedCount + 1
            table.insert(batch.failedEntries, logEntry(subject))
        end

        batch.nextIndex = batch.nextIndex + 1
    end

    end -- batchMode == "export" else

    if lastSubmittedIndexThisFrame then
        batch.camera.scene = batch.oldScene
        if batch.camera.scene then
            batch.camera.scene:update()
            batch.camera.scene:updateEffects()
            batch.camera.scene:updateProperties()
        end
    end

    -- Progress is the absolute position in the whole batch: items before the
    -- resume point count as already done, so a resumed run reads e.g. 2400/5000.
    if batch.onProgress then
        batch.onProgress((batch.startIndex - 1) + batch.completedCount, batch.totalItems)
    end

    if batch.completedCount >= batch.remainingToRender then
        writeBatchLogs(batch)

        if batch.onComplete then
            batch.onComplete(#batch.items, batch.successCount, batch.emptyCount, #batch.failedEntries)
        end

        activeBatch = nil
        event.unregister("enterFrame", onFrame)
    end
end

function this.cancelBatch()
    if activeBatch then
        local batch = activeBatch
        event.unregister("enterFrame", onFrame)

        batch.camera.scene = batch.oldScene
        if batch.camera.scene then
            batch.camera.scene:update()
            batch.camera.scene:updateEffects()
            batch.camera.scene:updateProperties()
        end

        writeBatchLogs(batch)

        if batch.onError then
            batch.onError("Batch rendering cancelled.")
        end

        activeBatch = nil
    end
end


-- Scans matching objects, dedupes, and kicks off the async batch. Also reads
-- settings.current.renderOnlyRotationExceptions directly.
function this.renderBatch(params)
    params = params or {}
    local resolution = params.resolution or 2048
    local limit = params.limit or math.huge
    -- Shared matcher: comma AND-terms + glob wildcards (nil = match all).
    local searchMatcher = subject_resolver.compileMatcher(params.searchPattern)

    if activeBatch then
        if params.onError then
            params.onError("A batch render is already in progress.")
        end
        return
    end

    local camera = tes3.getCamera()
    if not camera then
        if params.onError then
            params.onError("No camera found")
        end
        return
    end

    -- Flagged run: restrict to records matching a pattern in the flagged file.
    local flaggedMatcher
    if params.flaggedOnly then
        local matcher, path, count = readFlaggedMatcher()
        if not matcher then
            if params.onError then params.onError("Flagged file not found:\n" .. tostring(path)) end
            return
        end
        if count == 0 then
            if params.onError then params.onError("Flagged file is empty.") end
            return
        end
        flaggedMatcher = matcher
    end

    local types = params.objectType
    if types == nil then
        types = {}
        for _, meta in ipairs(thumbnail_settings.typeMetadata) do
            table.insert(types, meta.type)
        end
    elseif type(types) == "number" then
        types = { types }
    end

    -- Deduplicated by mesh path -- records sharing a mesh render once.
    -- In export mode, each record gets its own file, so dedupe by record id only.
    local isExportMode = (settings.current.batchMode == "export")
    local subjects = {}
    local seenMeshes = {}

    for _, objType in ipairs(types) do
        for obj in tes3.iterateObjects(objType) do
            local isActor = objType == tes3.objectType.npc or objType == tes3.objectType.creature
            -- One render per base record: skip per-placement instances and filtered NPCs.
            -- Export mode bypasses npcFiltering so every NPC record is exported,
            -- matching the preview which exports any NPC you open regardless of filter.
            local skip = (isActor and obj.isInstance == true)
                or (not isExportMode
                    and objType == tes3.objectType.npc
                    and settings.current.npcFiltering and not npcPassesFilter(obj))

            local mesh = not skip and obj.mesh
            if mesh and mesh:lower():match("%.nif$") then
                local matches = not searchMatcher or searchMatcher(obj)

                if matches then
                    local meshKey = subject_resolver.normalizeMeshPath(mesh)
                    -- In export mode dedupe by record id (each record is a separate file).
                    -- In thumbnail mode dedupe by mesh (records sharing a mesh write once).
                    local dedupeKey
                    if isExportMode then
                        dedupeKey = (obj.id or ""):lower()
                    elseif objType == tes3.objectType.npc then
                        -- NPCs share base skeleton meshes (looks are composited at
                        -- instancing), so dedupe them by record id instead of mesh.
                        dedupeKey = "npc:" .. (obj.id or ""):lower()
                    else
                        dedupeKey = meshKey
                    end
                    if dedupeKey ~= "" and not seenMeshes[dedupeKey] then
                        local skipRecord = (not isExportMode and settings.current.renderOnlyRotationExceptions
                                and not rotation_exceptions.match(meshKey))
                            or (flaggedMatcher and not flaggedMatcher(obj))
                        if not skipRecord then
                            seenMeshes[dedupeKey] = true
                            local subject = subject_resolver.resolve(obj)
                            -- skipExistingThumbnails only applies to thumbnail mode.
                            local skipExisting = not isExportMode
                                and settings.current.skipExistingThumbnails
                                and thumbnailExists(subject, mesh)
                            if not skipExisting then
                                table.insert(subjects, subject)
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(subjects, function(a, b)
        if a.typeKey ~= b.typeKey then
            return a.typeKey < b.typeKey
        end
        return a.recordId < b.recordId
    end)

    -- Resume point: 1-based index into the sorted batch. Items before it are
    -- treated as already done (they still count toward the displayed total).
    local startIndex = math.max(1, math.floor(params.startIndex or 1))
    if startIndex > 1 and startIndex > #subjects then
        if params.onError then
            params.onError(string.format("Resume index %d exceeds batch size %d.", startIndex, #subjects))
        end
        return
    end
    -- Renders remaining this run; the display total stays the whole batch.
    local remainingToRender = math.min(#subjects - (startIndex - 1), limit)

    local oldScene = camera.scene

    activeBatch = {
        items = subjects,
        totalItems = #subjects,
        startIndex = startIndex,
        remainingToRender = remainingToRender,
        batchMode = settings.current.batchMode or "thumbnails",
        resolution = resolution,
        dstWidth = params.dstWidth or params.dstResolution or 1024,
        dstHeight = params.dstHeight or params.dstResolution or 1024,
        forceOrtho = params.forceOrtho or false,
        outputFormat = settings.current.outputFormat,
        nextIndex = startIndex,
        activeJobs = {},
        activeJobsCount = 0,
        completedCount = 0,
        successCount = 0,
        emptyCount = 0,
        emptyEntries = {},
        failedEntries = {},
        camera = camera,
        oldScene = oldScene,
        onProgress = params.onProgress,
        onComplete = params.onComplete,
        onError = params.onError,
    }

    mwse.log("[Thumbnail Generator] Starting batch: mode=%s, subjects=%d, remainingToRender=%d",
        settings.current.batchMode or "thumbnails", #subjects, remainingToRender)

    event.register("enterFrame", onFrame)
end


return this
