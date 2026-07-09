-- Computes camera-space projected extents from real mesh geometry for tight,
-- centered thumbnail framing (bbox/vertex measurement -> NDC projection -> fit).
local this = {}

local defaultMargin = 1.05

local function transformLocalPoint(transform, point)
    local scale = transform.scale or 1
    return transform.rotation * (point * scale) + transform.translation
end

local function transformWorldPointToLocal(transform, point)
    local scale = transform.scale or 1
    if math.abs(scale) < 0.0001 then
        scale = 1
    end

    local inverseRotation = transform.rotation:copy()
    inverseRotation = inverseRotation:transpose()
    return (inverseRotation * (point - transform.translation)) / scale
end

-- =============================================================================
-- BOUNDS EXTRACTION
-- =============================================================================

local function computeBoundingBox(scene)
    local bbox = scene:createBoundingBox({
        observeAppCullFlag = true,
        onlyActiveChildren = true,
        accurateSkinned = true,
    })

    if not bbox:hasUninitializedData() then
        return bbox, "createBoundingBox(full)"
    end

    bbox = scene:createBoundingBox({ observeAppCullFlag = true })

    if not bbox:hasUninitializedData() then
        return bbox, "createBoundingBox(basic)"
    end

    return nil, "fallback"
end

-- Adds the 8 corners of an axis-aligned cube (or the bare center for size 0).
local function addCube(worldVerts, center, halfSize)
    if halfSize <= 0 then
        table.insert(worldVerts, center)
        return
    end
    for c = 1, 8 do
        local sx = (c <= 4) and -1 or 1
        local sy = ((c - 1) % 4 < 2) and -1 or 1
        local sz = (c % 2 == 1) and -1 or 1
        table.insert(worldVerts, center + tes3vector3.new(sx * halfSize, sy * halfSize, sz * halfSize))
    end
end

-- Live particles as world cubes (half-size radius*sizes[i]) plus a rough visual
-- mass. Never-simulated systems render nothing and contribute nothing.
local function collectParticleSystem(node)
    local data = node.data
    if not data then return nil end

    local active = data.activeCount or 0
    if active <= 0 then return nil end

    local verts = data.activeVertices or data.vertices
    if not verts then return nil end
    local count = math.min(active, data.vertexCount or active)

    local transform = node.worldTransform
    local worldScale = transform.scale or 1
    local baseRadius = data.radius or 0

    local sizes = data.sizes
    local colors = data.colors
    local cubes = {}
    local mass = 0
    for i = 1, count do
        local v = verts[i]
        -- Skip particles faded to (near-)invisibility.
        local alpha = colors and colors[i] and colors[i].a
        if v and (alpha == nil or alpha > 0.1) then
            local halfSize = baseRadius * ((sizes and sizes[i]) or 1) * worldScale
            table.insert(cubes, { center = transform * v, halfSize = halfSize })
            -- Rough visual weight: billboard area scaled by opacity.
            mass = mass + halfSize * halfSize * (alpha or 1)
        end
    end

    if #cubes == 0 then return nil end
    return { cubes = cubes, mass = mass }
end

