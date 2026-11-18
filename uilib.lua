--[[
    uilib - a Roblox/Luau UI library
    ===============================================================================

    A faithful port of the "memesense reworked" ImGui menu to Roblox, with a
    Linoria-shaped API so existing scripts port over with almost no rewriting.

    WHAT WAS PORTED, AND HOW
    ------------------------
    The source is immediate-mode (ImDrawList: rects, gradients, text, every frame).
    Roblox has no equivalent, so this is retained-mode (Instances created once),
    but every metric, colour and layout formula below is taken from the C++ rather
    than re-eyeballed:

      * Metrics.*        - the kMenuW / kSidebarW / kContentX / kItemSpacingY
                           constants out of shell.cpp, unchanged.
      * Grid layout      - ComputeChildLayout()'s 0.224 / 0.134 / 9 / 10 formula,
                           so a groupbox at grid {6,0,3,10} lands on the exact
                           pixel it did in the original.
      * Glass colours    - styling.hpp's glass(r,g,b,opacity) model. ImGui encodes
                           alpha in the colour; Roblox splits it into
                           BackgroundColor3 + BackgroundTransparency, so every
                           glass surface is registered and re-applied when an
                           opacity slider or the master alpha moves.
      * Accent flow bar  - the original walks 64 segments evaluating
                           0.5+0.5*sin(2pi*0.8*(u - t*1.7)) per frame. 64 Frames
                           would be absurd here, so it is one Frame with a
                           UIGradient baked to one full sine period whose Offset
                           scrolls. Identical on screen, one property write.
      * Tab glow         - DrawTabGlow draws 16 concentric circles of constant low
                           alpha. Reproduced with 8 concentric circular Frames,
                           which sums to the same radial falloff and needs no
                           uploaded image asset.
      * Notched titles   - DrawChildBorderAndTitle leaves a gap in the top border
                           from x=10 to x=16+textWidth for the title to sit in.
                           Built from 5 edge Frames per border ring, measured with
                           TextService so the notch fits the text.
      * Scrollbars       - EndChild() hand-rolls a track and thumb. A styled
                           ScrollingFrame is pixel-equivalent and far less code.
      * Roll animation   - the +-kMenuH content slide on tab change, quad-out over
                           kRollDuration.

    DELIBERATELY NOT PORTED
    -----------------------
      * draw_background_blur / BlurRegion. Needs the DX11 swapchain. Nothing in
        Roblox can blur what is behind a ScreenGui, so glass opacity carries the
        depth instead. Raise Library.Glass.Popup if you want popups to read solid.
      * The input "ghost" animation (chars rising out of the textbox on delete).
        Cute, but it is per-character Instances in Roblox.
      * Verdana. Roblox has no Verdana; Enum.Font.Code at 13 is the established
        stand-in for this look in Roblox ports. Override Library.Font if you like.

    QUICK START
    -----------
        local Library = loadstring(readfile("uilib.lua"))()

        local Window = Library:CreateWindow({ Title = "my script", Footer = "v1.0" })
        local Tabs = {
            Main   = Window:AddTab("Main"),
            Config = Window:AddTab("Config"),
        }

        local Box = Tabs.Main:AddLeftGroupbox("Aimbot")
        Box:AddToggle("AimEnabled", { Text = "Enabled" })
           :AddKeyPicker("AimKey", { Default = "MB2", Mode = "Hold", Text = "Aimbot" })
        Box:AddSlider("AimFov", { Text = "FOV", Default = 80, Min = 0, Max = 360 })

        local Save = Library:CreateSaveManager({ Folder = "myscript" })
        Save:BuildConfigSection(Tabs.Config)
        Save:LoadAutoloadConfig()

        Library.Toggles.AimEnabled.Value       --> boolean
        Library.Options.AimFov.Value           --> number
        Library.Options.AimKey:GetState()      --> boolean (respects Hold/Toggle)

    Everything the library creates is tracked, so Library:Unload() leaves nothing
    behind: no Instances, no connections, no bound render steps.
]]

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local TextService       = game:GetService("TextService")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

---------------------------------------------------------------------------------
-- METRICS
--
-- Straight out of shell.cpp. Changing these changes the whole menu's proportions
-- coherently, because every layout decision below is expressed in terms of them
-- rather than in literals sprinkled through the widget code.
---------------------------------------------------------------------------------
local Metrics = {
    MenuW        = 660,   -- kMenuW
    MenuH        = 560,   -- kMenuH
    SidebarW     = 80,    -- kSidebarW
    ContentX     = 100,   -- kContentX
    ContentY     = 30,    -- kContentY
    ContentPadR  = 23,    -- kContentPadR
    ContentPadB  = 23,    -- kContentPadB
    ItemSpacingY = 4,     -- kItemSpacingY
    ComboSpacing = 2,     -- AddItem(..., comboSpacing)
    RollDuration = 0.12,  -- kRollDuration
    FlowSpeed    = 1.70,  -- kAccentFlowSpeed
    FlowWaves    = 0.80,  -- kAccentFlowWaves
    FlowFloor    = 0.40,  -- kAccentFlowFloor
    TabGlowTime  = 0.10,  -- kTabGlowDuration
    SidebarTop   = 19,    -- kSidebarTop
    SidebarBot   = 6,     -- kSidebarBot
    AccentBarY   = 6,     -- topY in DrawMainChrome
    AccentBarH   = 4,

    -- Grid (ComputeChildLayout)
    GridMinFracX = 0.224,
    GridMinFracY = 0.134,
    GridStepsX   = 9,
    GridStepsY   = 10,

    -- Groupbox interior: content starts at pos + (22, 23), and every widget
    -- except the checkbox's own box is indented a further 20px. That offset is
    -- what gives the checkbox square its characteristic hang into the margin.
    BoxPadX      = 22,
    BoxPadY      = 23,
    Gutter       = 20,
    BoxPadR      = 17,   -- PanelRightX() = pos.x + size.x - 17
    BoxGap       = 6,    -- gap between auto-stacked groupboxes

    RowH         = 14,   -- checkbox itemHeight
    CheckSize    = 8,
    SliderH      = 6,    -- sliderBb is 6px tall
    ComboH       = 20,
    ButtonH      = 25,
    ListRowH     = 20,
    KeyBtnW      = 26,
    KeyBtnH      = 11,
    KeyBtnFont   = 9,
    SwatchW      = 16,
    SwatchH      = 10,
    ScrollW      = 6,
}

---------------------------------------------------------------------------------
-- THEME
--
-- styling.hpp's palette. Glass surfaces carry an opacity multiplier rather than a
-- fixed transparency so the four opacity sliders (and the master alpha) can drive
-- the whole menu live, exactly as style::glassWindow etc. do in the original.
---------------------------------------------------------------------------------
local Theme = {
    Accent       = Color3.fromRGB(167, 139, 250),  -- vars::colorAccent default

    Window       = Color3.fromRGB(18, 18, 22),
    Panel        = Color3.fromRGB(14, 14, 18),
    Sidebar      = Color3.fromRGB(14, 14, 18),
    Outline      = Color3.fromRGB(12, 12, 12),

    Text         = Color3.fromRGB(205, 205, 205),
    TextDim      = Color3.fromRGB(128, 128, 128),
    TextSpecial  = Color3.fromRGB(182, 182, 101),
    TextShadow   = Color3.fromRGB(8, 8, 8),
    TextBright   = Color3.fromRGB(255, 255, 255),
    ComboPreview = Color3.fromRGB(157, 157, 157),

    TabIdle      = Color3.fromRGB(62, 62, 62),
    TabHover     = Color3.fromRGB(118, 118, 118),
    TabActive    = Color3.fromRGB(210, 210, 210),

    -- Widget gradients: {topColor, bottomColor} per state.
    ChkIdle      = { Color3.fromRGB(77, 77, 77), Color3.fromRGB(47, 47, 47) },
    ChkHover     = { Color3.fromRGB(85, 85, 85), Color3.fromRGB(55, 55, 55) },
    BtnIdle      = { Color3.fromRGB(35, 35, 35), Color3.fromRGB(30, 30, 30) },
    BtnHover     = { Color3.fromRGB(45, 45, 45), Color3.fromRGB(38, 38, 38) },
    BtnHeld      = { Color3.fromRGB(28, 28, 28), Color3.fromRGB(33, 33, 33) },
    ComboIdle    = { Color3.fromRGB(31, 31, 31), Color3.fromRGB(36, 36, 36) },
    ComboHover   = { Color3.fromRGB(41, 41, 41), Color3.fromRGB(46, 46, 46) },

    SldTrack     = Color3.fromRGB(42, 42, 42),
    SldTrackHov  = Color3.fromRGB(56, 56, 56),
    RowHover     = Color3.fromRGB(40, 40, 40),
    Scroll       = Color3.fromRGB(150, 150, 160),
    ScrollTrack  = Color3.fromRGB(78, 78, 86),
}

---------------------------------------------------------------------------------
-- FILESYSTEM SHIM
--
-- Executor file functions are not guaranteed to exist (and do not exist at all in
-- Studio). Every call routes through here so a missing primitive degrades to
-- "configs unavailable" instead of erroring out mid-build. Memory-backed in
-- Studio, so the save/load UI is still exercisable while developing.
---------------------------------------------------------------------------------
local fs = {
    HasReal = (typeof(writefile) == "function" and typeof(readfile) == "function"),
    Memory  = {},
}

function fs.IsFolder(path)
    if fs.HasReal and isfolder then
        local ok, res = pcall(isfolder, path)
        return ok and res or false
    end
    return fs.Memory[path] == "folder"
end

function fs.MakeFolder(path)
    -- makefolder does not create intermediate levels, so walk the path.
    local built = nil
    for part in string.gmatch(path, "[^/\\]+") do
        built = built and (built .. "/" .. part) or part
        if fs.HasReal and makefolder then
            if not fs.IsFolder(built) then pcall(makefolder, built) end
        else
            fs.Memory[built] = "folder"
        end
    end
end

function fs.IsFile(path)
    if fs.HasReal and isfile then
        local ok, res = pcall(isfile, path)
        return ok and res or false
    end
    return type(fs.Memory[path]) == "string" and fs.Memory[path] ~= "folder"
end

function fs.Write(path, contents)
    if fs.HasReal then
        return pcall(writefile, path, contents)
    end
    fs.Memory[path] = contents
    return true
end

function fs.Read(path)
    if fs.HasReal then
        local ok, res = pcall(readfile, path)
        if ok then return res end
        return nil
    end
    local v = fs.Memory[path]
    if type(v) == "string" and v ~= "folder" then return v end
    return nil
end

function fs.Delete(path)
    if fs.HasReal and delfile then
        return pcall(delfile, path)
    end
    fs.Memory[path] = nil
    return true
end

