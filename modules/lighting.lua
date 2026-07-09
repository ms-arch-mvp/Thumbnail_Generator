-- Deterministic key/fill point lights for the offscreen render.
local this = {}

local function clampColor(value)
    return math.max(0, math.min(1, value))
end

-- Deliberately not weather-sampled: Morrowind's sky colors skew warm even in
-- "Clear" weather, and diffuseScale amplifying that clipped red/green before
-- blue caught up, producing a visible yellow tint on every render.
local function getCurrentLighting(ambientScale, diffuseScale)
    local ambient = clampColor(0.22 * ambientScale)
    local diffuse = clampColor(1.0 * diffuseScale)
    return {
        ambient = niColor.new(ambient, ambient, ambient),
        diffuse = niColor.new(diffuse, diffuse, diffuse),
        specular = niColor.new(0.35, 0.35, 0.35),
        sun = 1.0,
        ambientMultiplier = 1.0,
        dimmer = 1.0,
    }
end

function this.addThumbnailLighting(params)
    local root = params.root
    local scene = params.scene
    local camera = params.camera
    local targetPos = params.targetPos
    local radius = params.radius
    local config = params.config or {}

    local keyDimmer = config.keyDimmer
    local keyX = config.keyX
    local keyY = config.keyY
    local keyZ = config.keyZ
    local fillDimmer = config.fillDimmer
    local ambientScale = config.ambientScale
    local diffuseScale = config.diffuseScale

    local lights = {}
    local lighting = getCurrentLighting(ambientScale, diffuseScale)
    local safeRadius = math.max(radius or 1, 1)
    local lightRadius = math.floor(math.max(safeRadius * 10, 512))

    local function attachPointLight(name, position, dimmer)
        local light = niPointLight.new()
        light.name = name
        light.enabled = true
        light.dimmer = dimmer
        light.ambient = lighting.ambient
        light.diffuse = lighting.diffuse
        light.specular = lighting.specular
        light:setRadius(lightRadius)
        light.translation = position

        root:attachChild(light)
        light:attachAffectedNode(scene)
        table.insert(lights, light)
    end

    -- Detached from the world, so lights are camera-relative rather than cell lights.
    local keyPos = targetPos - camera.worldDirection * (safeRadius * keyZ) + camera.worldUp * (safeRadius * keyY) +
        camera.worldRight * (safeRadius * keyX)
    attachPointLight(
        "ThumbnailKeyLight",
        keyPos,
        math.max(0.8, lighting.sun * lighting.dimmer * keyDimmer)
    )

    -- Opposite side, softening shadows.
    local fillPos = targetPos - camera.worldDirection * (safeRadius * keyZ * 0.6) -
        camera.worldUp * (safeRadius * keyY * 0.3) - camera.worldRight * (safeRadius * keyX * 1.2)
    attachPointLight(
        "ThumbnailFillLight",
        fillPos,
        math.max(0.35, lighting.ambientMultiplier * fillDimmer)
    )

    scene:updateEffects()
    return lights
end


return this
