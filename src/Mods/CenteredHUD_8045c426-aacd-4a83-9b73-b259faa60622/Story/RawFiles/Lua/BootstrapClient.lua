---------------------------------------------
-- Divinity Centered HUD
-- Lets the user drag UIs that the game does not allow dragging (party portraits, minimap)
-- and remembers where they were dropped. Intended for ultrawide screens, where these
-- otherwise sit at the far edges. Standalone; only needs Norbyte's Script Extender.
--
-- Ctrl+Shift+P: pick up/drop the party portraits.
-- Ctrl+Shift+M: pick up/drop the minimap.
-- While moving: left-click drops, right-click cancels, Backspace resets that panel.
-- Ctrl+Shift+O or Ctrl+Shift+Backspace: reset all panels to their default positions.
---------------------------------------------

local VERSION = "1.0.0" -- Must match the ModuleInfo Version in meta.lsx; tools/build.py enforces this.
local SAVE_FILE = "CenteredHUD.json"
local LEGACY_SAVE_FILE = "EpipPanelMover.json" -- Read when SAVE_FILE does not exist yet; the mod's name before it became standalone.
local SAVE_VERSION = 3 -- Version 1 stored UIObject positions for all panels; version 2 stored flash root offsets for all panels.

local Mover = {
    ---Modes determine how a panel is moved:
    --- - "FlashRoot": offsets the flash root, in flash units. For fullscreen UIs, whose UIObject position the engine overrides.
    --- - "Widened": re-anchors the UI to the top-left of the screen, widens it to the whole viewport and offsets the flash root within it;
    ---   positions are in screen pixels. For UIs with a small movie area anchored elsewhere (ex. top-right), as the engine keeps
    ---   their UIObject at their anchor, and a plain flash root offset would get clipped.
    ---`OffstageElements` are root children that vanilla places outside the movie area, which only stay invisible due to clipping;
    ---they are hidden while a "Widened" panel is moved.
    ---@type {ID:string, Name:string, Key:string, Mode:"FlashRoot"|"Widened", DefaultAnchor:string?, OffstageElements:string[]?, GetUI:fun():UIObject?}[]
    PANELS = {
        {
            ID = "PartyPortraits",
            Name = "Party portraits",
            Key = "p",
            Mode = "FlashRoot",
            GetUI = function () return Ext.UI.GetByType(Ext.UI.TypeID.playerInfo) end,
        },
        {
            ID = "Minimap",
            Name = "Minimap",
            Key = "m",
            Mode = "Widened",
            DefaultAnchor = "topright",
            OffstageElements = {"hackIcon_mc"}, -- Placed at x=581 in minimap.swf, beyond its 420-wide movie.
            GetUI = function () return Ext.UI.GetByType(Ext.UI.TypeID.minimap) end,
        },
    },
    RESET_KEYS = {["o"] = true, ["backspace"] = true}, -- Alternatives, in case an overlay or other program captures one of them.
    PANEL_RESET_KEY = "backspace", -- Resets the panel being moved.
    ---Raw input IDs of modifier keys, to the modifier they count as.
    MODIFIER_KEYS = {
        lctrl = "Ctrl", rctrl = "Ctrl",
        lshift = "Shift", rshift = "Shift",
        lalt = "Alt", ralt = "Alt",
    },
    BLOCKED_INPUT_ID = "item7", -- Blocked keys are rewritten to this unbound ID so the game ignores them (the same trick Epip's InputLib uses).

    _SavedPositions = {}, ---@type table<string, number[]> Panel ID to {x, y}, in the units of the panel's mode.
    _Moving = nil, ---@type {Panel:table, StartMouse:number[], OriginalPos:number[]}?
    _PressedKeys = {}, ---@type table<string, true> Raw input IDs currently held down.
    _BlockedKeys = {}, ---@type table<string, true> Keys whose press was blocked; their repeats and release are blocked too.
}

---------------------------------------------
-- METHODS
---------------------------------------------

---Logs a message, and also shows it on screen when Epip is installed (its notification UI is optional).
---@param msg string
function Mover.Notify(msg)
    Ext.Utils.Print("[CenteredHUD] " .. msg)
    local epip = Mods and Mods.EpipEncounters
    local notification = epip and epip.Client and epip.Client.UI and epip.Client.UI.Notification
    if notification and notification.ShowNotification then
        pcall(notification.ShowNotification, msg)
    end
end

---@param modifier "Ctrl"|"Shift"|"Alt"
---@return boolean
function Mover.IsModifierHeld(modifier)
    for id,mod in pairs(Mover.MODIFIER_KEYS) do
        if mod == modifier and Mover._PressedKeys[id] then
            return true
        end
    end
    return false
end

function Mover.Load()
    local contents = Ext.IO.LoadFile(SAVE_FILE) or Ext.IO.LoadFile(LEGACY_SAVE_FILE)
    if not contents then return end
    local ok, data = pcall(Ext.Json.Parse, contents)
    if not (ok and type(data) == "table" and type(data.Positions) == "table") then return end

    -- Positions are only kept if they were saved with the mode the panel currently uses.
    local modes = data.Modes or {}
    for _,panel in ipairs(Mover.PANELS) do
        local pos = data.Positions[panel.ID]
        local mode = modes[panel.ID]
        if data.Version == 2 then
            mode = "FlashRoot"
        elseif data.Version ~= SAVE_VERSION then
            mode = nil
        end
        if mode == panel.Mode and type(pos) == "table" and tonumber(pos[1]) and tonumber(pos[2]) then
            Mover._SavedPositions[panel.ID] = {tonumber(pos[1]), tonumber(pos[2])}
        end
    end
end

function Mover.Save()
    local modes = {}
    for _,panel in ipairs(Mover.PANELS) do
        modes[panel.ID] = panel.Mode
    end
    local data = {
        Version = SAVE_VERSION,
        Positions = Mover._SavedPositions,
        Modes = modes,
    }
    Ext.IO.SaveFile(SAVE_FILE, Ext.Json.Stringify(data))
end

---Returns the scale from a panel's position units to screen pixels.
---@param panel table
---@param ui UIObject
---@return number
function Mover.GetPositionScale(panel, ui)
    if panel.Mode == "Widened" then return 1 end
    local ok, scale = pcall(ui.GetUIScaleMultiplier, ui)
    return (ok and type(scale) == "number" and scale > 0) and scale or 1
end

---Returns the scale from a UI's flash units to screen pixels.
---Resizing a UI does not scale its content, so this is the UI scale rather than the rendered size ratio.
---@param ui UIObject
---@return number
function Mover.GetMovieScale(ui)
    return Mover.GetPositionScale({Mode = "FlashRoot"}, ui)
end

---Anchors a "Widened" panel to the top-left of the screen and widens it to span the viewport,
---so its flash root can be offset anywhere without being clipped.
---@param panel table
---@param ui UIObject
function Mover.EnsureWidened(panel, ui)
    local viewport = Ext.UI.GetViewportSize()
    local pos = ui:GetPosition()
    local flashSize = ui.FlashSize
    if pos[1] ~= 0 or pos[2] ~= 0 or flashSize[1] < viewport[1] then
        local scale = Mover.GetMovieScale(ui)
        local movieSize = ui.FlashMovieSize -- The movie's native size; unaffected by Resize().
        ui:ExternalInterfaceCall("setAnchor", "topleft", "screen", "topleft")
        ui:Resize(math.ceil(viewport[1] / scale), movieSize[2], scale)
    end
end

---Sets the visibility of a panel's offstage elements.
---@param panel table
---@param root FlashMainTimeline
---@param visible boolean
function Mover.SetOffstageElementsVisible(panel, root, visible)
    for _,name in ipairs(panel.OffstageElements or {}) do
        local element = root[name]
        if element and element.visible ~= visible then
            element.visible = visible
        end
    end
end

---Returns the position of a panel, in the units of its mode.
---@param panel table
---@param ui UIObject
---@return number[]?
function Mover.GetPanelPosition(panel, ui)
    local root = ui:GetRoot()
    if not root then return nil end
    if panel.Mode == "Widened" then
        -- Screen position of the flash root's origin.
        local moviePos = ui:GetPosition()
        local scale = Mover.GetMovieScale(ui)
        return {moviePos[1] + root.x * scale, moviePos[2] + root.y * scale}
    end
    return {root.x, root.y}
end

---@param panel table
---@param ui UIObject
---@param pos number[] In the units of the panel's mode.
function Mover.SetPanelPosition(panel, ui, pos)
    local root = ui:GetRoot()
    if not root then return end
    if panel.Mode == "Widened" then
        Mover.EnsureWidened(panel, ui)
        Mover.SetOffstageElementsVisible(panel, root, false)
        local moviePos = ui:GetPosition()
        local scale = Mover.GetMovieScale(ui)
        root.x = (pos[1] - moviePos[1]) / scale
        root.y = (pos[2] - moviePos[2]) / scale
        return
    end
    root.x = pos[1]
    root.y = pos[2]
end

---Keeps a position within the viewport so a panel cannot be lost off-screen,
---ex. after lowering the resolution.
---@param panel table
---@param ui UIObject
---@param pos number[] In the units of the panel's mode.
---@return number[]
function Mover.ClampToViewport(panel, ui, pos)
    local viewport = Ext.UI.GetViewportSize()
    local scale = Mover.GetPositionScale(panel, ui)
    local maxX = math.max(0, viewport[1] / scale - 100) -- Keep at least some of the panel on-screen.
    local maxY = math.max(0, viewport[2] / scale - 100)
    local minX = panel.Mode == "Widened" and 0 or -maxX -- "Widened" positions are absolute; "FlashRoot" ones are offsets.
    local minY = panel.Mode == "Widened" and 0 or -maxY
    return {
        math.floor(math.max(minX, math.min(pos[1], maxX))),
        math.floor(math.max(minY, math.min(pos[2], maxY))),
    }
end

---Logs a UI's layout properties, to help diagnose panels that do not move correctly.
---@param panel table
---@param ui UIObject
function Mover.LogDiagnostics(panel, ui)
    local function Get(key)
        local ok, value = pcall(function () return ui[key] end)
        if not ok then return "?" end
        return type(value) == "table" and table.concat(value, ", ") or tostring(value)
    end
    local pos = ui:GetPosition()
    local root = ui:GetRoot()
    local viewport = Ext.UI.GetViewportSize()
    Ext.Utils.Print(string.format("[CenteredHUD] %s (mode %s): Position=%s, %s; Root=%s, %s; FlashSize=%s; FlashMovieSize=%s; SysPanelSize=%s; MovieLayout=%s; Anchor=%s/%s/%s; Viewport=%s, %s",
        panel.ID, panel.Mode, tostring(pos and pos[1]), tostring(pos and pos[2]),
        tostring(root and root.x), tostring(root and root.y),
        Get("FlashSize"), Get("FlashMovieSize"), Get("SysPanelSize"), Get("MovieLayout"),
        Get("AnchorPos"), Get("AnchorTarget"), Get("AnchorTPos"), viewport[1], viewport[2]))
end

---@param panel table
function Mover.StartMoving(panel)
    local ui = panel.GetUI()
    local pos = ui and Mover.GetPanelPosition(panel, ui)
    if not pos then
        Mover.Notify(panel.Name .. " is not currently on screen.")
        return
    end
    pcall(Mover.LogDiagnostics, panel, ui)
    local mouse = Ext.UI.GetMouseFlashPos()
    Mover._Moving = {
        Panel = panel,
        StartMouse = {mouse[1], mouse[2]},
        OriginalPos = pos,
    }
    Mover.Notify("Moving " .. panel.Name .. ": left-click to drop, right-click to cancel.")
end

---Moves the panel being dragged to follow the mouse.
function Mover.UpdateMoving()
    local moving = Mover._Moving
    local ui = moving.Panel.GetUI()
    if not ui then
        Mover._Moving = nil
        return
    end
    local mouse = Ext.UI.GetMouseFlashPos()
    local scale = Mover.GetPositionScale(moving.Panel, ui)
    Mover.SetPanelPosition(moving.Panel, ui, {
        math.floor(moving.OriginalPos[1] + (mouse[1] - moving.StartMouse[1]) / scale),
        math.floor(moving.OriginalPos[2] + (mouse[2] - moving.StartMouse[2]) / scale),
    })
end

---@param commit boolean If false, the panel returns to where it was.
function Mover.StopMoving(commit)
    local moving = Mover._Moving
    if not moving then return end
    Mover._Moving = nil

    local panel = moving.Panel
    local ui = panel.GetUI()
    local pos = ui and Mover.GetPanelPosition(panel, ui)
    if commit and pos then
        Mover._SavedPositions[panel.ID] = Mover.ClampToViewport(panel, ui, pos)
        Mover.Save()
        Mover.Notify(panel.Name .. " position saved.")
        pcall(Mover.LogDiagnostics, panel, ui)
    elseif ui then
        Mover.SetPanelPosition(panel, ui, moving.OriginalPos)
    end
end

---Restores a panel's vanilla layout and forgets its saved position.
---@param panel table
function Mover.ResetPanel(panel)
    Mover._SavedPositions[panel.ID] = nil
    local ui = panel.GetUI()
    local root = ui and ui:GetRoot()
    if not root then return end

    root.x, root.y = 0, 0 -- Vanilla UIs keep their flash root at the origin.
    if panel.Mode == "Widened" then
        Mover.SetOffstageElementsVisible(panel, root, true)
        local movieSize = ui.FlashMovieSize
        ui:Resize(movieSize[1], movieSize[2], Mover.GetMovieScale(ui))
        ui:ExternalInterfaceCall("setAnchor", panel.DefaultAnchor, "screen", panel.DefaultAnchor)
    end
end

function Mover.ResetAll()
    Mover._Moving = nil
    for _,panel in ipairs(Mover.PANELS) do
        Mover.ResetPanel(panel)
    end
    Mover.Save()
    Mover.Notify("Panel positions reset.")
end

---Re-applies saved positions; the game may reset its UIs on its own
---(ex. on resolution change, or when the UI is recreated).
function Mover.ApplySavedPositions()
    for _,panel in ipairs(Mover.PANELS) do
        local isBeingMoved = Mover._Moving and Mover._Moving.Panel == panel
        local saved = Mover._SavedPositions[panel.ID]
        local ui = (not isBeingMoved) and panel.GetUI()
        local current = saved and ui and Mover.GetPanelPosition(panel, ui)
        if current then
            local target = Mover.ClampToViewport(panel, ui, saved)
            if math.abs(current[1] - target[1]) > 1 or math.abs(current[2] - target[2]) > 1 then
                Mover.SetPanelPosition(panel, ui, target)
            elseif panel.Mode == "Widened" then
                Mover.SetOffstageElementsVisible(panel, ui:GetRoot(), false) -- In case the UI re-shows them on its own.
            end
        end
    end
end

---Handles a key or mouse button being pressed.
---@param id string Raw input ID.
---@return boolean -- Whether the input was consumed and should be blocked from reaching the game.
function Mover.OnKeyPressed(id)
    -- Drop/cancel with the mouse while moving, without the click reaching the game.
    if Mover._Moving and (id == "left2" or id == "right2") then
        Mover.StopMoving(id == "left2")
        return true
    end

    local isCombo = Mover.IsModifierHeld("Ctrl") and Mover.IsModifierHeld("Shift") and not Mover.IsModifierHeld("Alt")

    -- Reset only the panel being moved.
    if Mover._Moving and id == Mover.PANEL_RESET_KEY and not isCombo then
        local panel = Mover._Moving.Panel
        Mover._Moving = nil
        Mover.ResetPanel(panel)
        Mover.Save()
        Mover.Notify(panel.Name .. " reset.")
        return true
    end

    if not isCombo or Mover.MODIFIER_KEYS[id] then return false end
    Ext.Utils.Print("[CenteredHUD] Ctrl+Shift+" .. id) -- Helps diagnose combos captured by other programs.

    if Mover.RESET_KEYS[id] then
        Mover.ResetAll()
        return true
    end

    for _,panel in ipairs(Mover.PANELS) do
        if id == panel.Key then
            if Mover._Moving and Mover._Moving.Panel == panel then
                Mover.StopMoving(true)
            else
                Mover.StopMoving(false)
                Mover.StartMoving(panel)
            end
            return true
        end
    end
    return false
end

---------------------------------------------
-- EVENT LISTENERS
---------------------------------------------

Ext.Utils.Print("[CenteredHUD] v" .. VERSION .. " loaded")

Ext.Events.RawInput:Subscribe(function (ev)
    local input = ev.Input.Input
    local id = tostring(input.InputId)
    if id == "" then return end -- Unsupported keys, ex. media keys.

    local pressed = ev.Input.Value.State == "Pressed"
    local wasPressed = Mover._PressedKeys[id] == true
    Mover._PressedKeys[id] = pressed or nil

    local block
    if Mover._BlockedKeys[id] then
        -- Keep blocking repeats and the release of a consumed key, so the game never sees half of a key press.
        block = true
        if not pressed then
            Mover._BlockedKeys[id] = nil
        end
    elseif pressed and not wasPressed then
        block = Mover.OnKeyPressed(id)
        if block then
            Mover._BlockedKeys[id] = true
        end
    end

    if block then
        input.InputId = Mover.BLOCKED_INPUT_ID
    end
end)

Ext.Events.SessionLoaded:Subscribe(function (_)
    Mover.Load()
end)

Ext.Events.Tick:Subscribe(function (_)
    if Mover._Moving then
        Mover.UpdateMoving()
    end

    Mover.ApplySavedPositions()
end)