-- Rigid shapes contribute real vertices (the exact tightest projected bound);
-- skinned shapes use deformed per-shape bbox corners (data.vertices is bind pose).
-- Known gap: inactive LOD/switch branches still widen the extent.
local function collectWorldVerts(scene)
    local worldVerts = {}
    local particleSystems = {}

    for node in table.traverse({ scene }) do
        if not node:isAppCulled() then
            if node:isInstanceOfType(tes3.niType.NiTriShape) or node:isInstanceOfType(tes3.niType.NiTriStrips) then
                if node.skinInstance then
                    -- Deformed bounds, not bind pose -- bind-pose boxes sit
                    -- misplaced/inflated relative to the posed body and ruin the fit.
                    local shapeBbox = node:createBoundingBox({ observeAppCullFlag = true, accurateSkinned = true })
                    if not shapeBbox or shapeBbox:hasUninitializedData() then
                        shapeBbox = node:createBoundingBox({ observeAppCullFlag = true })
                    end
                    if shapeBbox and not shapeBbox:hasUninitializedData() then
                        for _, v in ipairs(shapeBbox:vertices()) do
                            table.insert(worldVerts, transformLocalPoint(node.worldTransform, v))
                        end
                    end
                elseif node.data and node.data.vertices then
                    for _, v in ipairs(node.data.vertices) do
                        table.insert(worldVerts, node.worldTransform * v)
                    end
                end
            elseif node:isInstanceOfType(tes3.niType.NiParticles) then
                local system = collectParticleSystem(node)
                if system then
                    table.insert(particleSystems, system)
                end
            end
        end
    end

    -- Heavy systems (flames, mist) always frame; sparse faint ones (stray sparks)
    -- draw as near-invisible dots, so they only count inside the padded core region.
    if #particleSystems > 0 then
        local maxMass = 0
        for _, system in ipairs(particleSystems) do
            maxMass = math.max(maxMass, system.mass)
        end

        for _, system in ipairs(particleSystems) do
            system.isCore = system.mass >= maxMass * 0.25
            if system.isCore then
                for _, cube in ipairs(system.cubes) do
                    addCube(worldVerts, cube.center, cube.halfSize)
                end
            end
        end

        local mn, mx
        for _, v in ipairs(worldVerts) do
            if mn then
                mn.x, mn.y, mn.z = math.min(mn.x, v.x), math.min(mn.y, v.y), math.min(mn.z, v.z)
                mx.x, mx.y, mx.z = math.max(mx.x, v.x), math.max(mx.y, v.y), math.max(mx.z, v.z)
            else
                mn, mx = v:copy(), v:copy()
            end
        end

        if mn then
            local pad = (mx - mn) * 0.15
            mn, mx = mn - pad, mx + pad
            for _, system in ipairs(particleSystems) do
                if not system.isCore then
                    for _, cube in ipairs(system.cubes) do
                        local c = cube.center
                        if c.x >= mn.x and c.x <= mx.x
                            and c.y >= mn.y and c.y <= mx.y
                            and c.z >= mn.z and c.z <= mx.z then
                            addCube(worldVerts, cube.center, cube.halfSize)
                        end
                    end
                end
            end
        end
    end

    if #worldVerts == 0 then
        return nil
    end
    return worldVerts
end

function this.computeBounds(params)
    local scene = params.scene

    local bbox, boundsSource = computeBoundingBox(scene)
    local bboxCenter, localBboxCenter, radius, worldVerts

    if bbox then
        localBboxCenter = (bbox.min + bbox.max) / 2
        local localVerts = bbox:vertices()
        local worldTransform = scene.worldTransform

        worldVerts = {}
        for i = 1, #localVerts do
            worldVerts[i] = transformLocalPoint(worldTransform, localVerts[i])
        end
        bboxCenter = transformLocalPoint(worldTransform, localBboxCenter)

        local maxDist = 0
        for i = 1, #worldVerts do
            local dist = (worldVerts[i] - bboxCenter):length()
            if dist > maxDist then maxDist = dist end
        end
        radius = maxDist
    else
        boundsSource = "worldBound"
        radius = math.max(scene.worldBoundRadius or 1, 1)
        bboxCenter = scene.worldBoundOrigin and scene.worldBoundOrigin:copy()
            or scene.worldTransform.translation:copy()
        localBboxCenter = transformWorldPointToLocal(scene.worldTransform, bboxCenter)

        worldVerts = {}
        for i = 1, 8 do
            local sx = (i <= 4) and -1 or 1
            local sy = ((i - 1) % 4 < 2) and -1 or 1
            local sz = (i % 2 == 1) and -1 or 1
            worldVerts[i] = bboxCenter + tes3vector3.new(sx * radius, sy * radius, sz * radius)
        end
    end

    if radius < 0.001 then radius = 1 end

    -- Exact vertices are strictly tighter than the AABB corners; keep the
    -- corners only when no shape/particle data was found.
    local exactWorldVerts = collectWorldVerts(scene)
    if exactWorldVerts then
        worldVerts = exactWorldVerts
        -- Grow, never shrink: particles may reach past the geometry bbox.
        for i = 1, #exactWorldVerts do
            local dist = (exactWorldVerts[i] - bboxCenter):length()
            if dist > radius then radius = dist end
        end
    end

    return {
        bboxCenter = bboxCenter,
        localBboxCenter = localBboxCenter,
        boundsSource = boundsSource,
        radius = radius,
        safeRadius = math.max(radius, 1),
        worldVerts = worldVerts,
    }
