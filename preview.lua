-- Interactive 3D preview editor: drag to rotate, scroll to zoom, live sliders.
local this = {}

local render = require("ThumbnailGenerator.render")
local subject_resolver = require("ThumbnailGenerator.modules.subject_resolver")
local config = require("ThumbnailGenerator.modules.thumbnail_settings")


local tempScene = nil

local backgroundMenuID = "ThumbnailGen:PreviewBackground"
local controlsMenuID = "ThumbnailGen:PreviewControls"
local selectMenuID = "ThumbnailGen:PreviewSelectMenu"

-- Slider bounds for raw zoom values.
local displayZoomMin = 0.05
local displayZoomMax = 10

-- Deliberately further back than the neutral fit (1.0), since zoom here no
-- longer affects the actual render (see zoom=1.0 override below).
local previewStartZoom = 2.0

local function getColor(name)
    return tes3ui.getPalette(name)
end

-- Applies `tempScene.config` to the live preview scene/lights.
local function updatePreviewScene(params)
    if not tempScene or not tempScene.scene then return end
    params = params or {}

    local camera = tempScene.camera
    local scene = tempScene.scene
    local alphaPlane = tempScene.alphaPlane
    local root = tempScene.root
    local radius = tempScene.radius
    local cfg = tempScene.config
    local profile = tempScene.subject and tempScene.subject.profile
    local rotationOnly = params.rotationOnly == true

    -- Frustum extents scale linearly with zoom; scaling in place avoids the
    -- re-fit snap after a drag (the drag fast path doesn't re-fit).
    if params.zoomOnly and tempScene.orthoFrustum and tempScene.lastFitZoom and tempScene.lastFitZoom > 0 then
        local ratio = (cfg.zoom or 1) / tempScene.lastFitZoom
        local f = tempScene.orthoFrustum
        f[1], f[2], f[3], f[4] = f[1] * ratio, f[2] * ratio, f[3] * ratio, f[4] * ratio
        tempScene.lastFitZoom = cfg.zoom or 1
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
    if rotationOnly and tempScene.rotationTargetPos and tempScene.rotationCenterLocal then
        local finalRot = render.getSceneRotation({
            camera = camera,
            config = cfg,
            profile = profile,
        })
        local sceneScale = scene.scale or 1

        scene.rotation = finalRot
        scene.translation = tempScene.rotationTargetPos
            - finalRot * (tempScene.rotationCenterLocal * sceneScale)
        scene:update()

        targetPos = tempScene.rotationTargetPos
        dynamicRadius = tempScene.rotationRadius or radius
    else
        rotationOnly = false

        -- Both modes poke a fitted frustum now; restore the pristine one before
        -- fitting so a stale narrow frustum from the last fit can't clip the scene.
        if tempScene.baseFrustum then
            tempScene.orthoFrustum = nil
            render.setFrustum(camera, tempScene.baseFrustum)
        end

        -- Fit the window aspect or the live view renders stretched; file renders stay square.
        local vw, vh = tes3.getViewportSize()
        local screenAspect = (vh and vh > 0) and (vw / vh) or 1

        local centerLocal
        targetPos, dynamicRadius, centerLocal = render.positionScene({
            scene = scene,
            alphaPlane = alphaPlane,
            camera = camera,
            config = cfg,
            radius = radius,
            ortho = cfg.ortho == true,
            orthoBase = tempScene.baseFrustum,
            targetAspect = screenAspect,
            profile = profile,
        })

        tempScene.rotationTargetPos = targetPos:copy()
        tempScene.rotationCenterLocal = centerLocal:copy()
        tempScene.rotationRadius = dynamicRadius

        -- Re-applied every frame: the engine rebuilds the frustum on
        -- FOV/camera-mode/cell changes.
        tempScene.orthoFrustum = render.getFrustum(camera)
        tempScene.lastFitZoom = cfg.zoom or 1
    end

    -- Lights don't need rebuilding for a pure rotation.
    if not rotationOnly then
        if tempScene.lights then
            for _, light in ipairs(tempScene.lights) do
                light:detachAffectedNode(scene)
                root:detachChild(light)
            end
        end

        tempScene.lights = render.addThumbnailLighting({
            root = root,
            scene = scene,
            camera = camera,
            targetPos = targetPos,
            radius = dynamicRadius,
            config = cfg,
        })
    end

    -- Centered translation the WASD pan offsets from (zoomOnly keeps the prior one).
    tempScene.baseTranslation = scene.translation:copy()

    camera.scene:update()
    camera.scene:updateEffects()
    camera.scene:updateProperties()
end

-- Shown when Preview is hit with an empty search: a button per source plugin
-- that has displayable records. Clicking one lists that plugin's records.
function this.showPluginMenu(plugins, options)
    local existing = tes3ui.findMenu(selectMenuID)
    if existing then existing:destroy() end

    local menu = tes3ui.createMenu({
        id = selectMenuID,
        fixedFrame = true,
    })
    menu.text = "Select Plugin to Browse"
    menu.minWidth = 500
    menu.minHeight = 600

    local contents = menu:createBlock()
    contents.flowDirection = tes3.flowDirection.topToBottom
    contents.widthProportional = 1.0
    contents.heightProportional = 1.0
    contents.borderAllSides = 12

    local title = contents:createLabel({ text = string.format("%d plugins with displayable records.", #plugins) })
    title.borderBottom = 8
    title.color = getColor("header_color")

    local scroll = contents:createVerticalScrollPane()
    scroll.widthProportional = 1.0
    scroll.heightProportional = 1.0
    scroll.borderBottom = 12
    local scrollContent = scroll:getContentElement()
    scrollContent.widthProportional = 1.0
    scrollContent.autoHeight = true

    for _, entry in ipairs(plugins) do
        local btn = scrollContent:createButton({ text = string.format("%s  (%d)", entry.plugin, entry.count) })
        btn.paddingTop = 8
        btn.paddingBottom = 8
        btn.borderBottom = 8
        btn:register(tes3.uiEvent.mouseClick, function()
            menu:destroy()
            local matches = subject_resolver.search({ sourceMod = entry.plugin, types = options.types })
            if #matches == 1 then
                if options.closeMenu then options.closeMenu(true) end
                this.open(matches[1].subject, options)
            elseif #matches > 1 then
                this.showSelectionMenu(matches, options)
            end
        end)
    end

    local btnClose = contents:createButton({ text = "Cancel" })
    btnClose.childAlignX = 1.0
    btnClose:register(tes3.uiEvent.mouseClick, function()
        menu:destroy()
    end)

    menu:updateLayout()
    scroll.widget:contentsChanged()
    tes3ui.enterMenuMode(selectMenuID)
end

function this.showSelectionMenu(matches, options)
    local existing = tes3ui.findMenu(selectMenuID)
    if existing then existing:destroy() end

    local menu = tes3ui.createMenu({
        id = selectMenuID,
        fixedFrame = true,
    })
    menu.text = "Select Item to Preview"
    menu.minWidth = 600
    menu.minHeight = 600

    local contents = menu:createBlock()
    contents.flowDirection = tes3.flowDirection.topToBottom
    contents.widthProportional = 1.0
    contents.heightProportional = 1.0
    contents.borderAllSides = 12

    local title = contents:createLabel({ text = string.format("Found %d matching items.", #matches) })
    title.borderBottom = 8
    title.color = getColor("header_color")

    local scroll = contents:createVerticalScrollPane()
    scroll.widthProportional = 1.0
    scroll.heightProportional = 1.0
    scroll.borderBottom = 12
    local scrollContent = scroll:getContentElement()
    scrollContent.widthProportional = 1.0
    scrollContent.autoHeight = true

    for _, match in ipairs(matches) do
        local entry = scrollContent:createBlock()
        entry.flowDirection = tes3.flowDirection.topToBottom
        entry.widthProportional = 1.0
        entry.autoHeight = true
        entry.borderBottom = 20

        local btn = entry:createButton({ text = match.id })
        btn.paddingTop = 8
        btn.paddingBottom = 8
        btn:register(tes3.uiEvent.mouseClick, function()
            menu:destroy()
            if options.closeMenu then
                options.closeMenu(true)
            end
            this.open(match.subject or match.obj, options)
        end)

        -- Buttons inset their text by the frame border; nudge the labels right to match.
        local labelIndent = 8

        local typeLabel = entry:createLabel({ text = "Type: " .. match.typeName })
        typeLabel.color = getColor("normal_color")
        typeLabel.borderTop = 4
        typeLabel.borderLeft = labelIndent
        if match.name ~= "" then
            local nameLabel = entry:createLabel({ text = "Name: " .. match.name })
            nameLabel.color = getColor("normal_color")
            nameLabel.borderTop = 4
            nameLabel.borderLeft = labelIndent
        end
        local meshLabel = entry:createLabel({ text = "Mesh: " .. match.mesh })
        meshLabel.color = getColor("disabled_color")
        meshLabel.borderTop = 4
        meshLabel.borderLeft = labelIndent
    end

    local btnClose = contents:createButton({ text = "Cancel" })
    btnClose.childAlignX = 1.0
    btnClose:register(tes3.uiEvent.mouseClick, function()
        menu:destroy()
    end)

    menu:updateLayout()

    scroll.widget:contentsChanged()

    tes3ui.enterMenuMode(selectMenuID)
end


function this.open(objOrSubject, options)
    local camera = tes3.getCamera()
    if not camera then
        error("No camera found")
    end

    local subject
    if type(objOrSubject) == "table" and objOrSubject.recordId then
        subject = objOrSubject
    else
        subject = subject_resolver.resolve(objOrSubject)
    end
    local obj = subject.object

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

    local initialConfig = subject.config

    -- Clone so editing doesn't touch the resolved config until explicitly saved.
    local currentConfig = {}
    for k, v in pairs(initialConfig) do
        currentConfig[k] = v
    end
    currentConfig.roll = currentConfig.roll or 0
    currentConfig.zoom = previewStartZoom

    -- Snapshot the opening camera values so the Reset button can restore them.
    local cameraDefaults = {
        yaw = currentConfig.yaw,
        pitch = currentConfig.pitch,
        roll = currentConfig.roll,
        zoom = currentConfig.zoom,
        perspectiveDistanceFactor = currentConfig.perspectiveDistanceFactor,
    }

    local function isMouseOverUI()
        local cp = tes3.getCursorPosition()
        -- Suppress capture over the settings menu and the (modal) switch-search
        -- selection list. positionY is the menu's top edge; it extends down (-y).
        for _, id in ipairs({ controlsMenuID, selectMenuID }) do
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

    tempScene = {
        subject = subject,
        obj = obj,
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
        panX = 0,
        panY = 0,
        baseFrustum = render.getFrustum(camera),
        -- MGE pauses world rendering in menus; unpause for a live view.
        mgePauseInMenus = mge.render.pauseRenderingInMenus,
        -- The file render bypasses MGE post-processing, so the live view must
        -- too. updateHDR alone only freezes auto-exposure, so both are needed.
        mgeShaders = mge.render.shaders,
        mgeHDR = mge.render.updateHDR,
        -- MGE per-pixel lighting brightens the on-screen view but not the raw
        -- fixed-function file render; match it to vanilla so the preview predicts
        -- the output. Cosmetic only -- the render never reads this.
        mgeLightingMode = mge.getLightingMode(),
        -- Flames often sit under NiLODNode levels that switch off at the ortho
        -- dolly distance; a tiny lodAdjust forces the highest-detail level.
        lodAdjust = camera.lodAdjust,
    }
    mge.render.pauseRenderingInMenus = false
    mge.render.shaders = false
    mge.render.updateHDR = false
    mge.setLightingMode(mge.lightingMode.vertex)
    camera.lodAdjust = config.current.lodAdjust

    local function applyDragRotation(newYaw, newPitch)
        newPitch = math.max(-90, math.min(90, newPitch))
        newYaw = (newYaw + 180) % 360 - 180

        tempScene.config.yaw = newYaw
        tempScene.config.pitch = newPitch

        -- Sync the yaw/pitch slider thumbs + labels to the drag value.
        if tempScene.sliders.yaw then
            tempScene.sliders.yaw.widget.current = math.floor(newYaw + 180)
        end
        if tempScene.labels.yaw then
            tempScene.labels.yaw.text = string.format("Yaw: %d deg", math.floor(newYaw))
        end
        if tempScene.sliders.pitch then
            tempScene.sliders.pitch.widget.current = math.floor(newPitch + 90)
        end
        if tempScene.labels.pitch then
            tempScene.labels.pitch.text = string.format("Pitch: %d deg", math.floor(newPitch))
        end

        updatePreviewScene({ rotationOnly = true })
    end

    -- Sets zoom from a discrete input (mouse wheel), syncing the zoom slider.
    local function applyZoom(newDisplayZoom)
        newDisplayZoom = math.max(displayZoomMin, math.min(displayZoomMax, newDisplayZoom))
        tempScene.config.zoom = 2.0 / newDisplayZoom
        if tempScene.sliders.zoom then
            tempScene.sliders.zoom.widget.current = math.floor((newDisplayZoom - displayZoomMin) / 0.05 + 0.5)
            if tempScene.labels.zoom then
                tempScene.labels.zoom.text = string.format("Zoom: %.2fx", newDisplayZoom)
            end
        end
        updatePreviewScene({ zoomOnly = true })
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
        local step = config.current.panSpeed * (tempScene.config.zoom or 1) * dt
        local dx, dy = 0, 0
        -- D pans the view right (subject slides left), etc.
        if ic:isKeyDown(tes3.scanCode.d) then dx = dx - step end
        if ic:isKeyDown(tes3.scanCode.a) then dx = dx + step end
        if ic:isKeyDown(tes3.scanCode.w) then dy = dy - step end
        if ic:isKeyDown(tes3.scanCode.s) then dy = dy + step end
        if dx ~= 0 then tempScene.panX = math.max(-panLimit, math.min(panLimit, tempScene.panX + dx)) end
        if dy ~= 0 then tempScene.panY = math.max(-panLimit, math.min(panLimit, tempScene.panY + dy)) end
    end

    -- Drives right-drag rotation from the live cursor and holds the ortho frustum
    -- (engine only rebuilds it on FOV/mode/cell changes). Torn down in destroy.
    local function onPreviewFrame(e)
        if not tempScene then return end

        if tempScene.dragStartMouseX then
            local cp = tes3.getCursorPosition()
            local dx = cp.x - tempScene.dragStartMouseX
            local dy = cp.y - tempScene.dragStartMouseY
            local sensitivity = 0.5
            applyDragRotation(
                tempScene.dragStartYaw + dx * sensitivity,
                tempScene.dragStartPitch - dy * sensitivity
            )
        end

        pollPan(e.delta or 0)

        -- Offset the subject from its centered base translation to pan (see pollPan).
        if tempScene.baseTranslation and (tempScene.panX ~= 0 or tempScene.panY ~= 0) then
            local cam = tempScene.camera
            tempScene.scene.translation = tempScene.baseTranslation
                + cam.worldRight * (tempScene.panX * tempScene.radius)
                + cam.worldUp * (tempScene.panY * tempScene.radius)
            tempScene.scene:update()
        end

        if tempScene.orthoFrustum then
            render.setFrustum(tempScene.camera, tempScene.orthoFrustum)
        end
    end
    event.register("enterFrame", onPreviewFrame)
    tempScene.frameHandler = onPreviewFrame

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
        if not tempScene or e.button ~= 1 or isMouseOverUI() or not isPreviewActive() then return end
        -- Clicking into the 3D view releases the search box, re-enabling WASD pan.
        tes3ui.acquireTextInput(nil)
        searchFocused = false
        local cp = tes3.getCursorPosition()
        tempScene.dragStartMouseX = cp.x
        tempScene.dragStartMouseY = cp.y
        tempScene.dragStartYaw = tempScene.config.yaw
        tempScene.dragStartPitch = tempScene.config.pitch
    end
    event.register(tes3.event.mouseButtonDown, onMouseButtonDown)
    tempScene.mouseDownHandler = onMouseButtonDown

    local function onMouseButtonUp(e)
        if not tempScene then return end
        if e.button == 1 then
            tempScene.dragStartMouseX = nil
            tempScene.dragStartMouseY = nil
        elseif e.button == 0 and tempScene.pendingRefit then
            -- Left-release after a rotation slider: settle so the subject re-centers
            -- (rotationOnly drifts it off-center mid-move). The re-center is
            -- frustum-independent, so keep the pre-release framing afterwards -- a
            -- full re-fit would also re-tighten the crop and change the apparent zoom.
            tempScene.pendingRefit = nil
            local keepFrustum = tempScene.orthoFrustum
            updatePreviewScene()
            if keepFrustum then
                tempScene.orthoFrustum = keepFrustum
                render.setFrustum(tempScene.camera, keepFrustum)
            end
        end
    end
    event.register(tes3.event.mouseButtonUp, onMouseButtonUp)
    tempScene.mouseUpHandler = onMouseButtonUp

    local zoomWheelStep = 0.05
    local function onMouseWheel(e)
        if not tempScene or isMouseOverUI() or not isPreviewActive() then return end
        local currentDisplayZoom = 2.0 / tempScene.config.zoom
        if e.delta > 0 then
            applyZoom(currentDisplayZoom + zoomWheelStep)
        elseif e.delta < 0 then
            applyZoom(currentDisplayZoom - zoomWheelStep)
        end
    end
    event.register(tes3.event.mouseWheel, onMouseWheel)
    tempScene.mouseWheelHandler = onMouseWheel

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
        controlsMenu.absolutePosAlignY = 0.5
        controlsMenu:updateLayout()
        controlsMenu.absolutePosAlignX = nil
        controlsMenu.absolutePosAlignY = nil
    end

    controlsMenu:register(tes3.uiEvent.destroy, function()
        controlsMenu:saveMenuPosition()
        if tempScene then
            local ts = tempScene
            tempScene = nil

            -- Engine won't rebuild the frustum on its own after an ortho session.
            if ts.frameHandler then
                event.unregister("enterFrame", ts.frameHandler)
            end
            if ts.mouseDownHandler then
                event.unregister(tes3.event.mouseButtonDown, ts.mouseDownHandler)
            end
            if ts.mouseUpHandler then
                event.unregister(tes3.event.mouseButtonUp, ts.mouseUpHandler)
            end
            if ts.mouseWheelHandler then
                event.unregister(tes3.event.mouseWheel, ts.mouseWheelHandler)
            end
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

            local bg = tes3ui.findMenu(backgroundMenuID)
            if bg then
                bg:destroy()
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
        if tempScene then
            tempScene.suppressExit = true
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

    local function acquireSearchInput()
        tes3ui.acquireTextInput(searchInput)
        searchFocused = true
    end
    searchBox:register(tes3.uiEvent.mouseClick, acquireSearchInput)
    searchInput:register(tes3.uiEvent.mouseClick, acquireSearchInput)

    local function runSwitchSearch()
        tes3ui.acquireTextInput(nil)
        searchFocused = false

        local types = config.getEnabledTypes()
        local switchOptions = {
            types = types,
            closeMenu = closeForSwitch,
            onExit = options and options.onExit,
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

    local settingsScroll = contents:createVerticalScrollPane()
    settingsScroll.widthProportional = 1.0
    settingsScroll.heightProportional = 1.0
    settingsScroll.borderBottom = 12
    local scrollContent = settingsScroll:getContentElement()
    scrollContent.widthProportional = 1.0
    scrollContent.autoHeight = true

    -- key -> function that syncs the slider widget + label from tempScene.config.
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

        local currentVal = tempScene.config[key]
        local displayVal = invert and (2.0 / currentVal) or currentVal
        local displayLabel = container:createLabel({ text = toTextFn(displayVal) })
        displayLabel.color = getColor("normal_color")
        tempScene.labels[key] = displayLabel

        local sliderMax = math.floor((maxVal - minVal) / stepVal + 0.5)
        local sliderCurrent = math.floor((displayVal - minVal) / stepVal + 0.5)

        local slider = container:createSlider({
            current = sliderCurrent,
            max = sliderMax,
            step = 1,
            jump = math.max(1, math.floor(sliderMax / 10)),
        })
        slider.width = 280
        tempScene.sliders[key] = slider

        local rotationOnly = key == "yaw" or key == "pitch" or key == "roll"
        local lastRaw = sliderCurrent
        local function applyFromSlider()
            local raw = slider.widget.current
            if raw == lastRaw then return end
            lastRaw = raw
            local shown = minVal + raw * stepVal
            tempScene.config[key] = invert and (2.0 / shown) or shown
            displayLabel.text = toTextFn(shown)
            updatePreviewScene({ rotationOnly = rotationOnly, zoomOnly = key == "zoom" })
            -- Rotation skips fitting mid-move to stay smooth; flag a settle-fit on release.
            if rotationOnly then tempScene.pendingRefit = true end
        end

        -- mouseStillPressed fires every held frame, giving the live drag update.
        slider:register(tes3.uiEvent.partScrollBarChanged, applyFromSlider)
        slider:register(tes3.uiEvent.mouseStillPressed, applyFromSlider)

        -- Pushes the current tempScene.config value back onto the widget + label
        -- (used by the Reset button, which sets config directly).
        sliderRefreshers[key] = function()
            local dv = invert and (2.0 / tempScene.config[key]) or tempScene.config[key]
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

    -- Orthographic and Background toggles share one row to save vertical space.
    local toggleRow = scrollContent:createBlock()
    toggleRow.flowDirection = tes3.flowDirection.leftToRight
    toggleRow.widthProportional = 1.0
    toggleRow.autoHeight = true
    toggleRow.borderBottom = 8
    toggleRow.childAlignY = 0.5

    local orthoToggleLabel = toggleRow:createLabel({ text = "Orthographic:" })
    orthoToggleLabel.color = getColor("normal_color")

    local orthoToggleBtn = toggleRow:createButton({ text = tempScene.config.ortho and "On" or "Off" })
    local function updateOrthoToggleVisual()
        orthoToggleBtn.widget.state = tempScene.config.ortho and tes3.uiState.active or tes3.uiState.normal
        orthoToggleBtn.text = tempScene.config.ortho and "On" or "Off"
    end
    updateOrthoToggleVisual()
    orthoToggleBtn:register(tes3.uiEvent.mouseClick, function()
        tempScene.config.ortho = not tempScene.config.ortho
        updateOrthoToggleVisual()
        updatePreviewScene()
        controlsMenu:updateLayout()
    end)

    local bgToggleLabel = toggleRow:createLabel({ text = "BG:" })
    bgToggleLabel.color = getColor("normal_color")
    bgToggleLabel.borderLeft = 12

    local bgWhite = false
    local bgToggleBtn = toggleRow:createButton({ text = "Black" })
    local function updateBgToggleVisual()
        bgToggleBtn.widget.state = bgWhite and tes3.uiState.active or tes3.uiState.normal
        bgToggleBtn.text = bgWhite and "White" or "Black"
    end
    updateBgToggleVisual()
    bgToggleBtn:register(tes3.uiEvent.mouseClick, function()
        bgWhite = not bgWhite
        render.setPlaneColor(tempScene.alphaPlane, bgWhite and 1 or 0)
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
        tempScene.config.yaw = (tempScene.config.yaw - 90 + 180) % 360 - 180
        if sliderRefreshers.yaw then sliderRefreshers.yaw() end
        local keepFrustum = tempScene.orthoFrustum
        updatePreviewScene()
        if keepFrustum then
            tempScene.orthoFrustum = keepFrustum
            render.setFrustum(tempScene.camera, keepFrustum)
        end
        controlsMenu:updateLayout()
    end)

    -- Restore the camera sliders to their opening values.
    local resetBtn = camButtonRow:createButton({ text = "Reset Camera" })
    resetBtn.borderLeft = 12
    resetBtn:register(tes3.uiEvent.mouseClick, function()
        for key, value in pairs(cameraDefaults) do
            tempScene.config[key] = value
            if sliderRefreshers[key] then sliderRefreshers[key]() end
        end
        tempScene.panX = 0
        tempScene.panY = 0
        updatePreviewScene()
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
                yaw = tempScene.config.yaw,
                pitch = tempScene.config.pitch,
                roll = tempScene.config.roll,
                -- Fit-to-frame re-crops to content, so zoom is moot there; with it
                -- off, honor the live zoom so a manual crop carries into the render.
                zoom = config.current.previewFitToFrame and 1.0 or tempScene.config.zoom,
                perspectiveDistanceFactor = tempScene.config.perspectiveDistanceFactor,
                keyDimmer = tempScene.config.keyDimmer,
                keyX = tempScene.config.keyX,
                keyY = tempScene.config.keyY,
                keyZ = tempScene.config.keyZ,
                fillDimmer = tempScene.config.fillDimmer,
                ambientScale = tempScene.config.ambientScale,
                diffuseScale = tempScene.config.diffuseScale,
                ortho = tempScene.config.ortho,
                -- pristine frustum, in case the live preview already narrowed it
                orthoBase = tempScene.baseFrustum,
                resolution = config.current.previewRenderResolution,
                dstResolution = config.current.previewOutputResolution,
                outputFormat = config.current.previewOutputFormat,
                fitToFrame = config.current.previewFitToFrame,
                -- WASD pan carries the crop into the render (moot when fit is on).
                panX = tempScene.panX,
                panY = tempScene.panY,
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

        -- Reattach and re-poke only -- a full updatePreviewScene() re-fit would
        -- visibly snap after a drag/zoom fast path.
        camera.scene = tempScene.root
        camera.scene:update()
        camera.scene:updateEffects()
        camera.scene:updateProperties()
        if tempScene.orthoFrustum then
            render.setFrustum(camera, tempScene.orthoFrustum)
        end
    end)

    local btnClosePreview = mainRow:createButton({ text = "Exit" })
    btnClosePreview.widthProportional = 1.0
    btnClosePreview:register(tes3.uiEvent.mouseClick, function()
        controlsMenu:destroy()
    end)

    updatePreviewScene()

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
