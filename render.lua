-- Core mesh-to-PNG thumbnail rendering pipeline.
local this = {}

local ir = require("image_resize.image_resize")
ir.load()
pcall(ir.init, 0, 4)


local ffi = require("ffi")

local settings = require("ThumbnailGenerator.modules.thumbnail_settings")
local lighting = require("ThumbnailGenerator.modules.lighting")
local subject_resolver = require("ThumbnailGenerator.modules.subject_resolver")
local camera_profiles = require("ThumbnailGenerator.modules.camera_profiles")
local framing = require("ThumbnailGenerator.modules.framing")
local scene_builder = require("ThumbnailGenerator.modules.scene_builder")
local matte = require("ThumbnailGenerator.modules.matte")

-- NI::Camera::viewFrustum: six floats {left, right, top, bottom, near, far} at
-- offset 0x100. MWSE has no Lua setter for it, so it's poked directly via FFI.
local frustumOffset = 0x100

-- Both modes dolly the camera by a radius multiple and poke a fitted frustum.
-- Particle sprites shrink with the raw dolly distance (the frustum doesn't
-- compensate them), so a too-large ortho factor kills candle flames.
local perspectiveDistanceFactor = 8

-- margin=1.0 is clip-safe since the 8-corner AABB already supersets the projected
-- geometry; only the fake-ortho fit uses this.
local orthoMargin = 1.0

-- First-pass headroom; the pixel refit re-crops at full resolution, so
-- generosity costs nothing and protects content the measurement can't see.
local firstPassMargin = 1.25

local function getFrustumPtr(camera)
    local base = mwse.memory.addressOf(camera)
    assert(base and base ~= 0, "could not resolve camera address for frustum poke")
    return ffi.cast("float*", base + frustumOffset)
end

function this.getFrustum(camera)
    local f = getFrustumPtr(camera)
    return { f[0], f[1], f[2], f[3], f[4], f[5] }
end


-- A poke persists until the next FOV/camera-mode/cell/video change; live callers
-- must re-apply each frame. camera:update() also refreshes culling planes.
function this.setFrustum(camera, frustum)
    local f = getFrustumPtr(camera)
    for i = 0, 5 do f[i] = frustum[i + 1] end
    camera:update()
end


this.addThumbnailLighting = lighting.addThumbnailLighting

function this.renderBatch(params)
    return require("ThumbnailGenerator.modules.batch_runner").renderBatch(params)
end


function this.cancelBatch()
    return require("ThumbnailGenerator.modules.batch_runner").cancelBatch()
end

-- Scene construction/normalization lives in modules/scene_builder; re-exported
-- here so every caller keeps going through render.
this.createActorScene = scene_builder.createActorScene
this.createRenderableScene = scene_builder.createRenderableScene
this.createRootNode = scene_builder.createRootNode
this.adaptParticleBlends = scene_builder.adaptParticleBlends


-- Subject orientation as a turntable orbit: yaw = azimuth about world up,
-- pitch = elevation, roll = spin about the view axis. Yaw/pitch steer the view
-- DIRECTION and the lookAt below re-pins up to world Z every frame, so the orbit
-- is roll-free (the subject never tips off vertical) and reduces to two scalars
-- the sliders track. Rotation exceptions already steer this same direction, and
-- batch keeps yaw=pitch=0, so their framing is byte-identical to before.
function this.getSceneRotation(params)
    local camera = params.camera
    local config = params.config or {}
    local profile = params.profile

    -- globalRotation is a shared azimuth added to every render (batch + preview),
    -- applied about world Z exactly like the preview's yaw / Rotate 90.
    local yaw = (config.yaw or 0) + (settings.current.globalRotation or 0)
    local pitch = config.pitch or 0
    local roll = config.roll or 0

    local offsetDir = camera_profiles.offsetDirForProfile(profile)

    -- Azimuth: swing the view direction around world Z.
    if yaw ~= 0 then
        local azimuth = tes3matrix33.new()
        azimuth:toRotationZ(math.rad(yaw))
        offsetDir = azimuth * offsetDir
    end
    -- Elevation: tilt about the horizontal axis perpendicular to the view
    -- (world up x view = (-y, x, 0)); skip when the view is already vertical.
    if pitch ~= 0 then
        local ax, ay = -offsetDir.y, offsetDir.x
        local len = math.sqrt(ax * ax + ay * ay)
        if len > 1e-5 then
            local elevation = tes3matrix33.new()
            elevation:toRotation(math.rad(pitch), ax / len, ay / len, 0)
            offsetDir = elevation * offsetDir
        end
    end

    local cameraBasis = tes3matrix33.new()
    cameraBasis:lookAt(camera.worldDirection, camera.worldUp)

    local virtualBasis = tes3matrix33.new()
    virtualBasis:lookAt(-offsetDir, tes3vector3.new(0, 0, 1))

    local rollRotation = tes3matrix33.new()
    rollRotation:toRotationY(math.rad(roll))

    return cameraBasis * rollRotation * virtualBasis:transpose()
