-- Pure pixel/backdrop utilities for the offscreen capture: backdrop-plane
-- material control, the black/white difference matte, content-bbox scans, and
-- the content-fitted frustum. No state, no engine mutation beyond the plane
-- material (callers own capture/restore).
local this = {}

local ir = require("image_resize.image_resize")

-- 1.0 = exact-to-pixel content fit; raise slightly if edges ever kiss the frame.
local contentMargin = 1.0

function this.pixelPtr(pixelDataObject)
    local pd = ir.castPixelData(pixelDataObject)
    return pd.pixels + pd.offsets[0]
end

-- The backdrop's material may be shared with the live preview's plane via the
-- mesh cache; capture its exact colors so the matte can put them back.
function this.capturePlaneColor(alphaPlane)
    for node in table.traverse({ alphaPlane }) do
        local mat = node:getProperty(ni.propertyType.material)
        if mat then
            local a, d, e = mat.ambient, mat.diffuse, mat.emissive
            return { a.r, a.g, a.b, d.r, d.g, d.b, e.r, e.g, e.b }
        end
    end
    return nil
end

function this.applyPlaneColor(alphaPlane, saved)
    for node in table.traverse({ alphaPlane }) do
        local mat = node:getProperty(ni.propertyType.material)
        if mat then
            mat.ambient = niColor.new(saved[1], saved[2], saved[3])
            mat.diffuse = niColor.new(saved[4], saved[5], saved[6])
            mat.emissive = niColor.new(saved[7], saved[8], saved[9])
            return
        end
    end
end

-- The backdrop renders exactly its material emissive. The material may sit below
-- the loaded root; returns false when not found so callers skip the matte.
function this.setPlaneColor(alphaPlane, value)
    for node in table.traverse({ alphaPlane }) do
        local mat = node:getProperty(ni.propertyType.material)
        if mat then
            mat.emissive = niColor.new(value, value, value)
            mat.ambient = niColor.new(0, 0, 0)
            mat.diffuse = niColor.new(0, 0, 0)
            return true
        end
    end
    return false
end

-- Content = not pure backdrop in both passes, so broken framebuffer alpha
-- can't hide content from the scan.
function this.scanContentBBox(ptrA, ptrB, resolution)
    local minX, minY, maxX, maxY = resolution, resolution, -1, -1
    for y = 0, resolution - 1 do
        local rowBase = y * resolution * 4
        for x = 0, resolution - 1 do
            local i = rowBase + x * 4
            if ptrA[i] > 8 or ptrA[i + 1] > 8 or ptrA[i + 2] > 8
                or ptrB[i] < 247 or ptrB[i + 1] < 247 or ptrB[i + 2] < 247 then
                if x < minX then minX = x end
                if x > maxX then maxX = x end
                if y < minY then minY = y end
                if y > maxY then maxY = y end
            end
        end
    end
    if maxX < 0 then return nil end
    return minX, minY, maxX, maxY
end

-- alpha = 1 - (white - black), color un-premultiplied from the black pass.
-- Framebuffer alpha is unreliable: opaque materials write junk texture alpha,
-- additive flames write none.
function this.matteToTarget(ptrA, ptrB, resolution)
    local totalBytes = resolution * resolution * 4
    for i = 0, totalBytes - 1, 4 do
        local d = ((ptrB[i] - ptrA[i]) + (ptrB[i + 1] - ptrA[i + 1]) + (ptrB[i + 2] - ptrA[i + 2])) / 3
        if d < 0 then d = 0 elseif d > 255 then d = 255 end
        local a = 255 - d
        if a < 1 then
            ptrA[i], ptrA[i + 1], ptrA[i + 2], ptrA[i + 3] = 0, 0, 0, 0
        else
            if a < 255 then
                local s = 255 / a
                local b = ptrA[i] * s
                local g = ptrA[i + 1] * s
                local r = ptrA[i + 2] * s
                ptrA[i] = b < 255 and b or 255
                ptrA[i + 1] = g < 255 and g or 255
                ptrA[i + 2] = r < 255 and r or 255
            end
            ptrA[i + 3] = a
        end
    end
end

-- Content bounding box of the rendered pixels: anything with alpha above a
-- small threshold.
function this.scanContentAlpha(ptr, resolution)
    local minX, minY, maxX, maxY = resolution, resolution, -1, -1
    for y = 0, resolution - 1 do
        local rowBase = y * resolution * 4
        for x = 0, resolution - 1 do
            if ptr[rowBase + x * 4 + 3] > 8 then
                if x < minX then minX = x end
                if x > maxX then maxX = x end
                if y < minY then minY = y end
                if y > maxY then maxY = y end
            end
        end
    end
    if maxX < 0 then return nil end
    return minX, minY, maxX, maxY
end

-- Derives a tightened, possibly off-center frustum around the content box.
-- Returns nil when the content already reaches every edge.
function this.frustumFromContent(frustum, minX, minY, maxX, maxY, resolution)
    if minX <= 0 and minY <= 0 and maxX >= resolution - 1 and maxY >= resolution - 1 then
        return nil
    end

    local left, right, top, bottom = frustum[1], frustum[2], frustum[3], frustum[4]
    local uMin, uMax = minX / resolution, (maxX + 1) / resolution
    local vMin, vMax = minY / resolution, (maxY + 1) / resolution

    -- Buffer row 0 is the image top.
    local newLeft = left + uMin * (right - left)
    local newRight = left + uMax * (right - left)
    local newTop = top + vMin * (bottom - top)
    local newBottom = top + vMax * (bottom - top)

    -- Square aspect: grow the smaller span about the content center.
    local cx = (newLeft + newRight) / 2
    local cy = (newTop + newBottom) / 2
    local half = math.max(math.abs(newRight - newLeft), math.abs(newTop - newBottom)) / 2 * contentMargin

    return { cx - half, cx + half, cy + half, cy - half, frustum[5], frustum[6] }
end

return this
