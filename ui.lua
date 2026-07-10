-- Main batch render window and its glue to render/preview.
local this = {}

local render = require("ThumbnailGenerator.render")
local thumbnail_settings = require("ThumbnailGenerator.modules.thumbnail_settings")
local preview_editor = require("ThumbnailGenerator.preview")
local subject_resolver = require("ThumbnailGenerator.modules.subject_resolver")
local settings = thumbnail_settings

local menuID = "ThumbnailGen:ThumbnailMenu"
local searchInputID = tes3ui.registerID("ThumbnailGen:SearchInput")

-- Kept across menu close/reopen (e.g. opening a preview and coming back) for
-- this game session; reset on reload.
local lastSearchPattern = ""

local function getColor(name)
    return tes3ui.getPalette(name)
end

--   leaveMenuMode()/enterMenuMode() are both deferred to frame end, and a same-frame
--   leave would win over the enter, dropping out of menu mode entirely.
function this.closeMenu(keepMenuMode)
    local menu = tes3ui.findMenu(menuID)
    if menu then
        pcall(render.cancelBatch)

        local searchInput = menu:findChild(searchInputID)
        if searchInput then
            lastSearchPattern = searchInput.text
        end

        if not keepMenuMode then
            tes3ui.leaveMenuMode()
        end
        menu:destroy()
    end
end


