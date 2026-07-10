-- Live preview 3D scene: state, fit/dolly/flatten math, and lifecycle.
-- begin() builds the camera scene and stashes everything that must be restored;
-- finish() restores it all. finish is only ever called from the preview
-- settings menu's destroy handler -- the sole cleanup path.
local this = {}

local render = require("ThumbnailGenerator.render")
local settings = require("ThumbnailGenerator.modules.thumbnail_settings")

-- All live-preview 3D state; nil while no preview is open. UI code reads and
-- writes fields directly (config, pan, drag bookkeeping, slider refs).
this.state = nil

-- Dolly fit: MGE's vertex-lighting path projects particles through the pristine
-- frustum and ignores pokes, so flames detach from their mesh in the live view.
-- With this mode on, the default projection stays live and the subject is moved
-- to the distance where it fills that view instead; zoom becomes a real dolly.
local function dollyFitEnabled()
    return settings.current.previewDollyFit == true
end
this.dollyFitEnabled = dollyFitEnabled

-- View depth of the rotation pivot -- the dolly-fit analogue of reading the
-- fitted frustum extents.
local function currentViewDepth()
    local ts = this.state
    if not (ts and ts.rotationTargetPos) then return nil end
    local cam = ts.camera
    return (ts.rotationTargetPos - cam.worldTransform.translation)
        :dot(cam.worldDirection)
end
this.currentViewDepth = currentViewDepth

-- Moves the whole view rig (subject, pivot, pan base, lights, backdrop) so the
-- pivot sits at the given view depth, sliding along its own view ray so angular
-- placement is preserved. The dolly-fit analogue of scaling the frustum in place.
local function restoreDollyDepth(depth)
    local ts = this.state
    if not (ts and ts.rotationTargetPos and depth) then return end
    local cam = ts.camera
    local camPos = cam.worldTransform.translation
    local current = (ts.rotationTargetPos - camPos):dot(cam.worldDirection)
    if current <= 0 then return end

    local pivot = camPos + (ts.rotationTargetPos - camPos) * (depth / current)
    local delta = pivot - ts.rotationTargetPos
    ts.rotationTargetPos = pivot
    if ts.baseTranslation then
        ts.baseTranslation = ts.baseTranslation + delta
    end
    ts.scene.translation = ts.scene.translation + delta
    ts.scene:update()

    -- The rig moves rigidly with the subject, so lighting is unchanged by depth.
    for _, light in ipairs(ts.lights or {}) do
        light.translation = light.translation + delta
        light:update()
    end

    -- Backdrop keeps its padding behind the subject, re-covering the default view.
    local base = ts.baseFrustum
    local planeDepth = (ts.alphaPlane.translation - camPos):dot(cam.worldDirection)
        + delta:dot(cam.worldDirection)
    ts.alphaPlane.translation = camPos + cam.worldDirection * planeDepth
    ts.alphaPlane.scale = math.max(10.0,
        math.max(planeDepth * math.abs(base[2]), planeDepth * math.abs(base[3])) * 1.05 / 100)
    ts.alphaPlane:update()

    cam.scene:update()
end
this.restoreDollyDepth = restoreDollyDepth

