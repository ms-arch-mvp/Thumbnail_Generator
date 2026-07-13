local function initialized()
    local status, err = pcall(function()
        require("ThumbnailGenerator.ui")

        event.register(tes3.event.keyDown, function(e)
            if tes3ui.menuMode() then return end
            if e.isShiftDown and not e.isControlDown and not e.isAltDown and e.keyCode == tes3.scanCode.g then
                require("ThumbnailGenerator.ui").openMenu()
            end
        end)
        mwse.log("[Thumbnail Generator] Initialized")
    end)
    if not status then
        mwse.log("[Thumbnail Generator] Error initializing: " .. tostring(err))
    end
end

event.register(tes3.event.initialized, initialized)

event.register("modConfigReady", function()
    require("ThumbnailGenerator.mcm").registerModConfig()
end)