function fs.List(path)
    if fs.HasReal and listfiles then
        local ok, res = pcall(listfiles, path)
        if ok and type(res) == "table" then return res end
        return {}
    end
    local out = {}
    for k in pairs(fs.Memory) do
        if fs.Memory[k] ~= "folder" and string.sub(k, 1, #path + 1) == path .. "/" then
            out[#out + 1] = k
        end
    end
    return out
end

---------------------------------------------------------------------------------
-- UTIL
---------------------------------------------------------------------------------
local Util = {}

-- Parent is assigned last: setting it first makes every subsequent property write
-- a change to a rendered instance, which is measurably slower when building a
-- tree this size.
function Util.New(class, props, children)
    local inst = Instance.new(class)
    local parent = nil
    if props then
        for key, value in pairs(props) do
            if key == "Parent" then
                parent = value
            else
                inst[key] = value
            end
        end
    end
    if children then
        for _, child in ipairs(children) do
            child.Parent = inst
        end
    end
    if parent then inst.Parent = parent end
    return inst
end

function Util.Lerp(a, b, t)
    return a + (b - a) * t
end

function Util.LerpColor(a, b, t)
    return Color3.new(
        Util.Lerp(a.R, b.R, t),
        Util.Lerp(a.G, b.G, t),
        Util.Lerp(a.B, b.B, t)
    )
end

function Util.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function Util.Round(value, places)
    local mult = 10 ^ (places or 0)
    return math.floor(value * mult + 0.5) / mult
end

-- Vertical gradient, the drawGradientV of the original. Rotation 90 in Roblox
-- runs top-to-bottom, which matches ImGui's top/bottom argument order.
function Util.Gradient(parent, top, bottom)
    return Util.New("UIGradient", {
        Rotation = 90,
        Color = ColorSequence.new(top, bottom),
        Parent = parent,
    })
end

function Util.SetGradient(gradient, pair)
    gradient.Color = ColorSequence.new(pair[1], pair[2])
end

function Util.TextWidth(text, font, size)
    local ok, res = pcall(function()
        return TextService:GetTextSize(text, size, font, Vector2.new(10000, 100))
    end)
    if ok and res then return res.X end
    return #tostring(text) * size * 0.55
end

-- Point-in-rect against an instance's rendered rect. Used for the outside-click
-- popup dismissal, where the click arrives at the ScreenGui rather than at the
-- popup, so there is no .MouseButton1Click to hang off.
function Util.PointInside(inst, point)
    if not inst or not inst.Parent or not inst.Visible then return false end
    local pos, size = inst.AbsolutePosition, inst.AbsoluteSize
    return point.X >= pos.X and point.X <= pos.X + size.X
       and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end

-- KeyToLabel from keybind.cpp. Three-letter abbreviations, mouse buttons as
-- M1..M5, everything unrecognised truncated rather than left blank.
local KEY_LABELS = {
    LeftShift = "SHF", RightShift = "SHF",
    LeftAlt = "ALT",   RightAlt = "ALT",
    LeftControl = "CTR", RightControl = "CTR",
    Space = "SPC", Delete = "DEL", Tab = "TAB", CapsLock = "CAP",
    Backspace = "BSP", Return = "ENT", Escape = "ESC",
    MB1 = "M1", MB2 = "M2", MB3 = "M3", MB4 = "M4", MB5 = "M5",
}

function Util.KeyLabel(key)
    if not key or key == "" then return "-" end
    local mapped = KEY_LABELS[key]
    if mapped then return mapped end
    if #key == 1 then return key end
    -- Zero..Nine -> the digit; F1..F12 keep their name.
    local digit = ({ Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
                     Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9" })[key]
    if digit then return digit end
    if string.match(key, "^F%d+$") then return key end
    return string.upper(string.sub(key, 1, 3))
end

local MOUSE_TO_KEY = {
    [Enum.UserInputType.MouseButton1] = "MB1",
    [Enum.UserInputType.MouseButton2] = "MB2",
    [Enum.UserInputType.MouseButton3] = "MB3",
}

-- Normalises an input event into the string form keybinds are stored as.
function Util.KeyFromInput(input)
    if input.UserInputType == Enum.UserInputType.Keyboard then
        return input.KeyCode.Name
    end
    return MOUSE_TO_KEY[input.UserInputType]
end

function Util.IsKeyDown(key)
    if not key or key == "" then return false end
    if key == "MB1" then return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end
    if key == "MB2" then return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) end
    if key == "MB3" then return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3) end
    local code = Enum.KeyCode[key]
    if not code then return false end
    return UserInputService:IsKeyDown(code)
end

---------------------------------------------------------------------------------
-- LIBRARY
---------------------------------------------------------------------------------
local Library = {
    Theme   = Theme,
    Metrics = Metrics,
    Util    = Util,

    Font      = Enum.Font.Code,
    FontSize  = 13,
    BoldFont  = Enum.Font.Code,

    -- style::menuAlpha, 0..1 here rather than 0..255.
    MenuAlpha = 1,

    -- style::glassWindow / glassPanel / glassWidget / glassPopup.
    Glass = {
        Window = 0.20,
        Panel  = 0.50,
        Widget = 0.22,
        Popup  = 0.50,
        Hover  = 0.28,
    },
    OutlineAlpha = 60 / 255,   -- style::outlineAlpha

    Toggles = {},
    Options = {},

    Unloaded     = false,
    Open         = false,
    MenuKey      = Enum.KeyCode.Insert,
    ShowKeybinds = false,

    _connections = {},
    _instances   = {},
    _renderBinds = {},
    _glass       = {},   -- surfaces whose transparency tracks a Glass.* value
    _accent      = {},   -- instances whose colour tracks the accent
    _outline     = {},   -- border surfaces tracking OutlineAlpha
    _popups      = {},   -- open popups, for outside-click dismissal
    _keybinds    = {},   -- every KeyPicker, for the HUD list and dispatch
    _tabs        = {},
    _watchers    = {},   -- per-frame hover/state watchers
}
Library.__index = Library

---------------------------------------------------------------------------------
-- LIFETIME BOOKKEEPING
--
-- Nothing is created or connected outside these three helpers, which is what
-- makes Unload total rather than best-effort.
---------------------------------------------------------------------------------
function Library:Connect(signal, fn)
    local conn = signal:Connect(fn)
    self._connections[#self._connections + 1] = conn
    return conn
end

function Library:Track(inst)
    self._instances[#self._instances + 1] = inst
    return inst
end

function Library:BindRender(name, priority, fn)
    RunService:BindToRenderStep(name, priority, fn)
    self._renderBinds[#self._renderBinds + 1] = name
end

function Library:Unload()
    if self.Unloaded then return end
    self.Unloaded = true

    for _, name in ipairs(self._renderBinds) do
        pcall(function() RunService:UnbindFromRenderStep(name) end)
    end
    self._renderBinds = {}

    for _, conn in ipairs(self._connections) do
        pcall(function() conn:Disconnect() end)
    end
    self._connections = {}

    for _, callback in ipairs(self._unloadCallbacks or {}) do
        pcall(callback)
    end

    if self.ScreenGui then
        pcall(function() self.ScreenGui:Destroy() end)
        self.ScreenGui = nil
    end

    self.Toggles = {}
    self.Options = {}
    self._popups = {}
    self._keybinds = {}
    self._glass = {}
    self._accent = {}
    self._outline = {}
    self._watchers = {}
end

function Library:OnUnload(callback)
    self._unloadCallbacks = self._unloadCallbacks or {}
    self._unloadCallbacks[#self._unloadCallbacks + 1] = callback
end

---------------------------------------------------------------------------------
-- THEMING REGISTRY
--
-- ImGui re-evaluates style::glass(...) on every draw, so an opacity change is
-- free and instant. Retained mode has to go back and touch each surface, so each
-- one registers what it is and gets re-applied on change.
---------------------------------------------------------------------------------
function Library:RegisterGlass(inst, colorOrNil, kind, scale)
    local entry = {
        Inst  = inst,
        Color = colorOrNil,
        Kind  = kind or "Widget",
        Scale = scale or 1,
    }
    self._glass[#self._glass + 1] = entry
    self:_ApplyGlass(entry)
    return inst
end

function Library:_ApplyGlass(entry)
    local inst = entry.Inst
    if not inst or not inst.Parent then return end
    local opacity = (self.Glass[entry.Kind] or 1) * entry.Scale * self.MenuAlpha
    if entry.Color then
        inst.BackgroundColor3 = entry.Color
    end
    inst.BackgroundTransparency = Util.Clamp(1 - opacity, 0, 1)
end

function Library:RegisterOutline(inst)
    self._outline[#self._outline + 1] = inst
    inst.BackgroundColor3 = Theme.Outline
    inst.BackgroundTransparency = Util.Clamp(1 - self.OutlineAlpha * self.MenuAlpha, 0, 1)
    return inst
end

-- `prop` is the property the accent drives: BackgroundColor3 for fills,
-- TextColor3 for text, ImageColor3 for icons.
function Library:RegisterAccent(inst, prop)
    self._accent[#self._accent + 1] = { Inst = inst, Prop = prop or "BackgroundColor3" }
    inst[prop or "BackgroundColor3"] = Theme.Accent
    return inst
end

function Library:SetAccent(color)
    Theme.Accent = color
    for _, entry in ipairs(self._accent) do
        if entry.Inst and entry.Inst.Parent then
            pcall(function() entry.Inst[entry.Prop] = color end)
        end
    end
    if self._flowGradient then
        self._flowGradient.Color = self:_BuildFlowSequence()
    end
    -- Toggle fills and tab icons read Theme.Accent at paint time rather than
    -- being registered surfaces, because they switch between the accent and a
    -- grey gradient. Repaint them so the change is visible immediately.
    for _, toggle in pairs(self.Toggles) do
        if toggle._Repaint then pcall(toggle._Repaint, toggle) end
    end
    if self.Window and self.Window.Tabs then
        for _, tab in ipairs(self.Window.Tabs) do
            tab:_Repaint(false)
        end
    end
    if self.Options and self.Options.MenuAccent then
        -- Keep the config-page swatch in step when the accent is set by code.
        self.Options.MenuAccent:SetValueSilent(color)
    end
end

function Library:Refresh()
    for _, entry in ipairs(self._glass) do
        self:_ApplyGlass(entry)
    end
    for _, inst in ipairs(self._outline) do
        if inst and inst.Parent then
            inst.BackgroundTransparency = Util.Clamp(1 - self.OutlineAlpha * self.MenuAlpha, 0, 1)
        end
    end
    -- Toggle fills and glow layers compute their own transparency from the glass
    -- values rather than being registered surfaces, because they switch between
    -- an accent fill and a gradient. Repaint them so an opacity slider still
    -- moves them.
    for _, toggle in pairs(self.Toggles) do
        if toggle._Repaint then pcall(toggle._Repaint, toggle) end
    end
    if self.Window and self.Window.Tabs then
        for _, tab in ipairs(self.Window.Tabs) do
            tab:_Repaint(false)
        end
    end
end

---------------------------------------------------------------------------------
-- TEXT HELPERS
---------------------------------------------------------------------------------
function Library:Label(parent, text, props)
    props = props or {}
    local label = Util.New("TextLabel", {
        BackgroundTransparency = 1,
        Font           = props.Bold and self.BoldFont or self.Font,
        Text           = text or "",
        TextSize       = props.TextSize or self.FontSize,
        TextColor3     = props.Color or Theme.Text,
        TextXAlignment = props.XAlign or Enum.TextXAlignment.Left,
        TextYAlignment = props.YAlign or Enum.TextYAlignment.Center,
        TextTruncate   = props.Truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
        TextWrapped    = props.Wrapped or false,
        Position       = props.Position or UDim2.new(),
        Size           = props.Size or UDim2.fromScale(1, 1),
        AnchorPoint    = props.AnchorPoint or Vector2.new(),
        ZIndex         = props.ZIndex or 2,
        Parent         = parent,
    })
    return label
end

-- The original draws title and button text twice, 1px apart, dark underneath.
-- Only those two places, so this is not applied to body text.
function Library:ShadowedLabel(parent, text, props)
    props = props or {}
    local shadow = self:Label(parent, text, {
        Bold = props.Bold, TextSize = props.TextSize, Color = Theme.TextShadow,
        XAlign = props.XAlign, YAlign = props.YAlign,
        Position = (props.Position or UDim2.new()) + UDim2.fromOffset(1, 1),
        Size = props.Size, AnchorPoint = props.AnchorPoint,
        ZIndex = (props.ZIndex or 2) - 1,
    })
    local main = self:Label(parent, text, props)
    return main, shadow
end

---------------------------------------------------------------------------------
-- HOVER WATCHER
--
-- GuiObject.MouseEnter/MouseLeave is unreliable once popups overlay the widget
-- and does not fire at all for a frame that is covered. The original simply asks
-- "is the mouse inside this rect" every frame, so a single shared RenderStepped
-- pass does the same here: one connection for every hover state in the menu.
---------------------------------------------------------------------------------
function Library:Watch(fn)
    self._watchers[#self._watchers + 1] = fn
    return fn
end

function Library:_StartWatchers()
    self:Connect(RunService.RenderStepped, function(dt)
        if self.Unloaded then return end
        local mouse = UserInputService:GetMouseLocation()
        -- GetMouseLocation includes the 36px topbar inset; the ScreenGui ignores
        -- it, so subtract it or every hover rect sits 36px too low.
        local point = Vector2.new(mouse.X, mouse.Y - self._guiInset)
        for index = #self._watchers, 1, -1 do
            local watcher = self._watchers[index]
            local ok = pcall(watcher, point, dt)
            if not ok then
                table.remove(self._watchers, index)
            end
        end
    end)
end

---------------------------------------------------------------------------------
-- POPUP LAYER
--
-- RenderPendingPopups() in the original defers every dropdown and colour picker
-- to the foreground draw list so they paint over the panels that spawned them.
-- Roblox's equivalent is a sibling frame with a higher ZIndex, which is why the
-- popup layer is not inside the window.
---------------------------------------------------------------------------------
function Library:RegisterPopup(popup)
    self._popups[#self._popups + 1] = popup
    return popup
end

function Library:CloseAllPopups(except)
    for _, popup in ipairs(self._popups) do
        if popup ~= except and popup.IsOpen then
            popup:Close()
        end
    end
end

function Library:AnyPopupOpen()
    for _, popup in ipairs(self._popups) do
        if popup.IsOpen then return true end
    end
    return false
end

---------------------------------------------------------------------------------
-- ROOT
---------------------------------------------------------------------------------
function Library:_Parent()
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then return hui end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then return core end
    return LocalPlayer:WaitForChild("PlayerGui")
end

function Library:_CreateRoot()
    if self.ScreenGui then return end

    self.ScreenGui = self:Track(Util.New("ScreenGui", {
        Name           = HttpService:GenerateGUID(false),
        DisplayOrder   = 999,
        IgnoreGuiInset = true,
        ResetOnSpawn   = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }))

    if syn and syn.protect_gui then pcall(syn.protect_gui, self.ScreenGui) end
    if protect_gui then pcall(protect_gui, self.ScreenGui) end
    self.ScreenGui.Parent = self:_Parent()

    -- IgnoreGuiInset moves our coordinate origin to the true top-left, so the
    -- 36px topbar offset has to come off GetMouseLocation. Read once rather than
    -- per frame; it does not change at runtime.
    self._guiInset = 0
    pcall(function()
        self._guiInset = game:GetService("GuiService"):GetGuiInset().Y
    end)

    -- Modal button: Roblox hides and locks the cursor in most games. A modal
    -- TextButton releases it for as long as the menu is up, without us having to
    -- fight whatever the game does to UserInputService.
    self.ModalBlocker = Util.New("TextButton", {
        Name = "Modal", Text = "", Modal = false, AutoButtonColor = false,
        BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 1), ZIndex = 0,
        Parent = self.ScreenGui,
    })

    self.PopupLayer = Util.New("Frame", {
        Name = "Popups", BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), ZIndex = 5000,
        Parent = self.ScreenGui,
    })

    self.NotifyLayer = Util.New("Frame", {
        Name = "Notifications", BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -14, 0, 14),
        Size = UDim2.new(0, 260, 1, -28),
        ZIndex = 6000,
        Parent = self.ScreenGui,
    }, {
        Util.New("UIListLayout", {
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 6),
        }),
    })

    self:_StartWatchers()

    -- One global press handler closes popups that were not clicked into, the
    -- same job the "released outside both rects" test does in the original.
    self:Connect(UserInputService.InputBegan, function(input, processed)
        if self.Unloaded then return end

        local isClick = input.UserInputType == Enum.UserInputType.MouseButton1
                     or input.UserInputType == Enum.UserInputType.MouseButton2
        if isClick then
            local mouse = UserInputService:GetMouseLocation()
            local point = Vector2.new(mouse.X, mouse.Y - self._guiInset)
            for _, popup in ipairs(self._popups) do
                if popup.IsOpen and not popup:HitTest(point) then
                    popup:Close()
                end
            end
        end

        -- Capture deliberately ignores `processed`. Binding a mouse button means
        -- clicking it while the cursor is over the menu, which Roblox reports as
        -- consumed by the GUI - gating on `processed` would make MB2 and MB3
        -- impossible to bind.
        if self._capturing then
            self:_HandleCapture(input)
            return
        end

        if processed then return end
        self:_HandleInput(input)
    end)

    self:Connect(UserInputService.InputEnded, function(input)
        if self.Unloaded then return end
        self:_HandleInputEnded(input)
    end)
end

---------------------------------------------------------------------------------
-- INPUT DISPATCH
--
-- ProcessKeybinds() in the original walks a registry rebuilt every frame and
-- toggles each bound value on press. Here the registry is persistent and each
-- KeyPicker decides what a press means based on its mode.
---------------------------------------------------------------------------------
-- Escape cancels, Delete/Backspace clears, anything else binds. Mirrors the
-- capturing branch of DrawKeybindButton.
function Library:_HandleCapture(input)
    local picker = self._capturing
    if not picker then return end

    if input.KeyCode == Enum.KeyCode.Escape then
        self:_StopCapture()
        return
    end
    if input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Delete then
        picker:SetValue("")
        self:_StopCapture()
        return
    end

    -- Left click is ignored while capturing: the click that opened the binder
    -- arrives here too, and would otherwise bind itself.
    if input.UserInputType == Enum.UserInputType.MouseButton1 then return end

    local key = Util.KeyFromInput(input)
    if key then
        picker:SetValue(key)
        self:_StopCapture()
    end
end

function Library:_HandleInput(input)
    if input.KeyCode == self.MenuKey then
        self:Toggle()
        return
    end

    local key = Util.KeyFromInput(input)
    if not key then return end
    for _, picker in ipairs(self._keybinds) do
        if picker.Value == key then
            picker:OnPressed()
        end
    end
end

function Library:_HandleInputEnded(input)
    local key = Util.KeyFromInput(input)
    if not key then return end
    for _, picker in ipairs(self._keybinds) do
        if picker.Value == key then
            picker:OnReleased()
        end
    end
end

function Library:_StartCapture(picker)
    self._capturing = picker
    picker:SetCapturing(true)
end

function Library:_StopCapture()
    if self._capturing then
        self._capturing:SetCapturing(false)
        self._capturing = nil
    end
end

---------------------------------------------------------------------------------
-- NOTIFICATIONS
---------------------------------------------------------------------------------
function Library:Notify(text, duration, title)
    if self.Unloaded or not self.NotifyLayer then return end
    duration = duration or 3

    local card = Util.New("Frame", {
        BackgroundColor3 = Color3.fromRGB(10, 10, 10),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, title and 44 or 28),
        Parent = self.NotifyLayer,
    })

    local border = Util.New("UIStroke", {
        Color = Color3.fromRGB(30, 30, 30), Thickness = 1, Transparency = 1,
        Parent = card,
    })

    local accent = self:RegisterAccent(Util.New("Frame", {
        BorderSizePixel = 0, Size = UDim2.new(0, 2, 1, 0),
        BackgroundTransparency = 1, Parent = card,
    }), "BackgroundColor3")

    local labels = {}
    if title then
        labels[1] = self:Label(card, title, {
            Bold = true, Color = Color3.fromRGB(205, 205, 205),
            Position = UDim2.fromOffset(10, 5), Size = UDim2.new(1, -16, 0, 15),
            YAlign = Enum.TextYAlignment.Top,
        })
        labels[2] = self:Label(card, text, {
            Color = Theme.TextDim, Truncate = true,
            Position = UDim2.fromOffset(10, 21), Size = UDim2.new(1, -16, 0, 18),
            YAlign = Enum.TextYAlignment.Top,
        })
    else
        labels[1] = self:Label(card, text, {
            Color = Theme.Text, Truncate = true,
            Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -16, 1, 0),
        })
    end

    for _, label in ipairs(labels) do label.TextTransparency = 1 end

    local info = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(card,   info, { BackgroundTransparency = 0.05 }):Play()
    TweenService:Create(accent, info, { BackgroundTransparency = 0 }):Play()
    TweenService:Create(border, info, { Transparency = 0 }):Play()
    for _, label in ipairs(labels) do
        TweenService:Create(label, info, { TextTransparency = 0 }):Play()
    end

    task.delay(duration, function()
        if not card or not card.Parent then return end
        local out = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        TweenService:Create(card,   out, { BackgroundTransparency = 1 }):Play()
        TweenService:Create(accent, out, { BackgroundTransparency = 1 }):Play()
        TweenService:Create(border, out, { Transparency = 1 }):Play()
        for _, label in ipairs(labels) do
            TweenService:Create(label, out, { TextTransparency = 1 }):Play()
        end
        task.delay(0.25, function()
            pcall(function() card:Destroy() end)
        end)
    end)
end

---------------------------------------------------------------------------------
-- WATERMARK
---------------------------------------------------------------------------------
function Library:SetWatermarkVisible(visible)
    if self.Watermark then self.Watermark.Visible = visible and true or false end
end

function Library:SetWatermark(text)
    self:_CreateRoot()

    if not self.Watermark then
        self.Watermark = Util.New("Frame", {
            Name = "Watermark", BorderSizePixel = 0,
            Position = UDim2.fromOffset(20, 20),
            Size = UDim2.fromOffset(200, 22),
            ZIndex = 4000, Visible = false,
            Parent = self.ScreenGui,
        })
        self:RegisterGlass(self.Watermark, Theme.Window, "Window", 5)

        Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = self.Watermark })

        -- Same two-stripe header as the main window, scaled down.
        self:RegisterOutline(Util.New("Frame", {
            BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), ZIndex = 2,
            Parent = self.Watermark,
        }))
        self:RegisterAccent(Util.New("Frame", {
            BorderSizePixel = 0, Position = UDim2.fromOffset(0, 2),
            Size = UDim2.new(1, 0, 0, 2), ZIndex = 2, Parent = self.Watermark,
        }), "BackgroundColor3")

        self.WatermarkLabel = self:Label(self.Watermark, "", {
            Position = UDim2.fromOffset(8, 4), Size = UDim2.new(1, -16, 1, -4),
            Color = Theme.Text,
        })
    end

    self.WatermarkLabel.Text = tostring(text)
    local width = Util.TextWidth(tostring(text), self.Font, self.FontSize)
    self.Watermark.Size = UDim2.fromOffset(math.max(120, width + 18), 24)
    self.Watermark.Visible = true
end

---------------------------------------------------------------------------------
-- KEYBIND LIST
--
-- Reads the live KeyPicker registry rather than a copy, so it cannot drift from
-- what the binds actually do.
---------------------------------------------------------------------------------
function Library:_CreateKeybindList()
    self:_CreateRoot()
    if self.KeybindFrame then return end

    self.KeybindFrame = Util.New("Frame", {
        Name = "Keybinds", BorderSizePixel = 0,
        Position = UDim2.new(0, 20, 0.4, 0),
        Size = UDim2.fromOffset(160, 30),
        ZIndex = 4000, Visible = false, Active = true,
        Parent = self.ScreenGui,
    })
    self:RegisterGlass(self.KeybindFrame, Theme.Window, "Window", 5)

    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = self.KeybindFrame })

    self:RegisterOutline(Util.New("Frame", {
        BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), ZIndex = 2,
        Parent = self.KeybindFrame,
    }))
    self:RegisterAccent(Util.New("Frame", {
        BorderSizePixel = 0, Position = UDim2.fromOffset(0, 2),
        Size = UDim2.new(1, 0, 0, 2), ZIndex = 2, Parent = self.KeybindFrame,
    }), "BackgroundColor3")

    self:Label(self.KeybindFrame, "Keybinds", {
        Bold = true, Position = UDim2.fromOffset(8, 4),
        Size = UDim2.new(1, -16, 0, 18), Color = Theme.Text,
    })

    self.KeybindList = Util.New("Frame", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 24),
        Size = UDim2.new(1, -16, 1, -28), ZIndex = 2,
        Parent = self.KeybindFrame,
    }, {
        Util.New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    self:_MakeDraggable(self.KeybindFrame, self.KeybindFrame)

    -- Rebuilt only when the rendered contents actually change, keyed off a
    -- signature string. Without that this churns a dozen Instances a frame.
    self:Watch(function()
        if not self.ShowKeybinds then
            if self.KeybindFrame.Visible then self.KeybindFrame.Visible = false end
            return
        end

        local rows, parts = {}, {}
        for _, picker in ipairs(self._keybinds) do
            if picker.Value and picker.Value ~= "" and picker.ShowInList then
                local active = picker:GetState()
                rows[#rows + 1] = { Text = picker.Text, Key = Util.KeyLabel(picker.Value), On = active }
                parts[#parts + 1] = picker.Text .. "|" .. picker.Value .. "|" .. tostring(active)
            end
        end

        local signature = table.concat(parts, ";")
        self.KeybindFrame.Visible = true
        if signature == self._keybindSignature then return end
        self._keybindSignature = signature

        for _, child in ipairs(self.KeybindList:GetChildren()) do
            if child:IsA("TextLabel") then child:Destroy() end
        end

        local widest = 0
        if #rows == 0 then
            local label = self:Label(self.KeybindList, "No keybinds set", {
                Color = Theme.TextDim, Size = UDim2.new(1, 0, 0, 18),
            })
            label.LayoutOrder = 1
            widest = Util.TextWidth("No keybinds set", self.Font, self.FontSize)
        else
            for index, row in ipairs(rows) do
                local plain = "[" .. row.Key .. "] | " .. row.Text .. ": " .. (row.On and "ON" or "OFF")
                local state = row.On and '<font color="#22c55e">ON</font>'
                                     or  '<font color="#ef4444">OFF</font>'
                local label = self:Label(self.KeybindList, "", {
                    Size = UDim2.new(1, 0, 0, 18), Color = Color3.fromRGB(230, 230, 230),
                })
                label.RichText = true
                label.Text = "[" .. row.Key .. "] | " .. row.Text .. ": " .. state
                label.LayoutOrder = index
                widest = math.max(widest, Util.TextWidth(plain, self.Font, self.FontSize))
            end
        end

        self.KeybindFrame.Size = UDim2.fromOffset(
            math.max(160, widest + 20),
            24 + math.max(#rows, 1) * 18 + 6
        )
    end)
end

function Library:SetKeybindListVisible(visible)
    self:_CreateKeybindList()
    self.ShowKeybinds = visible and true or false
    self._keybindSignature = nil
end

---------------------------------------------------------------------------------
-- DRAGGING
--
-- HandleMainWindowDrag() in the original gates on "not over a widget area and no
-- popup open". Here the drag handle is an explicit region, which gets the same
-- result without hit-testing every panel: the handle sits behind the panels, so
-- a click that lands on a widget never reaches it.
---------------------------------------------------------------------------------
function Library:_MakeDraggable(handle, target)
    local dragging, startInput, startPos = false, nil, nil

    self:Connect(handle.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if self:AnyPopupOpen() then return end
        dragging, startInput, startPos = true, input.Position, target.Position
    end)

    self:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    self:Connect(UserInputService.InputChanged, function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - startInput
        target.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end)
end

---------------------------------------------------------------------------------
-- ACCENT FLOW BAR
--
-- DrawTopAccentFlow samples 0.5+0.5*sin(2pi*waves*(u-scroll)) across 64 segments
-- with a floor of 0.40. Baked into a 20-keypoint ColorSequence covering one full
-- period; scrolling Offset.X reproduces the travel. Visually the same, one
-- property write a frame instead of 64 gradient quads.
---------------------------------------------------------------------------------
function Library:_BuildFlowSequence()
    local keypoints = {}
    local count = 20
    for index = 0, count - 1 do
        local t = index / (count - 1)
        local wave = 0.5 + 0.5 * math.sin(2 * math.pi * t)
        local level = Metrics.FlowFloor + (1 - Metrics.FlowFloor) * wave
        keypoints[#keypoints + 1] = ColorSequenceKeypoint.new(
            t, Color3.new(Theme.Accent.R * level, Theme.Accent.G * level, Theme.Accent.B * level)
        )
    end
    return ColorSequence.new(keypoints)
end

---------------------------------------------------------------------------------
-- WINDOW
---------------------------------------------------------------------------------
local Window = {}
Window.__index = Window

function Library:CreateWindow(config)
    config = config or {}
    self:_CreateRoot()

    local size = config.Size or UDim2.fromOffset(Metrics.MenuW, Metrics.MenuH)
    if config.Accent then
        Theme.Accent = config.Accent
    end
    if config.Font then self.Font = config.Font end
    if config.FontSize then self.FontSize = config.FontSize end
    if config.MenuKey then self.MenuKey = config.MenuKey end

    local window = setmetatable({
        Library   = self,
        Tabs      = {},
        TabCount  = 0,
        ActiveTab = nil,
        Title     = config.Title or "uilib",
        Footer    = config.Footer,
    }, Window)
    self.Window = window

    ---------------------------------------------------------------
    -- Root frame. Everything is drawn into this; the outer frame,
    -- sidebar fill and accent bar are siblings of the content area
    -- rather than ancestors, so clipping stays simple.
    ---------------------------------------------------------------
    local root = Util.New("Frame", {
        Name = "Window", BorderSizePixel = 0,
        AnchorPoint = config.Center == false and Vector2.new() or Vector2.new(0.5, 0.5),
        Position = config.Center == false
            and (config.Position or UDim2.fromOffset(100, 100))
            or UDim2.fromScale(0.5, 0.5),
        Size = size, Visible = false, ZIndex = 100,
        Parent = self.ScreenGui,
    })
    window.Root = root

    -- Window body starts at y = AccentBarY (the 6px above it is left clear so the
    -- accent bar reads as sitting on top of the frame, as in DrawMainChrome).
    local body = Util.New("Frame", {
        Name = "Body", BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, Metrics.AccentBarY),
        Size = UDim2.new(1, 0, 1, -Metrics.AccentBarY),
        Parent = root,
    })
    self:RegisterGlass(body, Theme.Window, "Window", 5)

    -- Sidebar fill + separator at x = SidebarW.
    local sidebar = Util.New("Frame", {
        Name = "Sidebar", BorderSizePixel = 0,
        Size = UDim2.new(0, Metrics.SidebarW, 1, 0), ZIndex = 2,
        Parent = body,
    })
    self:RegisterGlass(sidebar, Theme.Sidebar, "Window", 5)

    self:RegisterOutline(Util.New("Frame", {
        Name = "Separator", BorderSizePixel = 0,
        Position = UDim2.fromOffset(Metrics.SidebarW, 4),
        Size = UDim2.new(0, 1, 1, -4), ZIndex = 3,
        Parent = body,
    }))

    -- 2px frame on left, right and bottom (DrawMainChrome draws exactly these
    -- three; the top edge is the accent bar's job).
    for _, spec in ipairs({
        { Position = UDim2.new(), Size = UDim2.new(0, 2, 1, 0) },
        { Position = UDim2.new(1, -2, 0, 0), Size = UDim2.new(0, 2, 1, 0) },
        { Position = UDim2.new(0, 2, 1, -2), Size = UDim2.new(1, -4, 0, 2) },
    }) do
        self:RegisterOutline(Util.New("Frame", {
            BorderSizePixel = 0, Position = spec.Position, Size = spec.Size, ZIndex = 20,
            Parent = body,
        }))
    end

    local flowBar = Util.New("Frame", {
        Name = "AccentFlow", BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1),
        Position = UDim2.fromOffset(2, Metrics.AccentBarY),
        Size = UDim2.new(1, -4, 0, Metrics.AccentBarH), ZIndex = 30,
        Parent = root,
    })
    self._flowGradient = Util.New("UIGradient", {
        Color = self:_BuildFlowSequence(), Parent = flowBar,
    })

    -- One write a frame. Period = 1 / (FlowSpeed * FlowWaves), matching the
    -- original's scroll rate once the wave is normalised to one period.
    self:Connect(RunService.RenderStepped, function()
        if self.Unloaded or not root.Visible then return end
        local phase = (os.clock() * Metrics.FlowSpeed * Metrics.FlowWaves) % 1
        self._flowGradient.Offset = Vector2.new(-phase, 0)
    end)

    ---------------------------------------------------------------
    -- Drag zone: the top bar strip right of the sidebar. Sits at a
    -- low ZIndex so panels and widgets intercept their own clicks.
    ---------------------------------------------------------------
    local dragZone = Util.New("TextButton", {
        Name = "DragZone", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(Metrics.SidebarW, 0),
        Size = UDim2.new(1, -Metrics.SidebarW, 0, Metrics.ContentY),
        ZIndex = 4, Parent = body,
    })
    self:_MakeDraggable(dragZone, root)

    window.TitleLabel = self:ShadowedLabel(body, window.Title, {
        Bold = true, Color = Theme.Text,
        Position = UDim2.fromOffset(Metrics.ContentX - 1, 4),
        Size = UDim2.new(0, 300, 0, 20), ZIndex = 5,
    })

    if window.Footer then
        window.FooterLabel = self:Label(body, window.Footer, {
            Color = Theme.TextDim, XAlign = Enum.TextXAlignment.Right,
            Position = UDim2.new(1, -Metrics.ContentPadR - 300, 0, 4),
            Size = UDim2.fromOffset(300, 20), ZIndex = 5,
        })
    end

    ---------------------------------------------------------------
    -- Tab strip and content host.
    ---------------------------------------------------------------
    -- Everything inside `body` is offset by AccentBarY relative to the original's
    -- window-space coordinates, because body itself starts at that y. Every
    -- constant below therefore has AccentBarY subtracted once - get this wrong
    -- and the whole content area sits 6px low with a 6px gap at the bottom.
    local sidebarTop = Metrics.SidebarTop - Metrics.AccentBarY

    window.TabStrip = Util.New("Frame", {
        Name = "TabStrip", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, sidebarTop),
        Size = UDim2.new(0, Metrics.SidebarW, 1, -(sidebarTop + Metrics.SidebarBot)),
        ZIndex = 6, Parent = body,
    })

    -- The content host is the bounds rect from ComputeChildLayout: groupbox
    -- positions are relative to it, so the grid maths below needs no window
    -- offsets and stays readable.
    window.Content = Util.New("Frame", {
        Name = "Content", BackgroundTransparency = 1, ClipsDescendants = true,
        Position = UDim2.fromOffset(Metrics.ContentX - 1, Metrics.ContentY - 1 - Metrics.AccentBarY),
        Size = UDim2.new(
            1, -(Metrics.ContentX + Metrics.ContentPadR),
            1, -(Metrics.ContentY + Metrics.ContentPadB - Metrics.AccentBarY)
        ),
        ZIndex = 8, Parent = body,
    })

    self:Connect(window.Content:GetPropertyChangedSignal("AbsoluteSize"), function()
        window:Layout()
    end)

    if config.AutoShow ~= false then
        task.defer(function()
            if not self.Unloaded then self:Toggle(true) end
        end)
    end

    return window
end

function Library:Toggle(state)
    if self.Unloaded or not self.Window then return end
    if state == nil then state = not self.Open end
    self.Open = state and true or false

    self.Window.Root.Visible = self.Open
    if self.ModalBlocker then self.ModalBlocker.Modal = self.Open end
    if not self.Open then
        self:CloseAllPopups()
        self:_StopCapture()
    end
end

---------------------------------------------------------------------------------
-- GRID
--
-- ComputeChildLayout(), verbatim, in content-relative pixels.
---------------------------------------------------------------------------------
function Window:GridRect(gx, gy, gw, gh)
    local bounds = self.Content.AbsoluteSize
    if bounds.X <= 0 or bounds.Y <= 0 then
        bounds = Vector2.new(
            Metrics.MenuW - Metrics.ContentX - Metrics.ContentPadR,
            Metrics.MenuH - Metrics.ContentY - Metrics.ContentPadB
        )
    end

    local minX = (bounds.X - 2) * Metrics.GridMinFracX
    local minY = (bounds.Y - 2) * Metrics.GridMinFracY
    local stepX = (bounds.X - minX - 2) / Metrics.GridStepsX
    local stepY = (bounds.Y - minY - 2) / Metrics.GridStepsY

    return gx * stepX, gy * stepY, minX + gw * stepX, minY + gh * stepY
end

function Window:Layout()
    for _, tab in ipairs(self.Tabs) do
        tab:Layout()
    end
end

---------------------------------------------------------------------------------
-- TABS
---------------------------------------------------------------------------------
local Tab = {}
Tab.__index = Tab

function Window:AddTab(name, icon)
    local library = self.Library
    self.TabCount = self.TabCount + 1
    local index = self.TabCount

    local tab = setmetatable({
        Library    = library,
        Window     = self,
        Name       = name,
        Index      = index,
        Groupboxes = {},
        Columns    = { Left = {}, Right = {} },
    }, Tab)

    ---------------------------------------------------------------
    -- Sidebar button. TabButton() divides the strip by total+1, so
    -- the slot height depends on how many tabs exist; every button
    -- is relaid out as tabs are added.
    ---------------------------------------------------------------
    local button = Util.New("TextButton", {
        Name = "Tab" .. index, Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 40), ZIndex = 2,
        Parent = self.TabStrip,
    })
    tab.Button = button

    -- Glow: 8 concentric circles of constant low alpha, which integrates to the
    -- same radial falloff as DrawTabGlow's 16. Parented behind the icon.
    tab.GlowParts = {}
    for layer = 1, 8 do
        local radius = 26 * (layer / 8)
        local circle = library:RegisterAccent(Util.New("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(radius * 2, radius * 2),
            BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 1,
            Parent = button,
        }), "BackgroundColor3")
        Util.New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = circle })
        tab.GlowParts[layer] = circle
    end

    -- Icon, or the first letter of the name when no icon is supplied. The
    -- original is icon-only; falling back to a glyph keeps an unconfigured tab
    -- from rendering as an empty slot.
    if icon then
        tab.Icon = Util.New("ImageLabel", {
            BackgroundTransparency = 1, Image = icon,
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(24, 24), ImageColor3 = Theme.TabIdle, ZIndex = 3,
            Parent = button,
        })
    else
        tab.Icon = library:Label(button, string.upper(string.sub(name, 1, 1)), {
            Bold = true, TextSize = 20, Color = Theme.TabIdle,
            XAlign = Enum.TextXAlignment.Center, ZIndex = 3,
        })
    end

    tab.Tooltip = library:Label(button, name, {
        Color = Theme.TextDim, TextSize = 10,
        XAlign = Enum.TextXAlignment.Center, YAlign = Enum.TextYAlignment.Bottom,
        Position = UDim2.new(0, 0, 1, -4), Size = UDim2.new(1, 0, 0, 12), ZIndex = 3,
    })

    ---------------------------------------------------------------
    -- Page. One per tab; the roll animation slides this.
    ---------------------------------------------------------------
    tab.Page = Util.New("Frame", {
        Name = "Page" .. index, BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), Visible = false,
        Parent = self.Content,
    })

    -- Hover tint, evaluated per frame like the original rather than through
    -- MouseEnter, which misses when a popup covers the button.
    local hovered = false
    library:Watch(function(point)
        local isOver = Util.PointInside(button, point) and library.Open
        if isOver ~= hovered then
            hovered = isOver
            tab:_Repaint(hovered)
        end
    end)

    library:Connect(button.MouseButton1Click, function()
        self:SetActiveTab(tab)
    end)

    self.Tabs[index] = tab
    library._tabs[#library._tabs + 1] = tab

    -- Restrip every button now the count changed.
    for position, existing in ipairs(self.Tabs) do
        local slots = #self.Tabs + 1
        existing.Button.Size = UDim2.new(1, 0, 1 / slots, 0)
        existing.Button.Position = UDim2.fromScale(0, (position - 1) / slots)
    end

    if not self.ActiveTab then
        self:SetActiveTab(tab)
    else
        tab:_Repaint(false)
    end

    return tab
end

function Tab:_Repaint(hovered)
    local active = self.Window.ActiveTab == self
    local color
    if active then
        color = Theme.Accent
    elseif hovered then
        color = Util.LerpColor(Theme.TabIdle, Theme.Accent, 0.45)
    else
        color = Theme.TabIdle
    end

    if self.Icon:IsA("ImageLabel") then
        self.Icon.ImageColor3 = color
    else
        self.Icon.TextColor3 = color
    end
    self.Tooltip.TextColor3 = active and Theme.TabActive
                           or (hovered and Theme.TabHover or Theme.TabIdle)

    -- Glow fades with the same 0.10s ramp as kTabGlowDuration.
    local target = active and 1 or 0
    for _, circle in ipairs(self.GlowParts) do
        TweenService:Create(
            circle,
            TweenInfo.new(Metrics.TabGlowTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { BackgroundTransparency = 1 - (0.043 * target * Library.MenuAlpha) }
        ):Play()
    end
end

function Window:SetActiveTab(tab)
    if self.ActiveTab == tab then return end

    local library = self.Library
    library:CloseAllPopups()

    local previous = self.ActiveTab
    self.ActiveTab = tab

    if previous then
        previous.Page.Visible = false
        previous:_Repaint(false)
    end
    tab.Page.Visible = true
    tab:_Repaint(false)
    tab:Layout()

    -- Roll: the page enters from above or below depending on travel direction,
    -- quad-out over kRollDuration. BeginMain() computes the same sign.
    if previous then
        local direction = (tab.Index > previous.Index) and 1 or -1
        tab.Page.Position = UDim2.fromOffset(0, direction * Metrics.MenuH)
        TweenService:Create(
            tab.Page,
            TweenInfo.new(Metrics.RollDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { Position = UDim2.new() }
        ):Play()
    else
        tab.Page.Position = UDim2.new()
    end
end

---------------------------------------------------------------------------------
-- GROUPBOXES
--
-- Two placement modes:
--
--   AddGroupbox(name, { X = 6, Y = 0, W = 3, H = 10 })
--       exact grid placement, the way the original's pages are written.
--
--   AddLeftGroupbox(name) / AddRightGroupbox(name)
--       Linoria-style stacking. Boxes in a column share its height by weight,
--       so adding a third box reflows the first two instead of overflowing.
---------------------------------------------------------------------------------
local Groupbox = {}
Groupbox.__index = Groupbox

function Tab:AddGroupbox(name, grid)
    local box = self:_NewGroupbox(name)
    box.Grid = grid or { X = 0, Y = 0, W = 3, H = 10 }
    self:Layout()
    return box
end

function Tab:AddLeftGroupbox(name, weight)
    local box = self:_NewGroupbox(name)
    box.Column = "Left"
    box.Weight = weight or 1
    local column = self.Columns.Left
    column[#column + 1] = box
    self:Layout()
    return box
end

function Tab:AddRightGroupbox(name, weight)
    local box = self:_NewGroupbox(name)
    box.Column = "Right"
    box.Weight = weight or 1
    local column = self.Columns.Right
    column[#column + 1] = box
    self:Layout()
    return box
end

function Tab:Layout()
    local window = self.Window

    for _, box in ipairs(self.Groupboxes) do
        if box.Grid then
            local x, y, w, h = window:GridRect(box.Grid.X, box.Grid.Y, box.Grid.W, box.Grid.H)
            box:SetRect(x, y, w, h)
        end
    end

    -- Columns use grid X 0 and 6 (width 3 each), matching how the original lays
    -- out a two-panel page, then split that column's height by weight.
    for side, column in pairs(self.Columns) do
        if #column > 0 then
            local gridX = (side == "Left") and 0 or 6
            local x, y, w, h = window:GridRect(gridX, 0, 3, Metrics.GridStepsY)

            local total = 0
            for _, box in ipairs(column) do total = total + box.Weight end

            local gaps = (#column - 1) * Metrics.BoxGap
            local usable = h - gaps
            local cursor = y

            for _, box in ipairs(column) do
                local boxHeight = usable * (box.Weight / total)
                box:SetRect(x, cursor, w, boxHeight)
                cursor = cursor + boxHeight + Metrics.BoxGap
            end
        end
    end
end

function Tab:_NewGroupbox(name)
    local library = self.Library

    local box = setmetatable({
        Library = library,
        Tab     = self,
        Name    = name,
        Weight  = 1,
        Cursor  = 0,       -- y offset of the next widget, in content pixels
        Widgets = {},
    }, Groupbox)

    local frame = Util.New("Frame", {
        Name = "Groupbox", BorderSizePixel = 0, Size = UDim2.fromOffset(100, 100),
        Parent = self.Page,
    })
    box.Frame = frame
    library:RegisterGlass(frame, Theme.Panel, "Panel", 0.4)

    ---------------------------------------------------------------
    -- Notched border. DrawChildBorderAndTitle draws two rings, the
    -- inner one accented while resizing, each with a gap in the top
    -- edge from x=10 to x=16+titleWidth for the title to sit in.
    ---------------------------------------------------------------
    local titleWidth = (name and name ~= "")
        and Util.TextWidth(name, library.BoldFont, library.FontSize)
        or 0
    local gapStart = 10
    local gapEnd   = (name and name ~= "") and (16 + titleWidth) or 10

    local function edge(position, size, zindex)
        return library:RegisterOutline(Util.New("Frame", {
            BorderSizePixel = 0, Position = position, Size = size,
            ZIndex = zindex, Parent = frame,
        }))
    end

    -- Outer ring.
    edge(UDim2.new(),            UDim2.new(0, 1, 1, 0),  10)
    edge(UDim2.new(1, -1, 0, 0), UDim2.new(0, 1, 1, 0),  10)
    edge(UDim2.new(0, 0, 1, -1), UDim2.new(1, 0, 0, 1),  10)
    edge(UDim2.new(),            UDim2.fromOffset(gapStart, 1), 10)
    box.TopEdgeOuter = edge(UDim2.fromOffset(gapEnd, 0), UDim2.new(1, -gapEnd, 0, 1), 10)

    -- Inner ring, inset 1px.
    edge(UDim2.fromOffset(1, 1),  UDim2.new(0, 1, 1, -2), 10)
    edge(UDim2.new(1, -2, 0, 1),  UDim2.new(0, 1, 1, -2), 10)
    edge(UDim2.new(0, 1, 1, -2),  UDim2.new(1, -2, 0, 1), 10)
    edge(UDim2.fromOffset(1, 1),  UDim2.fromOffset(gapStart - 1, 1), 10)
    box.TopEdgeInner = edge(UDim2.fromOffset(gapEnd, 1), UDim2.new(1, -gapEnd - 1, 0, 1), 10)

    if name and name ~= "" then
        -- The title straddles the top edge: y = -fontSize * 0.5.
        box.TitleLabel = library:ShadowedLabel(frame, name, {
            Bold = true, Color = Theme.Text,
            Position = UDim2.fromOffset(13, -math.floor(library.FontSize * 0.5)),
            Size = UDim2.fromOffset(titleWidth + 6, library.FontSize + 4),
            ZIndex = 12,
        })
    end

    ---------------------------------------------------------------
    -- Scrolling content. EndChild() hand-rolls a 6px track with a
    -- 4px thumb in gray40/gray65; a styled ScrollingFrame lands on
    -- the same pixels.
    ---------------------------------------------------------------
    box.Content = Util.New("ScrollingFrame", {
        Name = "Content", BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(Metrics.BoxPadX, Metrics.BoxPadY),
        Size = UDim2.new(1, -(Metrics.BoxPadX + Metrics.BoxPadR - 6), 1, -(Metrics.BoxPadY + 6)),
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = Metrics.ScrollW - 2,
        ScrollBarImageColor3 = Theme.Scroll,
        ScrollBarImageTransparency = 0.3,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        ClipsDescendants = true, ZIndex = 2,
        Parent = frame,
    })

    self.Groupboxes[#self.Groupboxes + 1] = box
    return box
end

function Groupbox:SetRect(x, y, w, h)
    self.Frame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
    self.Frame.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
end

-- ContentWidth() in the original: clamp(panelW - 90, 63, 202). Widgets that span
-- the box (sliders, combos, buttons, listboxes) all use this.
function Groupbox:ContentWidth()
    local width = self.Frame.AbsoluteSize.X
    if width <= 0 then width = 258 end
    return Util.Clamp(width - 90, 63, 202)
end

-- AddItem(): advance the cursor by the row height plus the standard spacing, or
-- the tighter combo spacing. Returns the y the row was placed at.
function Groupbox:AddItem(height, comboSpacing)
    local y = self.Cursor
    self.Cursor = y + height + (comboSpacing and Metrics.ComboSpacing or Metrics.ItemSpacingY)
    return y
end

function Groupbox:_Row(height, comboSpacing)
    local y = self:AddItem(height, comboSpacing)
    local row = Util.New("Frame", {
        Name = "Row", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, y),
        Size = UDim2.new(1, 0, 0, height),
        Parent = self.Content,
    })
    return row, y
end

---------------------------------------------------------------------------------
-- WIDGET: LABEL
---------------------------------------------------------------------------------
function Groupbox:AddLabel(text, options)
    options = options or {}
    if type(options) == "boolean" then options = { Special = options } end

    local library = self.Library
    local height = options.Wrapped and (library.FontSize * 3) or (library.FontSize + 2)
    local row = self:_Row(height)

    local label = library:Label(row, text, {
        Color = options.Special and Theme.TextSpecial or Theme.Text,
        Wrapped = options.Wrapped,
        Position = UDim2.fromOffset(Metrics.Gutter, 0),
        Size = UDim2.new(1, -(Metrics.Gutter + Metrics.BoxPadR), 1, 0),
        YAlign = options.Wrapped and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
    })

    local object = {
        Type = "Label", Row = row, Label = label,
        SetText = function(_, value) label.Text = tostring(value) end,
        SetVisible = function(_, visible) row.Visible = visible and true or false end,
    }
    self.Widgets[#self.Widgets + 1] = object
    return object
end

function Groupbox:AddDivider()
    local library = self.Library
    local row = self:_Row(5)
    library:RegisterOutline(Util.New("Frame", {
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(Metrics.Gutter, 2),
        Size = UDim2.new(1, -(Metrics.Gutter * 2 + 4), 0, 1),
        Parent = row,
    }))
    return { Type = "Divider", Row = row }
end

---------------------------------------------------------------------------------
-- WIDGET: BUTTON
--
-- 25px tall, vertical gradient per state, double border, centred label with a
-- 1px shadow. `Confirm = true` makes the first press arm it and the second fire,
-- which is what menuConfirmations gates in the original.
---------------------------------------------------------------------------------
function Groupbox:AddButton(options, func)
    -- Accept AddButton("Text", fn) as well as AddButton({ Text =, Func = }).
    if type(options) == "string" then
        options = { Text = options, Func = func }
    end
    options = options or {}

    local library = self.Library
    local height = options.Height or Metrics.ButtonH
    local row = self:_Row(height + 5)

    local button = Util.New("TextButton", {
        Name = "Button", Text = "", AutoButtonColor = false, BorderSizePixel = 0,
        BackgroundColor3 = Color3.new(1, 1, 1),
        Position = UDim2.fromOffset(Metrics.Gutter, 0),
        Size = UDim2.new(0, self:ContentWidth(), 0, height),
        Parent = row,
    })
    library:RegisterGlass(button, nil, "Widget", 1)
    local gradient = Util.Gradient(button, Theme.BtnIdle[1], Theme.BtnIdle[2])

    -- Two rings, as in the original (widgetBorder then border 1px inside).
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = button })
    library:RegisterOutline(Util.New("Frame", {
        BorderSizePixel = 0, Position = UDim2.fromOffset(1, 1),
        Size = UDim2.new(1, -2, 0, 1), Parent = button,
    }))

    local label, labelShadow = library:ShadowedLabel(button, options.Text or "Button", {
        Color = Theme.Text, XAlign = Enum.TextXAlignment.Center, ZIndex = 3,
    })

    -- Both halves of the shadowed pair have to move together or the confirm
    -- state leaves the old text showing one pixel down and to the right.
    local function setLabel(text)
        label.Text = text
        labelShadow.Text = text
    end

    local object = { Type = "Button", Row = row, Button = button, Label = label }
    local armed = false

    local hovered, held = false, false
    local function repaint()
        if held then
            Util.SetGradient(gradient, Theme.BtnHeld)
        elseif hovered then
            Util.SetGradient(gradient, Theme.BtnHover)
        else
            Util.SetGradient(gradient, Theme.BtnIdle)
        end
    end

    library:Watch(function(point)
        local isOver = Util.PointInside(button, point)
        if isOver ~= hovered then
            hovered = isOver
            if not isOver then held = false end
            repaint()
        end
    end)

    library:Connect(button.MouseButton1Down, function()
        held = true; repaint()
    end)
    library:Connect(button.MouseButton1Up, function()
        held = false; repaint()
    end)

    library:Connect(button.MouseButton1Click, function()
        if library:AnyPopupOpen() then return end

        if options.Confirm and not armed then
            armed = true
            setLabel("are you sure?")
            task.delay(2, function()
                if armed and label and label.Parent then
                    armed = false
                    setLabel(options.Text or "Button")
                end
            end)
            return
        end

        armed = false
        setLabel(options.Text or "Button")
        if options.Func then
            local ok, err = pcall(options.Func)
            if not ok then
                library:Notify("button error: " .. tostring(err), 6, "uilib")
            end
        end
    end)

    function object:SetText(value)
        options.Text = tostring(value)
        setLabel(options.Text)
    end
    function object:SetVisible(visible)
        row.Visible = visible and true or false
    end

    -- Keeps the button at ContentWidth() as the panel is relaid out.
    library:Watch(function()
        local want = self:ContentWidth()
        if button.Size.X.Offset ~= want then
            button.Size = UDim2.new(0, want, 0, height)
        end
    end)

    self.Widgets[#self.Widgets + 1] = object
    return object
end

---------------------------------------------------------------------------------
-- WIDGET: TOGGLE
--
-- DrawCheckbox: 14px row, an 8x8 box at the left margin (outside the text
-- column), accent-filled when on and a vertical grey gradient otherwise. The
-- whole 150px row is the hit target, not just the box.
---------------------------------------------------------------------------------
-- The public AddToggle is defined further down, once the addon constructors it
-- has to attach exist. This is the widget itself.
function Groupbox:_CreateToggle(index, options)
    options = options or {}
    local library = self.Library
    local row = self:_Row(Metrics.RowH)

    -- The whole row is the hit target, not just the 8px box (DrawCheckbox tests
    -- a 150px rect). The right 70px are left out so clicking a keybind button or
    -- a colour swatch on this row does not also flip the toggle.
    local hit = Util.New("TextButton", {
        Name = "Hit", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(1, -70, 1, 0), ZIndex = 2,
        Parent = row,
    })

    local boxY = math.floor((Metrics.RowH - Metrics.CheckSize) * 0.5)
    local outer = Util.New("Frame", {
        Name = "Box", BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, boxY),
        Size = UDim2.fromOffset(Metrics.CheckSize, Metrics.CheckSize), ZIndex = 3,
        Parent = row,
    })
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = outer })

    local fill = Util.New("Frame", {
        Name = "Fill", BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1),
        Position = UDim2.fromOffset(1, 1),
        Size = UDim2.fromOffset(Metrics.CheckSize - 2, Metrics.CheckSize - 2), ZIndex = 4,
        Parent = outer,
    })
    local fillGradient = Util.Gradient(fill, Theme.ChkIdle[1], Theme.ChkIdle[2])

    local label = library:Label(row, options.Text or index, {
        Color = options.Risky and Theme.TextSpecial or Theme.Text,
        Position = UDim2.fromOffset(Metrics.Gutter, 0),
        Size = UDim2.new(1, -(Metrics.Gutter + Metrics.BoxPadR), 1, 0),
        ZIndex = 3,
    })

    local toggle = {
        Type       = "Toggle",
        Index      = index,
        Text       = options.Text or index,
        Value      = options.Default and true or false,
        Row        = row,
        Groupbox   = self,
        Library    = library,
        Callbacks  = {},
        Addons     = {},
        _hovered   = false,
    }

    if options.Callback then toggle.Callbacks[1] = options.Callback end

    function toggle:_Repaint()
        if self.Value then
            fill.BackgroundTransparency = 0
            fill.BackgroundColor3 = Theme.Accent
            fillGradient.Enabled = false
        else
            fillGradient.Enabled = true
            Util.SetGradient(fillGradient, self._hovered and Theme.ChkHover or Theme.ChkIdle)
            fill.BackgroundColor3 = Color3.new(1, 1, 1)
            fill.BackgroundTransparency = Util.Clamp(
                1 - library.Glass.Widget * library.MenuAlpha * 3.5, 0, 1
            )
        end
        label.TextColor3 = (options.Risky and Theme.TextSpecial)
            or (self.Value and Color3.fromRGB(205, 205, 205))
            or (self._hovered and Color3.fromRGB(190, 190, 190) or Theme.Text)
    end

    function toggle:SetValue(value, silent)
        self.Value = value and true or false
        self:_Repaint()
        if silent then return end
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, self.Value)
        end
    end

    function toggle:SetValueSilent(value)
        self:SetValue(value, true)
    end

    function toggle:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function toggle:SetVisible(visible)
        row.Visible = visible and true or false
    end

    function toggle:SetText(value)
        self.Text = tostring(value)
        label.Text = self.Text
    end

    library:Watch(function(point)
        local isOver = Util.PointInside(hit, point)
        if isOver ~= toggle._hovered then
            toggle._hovered = isOver
            toggle:_Repaint()
        end
    end)

    library:Connect(hit.MouseButton1Click, function()
        if library:AnyPopupOpen() then return end
        toggle:SetValue(not toggle.Value)
    end)

    toggle:_Repaint()

    library.Toggles[index] = toggle
    self.Widgets[#self.Widgets + 1] = toggle
    return toggle
end

---------------------------------------------------------------------------------
-- WIDGET: SLIDER
--
-- Label above, a 6px track below it, accent fill, bold value text riding the
-- fill edge, and -/+ steppers either side. Dragging anywhere on the track jumps
-- to that position (the original has no grab offset) and the arrow keys nudge
-- while hovered.
---------------------------------------------------------------------------------
function Groupbox:AddSlider(index, options)
    options = options or {}
    local library = self.Library

    local minimum  = options.Min or 0
    local maximum  = options.Max or 100
    local rounding = options.Rounding or 0
    local step     = options.Step or (rounding > 0 and 10 ^ -rounding or 1)
    local suffix   = options.Suffix or ""
    local prefix   = options.Prefix or ""
    local hasLabel = options.Text ~= nil and options.Text ~= ""

    local labelH = hasLabel and (library.FontSize + 1) or 0
    local row = self:_Row(labelH + 12)

    if hasLabel then
        library:Label(row, options.Text, {
            Color = Theme.Text,
            Position = UDim2.fromOffset(Metrics.Gutter, 0),
            Size = UDim2.new(1, -(Metrics.Gutter + Metrics.BoxPadR), 0, labelH),
        })
    end

    local width = self:ContentWidth()

    -- The track's own border is drawn as a filled rect under the interior, which
    -- is a UIStroke here.
    local track = Util.New("Frame", {
        Name = "Track", BorderSizePixel = 0, BackgroundColor3 = Theme.SldTrack,
        Position = UDim2.fromOffset(Metrics.Gutter, labelH + 4),
        Size = UDim2.fromOffset(width, Metrics.SliderH),
        ZIndex = 2, Parent = row,
    })
    library:RegisterGlass(track, Theme.SldTrack, "Widget", 3.5)
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = track })

    local fill = library:RegisterAccent(Util.New("Frame", {
        Name = "Fill", BorderSizePixel = 0,
        Position = UDim2.fromOffset(1, 1),
        Size = UDim2.new(0, 0, 1, -2), ZIndex = 3,
        Parent = track,
    }), "BackgroundColor3")

    local valueLabel = library:Label(track, "", {
        Bold = true, Color = Theme.TextBright,
        XAlign = Enum.TextXAlignment.Center,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(90, library.FontSize + 2), ZIndex = 6,
    })
    valueLabel.TextTransparency = 0.1

    local function stepper(text, atRight)
        local button = Util.New("TextButton", {
            Name = "Step", Text = text, AutoButtonColor = false,
            BackgroundTransparency = 1, BorderSizePixel = 0,
            Font = library.Font, TextSize = 10, TextColor3 = Color3.fromRGB(120, 120, 120),
            Position = atRight
                and UDim2.fromOffset(Metrics.Gutter + width + 1, labelH + 1)
                or  UDim2.fromOffset(Metrics.Gutter - 10, labelH + 1),
            Size = UDim2.fromOffset(10, 12), ZIndex = 4,
            Parent = row,
        })
        return button
    end

    local minus = stepper("-", false)
    local plus  = stepper("+", true)

    local slider = {
        Type      = "Slider",
        Index     = index,
        Text      = options.Text or index,
        Min       = minimum,
        Max       = maximum,
        Value     = Util.Clamp(options.Default or minimum, minimum, maximum),
        Row       = row,
        Library   = library,
        Callbacks = {},
        _hovered  = false,
        _dragging = false,
    }

    if options.Callback then slider.Callbacks[1] = options.Callback end

    local function format(value)
        local text
        if rounding > 0 then
            text = string.format("%." .. rounding .. "f", value)
        else
            text = tostring(math.floor(value + 0.5))
        end
        return prefix .. text .. suffix
    end

    function slider:_Repaint()
        local alpha = (self.Max > self.Min)
            and ((self.Value - self.Min) / (self.Max - self.Min))
            or 0
        local interior = track.AbsoluteSize.X - 2
        if interior <= 0 then interior = width - 2 end
        local fillWidth = interior * alpha

        fill.Size = UDim2.new(0, math.floor(fillWidth), 1, -2)
        valueLabel.Text = format(self.Value)
        valueLabel.Position = UDim2.fromOffset(1 + fillWidth, Metrics.SliderH * 0.5)
        track.BackgroundColor3 = (self._hovered or self._dragging)
            and Theme.SldTrackHov or Theme.SldTrack
    end

    function slider:SetValue(value, silent)
        value = Util.Clamp(value, self.Min, self.Max)
        if rounding > 0 then
            value = Util.Round(value, rounding)
        else
            value = math.floor(value + 0.5)
        end
        self.Value = value
        self:_Repaint()
        if silent then return end
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, self.Value)
        end
    end

    function slider:SetValueSilent(value) self:SetValue(value, true) end

    function slider:SetMin(value)
        self.Min = value
        self:SetValue(self.Value)
    end

    function slider:SetMax(value)
        self.Max = value
        self:SetValue(self.Value)
    end

    function slider:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function slider:SetVisible(visible) row.Visible = visible and true or false end

    local function valueFromPoint(point)
        local left = track.AbsolutePosition.X
        local span = math.max(track.AbsoluteSize.X - 1, 1)
        local alpha = Util.Clamp((point.X - left) / span, 0, 1)
        return slider.Min + alpha * (slider.Max - slider.Min)
    end

    library:Connect(track.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        if library:AnyPopupOpen() then return end
        slider._dragging = true
        slider:SetValue(valueFromPoint(UserInputService:GetMouseLocation()
            - Vector2.new(0, library._guiInset)))
    end)

    library:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 and slider._dragging then
            slider._dragging = false
            slider:_Repaint()
        end
    end)

    library:Watch(function(point)
        local isOver = Util.PointInside(track, point)
        if isOver ~= slider._hovered then
            slider._hovered = isOver
            slider:_Repaint()
        end
        if slider._dragging then
            slider:SetValue(valueFromPoint(point))
        end
    end)

    library:Connect(minus.MouseButton1Click, function()
        slider:SetValue(slider.Value - step)
    end)
    library:Connect(plus.MouseButton1Click, function()
        slider:SetValue(slider.Value + step)
    end)

    -- Arrow keys while hovered, as in the original.
    library:Connect(UserInputService.InputBegan, function(input, processed)
        if processed or not slider._hovered or not library.Open then return end
        if input.KeyCode == Enum.KeyCode.Left then
            slider:SetValue(slider.Value - step)
        elseif input.KeyCode == Enum.KeyCode.Right then
            slider:SetValue(slider.Value + step)
        end
    end)

    -- Relayout on panel resize.
    library:Watch(function()
        local want = self:ContentWidth()
        if track.Size.X.Offset ~= want then
            track.Size = UDim2.fromOffset(want, Metrics.SliderH)
            plus.Position = UDim2.fromOffset(Metrics.Gutter + want + 1, labelH + 1)
            slider:_Repaint()
        end
    end)

    slider:_Repaint()
    library.Options[index] = slider
    self.Widgets[#self.Widgets + 1] = slider
    return slider
end

---------------------------------------------------------------------------------
-- WIDGET: DROPDOWN
--
-- SingleSelect / MultiSelect. The popup is parented to the popup layer rather
-- than to the frame that opened it, which is the retained-mode equivalent of
-- RenderPendingPopups() deferring it to the foreground draw list.
---------------------------------------------------------------------------------
function Groupbox:AddDropdown(index, options)
    options = options or {}
    local library = self.Library

    local multi    = options.Multi and true or false
    local values   = options.Values or {}
    local hasLabel = options.Text ~= nil and options.Text ~= ""
    local labelH   = hasLabel and (library.FontSize + 1) or 0
    local row = self:_Row(labelH + 4 + Metrics.ComboH, true)

    if hasLabel then
        library:Label(row, options.Text, {
            Color = Theme.Text,
            Position = UDim2.fromOffset(Metrics.Gutter, 0),
            Size = UDim2.new(1, -(Metrics.Gutter + Metrics.BoxPadR), 0, labelH),
        })
    end

    local width = self:ContentWidth()

    local frame = Util.New("TextButton", {
        Name = "Combo", Text = "", AutoButtonColor = false, BorderSizePixel = 0,
        BackgroundColor3 = Color3.new(1, 1, 1),
        Position = UDim2.fromOffset(Metrics.Gutter, labelH + 4),
        Size = UDim2.fromOffset(width, Metrics.ComboH), ZIndex = 2,
        Parent = row,
    })
    library:RegisterGlass(frame, nil, "Widget", 1)
    local gradient = Util.Gradient(frame, Theme.ComboIdle[1], Theme.ComboIdle[2])
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = frame })

    local preview = library:Label(frame, "", {
        Color = Theme.ComboPreview, Truncate = true,
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -24, 1, 0), ZIndex = 3,
    })

    -- The arrow: a line plus AddTriangleFilled in the original. Built from four
    -- stacked 1px rows rather than a glyph, because Enum.Font.Code has no
    -- guaranteed triangle character and a missing glyph renders as a box.
    local arrow = Util.New("Frame", {
        Name = "Arrow", BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(1, -9, 0.5, 1),
        Size = UDim2.fromOffset(7, 4), ZIndex = 3, Parent = frame,
    })
    for step = 0, 3 do
        Util.New("Frame", {
            BackgroundColor3 = Theme.ComboPreview, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, step),
            Size = UDim2.fromOffset(7 - step * 2, 1), ZIndex = 3, Parent = arrow,
        })
    end

    local dropdown = {
        Type      = "Dropdown",
        Index     = index,
        Text      = options.Text or index,
        Multi     = multi,
        Values    = values,
        Value     = multi and {} or nil,
        IsOpen    = false,
        Row       = row,
        Library   = library,
        Callbacks = {},
        _hovered  = false,
        _rows     = {},
    }

    if options.Callback then dropdown.Callbacks[1] = options.Callback end

    ---------------------------------------------------------------
    -- Popup
    ---------------------------------------------------------------
    local popup = Util.New("Frame", {
        Name = "DropdownPopup", BorderSizePixel = 0, BackgroundColor3 = Theme.Panel,
        Visible = false, ZIndex = 50, ClipsDescendants = false,
        Parent = library.PopupLayer,
    })
    library:RegisterGlass(popup, Theme.Panel, "Popup", 1)
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = popup })

    local popupList = Util.New("ScrollingFrame", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2),
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Scroll,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ElasticBehavior = Enum.ElasticBehavior.Never, ZIndex = 51,
        Parent = popup,
    }, {
        Util.New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    function dropdown:_PreviewText()
        if self.Multi then
            local parts = {}
            for _, value in ipairs(self.Values) do
                if self.Value[value] then parts[#parts + 1] = tostring(value) end
            end
            if #parts == 0 then return "None" end
            local text = table.concat(parts, ", ")
            if #text > 56 then text = string.sub(text, 1, 56) .. "..." end
            return text
        end
        if self.Value == nil then return options.Placeholder or "---" end
        return tostring(self.Value)
    end

    function dropdown:_RebuildRows()
        for _, existing in ipairs(self._rows) do
            existing.Frame:Destroy()
        end
        self._rows = {}

        local rowHeight = Metrics.ListRowH - 2
        for order, value in ipairs(self.Values) do
            local entry = Util.New("TextButton", {
                Name = "Option", Text = "", AutoButtonColor = false,
                BackgroundColor3 = Theme.RowHover, BackgroundTransparency = 1,
                BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, rowHeight),
                LayoutOrder = order, ZIndex = 52, Parent = popupList,
            })

            local text = library:Label(entry, tostring(value), {
                Color = Theme.Text,
                Position = UDim2.fromOffset(10, 0),
                Size = UDim2.new(1, -14, 1, 0), ZIndex = 53,
            })

            local record = { Frame = entry, Label = text, Value = value }
            self._rows[#self._rows + 1] = record

            library:Connect(entry.MouseEnter, function()
                entry.BackgroundTransparency = Util.Clamp(
                    1 - library.Glass.Widget * library.MenuAlpha * 3, 0, 1
                )
            end)
            library:Connect(entry.MouseLeave, function()
                entry.BackgroundTransparency = 1
            end)

            library:Connect(entry.MouseButton1Click, function()
                if self.Multi then
                    self.Value[value] = (not self.Value[value]) or nil
                    self:_Repaint()
                    self:_Fire()
                else
                    self:SetValue(value)
                    self:Close()
                end
            end)
        end

        self:_Repaint()
    end

    function dropdown:_Repaint()
        preview.Text = self:_PreviewText()
        for _, record in ipairs(self._rows) do
            local selected
            if self.Multi then
                selected = self.Value[record.Value] and true or false
            else
                selected = self.Value == record.Value
            end
            record.Label.TextColor3 = selected and Theme.Accent or Theme.Text
        end
        Util.SetGradient(gradient,
            (self._hovered or self.IsOpen) and Theme.ComboHover or Theme.ComboIdle)
    end

    function dropdown:_Fire()
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, self.Value)
        end
    end

    function dropdown:SetValue(value, silent)
        if self.Multi then
            local set = {}
            if type(value) == "table" then
                -- Accept both {Item = true} and {"Item", "Other"}.
                local isArray = value[1] ~= nil
                if isArray then
                    for _, item in ipairs(value) do set[item] = true end
                else
                    for item, on in pairs(value) do
                        if on then set[item] = true end
                    end
                end
            end
            self.Value = set
        else
            if type(value) == "number" and self.Values[value] ~= nil then
                value = self.Values[value]
            end
            self.Value = value
        end
        self:_Repaint()
        if not silent then self:_Fire() end
    end

    function dropdown:SetValueSilent(value) self:SetValue(value, true) end

    function dropdown:SetValues(newValues, keep)
        self.Values = newValues or {}
        if not keep then
            if self.Multi then
                self.Value = {}
            else
                local stillThere = false
                for _, value in ipairs(self.Values) do
                    if value == self.Value then
                        stillThere = true
                        break
                    end
                end
                if not stillThere then self.Value = self.Values[1] end
            end
        end
        self:_RebuildRows()
        if self.IsOpen then self:_Position() end
    end

    function dropdown:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function dropdown:SetVisible(visible)
        row.Visible = visible and true or false
        if not visible then self:Close() end
    end

    function dropdown:_Position()
        local rowHeight = Metrics.ListRowH - 2
        local shown = math.min(#self.Values, options.MaxVisible or 8)
        local height = math.max(shown * rowHeight + 2, rowHeight + 2)

        local origin = frame.AbsolutePosition
        local below = origin.Y + frame.AbsoluteSize.Y + 1
        -- Flip above the frame when there is no room below, so a dropdown at the
        -- bottom of a panel is still usable.
        local viewport = library.ScreenGui.AbsoluteSize.Y
        if below + height > viewport and origin.Y - height - 1 > 0 then
            below = origin.Y - height - 1
        end

        popup.Position = UDim2.fromOffset(origin.X, below)
        popup.Size = UDim2.fromOffset(frame.AbsoluteSize.X, height)
    end

    function dropdown:Open()
        library:CloseAllPopups(self)
        self.IsOpen = true
        self:_Position()
        popup.Visible = true
        self:_Repaint()
    end

    function dropdown:Close()
        self.IsOpen = false
        popup.Visible = false
        self:_Repaint()
    end

    function dropdown:HitTest(point)
        return Util.PointInside(popup, point) or Util.PointInside(frame, point)
    end

    library:RegisterPopup(dropdown)

    library:Watch(function(point)
        local isOver = Util.PointInside(frame, point)
        if isOver ~= dropdown._hovered then
            dropdown._hovered = isOver
            dropdown:_Repaint()
        end
        -- The panel scrolls and the window drags, so an open popup has to follow
        -- the frame rather than being positioned once.
        if dropdown.IsOpen then dropdown:_Position() end
    end)

    library:Connect(frame.MouseButton1Click, function()
        if dropdown.IsOpen then
            dropdown:Close()
        else
            dropdown:Open()
        end
    end)

    library:Watch(function()
        local want = self:ContentWidth()
        if frame.Size.X.Offset ~= want then
            frame.Size = UDim2.fromOffset(want, Metrics.ComboH)
        end
    end)

    dropdown:_RebuildRows()
    if options.Default ~= nil then
        dropdown:SetValue(options.Default, true)
    elseif not multi then
        dropdown.Value = nil
        dropdown:_Repaint()
    end

    library.Options[index] = dropdown
    self.Widgets[#self.Widgets + 1] = dropdown
    return dropdown
end

---------------------------------------------------------------------------------
-- WIDGET: LISTBOX
--
-- Always-open list of fixed 20px rows; the selected row gets the hover fill and
-- accent text, as in listbox.cpp.
---------------------------------------------------------------------------------
function Groupbox:AddListbox(index, options)
    options = options or {}
    local library = self.Library

    local values = options.Values or {}
    local rows = options.Rows or math.max(#values, 3)
    local height = rows * Metrics.ListRowH + 2
    local row = self:_Row(height, true)

    local box = Util.New("Frame", {
        Name = "Listbox", BorderSizePixel = 0, BackgroundColor3 = Color3.fromRGB(17, 17, 18),
        Position = UDim2.fromOffset(Metrics.Gutter, 0),
        Size = UDim2.fromOffset(self:ContentWidth(), height),
        ZIndex = 2, Parent = row,
    })
    library:RegisterGlass(box, Color3.fromRGB(17, 17, 18), "Widget", 0.82)
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = box })

    local scroller = Util.New("ScrollingFrame", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(1, 1), Size = UDim2.new(1, -2, 1, -2),
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Scroll,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ElasticBehavior = Enum.ElasticBehavior.Never, ZIndex = 3,
        Parent = box,
    }, {
        Util.New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
    })

    local listbox = {
        Type      = "Listbox",
        Index     = index,
        Text      = options.Text or index,
        Values    = values,
        Value     = nil,
        Row       = row,
        Library   = library,
        Callbacks = {},
        _rows     = {},
    }

    if options.Callback then listbox.Callbacks[1] = options.Callback end

    function listbox:_Rebuild()
        for _, record in ipairs(self._rows) do record.Frame:Destroy() end
        self._rows = {}

        for order, value in ipairs(self.Values) do
            local entry = Util.New("TextButton", {
                Name = "Row", Text = "", AutoButtonColor = false,
                BackgroundColor3 = Theme.RowHover, BackgroundTransparency = 1,
                BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, Metrics.ListRowH - 2),
                LayoutOrder = order, ZIndex = 4, Parent = scroller,
            })
            local text = library:Label(entry, tostring(value), {
                Color = Theme.Text, Position = UDim2.fromOffset(10, 0),
                Size = UDim2.new(1, -14, 1, 0), ZIndex = 5,
            })

            local record = { Frame = entry, Label = text, Value = value }
            self._rows[#self._rows + 1] = record

            library:Connect(entry.MouseEnter, function()
                if self.Value ~= value then
                    entry.BackgroundTransparency = Util.Clamp(
                        1 - library.Glass.Widget * library.MenuAlpha * 3, 0, 1
                    )
                end
            end)
            library:Connect(entry.MouseLeave, function()
                if self.Value ~= value then entry.BackgroundTransparency = 1 end
            end)
            library:Connect(entry.MouseButton1Click, function()
                if library:AnyPopupOpen() then return end
                self:SetValue(value)
            end)
        end
        self:_Repaint()
    end

    function listbox:_Repaint()
        for _, record in ipairs(self._rows) do
            local selected = self.Value == record.Value
            record.Label.TextColor3 = selected and Theme.Accent or Theme.Text
            record.Frame.BackgroundTransparency = selected
                and Util.Clamp(1 - library.Glass.Widget * library.MenuAlpha * 3, 0, 1)
                or 1
        end
    end

    function listbox:SetValue(value, silent)
        if type(value) == "number" and self.Values[value] ~= nil then
            value = self.Values[value]
        end
        self.Value = value
        self:_Repaint()
        if silent then return end
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, self.Value)
        end
    end

    function listbox:SetValueSilent(value) self:SetValue(value, true) end

    function listbox:SetValues(newValues, keep)
        self.Values = newValues or {}
        if not keep then
            local stillThere = false
            for _, value in ipairs(self.Values) do
                if value == self.Value then
                    stillThere = true
                    break
                end
            end
            if not stillThere then self.Value = nil end
        end
        self:_Rebuild()
    end

    function listbox:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function listbox:SetVisible(visible) row.Visible = visible and true or false end

    library:Watch(function()
        local want = self:ContentWidth()
        if box.Size.X.Offset ~= want then
            box.Size = UDim2.fromOffset(want, height)
        end
    end)

    listbox:_Rebuild()
    if options.Default ~= nil then listbox:SetValue(options.Default, true) end

    library.Options[index] = listbox
    self.Widgets[#self.Widgets + 1] = listbox
    return listbox
end

---------------------------------------------------------------------------------
-- WIDGET: INPUT
--
-- The original hand-rolls caret, selection and a per-character "ghost" rise
-- animation. A TextBox gets the first two for free from the engine; the ghosts
-- are per-character Instances in Roblox and are not worth it.
---------------------------------------------------------------------------------
function Groupbox:AddInput(index, options)
    options = options or {}
    local library = self.Library

    local hasLabel = options.Text ~= nil and options.Text ~= ""
    local labelH = hasLabel and (library.FontSize + 1) or 0
    local row = self:_Row(labelH + 4 + Metrics.ComboH, true)

    if hasLabel then
        library:Label(row, options.Text, {
            Color = Theme.Text,
            Position = UDim2.fromOffset(Metrics.Gutter, 0),
            Size = UDim2.new(1, -(Metrics.Gutter + Metrics.BoxPadR), 0, labelH),
        })
    end

    local frame = Util.New("Frame", {
        Name = "Input", BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1),
        Position = UDim2.fromOffset(Metrics.Gutter, labelH + 4),
        Size = UDim2.fromOffset(self:ContentWidth(), Metrics.ComboH),
        ZIndex = 2, Parent = row,
    })
    library:RegisterGlass(frame, nil, "Widget", 1)
    Util.Gradient(frame, Theme.ComboIdle[1], Theme.ComboIdle[2])
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = frame })

    local textbox = Util.New("TextBox", {
        Name = "Box", BackgroundTransparency = 1, BorderSizePixel = 0,
        ClearTextOnFocus = false, Text = options.Default or "",
        PlaceholderText = options.Placeholder or "",
        PlaceholderColor3 = Theme.TextDim,
        Font = library.Font, TextSize = library.FontSize, TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -14, 1, 0), ZIndex = 3,
        Parent = frame,
    })

    local input = {
        Type      = "Input",
        Index     = index,
        Text      = options.Text or index,
        Value     = options.Default or "",
        Row       = row,
        Library   = library,
        Callbacks = {},
    }

    if options.Callback then input.Callbacks[1] = options.Callback end

    function input:_Fire()
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, self.Value)
        end
    end

    function input:SetValue(value, silent)
        value = tostring(value or "")
        if options.MaxLength and #value > options.MaxLength then
            value = string.sub(value, 1, options.MaxLength)
        end
        if options.Numeric then
            value = string.gsub(value, "[^%d%.%-]", "")
        end
        self.Value = value
        if textbox.Text ~= value then textbox.Text = value end
        if not silent then self:_Fire() end
    end

    function input:SetValueSilent(value) self:SetValue(value, true) end

    function input:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function input:SetVisible(visible) row.Visible = visible and true or false end

    -- `Finished = true` fires only on Enter / focus loss, which is what a path or
    -- a name field wants; otherwise every keystroke fires.
    if options.Finished then
        library:Connect(textbox.FocusLost, function(enterPressed)
            if enterPressed or options.FireOnBlur ~= false then
                input:SetValue(textbox.Text)
            else
                textbox.Text = input.Value
            end
        end)
    else
        library:Connect(textbox:GetPropertyChangedSignal("Text"), function()
            input:SetValue(textbox.Text)
        end)
    end

    library:Watch(function()
        local want = self:ContentWidth()
        if frame.Size.X.Offset ~= want then
            frame.Size = UDim2.fromOffset(want, Metrics.ComboH)
        end
    end)

    library.Options[index] = input
    self.Widgets[#self.Widgets + 1] = input
    return input
end

---------------------------------------------------------------------------------
-- ADDON: KEY PICKER
--
-- DrawKeybindButton: a 26x11 [KEY] button right-aligned at PanelRightX(). The
-- original's binds all behave as "press to toggle"; the three Linoria modes are
-- added because scripts expect them:
--
--   Always - on whenever the parent toggle is on
--   Toggle - each press flips it
--   Hold   - on only while the key is held
--
-- Right-clicking the button cycles the mode, which is how you change it without
-- a context menu.
---------------------------------------------------------------------------------
-- `rightOffset` is how far in from the row's right edge the widget sits, in
-- pixels. The row spans the scrolling content frame, whose right edge is already
-- 6px left of PanelRightX(), so an offset of 6 lands exactly where the original
-- puts its keybind button and 26 / 46 reproduce the two-swatch spacing in
-- visuals.cpp (PanelRightX()-17 and -37).
local ROW_RIGHT_BASE = 6

local function CreateKeyPicker(groupbox, parentRow, index, options, parentToggle, rightOffset)
    options = options or {}
    local library = groupbox.Library

    local button = Util.New("TextButton", {
        Name = "KeyPicker", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -(rightOffset or ROW_RIGHT_BASE), 0.5, 0),
        Size = UDim2.fromOffset(Metrics.KeyBtnW, Metrics.KeyBtnH),
        ZIndex = 6, Parent = parentRow,
    })

    local label = library:Label(button, "[-]", {
        TextSize = Metrics.KeyBtnFont, Color = Color3.fromRGB(160, 160, 160),
        XAlign = Enum.TextXAlignment.Center, ZIndex = 7,
    })

    local picker = {
        Type        = "KeyPicker",
        Index       = index,
        Text        = options.Text or (parentToggle and parentToggle.Text) or index,
        Value       = options.Default or "",
        Mode        = options.Mode or "Toggle",
        Active      = false,
        ShowInList  = options.NoUI ~= true,
        SyncToggle  = options.SyncToggleState and true or false,
        Parent      = parentToggle,
        Library     = library,
        Callbacks   = {},
        _capturing  = false,
    }

    if options.Callback then picker.Callbacks[1] = options.Callback end

    function picker:_Repaint()
        if self._capturing then
            label.Text = "[...]"
            label.TextColor3 = Color3.fromRGB(220, 220, 220)
        elseif self.Value == "" then
            label.Text = "[-]"
            label.TextColor3 = Color3.fromRGB(160, 160, 160)
        else
            label.Text = "[" .. Util.KeyLabel(self.Value) .. "]"
            label.TextColor3 = self:GetState()
                and Theme.Accent
                or Color3.fromRGB(160, 160, 160)
        end
    end

    function picker:SetCapturing(state)
        self._capturing = state and true or false
        self:_Repaint()
    end

    -- GetState is the question the script actually asks: "should the feature this
    -- bind guards be acting right now".
    function picker:GetState()
        if self.Value == "" then
            -- No key bound: defer entirely to the parent toggle, so an unbound
            -- picker never gates a feature off.
            return self.Parent and self.Parent.Value or true
        end
        if self.Mode == "Always" then
            return self.Parent and self.Parent.Value or true
        end
        if self.Mode == "Hold" then
            return Util.IsKeyDown(self.Value)
        end
        return self.Active
    end

    function picker:_Fire()
        local state = self:GetState()
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, state, self.Value, self.Mode)
        end
        if self.SyncToggle and self.Parent then
            self.Parent:SetValue(state)
        end
        self:_Repaint()
    end

    function picker:OnPressed()
        if self.Mode == "Toggle" then
            self.Active = not self.Active
            self:_Fire()
        elseif self.Mode == "Hold" then
            self:_Fire()
        end
    end

    function picker:OnReleased()
        if self.Mode == "Hold" then
            self:_Fire()
        end
    end

    function picker:SetValue(key, silent)
        self.Value = key or ""
        self.Active = false
        self:_Repaint()
        if not silent then self:_Fire() end
    end

    function picker:SetValueSilent(key) self:SetValue(key, true) end

    function picker:SetMode(mode, silent)
        self.Mode = mode or "Toggle"
        self.Active = false
        self:_Repaint()
        if not silent then self:_Fire() end
    end

    function picker:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self:GetState(), self.Value, self.Mode)
        return self
    end

    function picker:SetVisible(visible) button.Visible = visible and true or false end

    function picker:SetRowOffset(offset)
        button.Position = UDim2.new(1, -offset, 0.5, 0)
    end

    library:Connect(button.MouseButton1Click, function()
        if library._capturing == picker then
            library:_StopCapture()
        else
            library:_StopCapture()
            library:_StartCapture(picker)
        end
    end)

    library:Connect(button.MouseButton2Click, function()
        local order = { "Always", "Toggle", "Hold" }
        local current = table.find(order, picker.Mode) or 2
        picker:SetMode(order[(current % #order) + 1])
        library:Notify(picker.Text .. " keybind mode: " .. picker.Mode, 2)
    end)

    -- Hold mode has no press/release event while the key is already down at the
    -- time the mode changes, and the HUD needs the live state anyway.
    library:Watch(function()
        local state = picker:GetState()
        if state ~= picker._lastState then
            picker._lastState = state
            picker:_Repaint()
        end
    end)

    picker:_Repaint()
    library._keybinds[#library._keybinds + 1] = picker
    library.Options[index] = picker
    return picker
end

function Groupbox:AddKeyPicker(index, options)
    options = options or {}
    local row = self:_Row(Metrics.RowH)
    self.Library:Label(row, options.Text or index, {
        Color = Theme.Text,
        Position = UDim2.fromOffset(Metrics.Gutter, 0),
        Size = UDim2.new(1, -(Metrics.Gutter + 40), 1, 0),
    })
    local picker = CreateKeyPicker(self, row, index, options, nil, ROW_RIGHT_BASE)
    self.Widgets[#self.Widgets + 1] = picker
    return picker
end

---------------------------------------------------------------------------------
-- ADDON: COLOR PICKER
--
-- ColorButton: a 16x10 swatch over a checkerboard (so alpha reads), opening an
-- HSV popup anchored 160px to its left. The popup is the original's layout:
-- 150x140 SV square, 12px hue strip beside it, then alpha and preview bars.
---------------------------------------------------------------------------------
local function CreateColorPicker(groupbox, parentRow, index, options, rightOffset)
    options = options or {}
    local library = groupbox.Library

    local swatch = Util.New("TextButton", {
        Name = "ColorPicker", Text = "", AutoButtonColor = false, BorderSizePixel = 0,
        BackgroundColor3 = options.Default or Color3.new(1, 1, 1),
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -(rightOffset or ROW_RIGHT_BASE), 0.5, 0),
        Size = UDim2.fromOffset(Metrics.SwatchW, Metrics.SwatchH),
        ZIndex = 6, Parent = parentRow,
    })
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = swatch })

    -- Light-over-dark overlay: drawGradientV(white 30 -> black 30) on top of the
    -- colour, which is what gives the swatch its slight sheen.
    Util.New("Frame", {
        BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.88,
        BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 7, Parent = swatch,
    }, { Util.New("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.88),
            NumberSequenceKeypoint.new(1, 1),
        }),
    }) })

    local picker = {
        Type       = "ColorPicker",
        Index      = index,
        Text       = options.Text or index,
        Value      = options.Default or Color3.new(1, 1, 1),
        Transparency = options.Transparency or 0,
        HasAlpha   = options.Transparency ~= nil,
        IsOpen     = false,
        Library    = library,
        Callbacks  = {},
    }

    if options.Callback then picker.Callbacks[1] = options.Callback end

    picker.Hue, picker.Sat, picker.Val = picker.Value:ToHSV()

    ---------------------------------------------------------------
    -- Popup
    ---------------------------------------------------------------
    local SV_W, SV_H, HUE_W, BAR_H, GAP, PAD = 150, 140, 12, 10, 4, 5
    local popWidth  = PAD + SV_W + GAP + HUE_W + PAD
    local popHeight = PAD + SV_H + GAP + BAR_H + GAP + BAR_H + PAD

    local popup = Util.New("Frame", {
        Name = "ColorPopup", BorderSizePixel = 0, BackgroundColor3 = Theme.Panel,
        Size = UDim2.fromOffset(popWidth, popHeight),
        Visible = false, ZIndex = 60, Parent = library.PopupLayer,
    })
    library:RegisterGlass(popup, Theme.Panel, "Popup", 1)
    Util.New("UIStroke", { Color = Theme.Outline, Thickness = 1, Parent = popup })

    -- SV square: white-to-hue horizontally, transparent-to-black vertically.
    -- Exactly the two AddRectFilledMultiColor calls in the original.
    local svArea = Util.New("Frame", {
        Name = "SV", BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1),
        Position = UDim2.fromOffset(PAD, PAD),
        Size = UDim2.fromOffset(SV_W, SV_H), ZIndex = 61, Parent = popup,
    })
    local svHue = Util.New("UIGradient", {
        Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHSV(0, 1, 1)),
        Parent = svArea,
    })
    Util.New("Frame", {
        BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), ZIndex = 62, Parent = svArea,
    }, { Util.New("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(1, 0),
        }),
    }) })

    local svCursor = Util.New("Frame", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(8, 8), ZIndex = 64, Parent = svArea,
    }, {
        Util.New("UICorner", { CornerRadius = UDim.new(1, 0) }),
        Util.New("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 1.5, Transparency = 0.2 }),
    })

    -- Hue strip: six segments in the original, one 7-keypoint gradient here.
    local hueStrip = Util.New("Frame", {
        Name = "Hue", BorderSizePixel = 0, BackgroundColor3 = Color3.new(1, 1, 1),
        Position = UDim2.fromOffset(PAD + SV_W + GAP, PAD),
        Size = UDim2.fromOffset(HUE_W, SV_H), ZIndex = 61, Parent = popup,
    }, {
        Util.New("UIGradient", {
            Rotation = 90,
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0.000, Color3.fromHSV(0 / 6, 1, 1)),
                ColorSequenceKeypoint.new(0.167, Color3.fromHSV(1 / 6, 1, 1)),
                ColorSequenceKeypoint.new(0.333, Color3.fromHSV(2 / 6, 1, 1)),
                ColorSequenceKeypoint.new(0.500, Color3.fromHSV(3 / 6, 1, 1)),
                ColorSequenceKeypoint.new(0.667, Color3.fromHSV(4 / 6, 1, 1)),
                ColorSequenceKeypoint.new(0.833, Color3.fromHSV(5 / 6, 1, 1)),
                ColorSequenceKeypoint.new(1.000, Color3.fromHSV(1, 1, 1)),
            }),
        }),
    })

    local hueCursor = Util.New("Frame", {
        BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.1,
        BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.new(1, 0, 0, 2), ZIndex = 63, Parent = hueStrip,
    })

    -- Alpha bar: the colour ramping from fully transparent on the left to opaque
    -- on the right, over a flat mid-grey. The original lays a checkerboard
    -- behind it; grey reads the same at 10px tall and costs one Frame instead of
    -- the ~40 a 4px checker would need.
    local alphaBar, alphaRamp, alphaCursor
    if picker.HasAlpha then
        alphaBar = Util.New("Frame", {
            Name = "Alpha", BorderSizePixel = 0, BackgroundColor3 = Color3.fromRGB(128, 128, 128),
            Position = UDim2.fromOffset(PAD, PAD + SV_H + GAP),
            Size = UDim2.fromOffset(SV_W, BAR_H), ZIndex = 61, Parent = popup,
        })
        alphaRamp = Util.New("Frame", {
            Name = "Ramp", BackgroundColor3 = picker.Value, BorderSizePixel = 0,
            Size = UDim2.fromScale(1, 1), ZIndex = 62, Parent = alphaBar,
        }, { Util.New("UIGradient", {
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1),
                NumberSequenceKeypoint.new(1, 0),
            }),
        }) })
        alphaCursor = Util.New("Frame", {
            BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.new(0, 2, 1, 0),
            ZIndex = 63, Parent = alphaBar,
        })
    end

    local previewBar = Util.New("Frame", {
        Name = "Preview", BorderSizePixel = 0, BackgroundColor3 = picker.Value,
        Position = UDim2.fromOffset(PAD, popHeight - PAD - BAR_H),
        Size = UDim2.fromOffset(SV_W + GAP + HUE_W, BAR_H), ZIndex = 61, Parent = popup,
    })

    -- Not in the original, but typing a hex is the one thing an HSV square is bad
    -- at. Stroked, because it sits on top of the preview swatch and would be
    -- unreadable against a light colour otherwise.
    local hexBox = Util.New("TextBox", {
        Name = "Hex", BackgroundTransparency = 1, BorderSizePixel = 0,
        ClearTextOnFocus = false, Font = library.Font, TextSize = 10,
        TextColor3 = Color3.fromRGB(240, 240, 240), Text = "",
        TextStrokeColor3 = Color3.new(0, 0, 0), TextStrokeTransparency = 0.4,
        TextXAlignment = Enum.TextXAlignment.Center,
        Size = UDim2.fromScale(1, 1), ZIndex = 62, Parent = previewBar,
    })

    function picker:_Repaint()
        self.Value = Color3.fromHSV(self.Hue, self.Sat, self.Val)
        swatch.BackgroundColor3 = self.Value
        swatch.BackgroundTransparency = self.HasAlpha and self.Transparency or 0

        svHue.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHSV(self.Hue, 1, 1))
        svCursor.Position = UDim2.fromScale(self.Sat, 1 - self.Val)
        hueCursor.Position = UDim2.fromScale(0, self.Hue)
        previewBar.BackgroundColor3 = self.Value

        if alphaCursor then
            alphaRamp.BackgroundColor3 = self.Value
            alphaCursor.Position = UDim2.fromScale(1 - self.Transparency, 0)
        end

        if not hexBox:IsFocused() then
            hexBox.Text = string.format("#%02X%02X%02X",
                math.floor(self.Value.R * 255 + 0.5),
                math.floor(self.Value.G * 255 + 0.5),
                math.floor(self.Value.B * 255 + 0.5))
        end
    end

    function picker:_Fire()
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, self.Value, self.Transparency)
        end
    end

    function picker:SetValue(color, transparency, silent)
        if typeof(color) == "Color3" then
            self.Hue, self.Sat, self.Val = color:ToHSV()
        end
        if transparency ~= nil then self.Transparency = Util.Clamp(transparency, 0, 1) end
        self:_Repaint()
        if not silent then self:_Fire() end
    end

    function picker:SetValueSilent(color, transparency)
        self:SetValue(color, transparency, true)
    end

    function picker:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value, self.Transparency)
        return self
    end

    function picker:SetVisible(visible) swatch.Visible = visible and true or false end

    function picker:SetRowOffset(offset)
        swatch.Position = UDim2.new(1, -offset, 0.5, 0)
    end

    function picker:Open()
        library:CloseAllPopups(self)
        self.IsOpen = true
        -- anchorPos = (bb.Min.x - 160, bb.Max.y + 3) in the original. Clamped so
        -- a swatch near a screen edge still shows the whole popup.
        local origin = swatch.AbsolutePosition
        local viewport = library.ScreenGui.AbsoluteSize
        local x = Util.Clamp(origin.X - 160, 4, math.max(viewport.X - popWidth - 4, 4))
        local y = origin.Y + swatch.AbsoluteSize.Y + 3
        if y + popHeight > viewport.Y then
            y = math.max(origin.Y - popHeight - 3, 4)
        end
        popup.Position = UDim2.fromOffset(x, y)
        popup.Visible = true
        self:_Repaint()
    end

    function picker:Close()
        self.IsOpen = false
        popup.Visible = false
    end

    function picker:HitTest(point)
        return Util.PointInside(popup, point) or Util.PointInside(swatch, point)
    end

    library:RegisterPopup(picker)

    library:Connect(swatch.MouseButton1Click, function()
        if picker.IsOpen then picker:Close() else picker:Open() end
    end)

    ---------------------------------------------------------------
    -- Dragging the three regions. One shared drag target rather
    -- than three connection sets, so there is no way to end up
    -- dragging two at once.
    ---------------------------------------------------------------
    local dragTarget = nil

    local function beginDrag(target)
        return function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
            dragTarget = target
        end
    end

    library:Connect(svArea.InputBegan, beginDrag("sv"))
    library:Connect(hueStrip.InputBegan, beginDrag("hue"))
    if alphaBar then
        library:Connect(alphaBar.InputBegan, beginDrag("alpha"))
    end

    library:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 and dragTarget then
            dragTarget = nil
            picker:_Fire()
        end
    end)

    library:Watch(function(point)
        if not dragTarget or not picker.IsOpen then return end

        if dragTarget == "sv" then
            local pos, size = svArea.AbsolutePosition, svArea.AbsoluteSize
            picker.Sat = Util.Clamp((point.X - pos.X) / size.X, 0, 1)
            picker.Val = 1 - Util.Clamp((point.Y - pos.Y) / size.Y, 0, 1)
        elseif dragTarget == "hue" then
            local pos, size = hueStrip.AbsolutePosition, hueStrip.AbsoluteSize
            picker.Hue = Util.Clamp((point.Y - pos.Y) / size.Y, 0, 1)
        elseif dragTarget == "alpha" and alphaBar then
            local pos, size = alphaBar.AbsolutePosition, alphaBar.AbsoluteSize
            picker.Transparency = 1 - Util.Clamp((point.X - pos.X) / size.X, 0, 1)
        end

        picker:_Repaint()
        picker:_Fire()
    end)

    library:Connect(hexBox.FocusLost, function()
        local hex = string.gsub(hexBox.Text, "#", "")
        if #hex == 6 then
            local r = tonumber(string.sub(hex, 1, 2), 16)
            local g = tonumber(string.sub(hex, 3, 4), 16)
            local b = tonumber(string.sub(hex, 5, 6), 16)
            if r and g and b then
                picker:SetValue(Color3.fromRGB(r, g, b))
                return
            end
        end
        picker:_Repaint()
    end)

    picker:_Repaint()
    library.Options[index] = picker
    return picker
