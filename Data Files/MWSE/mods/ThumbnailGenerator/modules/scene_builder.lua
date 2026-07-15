-- Scene construction/normalization: turns a record into a renderable scene
-- (plain records: mesh load + clone; actors: temporary posed reference) and
-- fixes up everything a static offscreen capture needs -- particle follow bits,
-- helper-node culling, switch-node pinning, and capture-safe particle blends.
local this = {}

local bit = require("bit")

local settings = require("ThumbnailGenerator.modules.thumbnail_settings")

-- Animation text keys ("Idle: Loop Start") live in the keyframe manager's
-- sequences, not node extra data; one key's text can hold several markers.
local function collectTextKeys(sceneNode)
    local keys = {}

    local function addKey(time, text)
        for line in tostring(text):gmatch("[^\r\n]+") do
            table.insert(keys, { time = time, text = line })
        end
    end

    for node in table.traverse({ sceneNode }) do
        pcall(function()
            local extra = node.extraData
            while extra do
                if extra:isInstanceOfType(tes3.niType.NiTextKeyExtraData) and extra.keys then
                    for _, key in ipairs(extra.keys) do
                        addKey(key.time, key.text)
                    end
                end
                extra = extra.next
            end
        end)

        local controller = node.controller
        while controller do
            local okSeq, sequences = pcall(function() return controller.sequences end)
            if okSeq and sequences then
                pcall(function()
                    for _, sequence in ipairs(sequences) do
                        local textKeyData = sequence.textKeys
                        if textKeyData then
                            -- niTextKeyExtraData object or a bare key array.
                            local list = textKeyData.keys or textKeyData
                            for _, key in ipairs(list) do
                                addKey(key.time, key.text)
                            end
                        end
                    end
                end)
            end
            controller = controller.nextController
        end
    end

    return keys
end

