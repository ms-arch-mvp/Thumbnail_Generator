-- Single authority for which side of a subject the camera looks at: resolves a
-- category from config's view directions and folds in rotation exceptions;
-- `offsetDirForProfile` turns that into the direction `render.getSceneRotation` uses.
local this = {}

local rotation_exceptions = require("ThumbnailGenerator.modules.rotation_exceptions")
local settings = require("ThumbnailGenerator.modules.thumbnail_settings")

-- Hair body parts get their own view: the bodypart direction is tuned for faces.
local function isHair(subject)
    return subject.object ~= nil
        and subject.objectType == tes3.objectType.bodyPart
        and subject.object.part == tes3.partIndex.hair
end

-- Precedence: hair > per-type view direction > standard fallback.
function this.resolve(subject)
    if not subject then return nil end

    local category = "standard"
    if isHair(subject) then
        category = "hair"
    else
        local key = settings.typeToKey[subject.objectType]
        if key and settings.current.viewDirections[key] then
            category = key
        end
    end

    -- Orientation-only corrections, consumed as an additive yaw adjustment at render time.
    local rotationRules = {}
    local rotationMatch = rotation_exceptions.match(subject.normalizedMeshPath)
    if rotationMatch then
        table.insert(rotationRules, { orbitAdjustDeg = rotationMatch.rotation })
    end

    return {
        category = category,
        rotationRules = rotationRules,
    }
end

function this.offsetDirForProfile(profile)
    local dir
    if profile and profile.direction then
        -- Explicit direction (render profiles' "override" mode): replaces the
        -- category base view entirely; rotationRules still apply if present.
        dir = tes3vector3.new(profile.direction[1], profile.direction[2], profile.direction[3])
    else
        local directions = settings.current.viewDirections
        local base = directions[(profile and profile.category) or "standard"] or directions.standard
        dir = tes3vector3.new(base[1], base[2], base[3])
    end

    local angleDeg = 0
    if profile and profile.rotationRules then
        for _, rule in ipairs(profile.rotationRules) do
            angleDeg = angleDeg + (rule.orbitAdjustDeg or 0)
        end
    end
    if angleDeg ~= 0 then
        -- Rotate the diagonal about world-Z. Negated because the adjustment is
        -- expressed CCW while MW toRotationZ is CW.
        local rot = tes3matrix33.new()
        rot:toRotationZ(math.rad(-angleDeg))
        dir = rot * dir
    end

    return dir:normalized()
end


return this