end

function Groupbox:AddColorPicker(index, options)
    options = options or {}
    local row = self:_Row(Metrics.RowH)
    self.Library:Label(row, options.Text or index, {
        Color = Theme.Text,
        Position = UDim2.fromOffset(Metrics.Gutter, 0),
        Size = UDim2.new(1, -(Metrics.Gutter + 40), 1, 0),
    })
    local picker = CreateColorPicker(self, row, index, options, ROW_RIGHT_BASE)
    self.Widgets[#self.Widgets + 1] = picker
    return picker
end

---------------------------------------------------------------------------------
-- TOGGLE ADDONS
--
-- Chainable, so a feature and its bind and its colour read as one statement:
--
--   Box:AddToggle("Boxes", { Text = "Boxes" })
--      :AddColorPicker("BoxColor", { Default = Color3.new(1,1,1) })
--      :AddKeyPicker("BoxKey", { Mode = "Toggle" })
--
-- Multiple colour pickers on one row step leftward by swatch width, matching how
-- visuals.cpp places its two bbox swatches at PanelRightX()-37 and -17.
---------------------------------------------------------------------------------
-- Addons fill the row's right edge from the outside in: the keybind button
-- (26px) always takes the outermost slot, then each swatch (16px) steps a
-- further 20px inward, which is the spacing visuals.cpp uses for its two stacked
-- bbox swatches at PanelRightX()-17 and -37.
--
-- Recomputed from scratch on every attach rather than assigned once, because the
-- chain can be written in either order:
--
--   :AddColorPicker(...):AddKeyPicker(...)
--   :AddKeyPicker(...):AddColorPicker(...)
--
-- and in the first the swatch is created before the keybind exists to be given
-- room for.
local function RelayoutAddons(toggle)
    local offset = ROW_RIGHT_BASE

    if toggle.KeyPicker then
        toggle.KeyPicker:SetRowOffset(offset)
        offset = offset + Metrics.KeyBtnW + 4
    end

    for _, addon in ipairs(toggle.Addons) do
        if addon.Type == "ColorPicker" then
            addon:SetRowOffset(offset)
            offset = offset + Metrics.SwatchW + 4
        end
    end
end

local function AttachKeyPicker(self, index, options)
    options = options or {}
    options.Text = options.Text or self.Text
    local picker = CreateKeyPicker(self.Groupbox, self.Row, index, options, self, ROW_RIGHT_BASE)
    self.Addons[#self.Addons + 1] = picker
    self.KeyPicker = picker
    RelayoutAddons(self)
    return self
end

local function AttachColorPicker(self, index, options)
    local picker = CreateColorPicker(self.Groupbox, self.Row, index, options, ROW_RIGHT_BASE)
    self.Addons[#self.Addons + 1] = picker
    self.ColorPicker = self.ColorPicker or picker
    RelayoutAddons(self)
    return self
end

-- The real AddToggle: build the widget, then hand it the two chainable addon
-- methods. Split this way because the addon constructors are locals declared
-- after the toggle widget, and a toggle has to be able to attach them.
function Groupbox:AddToggle(index, options)
    local toggle = self:_CreateToggle(index, options)
    toggle.AddKeyPicker   = AttachKeyPicker
    toggle.AddColorPicker = AttachColorPicker
    return toggle
end

---------------------------------------------------------------------------------
-- SAVE MANAGER
--
-- Folder layout:
--   <Folder>/
--     settings/autoload.txt     name of the config to load on execute
--     configs/<name>.json       one file per config
--
-- A config stores every registered Toggle and Option by index, so adding a
-- widget later is backwards compatible: unknown keys in the file are ignored and
-- missing keys keep their defaults.
---------------------------------------------------------------------------------
local SaveManager = {}
SaveManager.__index = SaveManager

function Library:CreateSaveManager(config)
    config = config or {}
    local folder = config.Folder or "uilib"
    if config.SubFolder then
        folder = folder .. "/" .. config.SubFolder
    end

    local manager = setmetatable({
        Library    = self,
        Folder     = folder,
        Ignore     = {},
        Parser     = {},
    }, SaveManager)

    for _, ignored in ipairs(config.Ignore or {}) do
        manager.Ignore[ignored] = true
    end

    fs.MakeFolder(folder)
    fs.MakeFolder(folder .. "/configs")
    fs.MakeFolder(folder .. "/settings")

    self.SaveManager = manager
    return manager
end

function SaveManager:SetIgnoreIndexes(list)
    for _, index in ipairs(list or {}) do
        self.Ignore[index] = true
    end
end

function SaveManager:ConfigPath(name)
    return self.Folder .. "/configs/" .. name .. ".json"
end

function SaveManager:AutoloadPath()
    return self.Folder .. "/settings/autoload.txt"
end

-- Each option type serialises to a plain table so JSONEncode never sees a
-- Color3 or an Enum, which it cannot represent.
function SaveManager:Serialize()
    local data = { Toggles = {}, Options = {} }
    local library = self.Library

    for index, toggle in pairs(library.Toggles) do
        if not self.Ignore[index] then
            data.Toggles[index] = toggle.Value
        end
    end

    for index, option in pairs(library.Options) do
        if not self.Ignore[index] then
            if option.Type == "Slider" then
                data.Options[index] = { type = "Slider", value = option.Value }
            elseif option.Type == "Dropdown" then
                if option.Multi then
                    local selected = {}
                    for value, on in pairs(option.Value or {}) do
                        if on then selected[#selected + 1] = value end
                    end
                    data.Options[index] = { type = "MultiDropdown", value = selected }
                else
                    data.Options[index] = { type = "Dropdown", value = option.Value }
                end
            elseif option.Type == "Listbox" then
                data.Options[index] = { type = "Listbox", value = option.Value }
            elseif option.Type == "Input" then
                data.Options[index] = { type = "Input", value = option.Value }
            elseif option.Type == "KeyPicker" then
                data.Options[index] = { type = "KeyPicker", key = option.Value, mode = option.Mode }
            elseif option.Type == "ColorPicker" then
                data.Options[index] = {
                    type = "ColorPicker",
                    r = math.floor(option.Value.R * 255 + 0.5),
                    g = math.floor(option.Value.G * 255 + 0.5),
                    b = math.floor(option.Value.B * 255 + 0.5),
                    a = option.Transparency,
                }
            end
        end
    end

    return data
end

function SaveManager:Deserialize(data)
    if type(data) ~= "table" then return false, "malformed config" end
    local library = self.Library

    for index, value in pairs(data.Toggles or {}) do
        local toggle = library.Toggles[index]
        if toggle and not self.Ignore[index] then
            toggle:SetValue(value and true or false)
        end
    end

    for index, record in pairs(data.Options or {}) do
        local option = library.Options[index]
        if option and not self.Ignore[index] and type(record) == "table" then
            if option.Type == "ColorPicker" then
                option:SetValue(
                    Color3.fromRGB(record.r or 255, record.g or 255, record.b or 255),
                    record.a
                )
            elseif option.Type == "KeyPicker" then
                option:SetMode(record.mode or "Toggle", true)
                option:SetValue(record.key or "")
            elseif option.Type == "Dropdown" and option.Multi then
                option:SetValue(record.value or {})
            else
                option:SetValue(record.value)
            end
        end
    end

    return true
end

function SaveManager:Save(name)
    if not name or name == "" then return false, "no config name" end

    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(self:Serialize())
    end)
    if not ok then return false, "encode failed" end

    local written = fs.Write(self:ConfigPath(name), encoded)
    if not written then return false, "write failed" end
    return true
end

function SaveManager:Load(name)
    if not name or name == "" then return false, "no config name" end

    local contents = fs.Read(self:ConfigPath(name))
    if not contents then return false, "config does not exist" end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(contents)
    end)
    if not ok then return false, "decode failed" end

    return self:Deserialize(decoded)
end

function SaveManager:Delete(name)
    if not name or name == "" then return false, "no config name" end
    if not fs.IsFile(self:ConfigPath(name)) then return false, "config does not exist" end
    fs.Delete(self:ConfigPath(name))
    return true
end

function SaveManager:List()
    local names = {}
    for _, path in ipairs(fs.List(self.Folder .. "/configs")) do
        local name = string.match(path, "([^/\\]+)%.json$")
        if name then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

function SaveManager:SetAutoload(name)
    if name and name ~= "" then
        fs.Write(self:AutoloadPath(), name)
    else
        fs.Delete(self:AutoloadPath())
    end
end

function SaveManager:GetAutoload()
    local contents = fs.Read(self:AutoloadPath())
    if not contents then return nil end
    local name = string.gsub(contents, "%s", "")
    if name == "" then return nil end
    return name
end

function SaveManager:LoadAutoloadConfig()
    local name = self:GetAutoload()
    if not name then return false end

    local ok, err = self:Load(name)
    if ok then
        self.Library:Notify('auto loaded config "' .. name .. '"', 4)
    else
        self.Library:Notify("autoload failed: " .. tostring(err), 6)
    end
    if self._autoloadLabel then
        self._autoloadLabel:SetText("current autoload: " .. name)
    end
    return ok
end

---------------------------------------------------------------------------------
-- SAVE MANAGER UI
--
-- Builds the config page the original's config.cpp sketches: a list of presets,
-- a name box, and load / save / delete / refresh buttons, plus the menu settings
-- that page also owns (menu key, accent, opacity sliders).
---------------------------------------------------------------------------------
function SaveManager:BuildConfigSection(tab, options)
    options = options or {}
    local library = self.Library

    local left  = tab:AddLeftGroupbox("Configs")
    local right = tab:AddRightGroupbox("Menu")

    local list = left:AddListbox("ConfigList", {
        Values = self:List(), Rows = 6,
    })
    local nameBox = left:AddInput("ConfigName", {
        Placeholder = "config name", Finished = true,
    })

    -- The list and the name box drive each other: clicking a preset fills the
    -- box, so Save overwrites the selected one rather than silently creating a
    -- near-duplicate.
    list:OnChanged(function(value)
        if value then nameBox:SetValueSilent(value) end
    end)

    local function refresh()
        list:SetValues(self:List(), true)
    end

    left:AddButton({ Text = "Create / Save", Func = function()
        local name = nameBox.Value
        local ok, err = self:Save(name)
        if ok then
            refresh()
            library:Notify('saved config "' .. name .. '"', 3)
        else
            library:Notify("save failed: " .. tostring(err), 5)
        end
    end })

    left:AddButton({ Text = "Load", Func = function()
        local name = list.Value or nameBox.Value
        local ok, err = self:Load(name)
        if ok then
            library:Notify('loaded config "' .. tostring(name) .. '"', 3)
        else
            library:Notify("load failed: " .. tostring(err), 5)
        end
    end })

    left:AddButton({ Text = "Delete", Confirm = true, Func = function()
        local name = list.Value or nameBox.Value
        local ok, err = self:Delete(name)
        if ok then
            refresh()
            library:Notify('deleted config "' .. tostring(name) .. '"', 3)
        else
            library:Notify("delete failed: " .. tostring(err), 5)
        end
    end })

    left:AddButton({ Text = "Refresh list", Func = function()
        refresh()
        library:Notify("config list refreshed", 2)
    end })

    left:AddDivider()

    self._autoloadLabel = left:AddLabel("current autoload: none")

    left:AddButton({ Text = "Set as autoload", Func = function()
        local name = list.Value or nameBox.Value
        if not name or name == "" then
            library:Notify("select a config first", 3)
            return
        end
        self:SetAutoload(name)
        self._autoloadLabel:SetText("current autoload: " .. name)
        library:Notify('"' .. name .. '" will load on execute', 3)
    end })

    left:AddButton({ Text = "Clear autoload", Func = function()
        self:SetAutoload(nil)
        self._autoloadLabel:SetText("current autoload: none")
        library:Notify("autoload cleared", 3)
    end })

    local current = self:GetAutoload()
    if current then
        self._autoloadLabel:SetText("current autoload: " .. current)
    end

    ---------------------------------------------------------------
    -- Menu settings (the right half of the original's config page)
    ---------------------------------------------------------------
    if options.NoMenuSection then return self end

    local menuKeys = { "Insert", "RightShift", "RightControl", "F1", "F2", "F4", "End" }
    right:AddDropdown("MenuKey", {
        Text = "Menu key", Values = menuKeys, Default = "Insert",
        Callback = function(value)
            local code = Enum.KeyCode[value]
            if code then library.MenuKey = code end
        end,
    })

    right:AddColorPicker("MenuAccent", {
        Text = "Menu accent", Default = Theme.Accent,
        Callback = function(color) library:SetAccent(color) end,
    })

    right:AddToggle("MenuKeybindList", {
        Text = "Show keybind list",
        Callback = function(value) library:SetKeybindListVisible(value) end,
    })

    right:AddToggle("MenuWatermark", {
        Text = "Show watermark", Default = true,
        Callback = function(value) library:SetWatermarkVisible(value) end,
    })

    right:AddDivider()
    right:AddLabel("Glass tuning")

    right:AddSlider("MenuAlpha", {
        Text = "Menu opacity", Default = 100, Min = 10, Max = 100, Suffix = "%",
        Callback = function(value)
            library.MenuAlpha = value / 100
            library:Refresh()
        end,
    })

    for _, spec in ipairs({
        { Index = "GlassWindow", Text = "Board opacity",  Key = "Window", Default = 20 },
        { Index = "GlassPanel",  Text = "Panel opacity",  Key = "Panel",  Default = 50 },
        { Index = "GlassWidget", Text = "Widget opacity", Key = "Widget", Default = 22 },
        { Index = "GlassPopup",  Text = "Popup opacity",  Key = "Popup",  Default = 50 },
    }) do
        right:AddSlider(spec.Index, {
            Text = spec.Text, Default = spec.Default, Min = 0, Max = 100, Suffix = "%",
            Callback = function(value)
                library.Glass[spec.Key] = value / 100
                library:Refresh()
            end,
        })
    end

    right:AddSlider("OutlineAlpha", {
        Text = "Outline alpha", Default = 60, Min = 0, Max = 255,
        Callback = function(value)
            library.OutlineAlpha = value / 255
            library:Refresh()
        end,
    })

    right:AddDivider()
    right:AddButton({ Text = "Unload script", Confirm = true, Func = function()
        library:Unload()
    end })

    -- The menu's own settings are not part of a feature config.
    self:SetIgnoreIndexes({
        "MenuKey", "MenuAccent", "MenuKeybindList", "MenuWatermark", "MenuAlpha",
        "GlassWindow", "GlassPanel", "GlassWidget", "GlassPopup", "OutlineAlpha",
        "ConfigList", "ConfigName",
    })

    return self
end

---------------------------------------------------------------------------------
-- EXPORT
---------------------------------------------------------------------------------
Library.SaveManagerClass = SaveManager
Library.WindowClass      = Window
Library.TabClass         = Tab
Library.GroupboxClass    = Groupbox
Library.FS               = fs

return Library