-- Compression along the camera view axis: I - (1-epsilon)*v*vT. Perspective
-- projection of a depth-flattened subject converges to an orthographic view of
-- the original, so this emulates ortho under dolly fit without touching the
-- projection (which MGE's vertex-lit particles refuse to follow). Symmetric, so
-- row/column order is irrelevant.
local function viewFlattenMatrix(camera, epsilon)
    local v = camera.worldDirection
    local k = 1 - epsilon
    return tes3matrix33.new(
        1 - k * v.x * v.x, -k * v.x * v.y, -k * v.x * v.z,
        -k * v.y * v.x, 1 - k * v.y * v.y, -k * v.y * v.z,
        -k * v.z * v.x, -k * v.z * v.y, 1 - k * v.z * v.z
    )
end

-- Applies `state.config` to the live preview scene/lights.
function this.update(params)
    local ts = this.state
    if not ts or not ts.scene then return end
    params = params or {}

    local camera = ts.camera
    local scene = ts.scene
    local alphaPlane = ts.alphaPlane
    local root = ts.root
    local radius = ts.radius
    local cfg = ts.config
    local profile = ts.subject and ts.subject.profile
    local rotationOnly = params.rotationOnly == true

    -- Dolly-fit zoom: view depth scales linearly with zoom exactly as the frustum
    -- extents do, so slide the rig instead of poking the frustum.
    if params.zoomOnly and dollyFitEnabled() and not ts.orthoFrustum
        and ts.lastFitZoom and ts.lastFitZoom > 0 then
        local ratio = (cfg.zoom or 1) / ts.lastFitZoom
        ts.lastFitZoom = cfg.zoom or 1
        local depth = currentViewDepth()
        if depth and depth > 0 then
            restoreDollyDepth(depth * ratio)
        end
        return
    end

    -- Frustum extents scale linearly with zoom; scaling in place avoids the
    -- re-fit snap after a drag (the drag fast path doesn't re-fit).
    if params.zoomOnly and ts.orthoFrustum and ts.lastFitZoom and ts.lastFitZoom > 0 then
        local ratio = (cfg.zoom or 1) / ts.lastFitZoom
        local f = ts.orthoFrustum
        f[1], f[2], f[3], f[4] = f[1] * ratio, f[2] * ratio, f[3] * ratio, f[4] * ratio
        ts.lastFitZoom = cfg.zoom or 1
        render.setFrustum(camera, f)

        -- Keep the backdrop covering the (possibly wider) view.
        local camPos = camera.worldTransform.translation
        local planeDepth = (alphaPlane.translation - camPos):dot(camera.worldDirection)
        alphaPlane.scale = math.max(10.0,
            math.max(planeDepth * math.abs(f[2]), planeDepth * math.abs(f[3])) * 1.05 / 100)
        alphaPlane:update()

        camera.scene:update()
        return
    end

    local targetPos
    local dynamicRadius

    -- Rotate around a fixed pivot -- a full re-fit here would wobble on every tick.
    if rotationOnly and ts.rotationTargetPos and ts.rotationCenterLocal then
        local finalRot = render.getSceneRotation({
            camera = camera,
            config = cfg,
            profile = profile,
        })
        local sceneScale = scene.scale or 1

        -- Keep the foreshortening flatten composed during drags (the camera is
        -- static, so the cached view-axis compression stays valid across rotations).
        if ts.viewFlatten then
            finalRot = ts.viewFlatten * finalRot
        end

        scene.rotation = finalRot
        scene.translation = ts.rotationTargetPos
            - finalRot * (ts.rotationCenterLocal * sceneScale)
        scene:update()

        targetPos = ts.rotationTargetPos
        dynamicRadius = ts.rotationRadius or radius
    else
        rotationOnly = false

        -- Both modes poke a fitted frustum now; restore the pristine one before
        -- fitting so a stale narrow frustum from the last fit can't clip the scene.
        if ts.baseFrustum then
            ts.orthoFrustum = nil
            render.setFrustum(camera, ts.baseFrustum)
        end

        -- Fit the window aspect or the live view renders stretched; file renders stay square.
        local vw, vh = tes3.getViewportSize()
        local screenAspect = (vh and vh > 0) and (vw / vh) or 1

        -- Dolly fit emulates ortho by flattening (below), so fit at the
        -- perspective distance rather than the pointless ortho mega-dolly.
        local dollyFit = dollyFitEnabled() and ts.baseFrustum ~= nil

        local centerLocal
        targetPos, dynamicRadius, centerLocal = render.positionScene({
            scene = scene,
            alphaPlane = alphaPlane,
            camera = camera,
            config = cfg,
            radius = radius,
            ortho = cfg.ortho == true and not dollyFit,
            orthoBase = ts.baseFrustum,
            targetAspect = screenAspect,
            profile = profile,
        })

        ts.rotationTargetPos = targetPos:copy()
        ts.rotationCenterLocal = centerLocal:copy()
        ts.rotationRadius = dynamicRadius

        -- Re-applied every frame: the engine rebuilds the frustum on
        -- FOV/camera-mode/cell changes.
        ts.orthoFrustum = render.getFrustum(camera)
        ts.lastFitZoom = cfg.zoom or 1

        -- Dolly fit: convert the fitted frustum into an equivalent camera distance
        -- and keep the pristine projection live (the fitted/base extent ratio is
        -- exactly the depth ratio that preserves apparent size).
        ts.viewFlatten = nil
        if dollyFit then
            local fitted = ts.orthoFrustum
            local base = ts.baseFrustum
            local r = math.max(
                (fitted[2] - fitted[1]) / (base[2] - base[1]),
                (fitted[3] - fitted[4]) / (base[3] - base[4]))
            local camPos = camera.worldTransform.translation
            local depth0 = (targetPos - camPos):dot(camera.worldDirection)
            if depth0 > 0 and r > 0 then
                -- Keep small subjects clear of the game near plane.
                r = math.max(r, (base[5] * 4 + dynamicRadius) / depth0)
                local newTarget = camPos + (targetPos - camPos) * r
                local delta = newTarget - targetPos
                targetPos = newTarget
                scene.translation = scene.translation + delta
                scene:update()
                ts.rotationTargetPos = targetPos:copy()

                local planeDepth = (alphaPlane.translation - camPos):dot(camera.worldDirection)
                    + delta:dot(camera.worldDirection)
                alphaPlane.translation = camPos + camera.worldDirection * planeDepth
                alphaPlane.scale = math.max(10.0,
                    math.max(planeDepth * math.abs(base[2]), planeDepth * math.abs(base[3])) * 1.05 / 100)
                alphaPlane:update()

                render.setFrustum(camera, base)
                -- Nothing poked: the per-frame re-poke and frustum zoom path stay off.
                ts.orthoFrustum = nil

                -- Match the render's foreshortening: flatten the subject about the
                -- pivot so up-close proportions equal the render's distance-factor
                -- look (ortho F~100 -> near-flat, perspective F=8 -> mild telephoto).
                -- epsilon = depth/(factor*radius) makes the residual foreshortening
                -- exactly (F+1)/(F-1), tracking the respective slider.
                local factor = cfg.ortho == true
                    and (settings.current.orthoDistanceFactor or 100)
                    or (cfg.perspectiveDistanceFactor or 8)
                local depthNow = depth0 * r
                local epsilon = depthNow
                    / (math.max(dynamicRadius, 0.001) * math.max(factor, 1))
                epsilon = math.max(0.01, math.min(1, epsilon))
                if epsilon < 1 then
                    local flatten = viewFlattenMatrix(camera, epsilon)
                    scene.rotation = flatten * scene.rotation
                    scene.translation = flatten * (scene.translation - targetPos) + targetPos
                    scene:update()
                    ts.viewFlatten = flatten
                end
            end
        end
    end

    -- Lights don't need rebuilding for a pure rotation.
    if not rotationOnly then
        if ts.lights then
            for _, light in ipairs(ts.lights) do
                light:detachAffectedNode(scene)
                root:detachChild(light)
            end
        end

        ts.lights = render.addThumbnailLighting({
            root = root,
            scene = scene,
            camera = camera,
            targetPos = targetPos,
            radius = dynamicRadius,
            config = cfg,
        })
    end

    -- Centered translation the WASD pan offsets from (zoomOnly keeps the prior one).
    ts.baseTranslation = scene.translation:copy()

    camera.scene:update()
    camera.scene:updateEffects()
    camera.scene:updateProperties()
end

-- Builds the preview scene for a resolved subject, swaps it onto the camera,
-- and stashes every value finish() must restore. Returns the new state table.
function this.begin(subject)
    local camera = tes3.getCamera()
    if not camera then
        error("No camera found")
    end

    local oldScene = camera.scene

    local scene = render.createRenderableScene(subject, subject.meshPath)

    scene.translation = tes3vector3.new(0, 0, 0)
    scene.rotation = tes3matrix33.identity()
    scene:update()

    local alphaPlane = tes3.loadMesh("..\\MWSE\\mods\\ThumbnailGenerator\\meshes\\alphaPlane.nif")
    if not alphaPlane then
        error("Failed to load ..\\MWSE\\mods\\ThumbnailGenerator\\meshes\\alphaPlane.nif")
    end

    local root = render.createRootNode(scene, alphaPlane)
    camera.scene = root

    -- Clone so editing doesn't touch the resolved config until explicitly saved.
    local initialConfig = subject.config
    local currentConfig = {}
    for k, v in pairs(initialConfig) do
        currentConfig[k] = v
    end
    currentConfig.roll = currentConfig.roll or 0
    -- initialConfig.zoom is render-scale (from getDefaultConfig / settings.current);
    -- state.config.zoom must be internal (2.0 / displayZoom).
    -- Default config.lua zoom = 1.0 render-scale = 2.0 internal = display 1x (neutral fit).
    currentConfig.zoom = (initialConfig.zoom or 1.0) * 2.0
    -- Follow the MCM Orthographic (batch) toggle, so turning it off there opens
    -- the preview in perspective too instead of always defaulting to ortho.
    currentConfig.ortho = settings.current.forceOrtho
    -- Follow the MCM Fit to Frame toggle as the opening state.
    currentConfig.fitToFrame = settings.current.fitToFrame

    this.state = {
        subject = subject,
        obj = subject.object,
        radius = scene.worldBoundRadius,
        camera = camera,
        oldScene = oldScene,
        scene = scene,
        alphaPlane = alphaPlane,
        root = root,
        config = currentConfig,
        sliders = {},
        labels = {},
        -- WASD pan offsets, as a fraction of the frustum width/height.
        -- Restored from the session so "Save to session" carries pan into the next preview.
        panX = settings.current.panX or 0,
        panY = settings.current.panY or 0,
        baseFrustum = render.getFrustum(camera),
        -- MGE pauses world rendering in menus; unpause for a live view.
        mgePauseInMenus = mge.render.pauseRenderingInMenus,
        -- The file render bypasses MGE post-processing, so the live view must
        -- too. updateHDR alone only freezes auto-exposure, so both are needed.
        mgeShaders = mge.render.shaders,
        mgeHDR = mge.render.updateHDR,
        -- The file render bypasses MGE, so its lighting is vertex-style; forcing
        -- vertex for the live view matches that brightness (dolly fit keeps
        -- flames working without per-pixel). Restored on close.
        mgeLightingMode = mge.getLightingMode(),
        -- Flames often sit under NiLODNode levels that switch off at the ortho
        -- dolly distance; a tiny lodAdjust forces the highest-detail level.
        lodAdjust = camera.lodAdjust,
    }
    mge.render.pauseRenderingInMenus = false
    mge.render.shaders = false
    mge.render.updateHDR = false
    if settings.current.previewForceVertexLighting then
        mge.setLightingMode(mge.lightingMode.vertex)
    end
    camera.lodAdjust = settings.current.lodAdjust

    return this.state
end

-- Restores everything begin() changed: frustum (the engine won't rebuild it on
-- its own), MGE flags and lighting mode, LOD, and the original camera scene.
-- Returns the closed state table (for suppressExit), or nil if already closed.
function this.finish()
    local ts = this.state
    if not ts then return nil end
    this.state = nil

    if ts.baseFrustum then
        render.setFrustum(ts.camera, ts.baseFrustum)
    end
    if ts.mgePauseInMenus ~= nil then
        mge.render.pauseRenderingInMenus = ts.mgePauseInMenus
    end
    if ts.mgeShaders ~= nil then
        mge.render.shaders = ts.mgeShaders
    end
    if ts.mgeHDR ~= nil then
        mge.render.updateHDR = ts.mgeHDR
    end
    if ts.mgeLightingMode ~= nil then
        mge.setLightingMode(ts.mgeLightingMode)
    end
    if ts.lodAdjust ~= nil then
        ts.camera.lodAdjust = ts.lodAdjust
    end

    ts.camera.scene = ts.oldScene
    if ts.camera.scene then
        ts.camera.scene:update()
        ts.camera.scene:updateEffects()
        ts.camera.scene:updateProperties()
    end

    return ts
end

return this