end


-- Single shared point where preview, Render, and batch resolve orientation and
-- fit. Always pokes a fitted frustum: restore the returned savedFrustum after
-- rendering, and pass orthoBase when the live frustum may already be poked.
function this.positionScene(params)
    local scene = params.scene
    local alphaPlane = params.alphaPlane
    local camera = params.camera
    local config = params.config or {}

    local zoom = config.zoom or 1.0

    scene.translation = tes3vector3.new(0, 0, 0)

    local finalRot = this.getSceneRotation({
        camera = camera,
        config = config,
        profile = params.profile,
    })
    scene.rotation = finalRot
    scene:update()

    -- Phase 1: preliminary placement and projected measurement.
    -- orthoBase avoids compounding an already-narrowed live preview frustum.
    local currentFrustum = params.orthoBase or this.getFrustum(camera)

    local prelimBounds = framing.computeBounds({ scene = scene })
    local prelimCenter = prelimBounds.localBboxCenter
    local prelimRadius = prelimBounds.safeRadius
    local sceneScale = scene.scale or 1

    local prelimFactor = 2.5
    local prelimD = prelimRadius * prelimFactor
    local prelimTargetPos = camera.worldTransform.translation + camera.worldDirection * prelimD
    scene.translation = prelimTargetPos - finalRot * (prelimCenter * sceneScale)
    scene:update()

    local framingResult = framing.computeProjectedExtents({
        scene = scene,
        camera = camera,
        frustum = currentFrustum,
    })

    local radius = framingResult.radius
    local centerLocal = framingResult.localBboxCenter

    -- Distance is a radius multiple; the fitted frustum below does the filling.
    local orthoActive = params.ortho == true
    local liveFrustum = getFrustumPtr(camera)
    local savedFrustum = {
        liveFrustum[0], liveFrustum[1], liveFrustum[2],
        liveFrustum[3], liveFrustum[4], liveFrustum[5],
    }

    local distanceFactor = orthoActive
        and (params.orthoDistanceFactor or settings.current.orthoDistanceFactor)
        or (config.perspectiveDistanceFactor or perspectiveDistanceFactor)
    local d = math.max(radius * distanceFactor, radius + 1)

    -- Phase 2: final placement and projected recentering.
    local targetPos = camera.worldTransform.translation + camera.worldDirection * d
    local recenterOffset = tes3vector3.new(0, 0, 0)
    local finalTargetPos = targetPos

    scene.translation = finalTargetPos - finalRot * (centerLocal * sceneScale)
    scene:update()

    -- Angular center is frustum-independent, so this stays stable across FOV/aspect.
    local centeredFraming
    for _ = 1, 4 do
        centeredFraming = framing.computeProjectedExtents({
            scene = scene,
            camera = camera,
            frustum = currentFrustum,
        })

        if math.abs(centeredFraming.angularCenterX) <= 0.000001
            and math.abs(centeredFraming.angularCenterY) <= 0.000001 then
            break
        end

        local correction = camera.worldRight * (-centeredFraming.angularCenterX * d)
            + camera.worldUp * (-centeredFraming.angularCenterY * d)
        recenterOffset = recenterOffset + correction
        finalTargetPos = targetPos + recenterOffset
        scene.translation = finalTargetPos - finalRot * (centerLocal * sceneScale)
        scene:update()
    end

    centeredFraming = framing.computeProjectedExtents({
        scene = scene,
        camera = camera,
        frustum = currentFrustum,
    })

    -- Phase 3: deterministic fitted frustum. Same math for both modes -- the only
    -- difference is the camera distance chosen above (far = flat, near = perspective).
    local orthoFit = framing.computeOrthoFit({
        extents = centeredFraming,
        aspect = params.targetAspect or 1,
        zoom = zoom,
        margin = params.fitMargin or orthoMargin,
    })
    local activeFrustum = orthoFit.frustum
    this.setFrustum(camera, activeFrustum)

    local finalFramingResult = framing.computeProjectedExtents({
        scene = scene,
        camera = camera,
        frustum = activeFrustum,
    })

    if orthoFit then
        finalFramingResult.orthoDistance = d
        finalFramingResult.targetAspect = orthoFit.aspect
        finalFramingResult.frustumRight = orthoFit.right
        finalFramingResult.frustumTop = orthoFit.top
        finalFramingResult.near = orthoFit.near
        finalFramingResult.far = orthoFit.far
        finalFramingResult.depthPadding = orthoFit.depthPadding
        finalFramingResult.alphaPlaneDepth = orthoFit.alphaPlaneDepth
    end

    -- Phase 4: place the alpha plane from measured subject depth.
    local depthSpan = math.max(
        finalFramingResult.projectedDepthMax - finalFramingResult.projectedDepthMin,
        0
    )
    local depthPadding = orthoFit and orthoFit.depthPadding or math.max(depthSpan * 0.1, 1)
    local alphaPlaneDepth = orthoFit and orthoFit.alphaPlaneDepth
        or (finalFramingResult.projectedDepthMax + depthPadding)

    alphaPlane.translation = camera.worldTransform.translation
        + camera.worldDirection * alphaPlaneDepth

    local rot90 = tes3matrix33.new()
    rot90:toRotationZ(math.rad(90))
    alphaPlane.rotation = camera.worldTransform.rotation * rot90

    -- alphaPlane.nif is 200x200 world units at scale 1.
    local viewHalfWidth = alphaPlaneDepth * math.abs(activeFrustum[2])
    local viewHalfHeight = alphaPlaneDepth * math.abs(activeFrustum[3])
    alphaPlane.scale = math.max(10.0, math.max(viewHalfWidth, viewHalfHeight) * 1.05 / 100)
    alphaPlane:update()

    return finalTargetPos, radius, centerLocal, savedFrustum, finalFramingResult