end


-- =============================================================================
-- CAMERA-SPACE PROJECTION
-- =============================================================================

-- Takes min/max NDC over `verts` (world-space points, camera-relative):
-- camZ = dot(P-C, worldDirection); angular = camX|Y / camZ; ndc = angular / right|top.
local function projectCorners(verts, camera, frustum)
    local camPos = camera.worldTransform.translation
    local camDir = camera.worldDirection
    local camRight = camera.worldRight
    local camUp = camera.worldUp

    -- frustum's near/far are clipping planes, not part of this projection
    local rightExtent = frustum[2]
    local topExtent = frustum[3]

    local minNdcX, maxNdcX = math.huge, -math.huge
    local minNdcY, maxNdcY = math.huge, -math.huge
    local minCamX, maxCamX = math.huge, -math.huge
    local minCamY, maxCamY = math.huge, -math.huge
    local minCamZ, maxCamZ = math.huge, -math.huge
    local minAngularX, maxAngularX = math.huge, -math.huge
    local minAngularY, maxAngularY = math.huge, -math.huge

    local ndcCorners = {}

    for i = 1, #verts do
        local delta = verts[i] - camPos
        local camX = delta:dot(camRight)
        local camY = delta:dot(camUp)
        local camZ = delta:dot(camDir)

        -- Guard against points behind or at the camera
        if camZ < 0.001 then camZ = 0.001 end

        local angularX = camX / camZ
        local angularY = camY / camZ
        local ndcX = angularX / rightExtent
        local ndcY = angularY / topExtent

        ndcCorners[i] = { x = ndcX, y = ndcY }

        if ndcX < minNdcX then minNdcX = ndcX end
        if ndcX > maxNdcX then maxNdcX = ndcX end
        if ndcY < minNdcY then minNdcY = ndcY end
        if ndcY > maxNdcY then maxNdcY = ndcY end
        if camX < minCamX then minCamX = camX end
        if camX > maxCamX then maxCamX = camX end
        if camY < minCamY then minCamY = camY end
        if camY > maxCamY then maxCamY = camY end
        if camZ < minCamZ then minCamZ = camZ end
        if camZ > maxCamZ then maxCamZ = camZ end
        if angularX < minAngularX then minAngularX = angularX end
        if angularX > maxAngularX then maxAngularX = angularX end
        if angularY < minAngularY then minAngularY = angularY end
        if angularY > maxAngularY then maxAngularY = angularY end
    end

    return {
        projectedWidth = maxNdcX - minNdcX,
        projectedHeight = maxNdcY - minNdcY,
        projectedCenterX = (maxNdcX + minNdcX) / 2,
        projectedCenterY = (maxNdcY + minNdcY) / 2,
        cameraWidth = maxCamX - minCamX,
        cameraHeight = maxCamY - minCamY,
        cameraCenterX = (maxCamX + minCamX) / 2,
        cameraCenterY = (maxCamY + minCamY) / 2,
        angularMinX = minAngularX,
        angularMaxX = maxAngularX,
        angularMinY = minAngularY,
        angularMaxY = maxAngularY,
        angularWidth = maxAngularX - minAngularX,
        angularHeight = maxAngularY - minAngularY,
        angularCenterX = (maxAngularX + minAngularX) / 2,
        angularCenterY = (maxAngularY + minAngularY) / 2,
        projectedDepthMin = minCamZ,
        projectedDepthMax = maxCamZ,
        ndcCorners = ndcCorners,
    }
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