-- Picks a settled idle pose time from text keys: the loop midpoint of "Idle"
-- (falling back to Idle2..Idle9, then to the group's start/stop midpoint).
local function findIdlePoseTime(keys)
    local groups = {}
    for _, key in ipairs(keys) do
        local group, action = key.text:match("^%s*(.-)%s*:%s*(.-)%s*$")
        if group and group ~= "" then
            group = group:lower()
            groups[group] = groups[group] or {}
            groups[group][action:lower()] = key.time
        end
    end

    local candidates = { "idle", "idle2", "idle3", "idle4", "idle5", "idle6", "idle7", "idle8", "idle9" }
    for _, name in ipairs(candidates) do
        local g = groups[name]
        if g then
            local a, b = g["loop start"], g["loop stop"]
            if not (a and b and b >= a) then
                a, b = g["start"], g["stop"]
            end
            if a and b and b >= a then
                return (a + b) / 2, name
            end
            if g["start"] then
                return g["start"], name
            end
        end
    end
    return nil, nil
end

-- Actor visuals/animations are wired up at instancing time, not on the record:
-- spawn a temporary reference, pose it, clone the scene node, delete the reference.
function this.createActorScene(actor)
    local player = tes3.player
    local ref = tes3.createReference({
        object = actor,
        cell = player.cell,
        -- Out of sight/physics range; deleted again before any frame renders.
        position = player.position + tes3vector3.new(0, 0, 100000),
        orientation = tes3vector3.new(0, 0, 0),
    })

    local ok, result = pcall(function()
        if not ref or not ref.sceneNode then
            error("Failed to instance actor reference: " .. tostring(actor.id))
        end

        -- Idle loop midpoint = settled stance; engine timing is the fallback.
        local textKeys = collectTextKeys(ref.sceneNode)
        local poseTime = findIdlePoseTime(textKeys)

        if not poseTime then
            local timings = tes3.getAnimationActionTiming({ reference = ref, group = tes3.animationGroup.idle })
            if timings then
                local loopStart = timings["Loop Start"]
                local loopStop = timings["Loop Stop"]
                if loopStart and loopStop and loopStop > loopStart then
                    poseTime = (loopStart + loopStop) / 2
                else
                    poseTime = loopStart or timings["Start"]
                end
            end
        end

        -- Activate idle so controllers aren't sampling an inactive sequence.
        if poseTime then
            pcall(function()
                local animData = ref.mobile.animationController.animationData
                animData:playAnimationGroup(tes3.animationGroup.idle, tes3.animationStartFlag.immediate, -1)
                for i = 1, #animData.timings do
                    animData.timings[i] = poseTime
                end
            end)
        end

        if poseTime then
            ref.sceneNode:update({ controllers = true, time = poseTime })
        end

        local clone = ref.sceneNode:clone()

        -- clone() doesn't remap NiSkinInstance references; rebind skin root/bones
        -- by name before the original skeleton is deleted.
        for node in table.traverse({ clone }) do
            local skin = node.skinInstance
            if skin then
                skin.root = clone:getObjectByName(skin.root.name)
                for i, bone in ipairs(skin.bones) do
                    skin.bones[i] = clone:getObjectByName(bone.name)
                end
            end
        end

        -- Racial height/weight scaling is baked into the root's transform and
        -- positionScene overwrites the top node's rotation -- wrap so it survives.
        clone.translation = tes3vector3.new(0, 0, 0)
        local wrapper = niNode.new()
        wrapper:attachChild(clone)
        wrapper:update()
        return wrapper
    end)

    if ref then
        ref:delete()
    end

    if not ok then
        error(result)
    end
    return result
end

-- Without the Follow bit, particles stay where the mesh first loaded instead
-- of following the scene to the render position.
local niFlagFollow = 0x80

local function enableParticleFollow(scene)
    for node in table.traverse({ scene }) do
        if node:isInstanceOfType(tes3.niType.NiBSParticleNode) then
            node.flags = bit.bor(node.flags, niFlagFollow)
            node:update()
        end
    end
end

-- The engine never draws RootCollisionNode or "Bounding Box" helpers, but raw
-- loaded NIFs include them; app-culling hides them from render and framing alike.
local function hideCollisionNodes(scene)
    for node in table.traverse({ scene }) do
        if node:isInstanceOfType(tes3.niType.RootCollisionNode) then
            node.appCulled = true
        elseif node.name and node.name:lower() == "bounding box" then
            -- Actor meshes carry a "Bounding Box" helper the engine never draws;
            -- left visible it inflates the measured framing extents.
            node.appCulled = true
        end
    end
end

-- Switch nodes (NiSwitchNode, and its NiFltAnimationNode flipbook subclass) show
-- one child at a time, cycled by an animation controller the static thumbnail
-- never ticks -- so the flip is left in an undefined state and every frame draws
-- stacked (or none does). Pin a single valid frame: keep the active child (or the
-- first real one) and app-cull the siblings, so render and framing see one state.
-- NiLODNode is also a NiSwitchNode subclass but is excluded -- its level selection
-- is driven live by camera.lodAdjust (the flame-emitter fix), not pinned here.
local function pinSwitchNodes(scene)
    for node in table.traverse({ scene }) do
        if node:isInstanceOfType(tes3.niType.NiSwitchNode)
            and not node:isInstanceOfType(tes3.niType.NiLODNode) then
            local children = node.children
            -- switchIndex is 0-based (-1 = none); children is 1-based with nil gaps.
            local keep = node.switchIndex
            if not keep or keep < 0 or not children[keep + 1] then
                -- No usable active child: fall back to the first real one and re-point.
                keep = nil
                for i = 1, #children do
                    if children[i] then
                        keep = i - 1
                        break
                    end
                end
                if keep then node.switchIndex = keep end
            end
            if keep then
                for i = 1, #children do
                    if children[i] then
                        children[i].appCulled = (i - 1) ~= keep
                    end
                end
            end
        end
    end
end

-- Difference matting handles any particle blend that interacts with the
-- backdrop: additive (dest ONE -- flames, sparks) and true alpha blending
-- (dest INV_SRC_ALPHA -- smoke, red 6th-house flames) both capture correctly.
-- The one broken class is dest DST_ALPHA: additive in-game (the backbuffer has
-- no alpha channel, so destAlpha reads as 1) but backdrop-INDEPENDENT on the
-- offscreen target (whose alpha channel is real and ~0, so it replaces) --
-- identical in both matte passes, so it mattes as opaque black splotches.
-- Rewrite it to dest ONE, the in-game equivalent, for the capture (bit 0 =
-- blend enable, bits 5-8 = destination blend). The properties are shared via
-- the mesh cache: always call the returned restore function after the capture,
-- including on error. File renders only; the live preview needs no adaptation.
function this.adaptParticleBlends(scene)
    local restores = {}
    local alphaType = ni.propertyType and ni.propertyType.alpha
    if alphaType then
        local seen = {}
        for node in table.traverse({ scene }) do
            if node:isInstanceOfType(tes3.niType.NiParticles) then
                -- The alpha property may sit on the shape or a parent node.
                local holder, alphaProp = node, nil
                while holder and not alphaProp do
                    alphaProp = holder:getProperty(alphaType)
                    holder = holder.parent
                end
                if alphaProp and not seen[alphaProp] then
                    seen[alphaProp] = true
                    local flags = alphaProp.propertyFlags
                    local blending = bit.band(flags, 1) == 1
                    local destBlend = bit.band(bit.rshift(flags, 5), 0xF)
                    if blending and destBlend == 8 then
                        -- DST_ALPHA -> ONE for the capture.
                        local cleared = bit.band(flags, bit.bnot(bit.lshift(0xF, 5)))
                        local okSet = pcall(function() alphaProp.propertyFlags = cleared end)
                        if okSet then
                            table.insert(restores, { prop = alphaProp, flags = flags })
                        else
                            -- Read-only flags: degrade to culling rather than splotches.
                            node.appCulled = true
                        end
                    end
                end
            end
        end
        if #restores > 0 then
            scene:updateProperties()
        end
    end
    return function()
        for _, entry in ipairs(restores) do
            pcall(function() entry.prop.propertyFlags = entry.flags end)
        end
        restores = {}
    end
end

-- Particle data is shared with live world instances via the mesh cache, so a
-- clone can capture an arbitrary mid-simulation snapshot. Re-simulate
-- deterministically instead, in small steps -- particles are stateful, one big
-- jump just clumps them.
local particlePrimeStep = 0.1

local function primeParticles(scene)
    local primeTime = settings.current.particlePrimeTime or 0
    if primeTime <= 0 then return end

    local hasParticles = false
    for node in table.traverse({ scene }) do
        if node:isInstanceOfType(tes3.niType.NiParticles) then
            hasParticles = true
            break
        end
    end
    if not hasParticles then return end

    for t = 0, primeTime, particlePrimeStep do
        scene:update({ controllers = true, time = t })
    end
end

-- Creates a renderable scene from either a mesh path or a cloned NPC actor.
function this.createRenderableScene(subject, meshPath)
    local obj = subject and subject.object
    local scene
    if obj and (obj.objectType == tes3.objectType.npc or obj.objectType == tes3.objectType.creature) then
        scene = this.createActorScene(obj)
    else
        scene = tes3.loadMesh(meshPath)
        if not scene then
            error("Failed to load mesh: " .. tostring(meshPath))
        end
        scene = scene:clone()
        primeParticles(scene)
    end

    enableParticleFollow(scene)
    hideCollisionNodes(scene)
    pinSwitchNodes(scene)
    return scene
end

function this.createRootNode(scene, alphaPlane)
    local root = niNode.new()
    root.name = "ThumbnailRootNode"
    root:attachChild(scene)
    root:attachChild(alphaPlane)

    local zBuf = niZBufferProperty.new()
    zBuf.propertyFlags = 3
    root:attachProperty(zBuf)

    local vcol = niVertexColorProperty.new()
    vcol.source = ni.sourceVertexMode.ambDiff
    root:attachProperty(vcol)

    return root
end

return this