function this.openMenu()
    local existing = tes3ui.findMenu(menuID)
    if existing then
        tes3ui.moveMenuToFront(existing)
        return existing
    end

    local menu = tes3ui.createMenu({
        id = menuID,
        fixedFrame = true,
    })
    menu.minWidth = 500
    menu.minHeight = 120
    menu.autoHeight = true
    menu.autoWidth = true

    local contents = menu:createBlock()
    contents.flowDirection = tes3.flowDirection.topToBottom
    contents.widthProportional = 1.0
    contents.autoHeight = true
    contents.borderAllSides = 12

    local titleLabel = contents:createLabel({ text = "Thumbnails from search (id/name/mesh path/.esp/.esm):" })
    titleLabel.borderBottom = 15

    local inputBlock = contents:createBlock()
    inputBlock.autoHeight = false
    inputBlock.height = 75
    inputBlock.widthProportional = 1.0
    inputBlock.borderBottom = 12
    inputBlock.flowDirection = tes3.flowDirection.topToBottom

    local searchInput = inputBlock:createTextInput({ id = searchInputID, createBorder = false })
    searchInput.widthProportional = 1.0
    searchInput.height = 30
    searchInput.borderAllSides = 5
    searchInput.borderTop = 10
    searchInput.text = lastSearchPattern
    searchInput:register(tes3.uiEvent.mouseClick, function(e)
        tes3ui.acquireTextInput(e.source)
    end)
    searchInput:register(tes3.uiEvent.keyEnter, function()
        tes3ui.acquireTextInput(nil)
        return false
    end)

    local btnClear = inputBlock:createButton({ text = "Clear" })
    btnClear.borderTop = 10
    btnClear.visible = (lastSearchPattern ~= "")
    btnClear:register(tes3.uiEvent.mouseClick, function()
        searchInput.text = ""
        lastSearchPattern = ""
        btnClear.visible = false
        inputBlock:updateLayout()
        tes3ui.acquireTextInput(searchInput)
    end)

    searchInput:register(tes3.uiEvent.textUpdated, function()
        local hasText = searchInput.text ~= ""
        if btnClear.visible ~= hasText then
            btnClear.visible = hasText
            inputBlock:updateLayout()
        end
    end)

    -- Fixed two-line block reserves the space so a one- vs two-line status message
    -- doesn't resize the menu (a bare label auto-sizes to its text and ignores height).
    local statusBlock = contents:createBlock()
    statusBlock.widthProportional = 1.0
    statusBlock.height = 44
    statusBlock.autoHeight = false
    statusBlock.borderBottom = 16
    local statusLabel = statusBlock:createLabel({ text = "" })
    statusLabel.color = getColor("normal_color")

    local buttonBlock = contents:createBlock()
    buttonBlock.flowDirection = tes3.flowDirection.leftToRight
    buttonBlock.widthProportional = 1.0
    buttonBlock.autoHeight = true
    buttonBlock.childAlignX = 1.0
    buttonBlock.borderTop = 20

    local btnRender = buttonBlock:createButton({ text = "Batch" })
    btnRender.borderRight = 10

    local btnFlagged = buttonBlock:createButton({ text = "Flagged" })
    btnFlagged.borderRight = 10

    local btnCancel = buttonBlock:createButton({ text = "Cancel Batch" })
    btnCancel.borderRight = 10
    btnCancel.visible = false

    local btnPreview = buttonBlock:createButton({ text = "Preview" })
    btnPreview.borderRight = 10

    local btnClose = buttonBlock:createButton({ text = "Close" })

    btnClose:register(tes3.uiEvent.mouseClick, function() this.closeMenu() end)
    btnCancel:register(tes3.uiEvent.mouseClick, function()
        render.cancelBatch()
    end)

    btnPreview:register(tes3.uiEvent.mouseClick, function()
        local selectedTypes = thumbnail_settings.getEnabledTypes()

        if #selectedTypes == 0 then
            statusLabel.text = "Error: No object types selected."
            statusLabel.color = getColor("negative_color")
            menu:updateLayout()
            return
        end

        local searchPattern = searchInput.text
        if not searchPattern or searchPattern == "" then
            -- No pattern: browse by plugin instead of erroring.
            local plugins = subject_resolver.listPlugins({ types = selectedTypes })
            if #plugins == 0 then
                statusLabel.text = "Error: No displayable records found."
                statusLabel.color = getColor("negative_color")
                menu:updateLayout()
                return
            end
            preview_editor.showPluginMenu(plugins, {
                types = selectedTypes,
                closeMenu = this.closeMenu,
                onExit = this.openMenu,
            })
            return
        end

        local matches = subject_resolver.search({ pattern = searchPattern, types = selectedTypes })

        if #matches == 0 then
            statusLabel.text = "Error: No matching meshes found."
            statusLabel.color = getColor("negative_color")
            menu:updateLayout()
            return
        end

        if #matches == 1 then
            this.closeMenu(true)
            preview_editor.open(matches[1].subject, {
                closeMenu = this.closeMenu,
                onExit = this.openMenu,
            })
        else
            preview_editor.showSelectionMenu(matches, {
                closeMenu = this.closeMenu,
                onExit = this.openMenu,
            })
        end
    end)

    -- Shared batch launch. `extra` carries the scope: Batch passes enabled types
    -- and the search pattern; Flagged passes flaggedOnly (all types, flagged file).
    local function startBatch(extra)
        statusLabel.text = "Rendering batch... (Starting)"
        statusLabel.color = getColor("active_color")
        btnRender.visible = false
        btnFlagged.visible = false
        btnPreview.visible = false
        btnCancel.visible = true
        menu:updateLayout()

        local function restoreButtons()
            btnRender.visible = true
            btnFlagged.visible = true
            btnPreview.visible = true
            btnCancel.visible = false
        end

        -- one-frame delay so the "Starting" label actually renders first
        timer.frame.delayOneFrame(function()
            local ok, err = pcall(function()
                local params = {
                    forceOrtho = settings.current.forceOrtho,
                    resolution = settings.current.renderResolution,
                    dstResolution = settings.current.outputResolution,
                    onProgress = function(renderedCount, totalToRender)
                        statusLabel.text = string.format("Rendering batch... (%d/%d)", renderedCount, totalToRender)
                        menu:updateLayout()
                    end,
                    onComplete = function(totalFound, successCount, emptyCount, failedCount)
                        local text = string.format("Rendered %d thumbnails.", successCount)
                        if emptyCount and emptyCount > 0 then
                            text = text .. string.format(" %d empty skipped.", emptyCount)
                        end
                        if failedCount and failedCount > 0 then
                            text = text .. string.format(" %d failed.", failedCount)
                        end
                        statusLabel.text = text
                        statusLabel.color = getColor("positive_color")
                        restoreButtons()
                        menu:updateLayout()
                    end,
                    onError = function(errMsg)
                        statusLabel.text = tostring(errMsg)
                        statusLabel.color = getColor("negative_color")
                        restoreButtons()
                        menu:updateLayout()
                    end,
                }
                for key, value in pairs(extra) do params[key] = value end
                render.renderBatch(params)
            end)

            if not ok then
                statusLabel.text = "Error: " .. tostring(err)
                statusLabel.color = getColor("negative_color")
                restoreButtons()
                menu:updateLayout()
            end
        end)
    end

    btnRender:register(tes3.uiEvent.mouseClick, function()
        local selectedTypes = thumbnail_settings.getEnabledTypes()
        if #selectedTypes == 0 then
            statusLabel.text = "Error: No object types selected."
            statusLabel.color = getColor("negative_color")
            menu:updateLayout()
            return
        end
        startBatch({ objectType = selectedTypes, searchPattern = searchInput.text })
    end)

    -- Renders only meshes listed in the flagged file, across all object types.
    btnFlagged:register(tes3.uiEvent.mouseClick, function()
        startBatch({ flaggedOnly = true })
    end)

    menu:updateLayout()
    tes3ui.enterMenuMode(menuID)
    tes3ui.acquireTextInput(searchInput)
    return menu
end


return this