end


-- Scratch buffer for the white-backdrop readback of the matte pass.
local matteScratch = nil

this.setPlaneColor = matte.setPlaneColor




function this.ensureDirectory(path)
    local normalized = path:gsub("\\", "/")
    local parts = {}
    for part in normalized:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    if path:match("%.%w+$") then
        table.remove(parts)
    end

    local current = ""
    for i, part in ipairs(parts) do
        if i == 1 then
            current = part
        else
            current = current .. "/" .. part
        end
        if not lfs.directoryexists(current) then
            local ok, err = lfs.mkdir(current)
            if not ok then
                error("Failed to create directory " .. current .. ": " .. tostring(err))
            end
        end
    end
end


--   batch, "previews" for the interactive preview's Render button). Default "meshes".
function this.getOutputPath(subject, fallbackMeshPath, subFolder)
    local basePath = settings.getOutputFolder()
    subFolder = subFolder or "meshes"
    local path
    if subject and subject.object and subject.object.objectType == tes3.objectType.npc then
        local namePart = subject.recordId or "unknown"
        -- NPC thumbnails are organized separately from mesh-path thumbnails: put them
        -- under a top-level "npc" folder (parallel to the default "meshes" folder).
        -- The preview's test render still uses its own subFolder ("previews").
        if subFolder == "meshes" then
            path = string.format("%s/npc/%s.png", basePath, namePart)
        else
            path = string.format("%s/%s/npc/%s.png", basePath, subFolder, namePart)
        end
    else
        -- Normalized path keeps re-renders overwriting the same file.
        local meshName = (subject and subject.normalizedMeshPath and subject.normalizedMeshPath ~= "" and subject.normalizedMeshPath)
            or subject_resolver.normalizeMeshPath(fallbackMeshPath)
        if not meshName or meshName == "" then
            meshName = "unknown"
        end
        path = string.format("%s/%s/%s.png", basePath, subFolder, meshName)
    end
    -- Every output path is lowercased, folders included -- not just the mesh-derived
    -- filename (which normalizeMeshPath already lowercases on its own).
    return path:lower()
