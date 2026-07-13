-- Interactive 3D preview editor: drag to rotate, scroll to zoom, live sliders.
-- UI and input wiring only; the 3D state and fit math live in
-- modules/preview_scene, the subject pickers in modules/preview_pickers.
local this = {}

local render = require("ThumbnailGenerator.render")
local subject_resolver = require("ThumbnailGenerator.modules.subject_resolver")
local settings = require("ThumbnailGenerator.modules.thumbnail_settings")
local preview_scene = require("ThumbnailGenerator.modules.preview_scene")
local preview_pickers = require("ThumbnailGenerator.modules.preview_pickers")
local profiles = require("ThumbnailGenerator.modules.profiles")
local camera_profiles = require("ThumbnailGenerator.modules.camera_profiles")
local scene_builder = require("ThumbnailGenerator.modules.scene_builder")

local backgroundMenuID = "ThumbnailGen:PreviewBackground"
local controlsMenuID = "ThumbnailGen:PreviewControls"
local profilePopupID = "ThumbnailGen:ProfilePopup"

-- Slider bounds for raw zoom values.
local displayZoomMin = 0.05
local displayZoomMax = 10

local function getColor(name)
    return tes3ui.getPalette(name)
end

-- The pickers report a choice via options.onPick; wire it to open() with the
-- same options so nested pickers (plugin list -> selection list) keep working.
local function withOpen(options)
    options = options or {}
    options.onPick = function(subjectOrObj)
        this.open(subjectOrObj, options)
    end
    return options
end

function this.showPluginMenu(plugins, options)
    preview_pickers.showPluginMenu(plugins, withOpen(options))
end

function this.showSelectionMenu(matches, options)
    preview_pickers.showSelectionMenu(matches, withOpen(options))
end

