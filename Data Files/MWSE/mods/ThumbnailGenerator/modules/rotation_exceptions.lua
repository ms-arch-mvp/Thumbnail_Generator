
local this = {}

local exceptions = {}
this.exceptions = exceptions

this.filePath = "data files\\MWSE\\mods\\ThumbnailGenerator\\rotation_exceptions.txt"

function this.addEntry(rotation, path, source)
    local norm = path:gsub("\\", "/"):lower()
    norm = norm:match("^%s*(.-)%s*$")
    norm = norm:gsub("%.[nN][iI][fF]$", "")
    norm = norm:gsub("/+", "/"):gsub("^/+", ""):gsub("/+$", "")

    local dir, file
    local lastSlash = nil
    for i = #norm, 1, -1 do
        if norm:sub(i, i) == "/" then
            lastSlash = i
            break
        end
    end
    if lastSlash then
        dir = norm:sub(1, lastSlash - 1)
        file = norm:sub(lastSlash + 1)
    else
        dir = ""
        file = norm
    end

    table.insert(exceptions, { dir = dir, file = file, rotation = rotation, source = source or "custom" })
end


function this.loadFromFile(path)
    local file = io.open(path, "r")
    if not file then
        return false
    end

    for i = #exceptions, 1, -1 do
        table.remove(exceptions, i)
    end

    local currentRotation = nil
    local currentSource = "custom"

    for line in file:lines() do
        line = line:match("^%s*(.-)%s*$")

        if line == "" then
        elseif line:sub(1, 1) == "#" then
            currentSource = line:sub(2):match("^%s*(.-)%s*$"):lower()
        else
            local rotateHeader = line:lower():match("^rotate%s+(%d+)%s*:")
            if rotateHeader then
                currentRotation = tonumber(rotateHeader)
            elseif currentRotation then
                this.addEntry(currentRotation, line, currentSource)
            end
        end
    end

    file:close()
    return true
end


function this.match(normalizedMeshPath)
    if not normalizedMeshPath or normalizedMeshPath == "" then return nil end

    local dir, file
    local lastSlash = nil
    for i = #normalizedMeshPath, 1, -1 do
        if normalizedMeshPath:sub(i, i) == "/" then
            lastSlash = i
            break
        end
    end
    if lastSlash then
        dir = normalizedMeshPath:sub(1, lastSlash - 1)
        file = normalizedMeshPath:sub(lastSlash + 1)
    else
        dir = ""
        file = normalizedMeshPath
    end

    local best = nil
    for _, entry in ipairs(exceptions) do
        if entry.dir == dir and file:find(entry.file, 1, true) then
            best = entry
        end
    end

    if not best then return nil end
    return {
        rotation = best.rotation,
        dir = best.dir,
        file = best.file,
        source = best.source,
        provenance = string.format(
            "mesh exception: rotate %d (fragment '%s' in dir '%s', %s)",
            best.rotation, best.file, best.dir == "" and "<root>" or best.dir, best.source),
    }
end


if not this.loadFromFile(this.filePath) then
    mwse.log(string.format(
        "[Thumbnail Generator] rotation_exceptions.lua: could not open '%s' -- no rotation exceptions loaded.",
        this.filePath))
end


return this