-- Scene must already be oriented and placed at its preliminary position.
-- Used by `positionScene` for final camera distance, recentering, frustum fit.
function this.computeProjectedExtents(params)
    local scene = params.scene
    local camera = params.camera
    local frustum = params.frustum
    local margin = params.margin or defaultMargin

    local bounds = this.computeBounds({ scene = scene })
    local projection = projectCorners(bounds.worldVerts, camera, frustum)
    local fitSize = math.max(projection.projectedWidth, projection.projectedHeight) * margin

    if fitSize < 0.001 then fitSize = 2.0 end

    return {
        projectedWidth = projection.projectedWidth,
        projectedHeight = projection.projectedHeight,
        projectedCenterX = projection.projectedCenterX,
        projectedCenterY = projection.projectedCenterY,
        cameraWidth = projection.cameraWidth,
        cameraHeight = projection.cameraHeight,
        cameraCenterX = projection.cameraCenterX,
        cameraCenterY = projection.cameraCenterY,
        angularMinX = projection.angularMinX,
        angularMaxX = projection.angularMaxX,
        angularMinY = projection.angularMinY,
        angularMaxY = projection.angularMaxY,
        angularWidth = projection.angularWidth,
        angularHeight = projection.angularHeight,
        angularCenterX = projection.angularCenterX,
        angularCenterY = projection.angularCenterY,
        projectedDepthMin = projection.projectedDepthMin,
        projectedDepthMax = projection.projectedDepthMax,
        bboxCenter = bounds.bboxCenter,
        localBboxCenter = bounds.localBboxCenter,
        boundsSource = bounds.boundsSource,
        radius = bounds.radius,
        safeRadius = bounds.safeRadius,
        ndcCorners = projection.ndcCorners,
        fitSize = fitSize,
        margin = margin,
    }
end


-- Builds a fake-orthographic frustum from the subject's final angular footprint
-- rather than the live camera's FOV/aspect (which only controls flattening).
function this.computeOrthoFit(params)
    local extents = assert(params.extents, "extents are required")
    local aspect = params.aspect or 1
    local zoom = params.zoom or 1
    local margin = params.margin or extents.margin or defaultMargin

    assert(aspect > 0, "target aspect must be positive")
    if zoom < 0.01 then zoom = 0.01 end
    if margin < 1 then margin = 1 end

    local halfAngularWidth = math.max(math.abs(extents.angularMinX), math.abs(extents.angularMaxX))
    local halfAngularHeight = math.max(math.abs(extents.angularMinY), math.abs(extents.angularMaxY))

    local top = math.max(halfAngularHeight, halfAngularWidth / aspect) * margin * zoom
    if top < 0.000001 then top = 0.000001 end
    local right = top * aspect

    local depthMin = extents.projectedDepthMin
    local depthMax = extents.projectedDepthMax
    local depthSpan = math.max(depthMax - depthMin, 0)
    local minimumDepthPadding = params.minimumDepthPadding or 1
    local depthPadding = math.max(depthSpan * (params.depthPaddingFactor or 0.1), minimumDepthPadding)

    -- A full radius of clearance: the preview's rotation fast path doesn't re-fit
    -- these planes, so a tilt could otherwise clip geometry against the backdrop.
    local clearance = math.max(depthPadding, extents.radius or 0)
    local near = math.max(depthMin - clearance, 0.1)
    local alphaPlaneDepth = depthMax + clearance
    local far = alphaPlaneDepth + depthPadding

    return {
        frustum = { -right, right, top, -top, near, far },
        right = right,
        top = top,
        aspect = aspect,
        zoom = zoom,
        margin = margin,
        halfAngularWidth = halfAngularWidth,
        halfAngularHeight = halfAngularHeight,
        depthMin = depthMin,
        depthMax = depthMax,
        depthSpan = depthSpan,
        depthPadding = depthPadding,
        near = near,
        far = far,
        alphaPlaneDepth = alphaPlaneDepth,
    }
end


return this
