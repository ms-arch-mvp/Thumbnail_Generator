-- Async batch rendering queue: polls the image_resize thread pool and drives
-- itself via the enterFrame event.
local this = {}

local renderer = require("ThumbnailGenerator.render")
local thumbnail_settings = require("ThumbnailGenerator.modules.thumbnail_settings")
local subject_resolver = require("ThumbnailGenerator.modules.subject_resolver")
local rotation_exceptions = require("ThumbnailGenerator.modules.rotation_exceptions")
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

-- True if this subject's output file already exists (extension follows the
-- batch output format, matching what render() writes).
local function thumbnailExists(subject, meshPath)
    local outputPath = renderer.getOutputPath(subject, meshPath)
    local format = settings.current.outputFormat
    if format ~= "tga" and format ~= "dds" then format = "png" end
    outputPath = outputPath:gsub("%.%a+$", "") .. "." .. format
    return lfs.fileexists(outputPath)
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


-- Two phases per frame: reclaim completed compression jobs, then submit new
-- render jobs up to poolSize. Unregisters itself once the batch completes.
local function onFrame()
    if not activeBatch then
        event.unregister("enterFrame", onFrame)
        return
    end

    local batch = activeBatch
    local pool = getPixelPool(batch.resolution)

    local completed = pool:pollCompleted()
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
        completed = pool:pollCompleted()
    end

    local lastSubmittedIndexThisFrame = nil
    while batch.activeJobsCount < poolSize and batch.nextIndex <= #batch.items and batch.completedCount + batch.activeJobsCount < batch.limit do
        local slotIndex, slotObject = pool:acquire()
        if not slotIndex then
            break -- All buffer slots are currently busy, wait for next frame
        end

        local subject = batch.items[batch.nextIndex]
        local mPath = subject.meshPath
        local outputPath = renderer.getOutputPath(subject, mPath)
        local cfg = subject.config

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
                    zoom = cfg.zoom,
                    perspectiveDistanceFactor = cfg.perspectiveDistanceFactor,
                    keyDimmer = cfg.keyDimmer,
                    keyX = cfg.keyX,
                    keyY = cfg.keyY,
                    keyZ = cfg.keyZ,
                    fillDimmer = cfg.fillDimmer,
                    ambientScale = cfg.ambientScale,
                    diffuseScale = cfg.diffuseScale,
                    -- The MCM toggle is authoritative for the whole batch (not
                    -- `or cfg.ortho` -- that defaults true and would defeat toggling off).
                    ortho = batch.forceOrtho,
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

    if lastSubmittedIndexThisFrame then
        batch.camera.scene = batch.oldScene
        if batch.camera.scene then
            batch.camera.scene:update()
            batch.camera.scene:updateEffects()
            batch.camera.scene:updateProperties()
        end
    end

    local totalToRender = math.min(#batch.items, batch.limit)
    if batch.onProgress then
        batch.onProgress(batch.completedCount, totalToRender)
    end

    if batch.completedCount >= totalToRender then
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
            batch.onError("Batch rendering cancelled by user.")
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
    local searchPattern = params.searchPattern
    if searchPattern == "" then searchPattern = nil end

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
    local subjects = {}
    local seenMeshes = {}

    for _, objType in ipairs(types) do
        for obj in tes3.iterateObjects(objType) do
            local isActor = objType == tes3.objectType.npc or objType == tes3.objectType.creature
            -- One render per base record: skip per-placement instances and filtered NPCs.
            local skip = (isActor and obj.isInstance == true)
                or (objType == tes3.objectType.npc
                    and settings.current.npcFiltering and not npcPassesFilter(obj))

            local mesh = not skip and obj.mesh
            if mesh and mesh:lower():match("%.nif$") then
                local matches = true
                if searchPattern then
                    local name = (obj.name or ""):lower()
                    local id = (obj.id or ""):lower()
                    local mPath = mesh:lower()
                    local sourceMod = (obj.sourceMod or ""):lower()
                    local pat = searchPattern:lower()
                    matches = (name:find(pat, 1, true) or id:find(pat, 1, true) or mPath:find(pat, 1, true) or
                        sourceMod:find(pat, 1, true)) ~= nil
                end

                if matches then
                    local meshKey = subject_resolver.normalizeMeshPath(mesh)
                    -- NPCs share base skeleton meshes (looks are composited at
                    -- instancing), so dedupe them by record id instead of mesh.
                    local dedupeKey = meshKey
                    if objType == tes3.objectType.npc then
                        dedupeKey = "npc:" .. (obj.id or ""):lower()
                    end
                    if dedupeKey ~= "" and not seenMeshes[dedupeKey] then
                        local skip = settings.current.renderOnlyRotationExceptions
                            and not rotation_exceptions.match(meshKey)
                        if not skip then
                            seenMeshes[dedupeKey] = true
                            local subject = subject_resolver.resolve(obj)
                            if not (settings.current.skipExistingThumbnails and thumbnailExists(subject, mesh)) then
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

    local oldScene = camera.scene

    activeBatch = {
        items = subjects,
        limit = limit,
        resolution = resolution,
        dstWidth = params.dstWidth or params.dstResolution or 1024,
        dstHeight = params.dstHeight or params.dstResolution or 1024,
        forceOrtho = params.forceOrtho or false,
        outputFormat = settings.current.outputFormat,
        nextIndex = 1,
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

    event.register("enterFrame", onFrame)
end


return this