end

local renderTarget = nil
local pixelData = nil

-- Renders a single mesh to a transparent PNG via an offscreen render target,
-- synchronously (writes to disk) or async (queues readback compression).
function this.render(params)
    local subject = params.subject
    if not subject and params.meshPath then
        subject = subject_resolver.resolveFallback(params.meshPath)
        params.subject = subject
    end

    if subject then
        params.meshPath = params.meshPath or subject.meshPath
        if not params.outputPath then
            params.outputPath = this.getOutputPath(subject, params.meshPath or subject.meshPath)
        end
        params.recordId = params.recordId or subject.recordId

        local cfg = subject.config or {}
        params.yaw = params.yaw or cfg.yaw
        params.pitch = params.pitch or cfg.pitch
        params.roll = params.roll or cfg.roll
        params.zoom = params.zoom or cfg.zoom
        params.keyDimmer = params.keyDimmer or cfg.keyDimmer
        params.keyX = params.keyX or cfg.keyX
        params.keyY = params.keyY or cfg.keyY
        params.keyZ = params.keyZ or cfg.keyZ
        params.fillDimmer = params.fillDimmer or cfg.fillDimmer
        params.ambientScale = params.ambientScale or cfg.ambientScale
        params.diffuseScale = params.diffuseScale or cfg.diffuseScale
        params.ortho = params.ortho == nil and cfg.ortho or params.ortho
    end

    assert(params.meshPath, "meshPath is required")
    assert(params.outputPath, "outputPath is required")

    local camera = tes3.getCamera()
    if not camera then
        error("No camera found")
    end

    local oldScene = camera.scene

    local scene = this.createRenderableScene(subject, params.meshPath)
    -- Shared alpha properties may get rewritten: always restore, including on error.
    local restoreParticleBlends = this.adaptParticleBlends(scene)

    local alphaPlane = tes3.loadMesh("..\\MWSE\\mods\\ThumbnailGenerator\\meshes\\alphaPlane.nif")
    if not alphaPlane then
        error("Failed to load ..\\MWSE\\mods\\ThumbnailGenerator\\meshes\\alphaPlane.nif")
    end
    alphaPlane = alphaPlane:clone()

    local resolution = params.resolution or 2048
    local lights = {}
    local root
    -- Ortho dollies the subject and rewrites the frustum; restored via restoreFrustum().
    local savedFrustum = nil
    local function restoreFrustum()
        if savedFrustum then
            this.setFrustum(camera, savedFrustum)
            savedFrustum = nil
        end
    end
    -- Flames often sit under NiLODNode levels that switch off at the dolly
    -- distance; a tiny lodAdjust forces the highest-detail level regardless.
    local savedLodAdjust = nil
    local function restoreLodAdjust()
        if savedLodAdjust then
            camera.lodAdjust = savedLodAdjust
            savedLodAdjust = nil
        end
    end
    local savedPlaneColor = nil
    local function restorePlaneColor()
        if savedPlaneColor then
            matte.applyPlaneColor(alphaPlane, savedPlaneColor)
            savedPlaneColor = nil
        end
    end

    local ok, val1, val2 = pcall(function()
        local targetPos, radius, localBoundOrigin, framingResult
        targetPos, radius, localBoundOrigin, savedFrustum, framingResult = this.positionScene({
            scene = scene,
            alphaPlane = alphaPlane,
            camera = camera,
            config = params,
            ortho = params.ortho,
            orthoBase = params.orthoBase,
            targetAspect = params.targetAspect or 1,
            profile = subject and subject.profile,
            fitMargin = firstPassMargin,
        })

        -- WASD pan moves the subject in view (fraction of its radius, along the
        -- camera axes). Only when NOT fitting to frame -- the refit scans content,
        -- so a panned subject would just be re-cropped (and clipped) back.
        if params.fitToFrame == false and (params.panX or params.panY) then
            scene.translation = scene.translation
                + camera.worldRight * ((params.panX or 0) * radius)
                + camera.worldUp * ((params.panY or 0) * radius)
            scene:update()
        end

        root = this.createRootNode(scene, alphaPlane)
        lights = this.addThumbnailLighting({
            root = root,
            scene = scene,
            camera = camera,
            targetPos = targetPos,
            radius = radius,
            config = params,
        })

        camera.scene = root
        camera.scene:update()
        camera.scene:updateEffects()
        camera.scene:updateProperties()

        if renderTarget and (renderTarget.width ~= resolution or renderTarget.height ~= resolution) then
            renderTarget = nil
        end
        renderTarget = renderTarget or niRenderedTexture.create(resolution, resolution)
        camera.renderer:setRenderTarget(renderTarget)

        savedLodAdjust = camera.lodAdjust
        camera.lodAdjust = settings.current.lodAdjust

        if params.async then
            assert(params.pixelData, "pixelData pool slot is required for async renders")
        end

        if pixelData and (pixelData:getWidth() ~= resolution or pixelData:getHeight() ~= resolution) then
            pixelData = nil
        end
        local targetPixelData = params.pixelData or pixelData or niPixelData.new(resolution, resolution)
        if not params.pixelData then
            pixelData = targetPixelData
        end

        local function clickInto(dest)
            camera:clear()
            camera:click()
            camera:swapBuffers()
            renderTarget:readback(dest)
        end

        -- Black + white backdrop pair -> true alpha and an alpha-proof content
        -- scan. If the backdrop can't be colored, fall back to framebuffer alpha.
        savedPlaneColor = matte.capturePlaneColor(alphaPlane)
        local matteReady = savedPlaneColor ~= nil and matte.setPlaneColor(alphaPlane, 0)
        if not matteReady then
            mwse.log("[ThumbnailGen] Warning: backdrop material not found; using framebuffer alpha")
        end

        clickInto(targetPixelData)
        local ptrA = matte.pixelPtr(targetPixelData)
        local ptrB
        if matteReady then
            matte.setPlaneColor(alphaPlane, 1)
            if matteScratch and (matteScratch:getWidth() ~= resolution or matteScratch:getHeight() ~= resolution) then
                matteScratch = nil
            end
            matteScratch = matteScratch or niPixelData.new(resolution, resolution)
            clickInto(matteScratch)
            ptrB = matte.pixelPtr(matteScratch)
        end

        -- Refit to the rendered pixels: geometry fitting only approximates what draws.
        local minX, minY, maxX, maxY
        if matteReady then
            minX, minY, maxX, maxY = matte.scanContentBBox(ptrA, ptrB, resolution)
        else
            minX, minY, maxX, maxY = matte.scanContentAlpha(ptrA, resolution)
        end

        -- Nothing visible rendered (e.g. a record with no drawable content):
        -- skip the file entirely rather than writing a blank PNG.
        if minX == nil and params.skipEmpty then
            camera.renderer:setRenderTarget(nil)
            restoreFrustum()
            restoreLodAdjust()
            restorePlaneColor()
            restoreParticleBlends()
            for _, light in ipairs(lights) do
                light:detachAffectedNode(scene)
                root:detachChild(light)
            end
            if not params.keepSceneActive then
                camera.scene = oldScene
            end
            return nil, "empty"
        end

        -- fitToFrame (default on): tighten the frustum to the measured pixels.
        -- When off, keep the looser first-pass framing (firstPassMargin headroom).
        local refit = params.fitToFrame ~= false and minX
            and matte.frustumFromContent(this.getFrustum(camera), minX, minY, maxX, maxY, resolution)
        if refit then
            this.setFrustum(camera, refit)
            if matteReady then
                clickInto(matteScratch) -- backdrop still white
                matte.setPlaneColor(alphaPlane, 0)
            end
            clickInto(targetPixelData)
        end

        if matteReady then
            matte.matteToTarget(ptrA, ptrB, resolution)
        end
        -- The material is shared (e.g. with the live preview's backdrop): put its
        -- exact prior colors back rather than assuming black.
        restorePlaneColor()

        camera.renderer:setRenderTarget(nil)

        -- Frustum, LOD, and blend overrides were only needed for the clicks above.
        restoreFrustum()
        restoreLodAdjust()
        restoreParticleBlends()

        -- The image_resize DLL selects the output format from the extension.
        local outputFormat = params.outputFormat
        if outputFormat ~= "tga" and outputFormat ~= "dds" then
            outputFormat = "png"
        end
        local outputPath = params.outputPath:gsub("%.%a+$", "") .. "." .. outputFormat

        if params.async then
            for _, light in ipairs(lights) do
                light:detachAffectedNode(scene)
                root:detachChild(light)
            end
            if not params.keepSceneActive then
                camera.scene = oldScene
            end

            return targetPixelData, outputPath
        else
            local dstWidth = params.dstWidth or params.dstResolution or 1024
            local dstHeight = params.dstHeight or params.dstResolution or 1024
            local flipY = params.flipY == true
            local pngCompression = params.pngCompression or ir.PNG_COMPRESSION_BALANCED

            ir.writeSync(targetPixelData, resolution, resolution, dstWidth, dstHeight, flipY,
                outputPath, pngCompression)

            for _, light in ipairs(lights) do
                light:detachAffectedNode(scene)
                root:detachChild(light)
            end
            if not params.keepSceneActive then
                camera.scene = oldScene
            end

            return outputPath
        end
    end)

    -- Cleanup runs even on error so lights/frustum/scene are never left dangling.
    if not ok then
        for _, light in ipairs(lights) do
            if scene then
                local lightOk, lightErr = pcall(light.detachAffectedNode, light, scene)
                if not lightOk then
                    mwse.log("[ThumbnailGen] Warning: Failed to detach light from scene during cleanup: %s",
                        tostring(lightErr))
                end
            end
            if root then
                local rootOk, rootErr = pcall(root.detachChild, root, light)
                if not rootOk then
                    mwse.log("[ThumbnailGen] Warning: Failed to detach light from root during cleanup: %s",
                        tostring(rootErr))
                end
            end
        end
        local frustumOk, frustumErr = pcall(restoreFrustum)
        if not frustumOk then
            mwse.log("[ThumbnailGen] Warning: Failed to restore frustum during cleanup: %s", tostring(frustumErr))
        end
        pcall(restoreLodAdjust)
        -- The backdrop material may be shared via the mesh cache; never leave it
        -- mid-matte.
        pcall(restorePlaneColor)
        pcall(restoreParticleBlends)
        if camera then
            if camera.renderer then
                local rtOk, rtErr = pcall(camera.renderer.setRenderTarget, camera.renderer, nil)
                if not rtOk then
                    mwse.log("[ThumbnailGen] Warning: Failed to restore render target during cleanup: %s",
                        tostring(rtErr))
                end
            end
            camera.scene = oldScene
        end
        error(val1)
    end

    return val1, val2
end


return this
