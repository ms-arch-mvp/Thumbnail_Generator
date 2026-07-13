-- Subject pickers for the preview: a plugin browser and a search-result list.
-- Pure UI: choosing an entry calls options.onPick(subjectOrObj), which the
-- preview wires to its open(); options.closeMenu/types pass through unchanged.
local this = {}

local subject_resolver = require("ThumbnailGenerator.modules.subject_resolver")

-- Shared by both pickers; the preview's mouse-capture suppression checks it.
this.menuID = "ThumbnailGen:PreviewSelectMenu"

local function getColor(name)
    return tes3ui.getPalette(name)
end

-- Shown when Preview is hit with an empty search: a button per source plugin
-- that has displayable records. Clicking one lists that plugin's records.
function this.showPluginMenu(plugins, options)
    local existing = tes3ui.findMenu(this.menuID)
    if existing then existing:destroy() end

    local menu = tes3ui.createMenu({
        id = this.menuID,
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
        local block = scrollContent:createBlock()
        block.flowDirection = tes3.flowDirection.leftToRight
        block.widthProportional = 1.0
        block.autoHeight = true
        block.borderBottom = 8

        local btn = block:createButton({ text = string.format("%s  (%d)", entry.plugin, entry.count) })
        btn.paddingTop = 8
        btn.paddingBottom = 8
        btn.widthProportional = 1.0
        btn:register(tes3.uiEvent.mouseClick, function()
            menu:destroy()
            local matches = subject_resolver.search({ sourceMod = entry.plugin, types = options.types })
            if #matches == 1 then
                if options.closeMenu then options.closeMenu(true) end
                options.onPick(matches[1].subject)
            elseif #matches > 1 then
                this.showSelectionMenu(matches, options)
            end
        end)

        if options.onSelectSearchTerm then
            local btnSearch = block:createButton({ text = "Use" })
            btnSearch.paddingTop = 8
            btnSearch.paddingBottom = 8
            btnSearch.borderLeft = 8
            btnSearch:register(tes3.uiEvent.mouseClick, function()
                menu:destroy()
                options.onSelectSearchTerm(entry.plugin)
            end)
        end
    end

    local btnClose = contents:createButton({ text = "Cancel" })
    btnClose.childAlignX = 1.0
    btnClose:register(tes3.uiEvent.mouseClick, function()
        menu:destroy()
    end)

    menu:updateLayout()
    scroll.widget:contentsChanged()
    tes3ui.enterMenuMode(this.menuID)
end

function this.showSelectionMenu(matches, options)
    local existing = tes3ui.findMenu(this.menuID)
    if existing then existing:destroy() end

    local menu = tes3ui.createMenu({
        id = this.menuID,
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
            options.onPick(match.subject or match.obj)
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

    tes3ui.enterMenuMode(this.menuID)
end

return this