function this.open(objOrSubject, options)
    local subject
    if type(objOrSubject) == "table" and objOrSubject.recordId then
        subject = objOrSubject
    else
        subject = subject_resolver.resolve(objOrSubject)
    end

    -- Builds the camera scene and stashes everything the destroy handler restores.
    local ts = preview_scene.begin(subject)
    local camera = ts.camera

    -- Snapshot the opening camera values so the Reset button can restore them.
    local cameraDefaults = {
        yaw = ts.config.yaw,
        pitch = ts.config.pitch,
        roll = ts.config.roll,
        zoom = ts.config.zoom,
        perspectiveDistanceFactor = ts.config.perspectiveDistanceFactor,
    }

    local function isMouseOverUI()
        local cp = tes3.getCursorPosition()
        -- Suppress capture over the settings menu and the (modal) switch-search
        -- selection list. positionY is the menu's top edge; it extends down (-y).
        for _, id in ipairs({ controlsMenuID, preview_pickers.menuID }) do
            local menu = tes3ui.findMenu(id)
            if menu and menu.visible
                and cp.x >= menu.positionX and cp.x <= (menu.positionX + menu.width)
                and cp.y <= menu.positionY and cp.y >= (menu.positionY - menu.height) then
                return true
            end
        end
        return false
    end

    -- True only while one of our preview menus is topmost, so opening another menu
    -- (e.g. Escape) suspends the drag/zoom/pan capture.
    local function isPreviewActive()
        local top = tes3ui.getMenuOnTop()
        if not top then return false end
        return top.id == tes3ui.registerID(controlsMenuID)
            or top.id == tes3ui.registerID(backgroundMenuID)
    end

    -- True while this open()'s scene is still the live one; stale handlers from a
    -- closed or switched-away preview must not touch the current state.
    local function isCurrent()
        return preview_scene.state == ts
    end

    local function applyDragRotation(newYaw, newPitch)
        newPitch = math.max(-90, math.min(90, newPitch))
        newYaw = (newYaw + 180) % 360 - 180

        ts.config.yaw = newYaw
        ts.config.pitch = newPitch

        -- Sync the yaw/pitch slider thumbs + labels to the drag value.
        if ts.sliders.yaw then
            ts.sliders.yaw.widget.current = math.floor(newYaw + 180)
        end
        if ts.labels.yaw then
            ts.labels.yaw.text = string.format("Yaw: %d deg", math.floor(newYaw))
        end
        if ts.sliders.pitch then
            ts.sliders.pitch.widget.current = math.floor(newPitch + 90)
        end
        if ts.labels.pitch then
            ts.labels.pitch.text = string.format("Pitch: %d deg", math.floor(newPitch))
        end

        preview_scene.update({ rotationOnly = true })
    end

    -- Sets zoom from a discrete input (mouse wheel), syncing the zoom slider.
    -- Zoom is stored render-scale (1.0 = neutral, lower = closer); the display
    -- shows its reciprocal as magnification (higher = closer).
    local function applyZoom(newDisplayZoom)
        newDisplayZoom = math.max(displayZoomMin, math.min(displayZoomMax, newDisplayZoom))
        ts.config.zoom = 1.0 / newDisplayZoom
        if ts.sliders.zoom then
            ts.sliders.zoom.widget.current = math.floor((newDisplayZoom - displayZoomMin) / 0.05 + 0.5)
            if ts.labels.zoom then
                ts.labels.zoom.text = string.format("Zoom: %.2fx", newDisplayZoom)
            end
        end
        preview_scene.update({ zoomOnly = true })
    end

    -- Set true while the switch-search box has keyboard focus, to keep WASD panning
    -- from stealing typed characters.
    local searchFocused = false

    -- WASD moves the subject to pan. panX/panY are subject-radius offsets, so
    -- panSpeed reads as radii/second (at neutral zoom); dt keeps it framerate-
    -- independent and the zoom factor keeps on-screen speed constant.
    local panLimit = 2.0
    local function pollPan(dt)
        if searchFocused or not isPreviewActive() then return end
        local ic = tes3.worldController.inputController
        -- On-screen speed tracks visible size: render-scale zoom x the live margin.
        local step = settings.current.panSpeed * (ts.config.zoom or 1) * preview_scene.liveViewMargin * dt
        local dx, dy = 0, 0
        -- D pans the view right (subject slides left), etc.
        if ic:isKeyDown(tes3.scanCode.d) then dx = dx - step end
        if ic:isKeyDown(tes3.scanCode.a) then dx = dx + step end
        if ic:isKeyDown(tes3.scanCode.w) then dy = dy - step end
        if ic:isKeyDown(tes3.scanCode.s) then dy = dy + step end
        if dx ~= 0 then ts.panX = math.max(-panLimit, math.min(panLimit, ts.panX + dx)) end
        if dy ~= 0 then ts.panY = math.max(-panLimit, math.min(panLimit, ts.panY + dy)) end
    end

    -- Drives right-drag rotation from the live cursor and holds the ortho frustum
    -- (engine only rebuilds it on FOV/mode/cell changes). Torn down in destroy.
    local function onPreviewFrame(e)
        if not isCurrent() then return end

        if ts.dragStartMouseX then
            local cp = tes3.getCursorPosition()
            local dx = cp.x - ts.dragStartMouseX
            local dy = cp.y - ts.dragStartMouseY
            local sensitivity = 0.5
            applyDragRotation(
                ts.dragStartYaw + dx * sensitivity,
                ts.dragStartPitch - dy * sensitivity
            )
        end

        pollPan(e.delta or 0)

        -- Offset the subject from its centered base translation to pan (see pollPan).
        if ts.baseTranslation and (ts.panX ~= 0 or ts.panY ~= 0) then
            local cam = ts.camera
            ts.scene.translation = ts.baseTranslation
                + cam.worldRight * (ts.panX * ts.radius)
                + cam.worldUp * (ts.panY * ts.radius)
            ts.scene:update()
        end

        if ts.orthoFrustum then
            render.setFrustum(ts.camera, ts.orthoFrustum)
        end
    end
    event.register("enterFrame", onPreviewFrame)

    local bgMenu = tes3ui.createMenu({ id = backgroundMenuID, fixedFrame = true, modal = false })
    bgMenu.widthProportional = 1.0
    bgMenu.heightProportional = 1.0
    bgMenu.alpha = 0.0

    local bgFrame = bgMenu:findChild("PartNonDragMenu_main") or bgMenu:findChild("PartNonInteractive_outer_frame")
    if bgFrame then
        bgFrame.visible = false
    end

    local function onMouseButtonDown(e)
        -- In MWSE this uses 1 for the right mouse button.
        if not isCurrent() or e.button ~= 1 or isMouseOverUI() or not isPreviewActive() then return end
        -- Clicking into the 3D view releases the search box, re-enabling WASD pan.
        tes3ui.acquireTextInput(nil)
        searchFocused = false
        local cp = tes3.getCursorPosition()
        ts.dragStartMouseX = cp.x
        ts.dragStartMouseY = cp.y
        ts.dragStartYaw = ts.config.yaw
        ts.dragStartPitch = ts.config.pitch
    end
    event.register(tes3.event.mouseButtonDown, onMouseButtonDown)

    local function onMouseButtonUp(e)
        if not isCurrent() then return end
        if e.button == 1 then
            ts.dragStartMouseX = nil
            ts.dragStartMouseY = nil
        elseif e.button == 0 and ts.pendingRefit then
            -- Left-release after a rotation slider: settle so the subject re-centers
            -- (rotationOnly drifts it off-center mid-move). The re-center is
            -- frustum-independent, so keep the pre-release framing afterwards -- a
            -- full re-fit would also re-tighten the crop and change the apparent zoom.
            ts.pendingRefit = nil
            local keepFrustum = ts.orthoFrustum
            local keepDepth = not keepFrustum and preview_scene.dollyFitEnabled()
                and preview_scene.currentViewDepth() or nil
            preview_scene.update()
            if keepFrustum then
                ts.orthoFrustum = keepFrustum
                render.setFrustum(ts.camera, keepFrustum)
            elseif keepDepth then
                preview_scene.restoreDollyDepth(keepDepth)
            end
        end
    end
    event.register(tes3.event.mouseButtonUp, onMouseButtonUp)

    local zoomWheelStep = 0.10
    local function onMouseWheel(e)
        if not isCurrent() or isMouseOverUI() or not isPreviewActive() then return end
        local currentDisplayZoom = 1.0 / ts.config.zoom
        if e.delta > 0 then
            applyZoom(currentDisplayZoom + zoomWheelStep)
        elseif e.delta < 0 then
            applyZoom(currentDisplayZoom - zoomWheelStep)
        end
    end
    event.register(tes3.event.mouseWheel, onMouseWheel)

    if tes3.mobilePlayer then
        tes3.mobilePlayer.controlsDisabled = true
    end

    local controlsMenu = tes3ui.createMenu({ id = controlsMenuID, dragFrame = true })
    controlsMenu.text = "Preview"
    controlsMenu.width = 380
    controlsMenu.height = 680
    controlsMenu.minWidth = 380
    controlsMenu.minHeight = 680
    controlsMenu.maxWidth = 380
    controlsMenu.maxHeight = 680

    if not controlsMenu:loadMenuPosition() then
        controlsMenu.absolutePosAlignX = 1.0
        controlsMenu.absolutePosAlignY = 0.35
        controlsMenu:updateLayout()
        controlsMenu.absolutePosAlignX = nil
        controlsMenu.absolutePosAlignY = nil
    end

    -- The sole cleanup path: unregister this instance's handlers, then let
    -- preview_scene restore the frustum/MGE flags/camera scene.
    controlsMenu:register(tes3.uiEvent.destroy, function()
        controlsMenu:saveMenuPosition()

        event.unregister("enterFrame", onPreviewFrame)
        event.unregister(tes3.event.mouseButtonDown, onMouseButtonDown)
        event.unregister(tes3.event.mouseButtonUp, onMouseButtonUp)
        event.unregister(tes3.event.mouseWheel, onMouseWheel)

        if isCurrent() then
            preview_scene.finish()

            local bg = tes3ui.findMenu(backgroundMenuID)
            if bg then
                bg:destroy()
            end
            local popup = tes3ui.findMenu(profilePopupID)
            if popup then
                popup:destroy()
            end

            if tes3.mobilePlayer then
                tes3.mobilePlayer.controlsDisabled = false
            end

            -- suppressExit: closing only to switch to another subject.
            if options and options.onExit and not ts.suppressExit then
                options.onExit()
            end
        end
    end)

    local contents = controlsMenu:createBlock()
    contents.flowDirection = tes3.flowDirection.topToBottom
    contents.widthProportional = 1.0
    contents.heightProportional = 1.0
    contents.borderAllSides = 12
    local infoBlock = contents:createBlock()
    infoBlock.flowDirection = tes3.flowDirection.topToBottom
    infoBlock.widthProportional = 1.0
    infoBlock.autoHeight = true
    infoBlock.borderBottom = 8

    local idLabel = infoBlock:createLabel({ text = "ID: " .. subject.recordId })
    idLabel.color = getColor("header_color")
    local typeLabel = infoBlock:createLabel({ text = "Type: " .. subject.typeName })
    typeLabel.color = getColor("normal_color")
    local nameLabel = infoBlock:createLabel({ text = "Name: " .. subject.displayName })
    nameLabel.color = getColor("normal_color")
    local meshDisplay = subject.meshPath and subject.meshPath:gsub("%.[nN][iI][fF]$", ".nif") or "<unknown>"
    local meshLabel = infoBlock:createLabel({ text = "Mesh: " .. meshDisplay })
    meshLabel.color = getColor("disabled_color")
    local sourceDisplay = subject.sourceMod and subject.sourceMod:gsub("(%.%w+)$", string.lower) or "<unknown>"
    local sourceLabel = infoBlock:createLabel({ text = "Source: " .. sourceDisplay })
    sourceLabel.color = getColor("disabled_color")

    -- Search to switch subject without leaving preview mode. Closing for a
    -- switch suppresses onExit so the batch menu doesn't reopen in between.
    local function closeForSwitch()
        if isCurrent() then
            ts.suppressExit = true
        end
        local menu = tes3ui.findMenu(controlsMenuID)
        if menu then
            menu:destroy()
        end
    end

    local searchRow = infoBlock:createBlock()
    searchRow.flowDirection = tes3.flowDirection.leftToRight
    searchRow.widthProportional = 1.0
    searchRow.autoHeight = true
    searchRow.borderTop = 8

    local searchBox = searchRow:createThinBorder()
    searchBox.widthProportional = 1.0
    searchBox.height = 30
    searchBox.paddingAllSides = 6

    local searchInput = searchBox:createTextInput({ createBorder = false })
    searchInput.widthProportional = 1.0
    -- Shared with the batch menu's search box for this session.
    searchInput.text = settings.lastSearchPattern or ""

    local function acquireSearchInput()
        tes3ui.acquireTextInput(searchInput)
        searchFocused = true
    end
    searchBox:register(tes3.uiEvent.mouseClick, acquireSearchInput)
    searchInput:register(tes3.uiEvent.mouseClick, acquireSearchInput)

    local function runSwitchSearch()
        tes3ui.acquireTextInput(nil)
        searchFocused = false
        settings.lastSearchPattern = searchInput.text or ""

        local types = settings.getEnabledTypes()
        local switchOptions = {
            types = types,
            closeMenu = closeForSwitch,
            onExit = options and options.onExit,
            onSelectSearchTerm = function(term)
                searchInput.text = term
                settings.lastSearchPattern = term
                searchRow:updateLayout()
                acquireSearchInput()
            end,
        }

        -- Empty query: browse by plugin, same as the batch menu's Preview button.
        if not searchInput.text or searchInput.text == "" then
            local plugins = subject_resolver.listPlugins({ types = types })
            if #plugins == 0 then
                tes3.messageBox("No displayable records found.")
            else
                this.showPluginMenu(plugins, switchOptions)
            end
            return
        end

        local matches = subject_resolver.search({ pattern = searchInput.text, types = types })

        if #matches == 0 then
            tes3.messageBox("No matches found.")
        elseif #matches == 1 then
            closeForSwitch()
            this.open(matches[1].subject, options)
        else
            this.showSelectionMenu(matches, switchOptions)
        end
    end

    searchInput:register(tes3.uiEvent.keyEnter, function()
        runSwitchSearch()
        return false
    end)

    local searchButton = searchRow:createButton({ text = "Search" })
    searchButton.borderLeft = 6
    searchButton:register(tes3.uiEvent.mouseClick, runSwitchSearch)

    local searchClear = searchRow:createButton({ text = "Clear" })
    searchClear:register(tes3.uiEvent.mouseClick, function()
        searchInput.text = ""
        settings.lastSearchPattern = ""
        acquireSearchInput()
    end)

    local settingsScroll = contents:createVerticalScrollPane()
    settingsScroll.widthProportional = 1.0
    settingsScroll.heightProportional = 1.0
    settingsScroll.borderBottom = 12
    local scrollContent = settingsScroll:getContentElement()
    scrollContent.widthProportional = 1.0
    scrollContent.autoHeight = true

    -- key -> function that syncs the slider widget + label from ts.config.
    local sliderRefreshers = {}

    local function addSettingSlider(params)
        local parentBlock = params.parentBlock
        local key = params.key
        local minVal = params.minVal
        local maxVal = params.maxVal
        local stepVal = params.stepVal
        local toTextFn = params.toTextFn
        -- invert: shown value mirrors the raw value (zoom: higher shown = closer).
        local invert = params.invert == true

        local container = parentBlock:createBlock()
        container.flowDirection = tes3.flowDirection.topToBottom
        container.widthProportional = 1.0
        container.autoHeight = true
        container.borderBottom = 8

        local currentVal = ts.config[key]
        local displayVal = invert and (1.0 / currentVal) or currentVal
        local displayLabel = container:createLabel({ text = toTextFn(displayVal) })
        displayLabel.color = getColor("normal_color")
        ts.labels[key] = displayLabel

        local sliderMax = math.floor((maxVal - minVal) / stepVal + 0.5)
        local sliderCurrent = math.floor((displayVal - minVal) / stepVal + 0.5)

        local slider = container:createSlider({
            current = sliderCurrent,
            max = sliderMax,
            step = 1,
            jump = math.max(1, math.floor(sliderMax / 10)),
        })
        slider.width = 280
        ts.sliders[key] = slider

        local rotationOnly = key == "yaw" or key == "pitch" or key == "roll"
        local lastRaw = sliderCurrent
        local function applyFromSlider()
            local raw = slider.widget.current
            if raw == lastRaw then return end
            lastRaw = raw
            local shown = minVal + raw * stepVal
            ts.config[key] = invert and (1.0 / shown) or shown
            displayLabel.text = toTextFn(shown)
            preview_scene.update({ rotationOnly = rotationOnly, zoomOnly = key == "zoom" })
            -- Rotation skips fitting mid-move to stay smooth; flag a settle-fit on release.
            if rotationOnly then ts.pendingRefit = true end
        end

        -- mouseStillPressed fires every held frame, giving the live drag update.
        slider:register(tes3.uiEvent.partScrollBarChanged, applyFromSlider)
        slider:register(tes3.uiEvent.mouseStillPressed, applyFromSlider)

        -- Pushes the current ts.config value back onto the widget + label
        -- (used by the Reset button, which sets config directly).
        sliderRefreshers[key] = function()
            local dv = invert and (1.0 / ts.config[key]) or ts.config[key]
            lastRaw = math.floor((dv - minVal) / stepVal + 0.5)
            slider.widget.current = lastRaw
            displayLabel.text = toTextFn(dv)
        end
    end

    local camHeader = scrollContent:createLabel({ text = "- CAMERA -" })
    camHeader.color = getColor("header_color")
    camHeader.borderBottom = 4

    addSettingSlider({
        parentBlock = scrollContent,
        key = "yaw",
        minVal = -180,
        maxVal = 180,
        stepVal = 1,
        toTextFn = function(v) return string.format("Yaw: %d deg", math.floor(v)) end,
    })
    addSettingSlider({
        parentBlock = scrollContent,
        key = "pitch",
        minVal = -90,
        maxVal = 90,
        stepVal = 1,
        toTextFn = function(v) return string.format("Pitch: %d deg", math.floor(v)) end,
    })
    addSettingSlider({
        parentBlock = scrollContent,
        key = "zoom",
        minVal = displayZoomMin,
        maxVal = displayZoomMax,
        stepVal = 0.05,
        invert = true,
        toTextFn = function(v) return string.format("Zoom: %.2fx", v) end,
    })
    addSettingSlider({
        parentBlock = scrollContent,
        key = "roll",
        minVal = -180,
        maxVal = 180,
        stepVal = 1,
        toTextFn = function(v) return string.format("Roll: %d deg", math.floor(v)) end,
    })
    -- Camera distance in subject radii; size stays fitted so only foreshortening
    -- changes. Inert while Orthographic is on.
    addSettingSlider({
        parentBlock = scrollContent,
        key = "perspectiveDistanceFactor",
        minVal = 2,
        maxVal = 50,
        stepVal = 1,
        toTextFn = function(v)
            return string.format("Perspective: %d (~%d deg FOV)", math.floor(v), math.floor(2 * math.deg(math.atan(1 / v))))
        end,
    })

    -- Three stacked toggle buttons: Orthographic / Fit to Frame / BG.
    local toggleColumn = scrollContent:createBlock()
    toggleColumn.flowDirection = tes3.flowDirection.topToBottom
    toggleColumn.widthProportional = 1.0
    toggleColumn.autoHeight = true
    toggleColumn.borderBottom = 8

    -- Orthographic toggle ------------------------------------------------
    local orthoRow = toggleColumn:createBlock()
    orthoRow.flowDirection = tes3.flowDirection.leftToRight
    orthoRow.widthProportional = 1.0
    orthoRow.autoHeight = true
    orthoRow.childAlignY = 0.5
    orthoRow.borderBottom = 4

    local orthoToggleLabel = orthoRow:createLabel({ text = "Orthographic:" })
    orthoToggleLabel.color = getColor("normal_color")

    local orthoToggleBtn = orthoRow:createButton({ text = ts.config.ortho and "On" or "Off" })
    local function updateOrthoToggleVisual()
        -- Blue highlights the non-default (perspective); ortho is the default look.
        orthoToggleBtn.widget.state = ts.config.ortho and tes3.uiState.normal or tes3.uiState.active
        orthoToggleBtn.text = ts.config.ortho and "On" or "Off"
    end
    updateOrthoToggleVisual()
    orthoToggleBtn:register(tes3.uiEvent.mouseClick, function()
        ts.config.ortho = not ts.config.ortho
        updateOrthoToggleVisual()
        preview_scene.update()
        controlsMenu:updateLayout()
    end)

    -- Fit to Frame toggle ------------------------------------------------
    local fitRow = toggleColumn:createBlock()
    fitRow.flowDirection = tes3.flowDirection.leftToRight
    fitRow.widthProportional = 1.0
    fitRow.autoHeight = true
    fitRow.childAlignY = 0.5
    fitRow.borderBottom = 4

    local fitToggleLabel = fitRow:createLabel({ text = "Fit to Frame:" })
    fitToggleLabel.color = getColor("normal_color")

    local fitToggleBtn = fitRow:createButton({ text = ts.config.fitToFrame and "On" or "Off" })
    local function updateFitToggleVisual()
        -- Blue highlights the non-default (fit off); fit is the default look.
        fitToggleBtn.widget.state = ts.config.fitToFrame and tes3.uiState.normal or tes3.uiState.active
        fitToggleBtn.text = ts.config.fitToFrame and "On" or "Off"
    end
    updateFitToggleVisual()
    fitToggleBtn:register(tes3.uiEvent.mouseClick, function()
        ts.config.fitToFrame = not ts.config.fitToFrame
        updateFitToggleVisual()
        controlsMenu:updateLayout()
    end)

    -- BG toggle ----------------------------------------------------------
    local bgRow = toggleColumn:createBlock()
    bgRow.flowDirection = tes3.flowDirection.leftToRight
    bgRow.widthProportional = 1.0
    bgRow.autoHeight = true
    bgRow.childAlignY = 0.5

    local bgToggleLabel = bgRow:createLabel({ text = "BG:" })
    bgToggleLabel.color = getColor("normal_color")

    local bgWhite = false
    local bgToggleBtn = bgRow:createButton({ text = "Black" })
    local function updateBgToggleVisual()
        bgToggleBtn.widget.state = bgWhite and tes3.uiState.active or tes3.uiState.normal
        bgToggleBtn.text = bgWhite and "White" or "Black"
    end
    updateBgToggleVisual()
    bgToggleBtn:register(tes3.uiEvent.mouseClick, function()
        bgWhite = not bgWhite
        render.setPlaneColor(ts.alphaPlane, bgWhite and 1 or 0)
        updateBgToggleVisual()
        controlsMenu:updateLayout()
    end)

    local camButtonRow = scrollContent:createBlock()
    camButtonRow.flowDirection = tes3.flowDirection.leftToRight
    camButtonRow.widthProportional = 1.0
    camButtonRow.autoHeight = true
    camButtonRow.borderBottom = 8

    -- Step the subject 90 degrees clockwise about its vertical -- the same azimuth
    -- axis the batch rotation exceptions use. Re-centers but keeps the framing.
    local rotate90Btn = camButtonRow:createButton({ text = "Rotate 90" })
    rotate90Btn:register(tes3.uiEvent.mouseClick, function()
        ts.config.yaw = (ts.config.yaw - 90 + 180) % 360 - 180
        if sliderRefreshers.yaw then sliderRefreshers.yaw() end
        local keepFrustum = ts.orthoFrustum
        local keepDepth = not keepFrustum and preview_scene.dollyFitEnabled()
            and preview_scene.currentViewDepth() or nil
        preview_scene.update()
        if keepFrustum then
            ts.orthoFrustum = keepFrustum
            render.setFrustum(ts.camera, keepFrustum)
        elseif keepDepth then
            preview_scene.restoreDollyDepth(keepDepth)
        end
        controlsMenu:updateLayout()
    end)

    -- Restore the camera sliders to their opening values.
    local resetBtn = camButtonRow:createButton({ text = "Reset Camera" })
    resetBtn.borderLeft = 12
    resetBtn:register(tes3.uiEvent.mouseClick, function()
        for key, value in pairs(cameraDefaults) do
            ts.config[key] = value
            if sliderRefreshers[key] then sliderRefreshers[key]() end
        end
        ts.panX = 0
        ts.panY = 0
        preview_scene.update()
        controlsMenu:updateLayout()
    end)

    local lightHeader = scrollContent:createLabel({ text = "- LIGHTING -" })
    lightHeader.color = getColor("header_color")
    lightHeader.borderBottom = 4
    lightHeader.borderTop = 8

    addSettingSlider({
        parentBlock = scrollContent,
        key = "keyDimmer",
        minVal = 0.0,
        maxVal = 3.0,
        stepVal = 0.05,
        toTextFn = function(v) return string.format("Key Intensity: %.2f", v) end,
    })
    addSettingSlider({
        parentBlock = scrollContent,
        key = "keyX",
        minVal = -3.0,
        maxVal = 3.0,
        stepVal = 0.05,
        toTextFn = function(v) return string.format("Key Yaw Offset: %.2f", v) end,
    })
    addSettingSlider({
        parentBlock = scrollContent,
        key = "keyY",
        minVal = -3.0,
        maxVal = 3.0,
        stepVal = 0.05,
        toTextFn = function(v) return string.format("Key Pitch Offset: %.2f", v) end,
    })
    addSettingSlider({
        parentBlock = scrollContent,
        key = "keyZ",
        minVal = 0.5,
        maxVal = 5.0,
        stepVal = 0.05,
        toTextFn = function(v) return string.format("Key Dist Offset: %.2f", v) end,
    })

    addSettingSlider({
        parentBlock = scrollContent,
        key = "fillDimmer",
        minVal = 0.0,
        maxVal = 3.0,
        stepVal = 0.05,
        toTextFn = function(v) return string.format("Fill Intensity: %.2f", v) end,
    })
    addSettingSlider({
        parentBlock = scrollContent,
        key = "ambientScale",
        minVal = 0.0,
        maxVal = 2.0,
        stepVal = 0.05,
        toTextFn = function(v) return string.format("Ambient Scale: %.2f", v) end,
    })
    addSettingSlider({
        parentBlock = scrollContent,
        key = "diffuseScale",
        minVal = 0.0,
        maxVal = 2.0,
        stepVal = 0.05,
        toTextFn = function(v) return string.format("Diffuse Scale: %.2f", v) end,
    })

    local actionBlock = contents:createBlock()
    actionBlock.flowDirection = tes3.flowDirection.topToBottom
    actionBlock.widthProportional = 1.0
    actionBlock.autoHeight = true

    -- Save to session: copy the live preview's camera + lighting into the shared
    -- session config so batch renders adopt them (in memory only; not written to
    -- disk unless the MCM is opened and closed). Batch reads ortho from forceOrtho,
    -- so mirror the preview's ortho onto it. Reset session restores the loaded values.
    local sessionRow = actionBlock:createBlock()
    sessionRow.flowDirection = tes3.flowDirection.leftToRight
    sessionRow.widthProportional = 1.0
    sessionRow.autoHeight = true
    sessionRow.borderBottom = 6

    local btnSaveSession = sessionRow:createButton({ text = "Save to session" })
    btnSaveSession.widthProportional = 1.0
    btnSaveSession.borderRight = 6
    btnSaveSession:register(tes3.uiEvent.mouseClick, function()
        local cfg = ts.config
        local keys = { "yaw", "pitch", "roll", "perspectiveDistanceFactor",
            "keyDimmer", "keyX", "keyY", "keyZ", "fillDimmer", "ambientScale", "diffuseScale" }
        for _, key in ipairs(keys) do
            settings.current[key] = cfg[key]
        end
        settings.current.zoom = cfg.zoom
        settings.current.panX = ts.panX or 0
        settings.current.panY = ts.panY or 0
        settings.current.forceOrtho = cfg.ortho
        settings.current.fitToFrame = cfg.fitToFrame
        tes3.messageBox("Saved preview camera + lighting for this session's batch renders.")
    end)

    local btnResetSession = sessionRow:createButton({ text = "Reset session" })
    btnResetSession.widthProportional = 1.0
    btnResetSession:register(tes3.uiEvent.mouseClick, function()
        settings.resetSessionCamera()
        -- Snap the live preview's camera + lighting back to those defaults too, so
        -- the reset is visible (the ortho toggle is left as-is).
        local defaults = settings.getDefaultConfig(subject.objectType)
        for _, key in ipairs({ "yaw", "pitch", "roll", "perspectiveDistanceFactor",
            "keyDimmer", "keyX", "keyY", "keyZ", "fillDimmer", "ambientScale", "diffuseScale" }) do
            ts.config[key] = defaults[key]
            if sliderRefreshers[key] then sliderRefreshers[key]() end
        end
        ts.config.zoom = defaults.zoom or 1.0
        if sliderRefreshers.zoom then sliderRefreshers.zoom() end
        ts.panX = settings.current.panX or 0
        ts.panY = settings.current.panY or 0
        -- Restore fitToFrame and ortho to the session defaults and refresh buttons.
        ts.config.fitToFrame = settings.current.fitToFrame
        updateFitToggleVisual()
        ts.config.ortho = settings.current.forceOrtho
        updateOrthoToggleVisual()
        preview_scene.update()
        controlsMenu:updateLayout()
        tes3.messageBox("Reset session + preview camera and lighting to the loaded defaults.")
    end)

    -- Save Profile: persist the full preview state to file, applied to matching
    -- records by batch + preview when the MCM "Use Profiles" toggle is on.
    local function openProfilePopup()
        local existing = tes3ui.findMenu(profilePopupID)
        if existing then existing:destroy() end

        local popup = tes3ui.createMenu({ id = profilePopupID, fixedFrame = true })
        popup.minWidth = 520
        popup.minHeight = 260
        local pContents = popup:createBlock()
        pContents.flowDirection = tes3.flowDirection.topToBottom
        pContents.widthProportional = 1.0
        pContents.heightProportional = 1.0
        pContents.autoHeight = false
        pContents.borderAllSides = 12

        -- Scope: which records this profile applies to.
        local scope = "type"
        local scopeButtons = {}
        local function refreshScopeButtons()
            for key, btn in pairs(scopeButtons) do
                btn.widget.state = (key == scope) and tes3.uiState.active or tes3.uiState.normal
            end
        end

        local scopeLabel = pContents:createLabel({ text = "Apply to:" })
        scopeLabel.color = getColor("disabled_color")
        scopeLabel.borderBottom = 4
        local scopeRow = pContents:createBlock()
        scopeRow.flowDirection = tes3.flowDirection.leftToRight
        scopeRow.widthProportional = 1.0
        scopeRow.autoHeight = true
        scopeRow.borderBottom = 12

        local function addScopeButton(key, text)
            local btn = scopeRow:createButton({ text = text })
            btn:register(tes3.uiEvent.mouseClick, function()
                scope = key
                refreshScopeButtons()
            end)
            scopeButtons[key] = btn
        end
        addScopeButton("all", "All")
        addScopeButton("type", "Type: " .. (subject.typeName or "unknown"))
        addScopeButton("search", "Search:")

        -- Pattern input sits inline to the right of the "Search:" button.
        local patternInput = scopeRow:createTextInput({ createBorder = false })
        patternInput.widthProportional = 1.0
        patternInput.height = 30
        patternInput.borderAllSides = 5
        patternInput.text = searchInput.text or ""
        local function focusPattern()
            scope = "search"
            refreshScopeButtons()
            tes3ui.acquireTextInput(patternInput)
        end
        patternInput:register(tes3.uiEvent.mouseClick, focusPattern)
        -- Typing a pattern implies the search scope.
        patternInput:register(tes3.uiEvent.textUpdated, function()
            if scope ~= "search" then
                scope = "search"
                refreshScopeButtons()
            end
        end)

        -- Rotation mode: add the saved yaw on top of rotation_exceptions.txt
        -- corrections (current behavior), or replace those corrections entirely.
        local rotationMode = "add"
        local rotHint = pContents:createLabel({ text = "Rotations:" })
        rotHint.color = getColor("disabled_color")
        rotHint.borderBottom = 4
        local rotRow = pContents:createBlock()
        rotRow.flowDirection = tes3.flowDirection.leftToRight
        rotRow.widthProportional = 1.0
        rotRow.autoHeight = true
        rotRow.borderBottom = 10
        local rotBtn = rotRow:createButton({ text = "Add to built-in rotations" })
        rotBtn:register(tes3.uiEvent.mouseClick, function()
            rotationMode = rotationMode == "add" and "override" or "add"
            rotBtn.text = rotationMode == "add" and "Add to built-in rotations" or "Override built-in rotations"
            popup:updateLayout()
        end)

        local pSpacer = pContents:createBlock()
        pSpacer.widthProportional = 1.0
        pSpacer.heightProportional = 1.0

        local pButtons = pContents:createBlock()
        pButtons.flowDirection = tes3.flowDirection.leftToRight
        pButtons.widthProportional = 1.0
        pButtons.autoHeight = true
        pButtons.childAlignX = 1.0
        pButtons.borderTop = 8

        local btnSaveOk = pButtons:createButton({ text = "Save profile" })
        btnSaveOk:register(tes3.uiEvent.mouseClick, function()
            local pattern
            if scope == "search" then
                pattern = (patternInput.text or ""):match("^%s*(.-)%s*$")
                if pattern == "" then
                    tes3.messageBox("Enter a search pattern for a search-scoped profile.")
                    return
                end
            end

            local cfg = ts.config
            -- Override mode bakes the previewed subject's fully-resolved view
            -- direction (type base view + its rotation exception), so matched
            -- records render with exactly the orientation on screen now.
            local direction
            if rotationMode == "override" then
                local dir = camera_profiles.offsetDirForProfile(subject.profile)
                direction = { dir.x, dir.y, dir.z }
            end
            local savedPath, errPath = profiles.save({
                scope = scope,
                typeKey = scope == "type" and subject.typeKey or nil,
                typeName = scope == "type" and subject.typeName or nil,
                pattern = pattern,
                rotationMode = rotationMode,
                direction = direction,
                settings = {
                    yaw = cfg.yaw,
                    pitch = cfg.pitch,
                    roll = cfg.roll,
                    zoom = cfg.zoom or 1.0,
                    panX = ts.panX or 0,
                    panY = ts.panY or 0,
                    perspectiveDistanceFactor = cfg.perspectiveDistanceFactor,
                    keyDimmer = cfg.keyDimmer,
                    keyX = cfg.keyX,
                    keyY = cfg.keyY,
                    keyZ = cfg.keyZ,
                    fillDimmer = cfg.fillDimmer,
                    ambientScale = cfg.ambientScale,
                    diffuseScale = cfg.diffuseScale,
                    ortho = cfg.ortho == true,
                    fitToFrame = cfg.fitToFrame == true,
                },
            })
            if not savedPath then
                tes3.messageBox("Error: could not write profile file:\n%s", tostring(errPath))
                return
            end
            popup:destroy()
            local scopeText = scope == "all" and "all records"
                or scope == "type" and ("type " .. (subject.typeName or "?"))
                or string.format("search \"%s\"", pattern)
            tes3.messageBox("Profile saved for %s (%s).", scopeText, savedPath)
        end)

        local btnCancelPopup = pButtons:createButton({ text = "Cancel" })
        btnCancelPopup:register(tes3.uiEvent.mouseClick, function()
            popup:destroy()
        end)

        refreshScopeButtons()
        popup:updateLayout()
        tes3ui.enterMenuMode(profilePopupID)
        -- Focus the pattern box so the typing cursor is visible immediately.
        tes3ui.acquireTextInput(patternInput)
    end

    local profileRow = actionBlock:createBlock()
    profileRow.flowDirection = tes3.flowDirection.leftToRight
    profileRow.widthProportional = 1.0
    profileRow.autoHeight = true
    profileRow.borderBottom = 6

    local btnSaveProfile = profileRow:createButton({ text = "Save profile..." })
    btnSaveProfile.widthProportional = 1.0
    btnSaveProfile:register(tes3.uiEvent.mouseClick, openProfilePopup)

    -- Export the currently open object as a .nif under "<output>/exports".
    -- A basic clone: NPCs/creatures export their full posed hierarchy (skeleton
    -- + skinned meshes, skin refs rebound by name -- the "standard" export),
    -- everything else exports a plain clone of its mesh.
    local function exportSubject()
        local obj = subject.object
        local exportRoot

        if obj and (obj.objectType == tes3.objectType.npc
                or obj.objectType == tes3.objectType.creature) then
            -- createActorScene wraps the posed clone so preview repositioning can't
            -- disturb it; for export we want the clone itself as the file root, since
            -- it carries the racial height/weight scale on its transform.
            local wrapper = scene_builder.createActorScene(obj)
            exportRoot = wrapper.children[1]
            wrapper:detachChild(exportRoot)
        else
            local mesh = tes3.loadMesh(subject.meshPath)
            if not mesh then
                error("Failed to load mesh: " .. tostring(subject.meshPath))
            end
            exportRoot = mesh:clone()
        end

        -- Drop world placement; keep the transform's scale/rotation (size + pose).
        exportRoot.translation = tes3vector3.new(0, 0, 0)

        -- Filename per the MCM option: display name, record id, or mesh base name.
        -- Each falls back so a missing value never yields an empty filename.
        local mode = settings.current.exportFilename
        local rawName
        if mode == "id" then
            rawName = subject.recordId or subject.displayName
        elseif mode == "mesh" then
            -- NPCs are assembled from many meshes, so there is no single mesh name
            -- to use; fall back to the record id for them.
            if obj and obj.objectType == tes3.objectType.npc then
                rawName = subject.recordId
            else
                local meshPath = subject.normalizedMeshPath
                if meshPath and meshPath ~= "" then
                    rawName = meshPath:match("[^/]+$") or meshPath
                end
                rawName = rawName or subject.recordId or subject.displayName
            end
        else
            rawName = subject.displayName or subject.recordId
        end
        rawName = rawName or "export"
        local safeName = rawName:gsub("[^%w %._-]", "_")
        exportRoot.name = safeName

        local exportDir = settings.getOutputFolder() .. "\\exports"
        render.ensureDirectory(exportDir .. "\\")
        local fullPath = (exportDir .. "\\" .. safeName .. ".nif"):gsub("[/\\]+", "\\")

        exportRoot:update()
        exportRoot:saveBinary(fullPath)
        return fullPath
    end

    local exportRow = actionBlock:createBlock()
    exportRow.flowDirection = tes3.flowDirection.leftToRight
    exportRow.widthProportional = 1.0
    exportRow.autoHeight = true
    exportRow.borderBottom = 6

    local btnExport = exportRow:createButton({ text = "Export" })
    btnExport.widthProportional = 1.0
    btnExport:register(tes3.uiEvent.mouseClick, function()
        local ok, result = pcall(exportSubject)
        if ok then
            tes3.messageBox("Exported: " .. result)
        else
            tes3.messageBox("Error exporting: " .. tostring(result))
        end
    end)

    -- Perform test render & close
    local mainRow = actionBlock:createBlock()
    mainRow.flowDirection = tes3.flowDirection.leftToRight
    mainRow.widthProportional = 1.0
    mainRow.autoHeight = true

    local btnRenderTest = mainRow:createButton({ text = "Render" })
    btnRenderTest.widthProportional = 1.0
    btnRenderTest.borderRight = 6
    btnRenderTest:register(tes3.uiEvent.mouseClick, function()
        local mPath = subject.meshPath
        -- Same NPC-aware path logic as batch rendering, just under "previews".
        local outputPath = render.getOutputPath(subject, mPath, "previews")
        render.ensureDirectory(outputPath)
        local ok, result = pcall(function()
            return render.render({
                subject = subject,
                meshPath = mPath,
                outputPath = outputPath,
                yaw = ts.config.yaw,
                pitch = ts.config.pitch,
                roll = ts.config.roll,
                -- Fit-to-frame re-crops to content, so zoom is moot there; with it
                -- off, honor the live zoom so a manual crop carries into the render.
                zoom = ts.config.fitToFrame and 1.0 or ts.config.zoom,
                perspectiveDistanceFactor = ts.config.perspectiveDistanceFactor,
                keyDimmer = ts.config.keyDimmer,
                keyX = ts.config.keyX,
                keyY = ts.config.keyY,
                keyZ = ts.config.keyZ,
                fillDimmer = ts.config.fillDimmer,
                ambientScale = ts.config.ambientScale,
                diffuseScale = ts.config.diffuseScale,
                ortho = ts.config.ortho,
                -- pristine frustum, in case the live preview already narrowed it
                orthoBase = ts.baseFrustum,
                resolution = settings.current.previewRenderResolution,
                dstResolution = settings.current.previewOutputResolution,
                outputFormat = settings.current.previewOutputFormat,
                fitToFrame = ts.config.fitToFrame,
                -- WASD pan carries the crop into the render (moot when fit is on).
                panX = ts.panX,
                panY = ts.panY,
                -- Never write an empty preview render, regardless of the batch toggle.
                skipEmpty = true,
                keepSceneActive = false,
                recordId = subject.recordId,
            })
        end)

        if ok and result then
            -- result carries the final path (render normalizes the extension)
            local displayPath = result:gsub("^.-[/\\]previews[/\\]", "previews\\"):gsub("/", "\\")
            tes3.messageBox("Successfully rendered: " .. displayPath)
        elseif ok then
            tes3.messageBox("Error: nothing visible to render; no file written.")
        else
            tes3.messageBox("Error rendering: " .. tostring(result))
        end

        -- Reattach and re-poke only -- a full preview_scene.update() re-fit would
        -- visibly snap after a drag/zoom fast path.
        camera.scene = ts.root
        camera.scene:update()
        camera.scene:updateEffects()
        camera.scene:updateProperties()
        if ts.orthoFrustum then
            render.setFrustum(camera, ts.orthoFrustum)
        end
    end)

    local btnClosePreview = mainRow:createButton({ text = "Exit" })
    btnClosePreview.widthProportional = 1.0
    btnClosePreview:register(tes3.uiEvent.mouseClick, function()
        controlsMenu:destroy()
    end)

    preview_scene.update()

    bgMenu:updateLayout()
    controlsMenu:updateLayout()

    settingsScroll.widget:contentsChanged()

    -- Rows created below the fold miss their first paint (vanilla scroll-pane
    -- quirk); scroll the content through the view once so everything paints.
    settingsScroll.widget.positionY = 100000
    controlsMenu:updateLayout()
    settingsScroll.widget.positionY = 0
    controlsMenu:updateLayout()

    tes3ui.moveMenuToFront(controlsMenu)
    tes3ui.enterMenuMode(controlsMenuID)
end

return this
