--[[
    uilib v2 - a clean monochrome Roblox UI library
    ===============================================================================

    A ground-up redesign. v1 was a port of an ImGui cheat menu: 12px bitmap-ish
    text, 8px square checkboxes, sharp notched borders, translucent "glass"
    panels, 4px gutters. Accurate to its source and not nice to look at.

    This shares no visual DNA with it. The design language here is the one modern
    product UI has settled on - Linear, Vercel, Arc - adapted to a strictly
    black / white / grey palette:

      * FLAT, NOT GLASS. One near-black base, cards one step lighter, controls
        one step lighter again. Depth comes from those three steps and a single
        1px low-contrast border, never from transparency.
      * ROUNDED. 14px on the window, 10px on cards, 8px on controls, full radius
        on switches and knobs. This is the single biggest change from v1.
      * AIR. 20px window padding, 14px between cards, 8px between rows, 30px
        toggle rows. v1 packed rows 14px apart; nothing here is tighter than 24.
      * TYPE CARRIES THE HIERARCHY. One family at three weights and three sizes.
        No bold-and-shadowed titles, no coloured labels - a heading is smaller
        and dimmer than its content, which is what makes a dense panel scan.
      * WHITE IS THE ACCENT. In a monochrome palette the only "colour" available
        is contrast, so pure white is reserved for the active state and nothing
        else: a live toggle, a slider's fill, the selected row, a held keybind.
        Everything idle is grey. That constraint is what makes it read as
        designed rather than merely dark.
      * EVERYTHING MOVES. Every state change is a 0.12-0.18s ease-out: the
        switch knob, the tab indicator, hover fills, popups. Nothing snaps.

    API COMPATIBILITY
    -----------------
    The public API is unchanged from v1, deliberately. Private.lua has ~120 call
    sites against it and should not need touching for a reskin. Two notes:

      * AddGroupbox(name, grid) still accepts an ImGui-style {X,Y,W,H} rect, but
        the grid is gone - X picks the column and the rest is ignored. Cards size
        to their content now, which is strictly better than being stretched to
        fill a hand-computed row of a 10x11 grid.
      * The `weight` argument to AddLeftGroupbox / AddRightGroupbox is accepted
        and ignored, for the same reason.

    Layout is a UIListLayout in a scrolling column per side, so cards grow to fit
    their rows and a column scrolls when it runs out of room. v1 computed every
    row's y by hand off a cursor; none of that arithmetic survives.
]]

local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local TextService      = game:GetService("TextService")
local HttpService      = game:GetService("HttpService")
local Players          = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

---------------------------------------------------------------------------------
-- TYPE
--
-- The single biggest reason v1 looked cheap was Enum.Font.Code at 13px. Real
-- weights are only reachable through FontFace, and weight contrast at one size
-- is what replaces v1's bold-and-shadowed titles.
--
-- Family choice, having checked what actually ships:
--
--   Montserrat   default. A geometric sans, confirmed present in
--                rbxasset://fonts/families, and the family Roblox now maps the
--                removed Enum.Font.Gotham* values onto. Clean and unencumbered.
--   BuilderSans  Roblox's own interface face, also confirmed present and nicer
--                at small sizes - but it ships under the Builder Font License,
--                which restricts use outside Roblox experiences. Set
--                Library.Type.Prefer = "BuilderSans" before CreateWindow if you
--                want it.
--
-- Deliberately NOT used: Inter and GothamSSm. Neither is a real
-- rbxasset://fonts/families entry, despite both being widely copy-pasted; a
-- missing family silently renders as a fallback, so hardcoding one would have
-- looked fine on my side and wrong on yours.
--
-- The legacy Enum.Font path is the floor for clients without FontFace. Gotham
-- is tried first but is officially removed, so SourceSans - which has existed
-- since the beginning - is what actually guarantees the menu is never textless.
---------------------------------------------------------------------------------
local Type = {
    Prefer = "Montserrat",
    Family = nil,      -- resolved family asset path, nil when on legacy enums
    Faces  = {},       -- [weightName] = Font | Enum.Font
    Legacy = false,
}

do
    local FAMILIES = {
        Montserrat  = "rbxasset://fonts/families/Montserrat.json",
        BuilderSans = "rbxasset://fonts/families/BuilderSans.json",
    }

    local WEIGHTS = {
        Regular  = Enum.FontWeight.Regular,
        Medium   = Enum.FontWeight.Medium,
        SemiBold = Enum.FontWeight.SemiBold,
        Bold     = Enum.FontWeight.Bold,
    }

    -- Each tier is tried whole: a family missing a weight would otherwise
    -- collapse two tiers into one and flatten the hierarchy.
    --
    -- Construction is the only test, deliberately. Font.new does accept a path
    -- that does not exist, so the obvious guard is to probe a label's
    -- TextBounds - but an unparented TextLabel never renders and reports 0, and
    -- a parented one still reports 0 on the frame it was made, so that probe
    -- fails for a perfectly good family and silently drops the whole library to
    -- the legacy path. Both families below were checked against the engine's
    -- font-family list instead, which is the right place to establish this.
    local function build(family)
        local built = {}
        for name, weight in pairs(WEIGHTS) do
            local ok, face = pcall(function() return Font.new(family, weight) end)
            if not ok or not face then return nil end
            built[name] = face
        end
        return built
    end

    local order = { Type.Prefer, "Montserrat", "BuilderSans" }
    for _, name in ipairs(order) do
        local path = FAMILIES[name]
        if path then
            local built = build(path)
            if built then
                Type.Family, Type.Faces = path, built
                break
            end
        end
    end

    if not Type.Family then
        Type.Legacy = true
        local function face(...)
            for _, name in ipairs({ ... }) do
                local ok, value = pcall(function() return Enum.Font[name] end)
                if ok and value then return value end
            end
            return Enum.Font.SourceSans
        end
        Type.Faces = {
            Regular  = face("Gotham", "SourceSans"),
            Medium   = face("GothamMedium", "SourceSans"),
            SemiBold = face("GothamBold", "SourceSansSemibold", "SourceSansBold"),
            Bold     = face("GothamBlack", "SourceSansBold"),
        }
    end
end

-- One call sets whichever property this client supports. Only FontFace is set
-- on a modern client: the two properties are kept in sync by the engine, and
-- writing both would fight.
function Type.apply(label, weight)
    local face = Type.Faces[weight or "Medium"] or Type.Faces.Medium
    if Type.Legacy then
        label.Font = face
    else
        label.FontFace = face
    end
end

-- There is no synchronous way to measure a FontFace: GetTextSize takes a legacy
-- Enum.Font only and GetTextBoundsAsync yields. So anything that needs to size
-- itself to its text builds the labels first and reads TextBounds on the next
-- frame, which is exact. `measure` exists for that deferred pass.
function Type.measure(labels)
    local widest = 0
    for _, label in ipairs(labels) do
        if label and label.Parent then
            widest = math.max(widest, label.TextBounds.X)
        end
    end
    return widest
end

-- TextBounds is only populated once the label has actually rendered, and
-- task.defer can resume before that happens - so a single deferred read can
-- legitimately come back 0. Retry for a few frames, then give up and let the
-- caller keep its fallback size.
function Type.measureAsync(labels, callback, attempts)
    task.spawn(function()
        for _ = 1, attempts or 6 do
            local widest = Type.measure(labels)
            if widest > 0 then
                callback(widest)
                return
            end
            RunService.RenderStepped:Wait()
        end
    end)
end

---------------------------------------------------------------------------------
-- THEME
--
-- Three greys of elevation, two of border, four of text, and white. That is the
-- entire palette; there is no second hue anywhere in the library.
---------------------------------------------------------------------------------
local Theme = {
    Bg      = Color3.fromRGB(10, 10, 11),    -- window base
    Card    = Color3.fromRGB(16, 16, 19),    -- groupbox
    Control = Color3.fromRGB(23, 23, 27),    -- field / track at rest
    Hover   = Color3.fromRGB(30, 30, 35),    -- field hover, selected row
    Line    = Color3.fromRGB(38, 38, 44),    -- 1px border
    LineHi  = Color3.fromRGB(52, 52, 60),    -- focused / emphasised border

    Text    = Color3.fromRGB(244, 244, 246), -- primary
    Text2   = Color3.fromRGB(154, 154, 162), -- secondary, idle labels
    Text3   = Color3.fromRGB(102, 102, 110), -- tertiary, placeholders, headings
    Text4   = Color3.fromRGB(68, 68, 75),    -- disabled

    Accent  = Color3.fromRGB(255, 255, 255), -- the only "colour"
    OnAccent= Color3.fromRGB(10, 10, 11),    -- text/knob sitting on accent

    -- Kept because notifications read better with a hint of semantics, and both
    -- are near-white so the palette holds.
    Good    = Color3.fromRGB(236, 236, 238),
    Bad     = Color3.fromRGB(255, 120, 120),
}

---------------------------------------------------------------------------------
-- METRICS
---------------------------------------------------------------------------------
local M = {
    WindowW   = 760,
    WindowH   = 540,
    Radius    = 14,

    SidebarW  = 184,
    Pad       = 20,
    ColGap    = 14,

    CardRadius= 10,
    CardPad   = 14,
    CardGap   = 14,
    RowGap    = 8,

    TabH      = 36,
    TabRadius = 8,
    TabGap    = 2,

    RowH      = 30,     -- toggle / keypicker / colorpicker row
    SwitchW   = 36,
    SwitchH   = 20,
    KnobD     = 16,

    SliderH   = 46,     -- label row + track
    TrackH    = 4,
    SliderKnob= 11,

    FieldH    = 34,
    FieldR    = 8,
    ButtonH   = 34,
    ListRowH  = 32,

    ChipH     = 18,
    ChipR     = 5,
    SwatchW   = 28,
    SwatchH   = 16,
    SwatchR   = 5,

    TextSize  = 13,
    TitleSize = 12,
    SmallSize = 11,
}

---------------------------------------------------------------------------------
-- MOTION
--
-- One duration scale and one curve for the whole library. Mixing easings is what
-- makes an interface feel assembled from parts.
---------------------------------------------------------------------------------
local Motion = {
    Fast = 0.12,
    Base = 0.16,
    Slow = 0.24,
}

function Motion.to(inst, props, duration, style)
    local info = TweenInfo.new(
        duration or Motion.Base,
        style or Enum.EasingStyle.Quad,
        Enum.EasingDirection.Out
    )
    local tween = TweenService:Create(inst, info, props)
    tween:Play()
    return tween
end

---------------------------------------------------------------------------------
-- FILESYSTEM SHIM
--
-- Executor file functions are not guaranteed to exist and do not exist in
-- Studio. Everything routes through here so a missing primitive degrades to
-- "configs unavailable" instead of erroring mid-build; memory-backed otherwise,
-- so the save/load UI stays exercisable while developing.
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
    if fs.HasReal then return (pcall(writefile, path, contents)) end
    fs.Memory[path] = contents
    return true
end

function fs.Read(path)
    if fs.HasReal then
        local ok, res = pcall(readfile, path)
        return ok and res or nil
    end
    local v = fs.Memory[path]
    if type(v) == "string" and v ~= "folder" then return v end
    return nil
end

function fs.Delete(path)
    if fs.HasReal and delfile then return (pcall(delfile, path)) end
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
    for key in pairs(fs.Memory) do
        if fs.Memory[key] ~= "folder" and string.sub(key, 1, #path + 1) == path .. "/" then
            out[#out + 1] = key
        end
    end
    return out
end

---------------------------------------------------------------------------------
-- UTIL
---------------------------------------------------------------------------------
local Util = {}

-- Parent is assigned last: setting it first makes every subsequent property
-- write a change to a rendered instance, which is measurably slower across a
-- tree this size.
function Util.New(class, props, children)
    local inst = Instance.new(class)
    local parent
    if props then
        for key, value in pairs(props) do
            if key == "Parent" then
                parent = value
            elseif key == "Weight" then
                Type.apply(inst, value)
            else
                inst[key] = value
            end
        end
    end
    if children then
        for _, child in ipairs(children) do child.Parent = inst end
    end
    if parent then inst.Parent = parent end
    return inst
end

function Util.Corner(parent, radius)
    return Util.New("UICorner", {
        CornerRadius = UDim.new(0, radius or M.FieldR), Parent = parent,
    })
end

function Util.Stroke(parent, color, thickness)
    return Util.New("UIStroke", {
        Color = color or Theme.Line,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end

function Util.Pad(parent, all, top, bottom, left, right)
    return Util.New("UIPadding", {
        PaddingTop    = UDim.new(0, top or all or 0),
        PaddingBottom = UDim.new(0, bottom or all or 0),
        PaddingLeft   = UDim.new(0, left or all or 0),
        PaddingRight  = UDim.new(0, right or all or 0),
        Parent = parent,
    })
end

function Util.List(parent, gap, direction)
    return Util.New("UIListLayout", {
        FillDirection = direction or Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, gap or 0),
        Parent = parent,
    })
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

function Util.Lerp(a, b, t) return a + (b - a) * t end

function Util.PointInside(inst, point)
    if not inst or not inst.Parent or not inst.Visible then return false end
    local pos, size = inst.AbsolutePosition, inst.AbsoluteSize
    return point.X >= pos.X and point.X <= pos.X + size.X
       and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end

-- RichText is used for the keybind rows, so a name containing &, < or > would be
-- parsed as markup. Roblox renders the whole label as raw tags once markup is
-- malformed, so one bracket breaks the panel.
function Util.EscapeRich(text)
    local out = string.gsub(tostring(text), "&", "&amp;")
    out = string.gsub(out, "<", "&lt;")
    out = string.gsub(out, ">", "&gt;")
    return out
end

local KEY_LABELS = {
    LeftShift = "Shift", RightShift = "Shift",
    LeftAlt = "Alt", RightAlt = "Alt",
    LeftControl = "Ctrl", RightControl = "Ctrl",
    Space = "Space", Delete = "Del", Tab = "Tab", CapsLock = "Caps",
    Backspace = "Bksp", Return = "Enter", Escape = "Esc",
    MB1 = "M1", MB2 = "M2", MB3 = "M3",
    Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
    Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
}

-- Mixed case rather than v1's three-letter caps ("SHF", "CTR"): with real type
-- at 11px there is no reason to abbreviate past recognition.
function Util.KeyLabel(key)
    if not key or key == "" then return "—" end
    local mapped = KEY_LABELS[key]
    if mapped then return mapped end
    if #key == 1 then return key end
    if string.match(key, "^F%d+$") then return key end
    return key
end

local MOUSE_TO_KEY = {
    [Enum.UserInputType.MouseButton1] = "MB1",
    [Enum.UserInputType.MouseButton2] = "MB2",
    [Enum.UserInputType.MouseButton3] = "MB3",
}

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
    return code and UserInputService:IsKeyDown(code) or false
end

---------------------------------------------------------------------------------
-- LIBRARY
---------------------------------------------------------------------------------
local Library = {
    Theme   = Theme,
    Metrics = M,
    Util    = Util,
    Type    = Type,
    Motion  = Motion,
    FS      = fs,

    Toggles = {},
    Options = {},

    Unloaded     = false,
    Open         = false,
    MenuKey      = Enum.KeyCode.Insert,
    ShowKeybinds = false,

    -- v1 exposed Glass.* and MenuAlpha because its surfaces were translucent.
    -- This design is flat, so the only global visual knob is overall opacity.
    Opacity = 1,

    _connections = {},
    _renderBinds = {},
    _popups      = {},
    _keybinds    = {},
    _watchers    = {},
    _accent      = {},
    _surfaces    = {},
}
Library.__index = Library

---------------------------------------------------------------------------------
-- LIFETIME
--
-- Nothing is created or connected outside these helpers, which is what makes
-- Unload total rather than best-effort.
---------------------------------------------------------------------------------
function Library:Connect(signal, fn)
    local conn = signal:Connect(fn)
    self._connections[#self._connections + 1] = conn
    return conn
end

function Library:BindRender(name, priority, fn)
    RunService:BindToRenderStep(name, priority, fn)
    self._renderBinds[#self._renderBinds + 1] = name
end

function Library:OnUnload(callback)
    self._unloadCallbacks = self._unloadCallbacks or {}
    self._unloadCallbacks[#self._unloadCallbacks + 1] = callback
end

function Library:Unload()
    if self.Unloaded then return end
    self.Unloaded = true

    -- Consumer teardown runs FIRST, while the UI and its connections are still
    -- alive: a handler wants to restore game state and may read widget values on
    -- the way out, and running it after the teardown below would hand it a
    -- half-destroyed menu.
    for _, callback in ipairs(self._unloadCallbacks or {}) do
        pcall(callback)
    end

    for _, name in ipairs(self._renderBinds) do
        pcall(function() RunService:UnbindFromRenderStep(name) end)
    end
    self._renderBinds = {}

    for _, conn in ipairs(self._connections) do
        pcall(function() conn:Disconnect() end)
    end
    self._connections = {}

    if self.ScreenGui then
        pcall(function() self.ScreenGui:Destroy() end)
        self.ScreenGui = nil
    end

    self.Toggles, self.Options = {}, {}
    self._popups, self._keybinds, self._watchers = {}, {}, {}
    self._accent, self._surfaces = {}, {}
end

---------------------------------------------------------------------------------
-- THEMING REGISTRY
--
-- Accent is white by default, but it is one value and some people will want to
-- tint it, so anything that paints with it registers rather than hardcoding.
---------------------------------------------------------------------------------
function Library:Accent(inst, prop)
    prop = prop or "BackgroundColor3"
    self._accent[#self._accent + 1] = { Inst = inst, Prop = prop }
    inst[prop] = Theme.Accent
    return inst
end

function Library:SetAccent(color)
    Theme.Accent = color
    for _, entry in ipairs(self._accent) do
        if entry.Inst and entry.Inst.Parent then
            pcall(function() entry.Inst[entry.Prop] = color end)
        end
    end
    for _, toggle in pairs(self.Toggles) do
        if toggle._Repaint then pcall(toggle._Repaint, toggle) end
    end
    if self.Window then
        for _, tab in ipairs(self.Window.Tabs) do pcall(tab._Repaint, tab) end
    end
end

-- Opacity fades a whole panel, text and borders included, through CanvasGroup's
-- GroupTransparency. Doing it per-surface does not work: fading only the window
-- frame leaves every card, field and label fully opaque on top of a translucent
-- background, which reads as a rendering bug rather than a dimmed menu.
--
-- CanvasGroup rasterises its subtree, so it is not free and it is not on every
-- client. Where it is missing the panels are plain Frames and the opacity
-- control is simply not offered, rather than offered and broken.
Library.CanFade = (function()
    local ok, inst = pcall(Instance.new, "CanvasGroup")
    if ok and inst then
        inst:Destroy()
        return true
    end
    return false
end)()

-- Every top-level panel goes through this so one call fades all of them.
function Library:Panel(props, children)
    local panel = Util.New(self.CanFade and "CanvasGroup" or "Frame", props, children)
    self._surfaces[#self._surfaces + 1] = panel
    return panel
end

function Library:Refresh()
    if not self.CanFade then return end
    local transparency = Util.Clamp(1 - self.Opacity, 0, 1)
    for _, panel in ipairs(self._surfaces) do
        if panel and panel.Parent then
            pcall(function() panel.GroupTransparency = transparency end)
        end
    end
end

---------------------------------------------------------------------------------
-- TEXT HELPER
---------------------------------------------------------------------------------
function Library:Label(parent, text, opts)
    opts = opts or {}
    local label = Util.New("TextLabel", {
        BackgroundTransparency = 1,
        Text           = text or "",
        TextSize       = opts.Size or M.TextSize,
        TextColor3     = opts.Color or Theme.Text2,
        TextXAlignment = opts.XAlign or Enum.TextXAlignment.Left,
        TextYAlignment = opts.YAlign or Enum.TextYAlignment.Center,
        TextTruncate   = opts.Truncate ~= false
            and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
        TextWrapped    = opts.Wrapped or false,
        RichText       = opts.Rich or false,
        Position       = opts.Position or UDim2.new(),
        Size           = opts.Size2 or UDim2.fromScale(1, 1),
        AnchorPoint    = opts.AnchorPoint or Vector2.new(),
        AutomaticSize  = opts.AutoSize or Enum.AutomaticSize.None,
        ZIndex         = opts.ZIndex or 2,
        Weight         = opts.Weight or "Medium",
        Parent         = parent,
    })
    return label
end

---------------------------------------------------------------------------------
-- HOVER WATCHERS
--
-- MouseEnter/MouseLeave is unreliable once a popup overlays a control and does
-- not fire for a frame that is covered, so hover is a per-frame rect test -
-- one shared RenderStepped pass for every hover state in the menu.
---------------------------------------------------------------------------------
function Library:Watch(fn)
    self._watchers[#self._watchers + 1] = fn
    return fn
end

-- A watcher is dropped if it errors or if it returns false, which is how a
-- watcher attached to something transient retires itself.
function Library:_StartWatchers()
    self:Connect(RunService.RenderStepped, function(dt)
        if self.Unloaded then return end
        local mouse = UserInputService:GetMouseLocation()
        -- GetMouseLocation includes the topbar inset; the ScreenGui ignores it,
        -- so without this every hover rect sits 36px low.
        local point = Vector2.new(mouse.X, mouse.Y - self._guiInset)
        for index = #self._watchers, 1, -1 do
            local ok, keep = pcall(self._watchers[index], point, dt)
            if not ok or keep == false then
                table.remove(self._watchers, index)
            end
        end
    end)
end

-- Standard hover/press behaviour for anything that looks like a button: returns
-- the button so callers can chain, and repaints through the supplied function.
function Library:Interactive(button, paint)
    local state = { Hover = false, Held = false }

    self:Watch(function(point)
        local over = Util.PointInside(button, point)
        if over ~= state.Hover then
            state.Hover = over
            if not over then state.Held = false end
            paint(state)
        end
    end)

    self:Connect(button.MouseButton1Down, function()
        state.Held = true; paint(state)
    end)
    self:Connect(button.MouseButton1Up, function()
        state.Held = false; paint(state)
    end)

    paint(state)
    return state
end

---------------------------------------------------------------------------------
-- POPUPS
---------------------------------------------------------------------------------
function Library:RegisterPopup(popup)
    self._popups[#self._popups + 1] = popup
    return popup
end

function Library:CloseAllPopups(except)
    for _, popup in ipairs(self._popups) do
        if popup ~= except and popup.IsOpen then popup:Close() end
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

    self.ScreenGui = Util.New("ScreenGui", {
        Name           = HttpService:GenerateGUID(false),
        DisplayOrder   = 999,
        IgnoreGuiInset = true,
        ResetOnSpawn   = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })

    if syn and syn.protect_gui then pcall(syn.protect_gui, self.ScreenGui) end
    if protect_gui then pcall(protect_gui, self.ScreenGui) end
    self.ScreenGui.Parent = self:_Parent()

    self._guiInset = 0
    pcall(function()
        self._guiInset = game:GetService("GuiService"):GetGuiInset().Y
    end)

    -- Roblox hides and locks the cursor in most games. A modal TextButton
    -- releases it while the menu is up without fighting whatever the game does
    -- to UserInputService.
    self.Modal = Util.New("TextButton", {
        Name = "Modal", Text = "", Modal = false, AutoButtonColor = false,
        BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 1), ZIndex = 0,
        Parent = self.ScreenGui,
    })

    self.PopupLayer = Util.New("Frame", {
        Name = "Popups", BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), ZIndex = 5000, Parent = self.ScreenGui,
    })

    self.NotifyLayer = Util.New("Frame", {
        Name = "Notifications", BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -18, 1, -18),
        Size = UDim2.new(0, 280, 1, -36),
        ZIndex = 6000, Parent = self.ScreenGui,
    }, {
        Util.New("UIListLayout", {
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            VerticalAlignment = Enum.VerticalAlignment.Bottom,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, 8),
        }),
    })

    self:_StartWatchers()

    self:Connect(UserInputService.InputBegan, function(input, processed)
        if self.Unloaded then return end

        local isClick = input.UserInputType == Enum.UserInputType.MouseButton1
                     or input.UserInputType == Enum.UserInputType.MouseButton2
        if isClick then
            local mouse = UserInputService:GetMouseLocation()
            local point = Vector2.new(mouse.X, mouse.Y - self._guiInset)
            for _, popup in ipairs(self._popups) do
                if popup.IsOpen and not popup:HitTest(point) then popup:Close() end
            end
        end

        -- Capture ignores `processed`: binding a mouse button means clicking it
        -- over the menu, which Roblox reports as consumed by the GUI, so gating
        -- on processed would make M2 and M3 impossible to bind.
        if self._capturing then
            self:_HandleCapture(input)
            return
        end

        if processed then return end
        self:_HandleInput(input)
    end)

    self:Connect(UserInputService.InputEnded, function(input)
        if self.Unloaded then return end
        local key = Util.KeyFromInput(input)
        if not key then return end
        for _, picker in ipairs(self._keybinds) do
            if picker.Value == key then picker:OnReleased() end
        end
    end)
end

---------------------------------------------------------------------------------
-- INPUT
---------------------------------------------------------------------------------
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
    -- The click that opened the binder arrives here too and would bind itself.
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
        if picker.Value == key then picker:OnPressed() end
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
-- DRAGGING
---------------------------------------------------------------------------------
function Library:Draggable(handle, target)
    local dragging, origin, startPos = false, nil, nil

    self:Connect(handle.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if self:AnyPopupOpen() then return end
        dragging, origin, startPos = true, input.Position, target.Position
    end)

    self:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)

    self:Connect(UserInputService.InputChanged, function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - origin
        target.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end)
end

---------------------------------------------------------------------------------
-- NOTIFICATIONS
--
-- Bottom-right, stacked upward, sliding in from the right edge. A 2px white
-- rule down the left is the only ornament - in a mono palette that single
-- high-contrast edge is what separates a card from the background without a
-- shadow.
---------------------------------------------------------------------------------
function Library:Notify(text, duration, title)
    if self.Unloaded or not self.NotifyLayer then return end
    duration = duration or 3

    local card = Util.New("Frame", {
        BackgroundColor3 = Theme.Card,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, title and 54 or 38),
        Position = UDim2.fromOffset(24, 0),
        BorderSizePixel = 0,
        Parent = self.NotifyLayer,
    })
    Util.Corner(card, M.CardRadius)
    local stroke = Util.Stroke(card, Theme.Line)
    stroke.Transparency = 1

    local rule = self:Accent(Util.New("Frame", {
        BorderSizePixel = 0, Size = UDim2.new(0, 2, 1, -16),
        Position = UDim2.new(0, 0, 0, 8),
        BackgroundTransparency = 1, ZIndex = 3, Parent = card,
    }), "BackgroundColor3")
    Util.Corner(rule, 1)

    local labels = {}
    if title then
        labels[1] = self:Label(card, title, {
            Weight = "SemiBold", Color = Theme.Text, Size = M.TitleSize,
            Position = UDim2.fromOffset(16, 10), Size2 = UDim2.new(1, -28, 0, 16),
            YAlign = Enum.TextYAlignment.Top,
        })
        labels[2] = self:Label(card, text, {
            Color = Theme.Text2, Size = M.SmallSize,
            Position = UDim2.fromOffset(16, 28), Size2 = UDim2.new(1, -28, 0, 16),
            YAlign = Enum.TextYAlignment.Top,
        })
    else
        labels[1] = self:Label(card, text, {
            Color = Theme.Text, Size = M.TextSize,
            Position = UDim2.fromOffset(16, 0), Size2 = UDim2.new(1, -28, 1, 0),
        })
    end
    for _, label in ipairs(labels) do label.TextTransparency = 1 end

    Motion.to(card, { BackgroundTransparency = 0, Position = UDim2.new() }, Motion.Slow, Enum.EasingStyle.Quint)
    Motion.to(stroke, { Transparency = 0 }, Motion.Slow)
    Motion.to(rule, { BackgroundTransparency = 0 }, Motion.Slow)
    for _, label in ipairs(labels) do
        Motion.to(label, { TextTransparency = 0 }, Motion.Slow)
    end

    task.delay(duration, function()
        if not card or not card.Parent then return end
        Motion.to(card, { BackgroundTransparency = 1, Position = UDim2.fromOffset(24, 0) }, Motion.Base)
        Motion.to(stroke, { Transparency = 1 }, Motion.Base)
        Motion.to(rule, { BackgroundTransparency = 1 }, Motion.Base)
        for _, label in ipairs(labels) do
            Motion.to(label, { TextTransparency = 1 }, Motion.Base)
        end
        task.delay(Motion.Base + 0.05, function()
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
        self.Watermark = self:Panel({
            Name = "Watermark", BackgroundColor3 = Theme.Card, BorderSizePixel = 0,
            Position = UDim2.fromOffset(18, 18),
            Size = UDim2.fromOffset(160, 30),
            ZIndex = 4000, Visible = false, Parent = self.ScreenGui,
        })
        Util.Corner(self.Watermark, M.FieldR)
        Util.Stroke(self.Watermark, Theme.Line)

        self:Accent(Util.New("Frame", {
            BorderSizePixel = 0, Size = UDim2.fromOffset(4, 4),
            Position = UDim2.fromOffset(12, 13), ZIndex = 3,
            Parent = self.Watermark,
        }), "BackgroundColor3").Name = "Dot"
        Util.Corner(self.Watermark.Dot, 2)

        self.WatermarkLabel = self:Label(self.Watermark, "", {
            Color = Theme.Text2, Size = M.TitleSize,
            Position = UDim2.fromOffset(24, 0), Size2 = UDim2.new(1, -36, 1, 0),
        })
    end

    self.WatermarkLabel.Text = tostring(text)
    self.Watermark.Visible = true

    -- Exact rather than estimated from character count, which is why the
    -- watermark is laid out a frame or two late instead of immediately.
    Type.measureAsync({ self.WatermarkLabel }, function(width)
        if self.Watermark and self.Watermark.Parent then
            self.Watermark.Size = UDim2.fromOffset(math.max(140, width + 40), 30)
        end
    end)
end

---------------------------------------------------------------------------------
-- KEYBIND LIST
--
-- Reads the live KeyPicker registry rather than a copy, so it cannot drift from
-- what the binds actually do. State is a dot rather than the word ON/OFF: at a
-- glance you are reading presence, not text, and it keeps the row to two
-- elements instead of four.
--
-- Polled at 0.15s, not per frame, and the rows are rebuilt only when the
-- rendered result changes - without that, holding an aim key destroys and
-- recreates every label several times a second.
---------------------------------------------------------------------------------
function Library:_CreateKeybindList()
    self:_CreateRoot()
    if self.KeybindFrame then return end

    local frame = self:Panel({
        Name = "Keybinds", BackgroundColor3 = Theme.Card, BorderSizePixel = 0,
        Position = UDim2.new(0, 18, 0.5, -60),
        Size = UDim2.fromOffset(170, 40),
        AutomaticSize = Enum.AutomaticSize.Y,
        ZIndex = 4000, Visible = false, Active = true, Parent = self.ScreenGui,
    })
    Util.Corner(frame, M.CardRadius)
    Util.Stroke(frame, Theme.Line)
    Util.Pad(frame, nil, 12, 12, 12, 12)
    Util.List(frame, 6)
    self.KeybindFrame = frame

    self:Label(frame, "Keybinds", {
        Weight = "SemiBold", Color = Theme.Text3, Size = M.SmallSize,
        Size2 = UDim2.new(1, 0, 0, 14),
    }).LayoutOrder = 0

    self.KeybindRows = Util.New("Frame", {
        BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = frame,
    })
    Util.List(self.KeybindRows, 4)

    self:Draggable(frame, frame)

    local nextPoll = 0

    self:Watch(function()
        if not self.ShowKeybinds then
            if frame.Visible then frame.Visible = false end
            return
        end

        local now = os.clock()
        if now < nextPoll then return end
        nextPoll = now + 0.15

        local rows, parts = {}, {}
        for _, picker in ipairs(self._keybinds) do
            if picker.Value and picker.Value ~= "" and picker.ShowInList then
                local active = picker:GetState()
                -- "Enable Silent Aim" reads as "Silent Aim": the prefix earns
                -- its place on a menu toggle, not in a list where every row is
                -- already a feature.
                local name = string.gsub(picker.Text, "^Enable ", "")
                rows[#rows + 1] = { Name = name, Key = Util.KeyLabel(picker.Value), On = active }
                parts[#parts + 1] = name .. "|" .. picker.Value .. "|" .. tostring(active)
            end
        end

        local signature = table.concat(parts, ";")
        frame.Visible = true
        if signature == self._keybindSignature then return end
        self._keybindSignature = signature

        for _, child in ipairs(self.KeybindRows:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end

        if #rows == 0 then
            local row = Util.New("Frame", {
                BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16),
                LayoutOrder = 1, Parent = self.KeybindRows,
            })
            self:Label(row, "No keybinds set", {
                Color = Theme.Text4, Size = M.SmallSize,
            })
            frame.Size = UDim2.fromOffset(170, 40)
            return
        end

        local nameLabels = {}
        for index, row in ipairs(rows) do
            local holder = Util.New("Frame", {
                BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, M.ChipH),
                LayoutOrder = index, Parent = self.KeybindRows,
            })

            -- Key chip. AutomaticSize on X so a long key name is not clipped
            -- and a short one does not leave a gap.
            local chip = Util.New("Frame", {
                BackgroundColor3 = row.On and Theme.Accent or Theme.Control,
                BorderSizePixel = 0,
                Size = UDim2.fromOffset(0, M.ChipH),
                AutomaticSize = Enum.AutomaticSize.X,
                Parent = holder,
            })
            Util.Corner(chip, M.ChipR)
            Util.Pad(chip, nil, 0, 0, 6, 6)
            if not row.On then Util.Stroke(chip, Theme.Line) end

            local chipLabel = self:Label(chip, row.Key, {
                Weight = "SemiBold", Size = M.SmallSize - 1,
                Color = row.On and Theme.OnAccent or Theme.Text2,
                Size2 = UDim2.new(0, 0, 1, 0),
                AutoSize = Enum.AutomaticSize.X,
                XAlign = Enum.TextXAlignment.Center, Truncate = false,
            })

            local name = self:Label(holder, row.Name, {
                Color = row.On and Theme.Text or Theme.Text3, Size = M.SmallSize,
                Position = UDim2.fromOffset(0, 0), Size2 = UDim2.new(1, 0, 1, 0),
            })
            nameLabels[#nameLabels + 1] = name
            nameLabels[#nameLabels + 1] = chipLabel

            -- The chip's width is only known after it renders, so the name is
            -- pushed clear of it on the next frame.
            task.defer(function()
                if name.Parent and chip.Parent then
                    local offset = chip.AbsoluteSize.X + 8
                    name.Position = UDim2.fromOffset(offset, 0)
                    name.Size = UDim2.new(1, -offset, 1, 0)
                end
            end)
        end

        -- Deferred and retried: TextBounds is only meaningful once rendered, and
        -- FontFace has no synchronous measurement.
        Type.measureAsync(nameLabels, function(widest)
            if frame.Parent then
                frame.Size = UDim2.fromOffset(Util.Clamp(widest + 90, 170, 300), 40)
            end
        end)
    end)
end

function Library:SetKeybindListVisible(visible)
    self:_CreateKeybindList()
    self.ShowKeybinds = visible and true or false
    self._keybindSignature = nil
end

---------------------------------------------------------------------------------
-- WINDOW
--
--   root
--   |- sidebar          title block, tab list, sliding indicator
--   |- divider          1px
--   `- content          two scrolling columns of cards, one page per tab
--
-- The window is dragged by its title block, which is the only chrome that is
-- obviously not a control.
---------------------------------------------------------------------------------
local Window = {}
Window.__index = Window

function Library:CreateWindow(config)
    config = config or {}
    self:_CreateRoot()

    if config.Accent then Theme.Accent = config.Accent end
    if config.MenuKey then self.MenuKey = config.MenuKey end

    local window = setmetatable({
        Library  = self,
        Tabs     = {},
        TabCount = 0,
        Title    = config.Title or "uilib",
        Footer   = config.Footer,
    }, Window)
    self.Window = window

    local root = self:Panel({
        Name = "Window", BackgroundColor3 = Theme.Bg, BorderSizePixel = 0,
        AnchorPoint = config.Center == false and Vector2.new() or Vector2.new(0.5, 0.5),
        Position = config.Center == false
            and (config.Position or UDim2.fromOffset(120, 120))
            or UDim2.fromScale(0.5, 0.5),
        Size = config.Size or UDim2.fromOffset(M.WindowW, M.WindowH),
        Visible = false, ClipsDescendants = true, ZIndex = 100,
        Parent = self.ScreenGui,
    })
    Util.Corner(root, M.Radius)
    Util.Stroke(root, Theme.Line)
    window.Root = root

    -----------------------------------------------------------------
    -- Sidebar
    -----------------------------------------------------------------
    local sidebar = Util.New("Frame", {
        Name = "Sidebar", BackgroundTransparency = 1,
        Size = UDim2.new(0, M.SidebarW, 1, 0), Parent = root,
    })

    local header = Util.New("Frame", {
        Name = "Header", BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 78), Parent = sidebar,
    })
    self:Draggable(header, root)

    self:Label(header, window.Title, {
        Weight = "SemiBold", Color = Theme.Text, Size = 15,
        Position = UDim2.fromOffset(M.Pad, 26), Size2 = UDim2.new(1, -M.Pad * 2, 0, 18),
    })

    if window.Footer then
        self:Label(header, window.Footer, {
            Weight = "Regular", Color = Theme.Text3, Size = M.SmallSize,
            Position = UDim2.fromOffset(M.Pad, 45), Size2 = UDim2.new(1, -M.Pad * 2, 0, 14),
        })
    end

    window.TabList = Util.New("Frame", {
        Name = "Tabs", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, 78),
        Size = UDim2.new(1, 0, 1, -94), Parent = sidebar,
    })
    Util.Pad(window.TabList, nil, 0, 0, 10, 10)
    Util.List(window.TabList, M.TabGap)

    -- One bar that slides between tabs. Its y is derived from the tab index
    -- rather than read off AbsolutePosition, so it is correct on the first
    -- frame before anything has laid out.
    window.Indicator = self:Accent(Util.New("Frame", {
        Name = "Indicator", BorderSizePixel = 0,
        Position = UDim2.fromOffset(2, 78 + (M.TabH - 18) / 2),
        Size = UDim2.fromOffset(2, 18), ZIndex = 5,
        BackgroundTransparency = 1, Parent = sidebar,
    }), "BackgroundColor3")
    Util.Corner(window.Indicator, 1)

    Util.New("Frame", {
        Name = "Divider", BackgroundColor3 = Theme.Line, BorderSizePixel = 0,
        Position = UDim2.fromOffset(M.SidebarW, 0),
        Size = UDim2.new(0, 1, 1, 0), Parent = root,
    })

    -----------------------------------------------------------------
    -- Content
    -----------------------------------------------------------------
    window.Content = Util.New("Frame", {
        Name = "Content", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(M.SidebarW + 1, 0),
        Size = UDim2.new(1, -(M.SidebarW + 1), 1, 0), Parent = root,
    })
    Util.Pad(window.Content, M.Pad)

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

    local root = self.Window.Root
    if self.Modal then self.Modal.Modal = self.Open end

    if self.Open then
        -- A short rise in. Scaling the window would resample every glyph inside
        -- it, so position carries the motion. The resting position is whatever
        -- it is now (the user may have dragged the window), captured before the
        -- offset is applied.
        local resting = root.Position
        root.Position = resting + UDim2.fromOffset(0, 10)
        root.Visible = true
        Motion.to(root, { Position = resting }, Motion.Slow, Enum.EasingStyle.Quint)
    else
        self:CloseAllPopups()
        self:_StopCapture()
        root.Visible = false
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
        Library = library,
        Window  = self,
        Name    = name,
        Index   = index,
        Cards   = {},
    }, Tab)

    local button = Util.New("TextButton", {
        Name = "Tab" .. index, Text = "", AutoButtonColor = false,
        BackgroundColor3 = Theme.Control, BackgroundTransparency = 1,
        BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, M.TabH),
        LayoutOrder = index, Parent = self.TabList,
    })
    Util.Corner(button, M.TabRadius)
    tab.Button = button

    local textX = 12
    if icon then
        tab.Icon = Util.New("ImageLabel", {
            BackgroundTransparency = 1, Image = icon,
            Position = UDim2.fromOffset(12, (M.TabH - 16) / 2),
            Size = UDim2.fromOffset(16, 16),
            ImageColor3 = Theme.Text3, ZIndex = 3, Parent = button,
        })
        textX = 38
    end

    tab.Label = library:Label(button, name, {
        Color = Theme.Text3, Size = M.TextSize,
        Position = UDim2.fromOffset(textX, 0),
        Size2 = UDim2.new(1, -(textX + 10), 1, 0), ZIndex = 3,
    })

    -- One page per tab, both columns inside it.
    tab.Page = Util.New("Frame", {
        Name = "Page" .. index, BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), Visible = false,
        Parent = self.Content,
    })

    local function column(side)
        local frame = Util.New("ScrollingFrame", {
            Name = side, BackgroundTransparency = 1, BorderSizePixel = 0,
            Position = side == "Left" and UDim2.new()
                or UDim2.new(0.5, M.ColGap / 2, 0, 0),
            Size = UDim2.new(0.5, -M.ColGap / 2, 1, 0),
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = Theme.LineHi,
            ScrollingDirection = Enum.ScrollingDirection.Y,
            ElasticBehavior = Enum.ElasticBehavior.Never,
            VerticalScrollBarInset = Enum.ScrollBarInset.None,
            Parent = tab.Page,
        })
        Util.List(frame, M.CardGap)
        Util.Pad(frame, nil, 0, M.Pad, 0, 0)
        return frame
    end

    tab.Left  = column("Left")
    tab.Right = column("Right")

    local hovered = false
    library:Watch(function(point)
        local over = Util.PointInside(button, point) and library.Open
        if over ~= hovered then
            hovered = over
            tab:_Repaint()
        end
    end)
    tab._IsHovered = function() return hovered end

    library:Connect(button.MouseButton1Click, function()
        self:SetActiveTab(tab)
    end)

    self.Tabs[index] = tab

    if not self.ActiveTab then
        self:SetActiveTab(tab)
    else
        tab:_Repaint()
    end

    return tab
end

function Tab:_Repaint()
    local active = self.Window.ActiveTab == self
    local hovered = self._IsHovered and self._IsHovered() or false

    local textColor = active and Theme.Text
        or (hovered and Theme.Text2 or Theme.Text3)

    Motion.to(self.Label, { TextColor3 = textColor }, Motion.Fast)
    if self.Icon then
        Motion.to(self.Icon, { ImageColor3 = textColor }, Motion.Fast)
    end
    Motion.to(self.Button, {
        BackgroundTransparency = active and 0 or (hovered and 0.5 or 1),
    }, Motion.Fast)
end

function Window:SetActiveTab(tab)
    if self.ActiveTab == tab then return end

    local library = self.Library
    library:CloseAllPopups()

    local previous = self.ActiveTab
    self.ActiveTab = tab

    if previous then
        previous.Page.Visible = false
        previous:_Repaint()
    end
    tab.Page.Visible = true
    tab:_Repaint()

    -- Indicator slides; the page lifts. v1 slid the whole page in from +-560px,
    -- which at this size reads as a lurch rather than a transition.
    --
    -- y is derived from the tab index, not read off AbsolutePosition, so it is
    -- right on the first frame before anything has laid out. The tab list has no
    -- top padding, so 78 (its own y) is the first tab's top.
    local y = 78
        + (tab.Index - 1) * (M.TabH + M.TabGap)
        + (M.TabH - 18) / 2
    Motion.to(self.Indicator, {
        Position = UDim2.fromOffset(2, y),
        BackgroundTransparency = 0,
    }, Motion.Base, Enum.EasingStyle.Quint)

    if previous then
        for _, column in ipairs({ tab.Left, tab.Right }) do
            column.Position = column.Position + UDim2.fromOffset(0, 6)
            Motion.to(column, {
                Position = column.Position - UDim2.fromOffset(0, 6),
            }, Motion.Base, Enum.EasingStyle.Quint)
        end
    end
end

---------------------------------------------------------------------------------
-- CARDS (groupboxes)
--
-- A card sizes to its rows. v1 stretched panels to fill a hand-computed slot in
-- a 10x11 grid and then scrolled their contents; here the card is as tall as
-- what is in it and the COLUMN scrolls, which is why there is no row
-- arithmetic, no ContentWidth clamp and no resize watchers anywhere below.
---------------------------------------------------------------------------------
local Groupbox = {}
Groupbox.__index = Groupbox

function Tab:_NewCard(name, column)
    local library = self.Library

    local box = setmetatable({
        Library = library,
        Tab     = self,
        Name    = name,
        Order   = 0,
    }, Groupbox)

    local frame = Util.New("Frame", {
        Name = "Card", BackgroundColor3 = Theme.Card, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = #self.Cards + 1, Parent = column,
    })
    Util.Corner(frame, M.CardRadius)
    Util.Stroke(frame, Theme.Line)
    Util.Pad(frame, M.CardPad)
    Util.List(frame, M.RowGap)
    -- Not registered for fading: the window root is already a CanvasGroup and
    -- nesting one per card would rasterise every card into its own texture for
    -- no visual difference.
    box.Frame = frame

    if name and name ~= "" then
        -- Smaller and dimmer than the rows it heads. A heading that is louder
        -- than its content is what makes a dense panel hard to scan.
        box.TitleLabel = library:Label(frame, name, {
            Weight = "SemiBold", Color = Theme.Text3, Size = M.TitleSize,
            Size2 = UDim2.new(1, 0, 0, 18),
        })
        box.TitleLabel.LayoutOrder = 0
    end

    self.Cards[#self.Cards + 1] = box
    return box
end

-- `weight` is accepted and ignored: cards size to their content now.
function Tab:AddLeftGroupbox(name, _weight)
    return self:_NewCard(name, self.Left)
end

function Tab:AddRightGroupbox(name, _weight)
    return self:_NewCard(name, self.Right)
end

-- Compatibility shim. v1 took an ImGui grid rect; only the column survives,
-- taken from X (the grid was 9 wide, so anything past the midpoint is "right").
function Tab:AddGroupbox(name, grid)
    local right = type(grid) == "table" and (grid.X or 0) >= 4.5
    return self:_NewCard(name, right and self.Right or self.Left)
end

-- Rows are list-layout children, so a row only has to say how tall it is.
function Groupbox:_Row(height)
    self.Order = self.Order + 1
    return Util.New("Frame", {
        Name = "Row", BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, height),
        LayoutOrder = self.Order, Parent = self.Frame,
    })
end

-- A chevron built from two rotated bars. Font-independent: a glyph would render
-- as a box on any family that lacks it, and a stacked-pixel triangle is exactly
-- the look this redesign is getting away from.
function Util.Chevron(parent, color)
    local holder = Util.New("Frame", {
        Name = "Chevron", BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(12, 12), ZIndex = 3, Parent = parent,
    })
    local bars = {}
    for index, spec in ipairs({ { -2.4, 45 }, { 2.4, -45 } }) do
        bars[index] = Util.New("Frame", {
            BackgroundColor3 = color or Theme.Text3, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, spec[1], 0.5, 0),
            Size = UDim2.fromOffset(8, 1.5),
            Rotation = spec[2], Parent = holder,
        })
    end
    return holder, bars
end

---------------------------------------------------------------------------------
-- LABEL / DIVIDER
---------------------------------------------------------------------------------
function Groupbox:AddLabel(text, options)
    if type(options) == "boolean" then options = { Special = options } end
    options = options or {}

    local library = self.Library
    local height = options.Wrapped and 40 or 18
    local row = self:_Row(height)

    local label = library:Label(row, text, {
        Color = options.Special and Theme.Text or Theme.Text2,
        Size = M.TextSize, Wrapped = options.Wrapped,
        Truncate = not options.Wrapped,
        YAlign = options.Wrapped and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
    })

    if options.Wrapped then
        row.AutomaticSize = Enum.AutomaticSize.Y
        row.Size = UDim2.new(1, 0, 0, 0)
        label.Size = UDim2.new(1, 0, 0, 0)
        label.AutomaticSize = Enum.AutomaticSize.Y
    end

    local object = {
        Type = "Label", Row = row, Label = label,
        SetText = function(_, value) label.Text = tostring(value) end,
        SetVisible = function(_, visible) row.Visible = visible and true or false end,
    }
    return object
end

function Groupbox:AddDivider()
    local row = self:_Row(1)
    Util.New("Frame", {
        BackgroundColor3 = Theme.Line, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 1), Parent = row,
    })
    return { Type = "Divider", Row = row }
end

---------------------------------------------------------------------------------
-- BUTTON
--
-- Secondary by default. `Primary = true` fills it white with dark text, which in
-- a monochrome palette is the strongest emphasis available - so at most one per
-- card, or it stops meaning anything.
---------------------------------------------------------------------------------
function Groupbox:AddButton(options, func)
    if type(options) == "string" then options = { Text = options, Func = func } end
    options = options or {}

    local library = self.Library
    local height = options.Height or M.ButtonH
    local row = self:_Row(height)

    local primary = options.Primary and true or false

    local button = Util.New("TextButton", {
        Name = "Button", Text = "", AutoButtonColor = false, BorderSizePixel = 0,
        BackgroundColor3 = primary and Theme.Accent or Theme.Control,
        Size = UDim2.fromScale(1, 1), Parent = row,
    })
    Util.Corner(button, M.FieldR)
    if primary then
        library:Accent(button, "BackgroundColor3")
    else
        Util.Stroke(button, Theme.Line)
    end

    local label = library:Label(button, options.Text or "Button", {
        Weight = "SemiBold", Size = M.TextSize,
        Color = primary and Theme.OnAccent or Theme.Text,
        XAlign = Enum.TextXAlignment.Center, ZIndex = 3,
    })

    local armed = false

    library:Interactive(button, function(state)
        local transparency = 0
        if state.Held then
            transparency = primary and 0.25 or 0
        elseif state.Hover then
            transparency = primary and 0.12 or 0
        end
        Motion.to(button, {
            BackgroundTransparency = transparency,
            BackgroundColor3 = (not primary and (state.Hover or state.Held))
                and Theme.Hover or (primary and Theme.Accent or Theme.Control),
        }, Motion.Fast)
    end)

    library:Connect(button.MouseButton1Click, function()
        if library:AnyPopupOpen() then return end

        if options.Confirm and not armed then
            armed = true
            label.Text = "Click again to confirm"
            task.delay(2.5, function()
                if armed and label.Parent then
                    armed = false
                    label.Text = options.Text or "Button"
                end
            end)
            return
        end

        armed = false
        label.Text = options.Text or "Button"
        if options.Func then
            local ok, err = pcall(options.Func)
            if not ok then library:Notify(tostring(err), 6, "Button error") end
        end
    end)

    local object = { Type = "Button", Row = row, Button = button, Label = label }
    function object:SetText(value)
        options.Text = tostring(value)
        label.Text = options.Text
    end
    function object:SetVisible(visible) row.Visible = visible and true or false end
    return object
end

---------------------------------------------------------------------------------
-- TOGGLE
--
-- A pill switch, not a checkbox. v1 drew an 8x8 square with a 1px border, which
-- is the single most dated element in an ImGui menu: it is hard to hit, hard to
-- read at a glance, and has no sensible animation. A 36x20 track with a sliding
-- knob reads instantly, is a comfortable target, and the knob travel is the
-- animation.
--
-- The switch sits at the row's right edge; addons (keybind chip, colour
-- swatches) stack leftward from it.
---------------------------------------------------------------------------------
local ADDON_BASE = M.SwitchW + 12

function Groupbox:_CreateToggle(index, options)
    options = options or {}
    local library = self.Library
    local row = self:_Row(M.RowH)

    local label = library:Label(row, options.Text or index, {
        Color = Theme.Text2, Size = M.TextSize,
        Size2 = UDim2.new(1, -ADDON_BASE, 1, 0),
    })

    local track = Util.New("Frame", {
        Name = "Track", BackgroundColor3 = Theme.Control, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(M.SwitchW, M.SwitchH), ZIndex = 3, Parent = row,
    })
    Util.Corner(track, M.SwitchH / 2)
    local trackStroke = Util.Stroke(track, Theme.Line)

    local knob = Util.New("Frame", {
        Name = "Knob", BackgroundColor3 = Theme.Text3, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 2, 0.5, 0),
        Size = UDim2.fromOffset(M.KnobD, M.KnobD), ZIndex = 4, Parent = track,
    })
    Util.Corner(knob, M.KnobD / 2)

    -- Covers the label but not the switch or the addons, so clicking a keybind
    -- chip or a swatch does not also flip the toggle.
    local hit = Util.New("TextButton", {
        Name = "Hit", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(1, -ADDON_BASE, 1, 0), ZIndex = 2, Parent = row,
    })

    local toggle = {
        Type      = "Toggle",
        Index     = index,
        Text      = options.Text or index,
        Value     = options.Default and true or false,
        Row       = row,
        Groupbox  = self,
        Library   = library,
        Callbacks = {},
        Addons    = {},
        _hovered  = false,
    }
    if options.Callback then toggle.Callbacks[1] = options.Callback end

    function toggle:_Repaint()
        local on = self.Value
        Motion.to(track, {
            BackgroundColor3 = on and Theme.Accent
                or (self._hovered and Theme.Hover or Theme.Control),
        }, Motion.Fast)
        Motion.to(trackStroke, { Transparency = on and 1 or 0 }, Motion.Fast)
        Motion.to(knob, {
            Position = UDim2.new(0, on and (M.SwitchW - M.KnobD - 2) or 2, 0.5, 0),
            BackgroundColor3 = on and Theme.OnAccent
                or (self._hovered and Theme.Text2 or Theme.Text3),
        }, Motion.Base, Enum.EasingStyle.Quint)
        Motion.to(label, {
            TextColor3 = on and Theme.Text
                or (self._hovered and Theme.Text2 or Theme.Text3),
        }, Motion.Fast)
    end

    function toggle:SetValue(value, silent)
        self.Value = value and true or false
        self:_Repaint()
        if silent then return end
        for _, callback in ipairs(self.Callbacks) do pcall(callback, self.Value) end
    end

    function toggle:SetValueSilent(value) self:SetValue(value, true) end

    function toggle:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function toggle:SetVisible(visible) row.Visible = visible and true or false end

    function toggle:SetText(value)
        self.Text = tostring(value)
        label.Text = self.Text
    end

    library:Watch(function(point)
        local over = Util.PointInside(hit, point) or Util.PointInside(track, point)
        if over ~= toggle._hovered then
            toggle._hovered = over
            toggle:_Repaint()
        end
    end)

    local function flip()
        if library:AnyPopupOpen() then return end
        toggle:SetValue(not toggle.Value)
    end
    library:Connect(hit.MouseButton1Click, flip)

    -- The switch itself is also a target; without this the most obvious thing
    -- to click is the one thing that does nothing.
    local trackButton = Util.New("TextButton", {
        Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = track,
    })
    library:Connect(trackButton.MouseButton1Click, flip)

    toggle._Label = label
    toggle._Hit = hit
    toggle:_Repaint()

    library.Toggles[index] = toggle
    return toggle
end

---------------------------------------------------------------------------------
-- SLIDER
--
-- Name left, value right, track underneath. v1 printed the value centred on the
-- fill edge, riding over the bar - legible only because the bar was 6px tall.
-- Putting it at the row's right edge means it never collides with anything and
-- the eye finds it in the same place on every slider.
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

    local row = self:_Row(M.SliderH)

    local label = library:Label(row, options.Text or index, {
        Color = Theme.Text2, Size = M.TextSize,
        Size2 = UDim2.new(1, -80, 0, 16),
    })

    local valueLabel = library:Label(row, "", {
        Weight = "SemiBold", Color = Theme.Text, Size = M.TextSize,
        XAlign = Enum.TextXAlignment.Right,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, 0),
        Size2 = UDim2.fromOffset(90, 16),
    })

    -- A 4px bar is far too thin to grab, so an invisible 22px band over it is
    -- the actual target.
    local hit = Util.New("TextButton", {
        Name = "Hit", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 0, 24), Size = UDim2.new(1, 0, 0, 22),
        ZIndex = 4, Parent = row,
    })

    local track = Util.New("Frame", {
        Name = "Track", BackgroundColor3 = Theme.Control, BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 0, 32), Size = UDim2.new(1, 0, 0, M.TrackH),
        ZIndex = 2, Parent = row,
    })
    Util.Corner(track, M.TrackH / 2)

    local fill = library:Accent(Util.New("Frame", {
        Name = "Fill", BorderSizePixel = 0,
        Size = UDim2.fromScale(0, 1), ZIndex = 3, Parent = track,
    }), "BackgroundColor3")
    Util.Corner(fill, M.TrackH / 2)

    local knob = library:Accent(Util.New("Frame", {
        Name = "Knob", BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(M.SliderKnob, M.SliderKnob), ZIndex = 5, Parent = track,
    }), "BackgroundColor3")
    Util.Corner(knob, M.SliderKnob / 2)

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
        local text = rounding > 0
            and string.format("%." .. rounding .. "f", value)
            or tostring(math.floor(value + 0.5))
        return prefix .. text .. suffix
    end

    function slider:_Repaint()
        local span = self.Max - self.Min
        local alpha = span > 0 and ((self.Value - self.Min) / span) or 0

        Motion.to(fill, { Size = UDim2.fromScale(alpha, 1) }, Motion.Fast)
        Motion.to(knob, { Position = UDim2.fromScale(alpha, 0.5) }, Motion.Fast)

        local big = self._hovered or self._dragging
        Motion.to(knob, {
            Size = UDim2.fromOffset(big and 14 or M.SliderKnob,
                                    big and 14 or M.SliderKnob),
        }, Motion.Fast)
        Motion.to(label, {
            TextColor3 = big and Theme.Text or Theme.Text2,
        }, Motion.Fast)

        valueLabel.Text = format(self.Value)
    end

    function slider:SetValue(value, silent)
        value = Util.Clamp(value, self.Min, self.Max)
        value = rounding > 0 and Util.Round(value, rounding) or math.floor(value + 0.5)
        self.Value = value
        self:_Repaint()
        if silent then return end
        for _, callback in ipairs(self.Callbacks) do pcall(callback, self.Value) end
    end

    function slider:SetValueSilent(value) self:SetValue(value, true) end
    function slider:SetMin(value) self.Min = value; self:SetValue(self.Value, true) end
    function slider:SetMax(value) self.Max = value; self:SetValue(self.Value, true) end

    function slider:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function slider:SetVisible(visible) row.Visible = visible and true or false end

    local function valueFromX(x)
        local left = track.AbsolutePosition.X
        local width = math.max(track.AbsoluteSize.X, 1)
        local alpha = Util.Clamp((x - left) / width, 0, 1)
        return slider.Min + alpha * (slider.Max - slider.Min)
    end

    library:Connect(hit.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        if library:AnyPopupOpen() then return end
        slider._dragging = true
        -- GetMouseLocation rather than input.Position: the two are not
        -- guaranteed to share an origin once the ScreenGui ignores the topbar
        -- inset, and AbsolutePosition (which valueFromX compares against) is in
        -- the GetMouseLocation space. X needs no inset correction - the inset is
        -- vertical only - so this is also why a click applies immediately
        -- instead of waiting a frame for the watcher.
        slider:SetValue(valueFromX(UserInputService:GetMouseLocation().X))
    end)

    library:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 and slider._dragging then
            slider._dragging = false
            slider:_Repaint()
        end
    end)

    library:Watch(function(point)
        local over = Util.PointInside(hit, point)
        if over ~= slider._hovered then
            slider._hovered = over
            slider:_Repaint()
        end
        if slider._dragging then
            slider:SetValue(valueFromX(point.X))
        end
    end)

    -- Arrow keys nudge while hovered.
    library:Connect(UserInputService.InputBegan, function(input, processed)
        if processed or not slider._hovered or not library.Open then return end
        if input.KeyCode == Enum.KeyCode.Left then
            slider:SetValue(slider.Value - step)
        elseif input.KeyCode == Enum.KeyCode.Right then
            slider:SetValue(slider.Value + step)
        end
    end)

    slider:_Repaint()
    library.Options[index] = slider
    return slider
end

---------------------------------------------------------------------------------
-- DROPDOWN
--
-- The popup lives in the popup layer, not inside the card: a card sits in a
-- clipping ScrollingFrame, so a child popup would be cut off at the card edge.
---------------------------------------------------------------------------------
function Groupbox:AddDropdown(index, options)
    options = options or {}
    local library = self.Library

    local multi    = options.Multi and true or false
    local hasLabel = options.Text ~= nil and options.Text ~= ""
    local row = self:_Row(hasLabel and (16 + 6 + M.FieldH) or M.FieldH)

    if hasLabel then
        library:Label(row, options.Text, {
            Color = Theme.Text2, Size = M.TextSize,
            Size2 = UDim2.new(1, 0, 0, 16),
        })
    end

    local field = Util.New("TextButton", {
        Name = "Field", Text = "", AutoButtonColor = false, BorderSizePixel = 0,
        BackgroundColor3 = Theme.Control,
        Position = UDim2.new(0, 0, 0, hasLabel and 22 or 0),
        Size = UDim2.new(1, 0, 0, M.FieldH), Parent = row,
    })
    Util.Corner(field, M.FieldR)
    local fieldStroke = Util.Stroke(field, Theme.Line)

    local preview = library:Label(field, "", {
        Color = Theme.Text, Size = M.TextSize,
        Position = UDim2.fromOffset(12, 0), Size2 = UDim2.new(1, -36, 1, 0),
        ZIndex = 3,
    })

    local _, chevronBars = Util.Chevron(field, Theme.Text3)

    -- Base rotations are captured once. Reading Rotation back off the instance
    -- and negating it would flip the chevron on every repaint rather than
    -- tracking the open state.
    local chevronBase = {}
    for index2, bar in ipairs(chevronBars) do
        chevronBase[index2] = bar.Rotation
    end

    local dropdown = {
        Type      = "Dropdown",
        Index     = index,
        Text      = options.Text or index,
        Multi     = multi,
        Values    = options.Values or {},
        Value     = multi and {} or nil,
        IsOpen    = false,
        Row       = row,
        Library   = library,
        Callbacks = {},
        _hovered  = false,
        _rows     = {},
    }
    if options.Callback then dropdown.Callbacks[1] = options.Callback end

    -----------------------------------------------------------------
    -- Popup
    -----------------------------------------------------------------
    local popup = Util.New("Frame", {
        Name = "DropdownPopup", BackgroundColor3 = Theme.Card, BorderSizePixel = 0,
        Visible = false, ZIndex = 50, Parent = library.PopupLayer,
    })
    Util.Corner(popup, M.FieldR)
    Util.Stroke(popup, Theme.LineHi)

    local list = Util.New("ScrollingFrame", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12),
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.LineHi,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        ZIndex = 51, Parent = popup,
    })
    Util.List(list, 2)

    function dropdown:_PreviewText()
        if self.Multi then
            local parts = {}
            for _, value in ipairs(self.Values) do
                if self.Value[value] then parts[#parts + 1] = tostring(value) end
            end
            if #parts == 0 then return options.Placeholder or "None" end
            local text = table.concat(parts, ", ")
            return #text > 40 and (string.sub(text, 1, 40) .. "…") or text
        end
        if self.Value == nil then return options.Placeholder or "Select…" end
        return tostring(self.Value)
    end

    function dropdown:_RebuildRows()
        for _, record in ipairs(self._rows) do record.Frame:Destroy() end
        self._rows = {}

        for order, value in ipairs(self.Values) do
            local entry = Util.New("TextButton", {
                Name = "Option", Text = "", AutoButtonColor = false,
                BackgroundColor3 = Theme.Control, BackgroundTransparency = 1,
                BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, M.ListRowH - 4),
                LayoutOrder = order, ZIndex = 52, Parent = list,
            })
            Util.Corner(entry, 6)

            local text = library:Label(entry, tostring(value), {
                Color = Theme.Text2, Size = M.TextSize,
                Position = UDim2.fromOffset(10, 0), Size2 = UDim2.new(1, -30, 1, 0),
                ZIndex = 53,
            })

            -- Selection marker: a dot, not a tick. One 6px element reads as
            -- cleanly as a glyph and cannot be missing from a font.
            local dot = library:Accent(Util.New("Frame", {
                BorderSizePixel = 0, BackgroundTransparency = 1,
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, -10, 0.5, 0),
                Size = UDim2.fromOffset(6, 6), ZIndex = 53, Parent = entry,
            }), "BackgroundColor3")
            Util.Corner(dot, 3)

            local record = { Frame = entry, Label = text, Dot = dot, Value = value }
            self._rows[#self._rows + 1] = record

            -- MouseEnter/Leave rather than a frame watcher. Rows are rebuilt
            -- every SetValues call - which for a live player list is every join
            -- and leave - and a watcher closure per row would never be
            -- collected, growing the per-frame list without bound. A connection
            -- dies with its instance. It is also reliable here specifically:
            -- the popup is the topmost thing on screen, so nothing can cover a
            -- row and swallow the event.
            library:Connect(entry.MouseEnter, function()
                record.Hover = true
                self:_Repaint()
            end)
            library:Connect(entry.MouseLeave, function()
                record.Hover = false
                self:_Repaint()
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

        -- Placeholder grey when nothing is chosen, primary when something is.
        local empty
        if self.Multi then
            empty = next(self.Value or {}) == nil
        else
            empty = self.Value == nil
        end
        preview.TextColor3 = empty and Theme.Text3 or Theme.Text

        for _, record in ipairs(self._rows) do
            local selected = self.Multi
                and (self.Value[record.Value] and true or false)
                or (self.Value == record.Value)

            record.Label.TextColor3 = selected and Theme.Text or Theme.Text2
            record.Dot.BackgroundTransparency = selected and 0 or 1
            record.Frame.BackgroundTransparency = (record.Hover or selected) and 0 or 1
            record.Frame.BackgroundColor3 = selected and Theme.Hover or Theme.Control
        end

        Motion.to(field, {
            BackgroundColor3 = (self._hovered or self.IsOpen) and Theme.Hover or Theme.Control,
        }, Motion.Fast)
        Motion.to(fieldStroke, {
            Color = self.IsOpen and Theme.LineHi or Theme.Line,
        }, Motion.Fast)
        -- Chevron flips to point up while the popup is open.
        for index2, bar in ipairs(chevronBars) do
            local want = self.IsOpen and -chevronBase[index2] or chevronBase[index2]
            if bar.Rotation ~= want then
                Motion.to(bar, { Rotation = want }, Motion.Fast)
            end
        end
    end

    function dropdown:_Fire()
        for _, callback in ipairs(self.Callbacks) do pcall(callback, self.Value) end
    end

    function dropdown:SetValue(value, silent)
        if self.Multi then
            local set = {}
            if type(value) == "table" then
                -- Accept both { Item = true } and { "Item", "Other" }.
                if value[1] ~= nil then
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
                local present = false
                for _, value in ipairs(self.Values) do
                    if value == self.Value then
                        present = true
                        break
                    end
                end
                if not present then self.Value = nil end
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
        local rowH = M.ListRowH - 2
        local shown = math.min(math.max(#self.Values, 1), options.MaxVisible or 7)
        local height = shown * rowH + 12

        local origin = field.AbsolutePosition
        local below = origin.Y + field.AbsoluteSize.Y + 6
        local viewport = library.ScreenGui.AbsoluteSize.Y

        -- Flip above when there is no room below, so a dropdown at the bottom of
        -- a column is still usable.
        if below + height > viewport and origin.Y - height - 6 > 0 then
            below = origin.Y - height - 6
        end

        popup.Position = UDim2.fromOffset(origin.X, below)
        popup.Size = UDim2.fromOffset(field.AbsoluteSize.X, height)
    end

    function dropdown:Open()
        library:CloseAllPopups(self)
        self.IsOpen = true
        self:_Position()
        popup.Visible = true
        popup.BackgroundTransparency = 1
        Motion.to(popup, { BackgroundTransparency = 0 }, Motion.Fast)
        self:_Repaint()
    end

    function dropdown:Close()
        if not self.IsOpen then return end
        self.IsOpen = false
        popup.Visible = false
        self:_Repaint()
    end

    function dropdown:HitTest(point)
        return Util.PointInside(popup, point) or Util.PointInside(field, point)
    end

    library:RegisterPopup(dropdown)

    library:Watch(function(point)
        local over = Util.PointInside(field, point)
        if over ~= dropdown._hovered then
            dropdown._hovered = over
            dropdown:_Repaint()
        end
        -- The column scrolls and the window drags, so an open popup has to
        -- follow its field rather than being positioned once.
        if dropdown.IsOpen then dropdown:_Position() end
    end)

    library:Connect(field.MouseButton1Click, function()
        if dropdown.IsOpen then dropdown:Close() else dropdown:Open() end
    end)

    dropdown:_RebuildRows()
    if options.Default ~= nil then dropdown:SetValue(options.Default, true) end

    library.Options[index] = dropdown
    return dropdown
end

---------------------------------------------------------------------------------
-- LISTBOX
---------------------------------------------------------------------------------
function Groupbox:AddListbox(index, options)
    options = options or {}
    local library = self.Library

    local rows = options.Rows or math.max(#(options.Values or {}), 3)
    local height = rows * (M.ListRowH - 2) + 12
    local row = self:_Row(height)

    local box = Util.New("Frame", {
        Name = "Listbox", BackgroundColor3 = Theme.Control, BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), Parent = row,
    })
    Util.Corner(box, M.FieldR)
    Util.Stroke(box, Theme.Line)

    local list = Util.New("ScrollingFrame", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12),
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.LineHi,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        Parent = box,
    })
    Util.List(list, 2)

    local listbox = {
        Type      = "Listbox",
        Index     = index,
        Text      = options.Text or index,
        Values    = options.Values or {},
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
                BackgroundColor3 = Theme.Hover, BackgroundTransparency = 1,
                BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, M.ListRowH - 4),
                LayoutOrder = order, Parent = list,
            })
            Util.Corner(entry, 6)

            local text = library:Label(entry, tostring(value), {
                Color = Theme.Text2, Size = M.TextSize,
                Position = UDim2.fromOffset(10, 0), Size2 = UDim2.new(1, -20, 1, 0),
                ZIndex = 3,
            })

            local record = { Frame = entry, Label = text, Value = value }
            self._rows[#self._rows + 1] = record

            -- Connections, not watchers, for the same reason as the dropdown
            -- rows: these are rebuilt whenever the values change.
            library:Connect(entry.MouseEnter, function()
                record.Hover = true
                self:_Repaint()
            end)
            library:Connect(entry.MouseLeave, function()
                record.Hover = false
                self:_Repaint()
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
            record.Label.TextColor3 = selected and Theme.Text or Theme.Text2
            record.Frame.BackgroundTransparency =
                selected and 0 or (record.Hover and 0.5 or 1)
        end
    end

    function listbox:SetValue(value, silent)
        if type(value) == "number" and self.Values[value] ~= nil then
            value = self.Values[value]
        end
        self.Value = value
        self:_Repaint()
        if silent then return end
        for _, callback in ipairs(self.Callbacks) do pcall(callback, self.Value) end
    end

    function listbox:SetValueSilent(value) self:SetValue(value, true) end

    function listbox:SetValues(newValues, keep)
        self.Values = newValues or {}
        if not keep then
            local present = false
            for _, value in ipairs(self.Values) do
                if value == self.Value then
                    present = true
                    break
                end
            end
            if not present then self.Value = nil end
        end
        self:_Rebuild()
    end

    function listbox:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function listbox:SetVisible(visible) row.Visible = visible and true or false end

    listbox:_Rebuild()
    if options.Default ~= nil then listbox:SetValue(options.Default, true) end

    library.Options[index] = listbox
    return listbox
end

---------------------------------------------------------------------------------
-- INPUT
---------------------------------------------------------------------------------
function Groupbox:AddInput(index, options)
    options = options or {}
    local library = self.Library

    local hasLabel = options.Text ~= nil and options.Text ~= ""
    local row = self:_Row(hasLabel and (16 + 6 + M.FieldH) or M.FieldH)

    if hasLabel then
        library:Label(row, options.Text, {
            Color = Theme.Text2, Size = M.TextSize,
            Size2 = UDim2.new(1, 0, 0, 16),
        })
    end

    local field = Util.New("Frame", {
        Name = "Field", BackgroundColor3 = Theme.Control, BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 0, hasLabel and 22 or 0),
        Size = UDim2.new(1, 0, 0, M.FieldH), Parent = row,
    })
    Util.Corner(field, M.FieldR)
    local stroke = Util.Stroke(field, Theme.Line)

    local textbox = Util.New("TextBox", {
        Name = "Box", BackgroundTransparency = 1, BorderSizePixel = 0,
        ClearTextOnFocus = false, Text = options.Default or "",
        PlaceholderText = options.Placeholder or "",
        PlaceholderColor3 = Theme.Text3,
        TextSize = M.TextSize, TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0),
        ZIndex = 3, Weight = "Medium", Parent = field,
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

    function input:SetValue(value, silent)
        value = tostring(value or "")
        if options.MaxLength and #value > options.MaxLength then
            value = string.sub(value, 1, options.MaxLength)
        end
        if options.Numeric then value = string.gsub(value, "[^%d%.%-]", "") end
        self.Value = value
        if textbox.Text ~= value then textbox.Text = value end
        if silent then return end
        for _, callback in ipairs(self.Callbacks) do pcall(callback, self.Value) end
    end

    function input:SetValueSilent(value) self:SetValue(value, true) end

    function input:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self.Value)
        return self
    end

    function input:SetVisible(visible) row.Visible = visible and true or false end

    library:Connect(textbox.Focused, function()
        Motion.to(stroke, { Color = Theme.LineHi }, Motion.Fast)
        Motion.to(field, { BackgroundColor3 = Theme.Hover }, Motion.Fast)
    end)

    library:Connect(textbox.FocusLost, function(enterPressed)
        Motion.to(stroke, { Color = Theme.Line }, Motion.Fast)
        Motion.to(field, { BackgroundColor3 = Theme.Control }, Motion.Fast)
        if options.Finished then
            if enterPressed or options.FireOnBlur ~= false then
                input:SetValue(textbox.Text)
            else
                textbox.Text = input.Value
            end
        end
    end)

    -- `Finished = true` fires only on Enter / blur, which is what a name or a
    -- path field wants; otherwise every keystroke fires.
    if not options.Finished then
        library:Connect(textbox:GetPropertyChangedSignal("Text"), function()
            input:SetValue(textbox.Text)
        end)
    end

    library.Options[index] = input
    return input
end

---------------------------------------------------------------------------------
-- KEY PICKER
--
-- A chip, sized to its own text. v1 used a fixed 26x11 box with three-letter
-- caps ("SHF", "CTR") because 9px bitmap text could not fit more; with real
-- type there is no reason to abbreviate past recognition, so it reads "Shift".
--
-- Modes:
--   Always  on whenever the parent toggle is on
--   Toggle  each press flips it
--   Hold    on only while held
--
-- Left click binds, right click cycles the mode.
---------------------------------------------------------------------------------
local function CreateKeyPicker(groupbox, parentRow, index, options, parentToggle, offset)
    options = options or {}
    local library = groupbox.Library

    local chip = Util.New("TextButton", {
        Name = "KeyPicker", Text = "", AutoButtonColor = false,
        BackgroundColor3 = Theme.Control, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -(offset or 0), 0.5, 0),
        Size = UDim2.fromOffset(0, M.ChipH),
        AutomaticSize = Enum.AutomaticSize.X,
        ZIndex = 6, Parent = parentRow,
    })
    Util.Corner(chip, M.ChipR)
    Util.Pad(chip, nil, 0, 0, 7, 7)
    local chipStroke = Util.Stroke(chip, Theme.Line)

    local label = library:Label(chip, "—", {
        Weight = "SemiBold", Size = M.SmallSize - 1, Color = Theme.Text3,
        XAlign = Enum.TextXAlignment.Center, Truncate = false,
        Size2 = UDim2.new(0, 0, 1, 0), AutoSize = Enum.AutomaticSize.X,
    })

    local picker = {
        Type       = "KeyPicker",
        Index      = index,
        Text       = options.Text or (parentToggle and parentToggle.Text) or index,
        Value      = options.Default or "",
        Mode       = options.Mode or "Toggle",
        Active     = false,
        ShowInList = options.NoUI ~= true,
        SyncToggle = options.SyncToggleState and true or false,
        Parent     = parentToggle,
        Library    = library,
        Callbacks  = {},
        _capturing = false,
        _hovered   = false,
    }
    if options.Callback then picker.Callbacks[1] = options.Callback end

    function picker:_Repaint()
        local text, textColor, fill, strokeAlpha

        if self._capturing then
            text, textColor = "…", Theme.Text
            fill, strokeAlpha = Theme.Hover, 0
        elseif self.Value == "" then
            text, textColor = "—", Theme.Text3
            fill, strokeAlpha = Theme.Control, 0
        elseif self:GetState() then
            -- Live: the chip is the accent. This is the same white used by a
            -- toggled switch, so "on" looks the same everywhere.
            text, textColor = Util.KeyLabel(self.Value), Theme.OnAccent
            fill, strokeAlpha = Theme.Accent, 1
        else
            text, textColor = Util.KeyLabel(self.Value), Theme.Text2
            fill = self._hovered and Theme.Hover or Theme.Control
            strokeAlpha = 0
        end

        label.Text = text
        Motion.to(label, { TextColor3 = textColor }, Motion.Fast)
        Motion.to(chip, { BackgroundColor3 = fill }, Motion.Fast)
        Motion.to(chipStroke, {
            Transparency = strokeAlpha,
            Color = self._capturing and Theme.LineHi or Theme.Line,
        }, Motion.Fast)
    end

    function picker:SetCapturing(state)
        self._capturing = state and true or false
        self:_Repaint()
    end

    -- The key's own state, ignoring the toggle it is attached to.
    -- SyncToggleState drives the toggle from THIS, not from GetState: GetState
    -- folds the toggle in, so syncing from it would compute "off" for a toggle
    -- that is off and write that straight back, leaving the bind unable to ever
    -- switch its own feature on.
    function picker:GetRawState()
        if self.Value == "" then return true end
        if self.Mode == "Always" then return true end
        if self.Mode == "Hold" then return Util.IsKeyDown(self.Value) end
        return self.Active
    end

    -- What a feature loop should ask: "should the thing this bind guards be
    -- acting right now". Folds in the parent toggle, so a bind on a switched-off
    -- feature reads off however the key is sitting - and the keybind list shows
    -- exactly this, so the panel can never claim a dead feature is live.
    function picker:GetState()
        local parentOn = true
        if self.Parent then
            -- Written out rather than `self.Parent and self.Parent.Value or true`:
            -- that idiom returns true when the parent exists and is false,
            -- because `false or true` is true.
            parentOn = self.Parent.Value and true or false
        end
        return parentOn and self:GetRawState()
    end

    function picker:_Fire()
        local state = self:GetState()
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, state, self.Value, self.Mode)
        end
        if self.SyncToggle and self.Parent then
            self.Parent:SetValue(self:GetRawState())
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
        if self.Mode == "Hold" then self:_Fire() end
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

    function picker:SetVisible(visible) chip.Visible = visible and true or false end
    function picker:SetRowOffset(value) chip.Position = UDim2.new(1, -value, 0.5, 0) end
    function picker:Width() return chip.AbsoluteSize.X end

    library:Watch(function(point)
        local over = Util.PointInside(chip, point)
        if over ~= picker._hovered then
            picker._hovered = over
            picker:_Repaint()
        end
        -- Hold mode gets no press/release event if the key was already down when
        -- the mode changed, and the chip needs the live state regardless.
        local state = picker:GetState()
        if state ~= picker._lastState then
            picker._lastState = state
            picker:_Repaint()
        end
    end)

    library:Connect(chip.MouseButton1Click, function()
        if library._capturing == picker then
            library:_StopCapture()
        else
            library:_StopCapture()
            library:_StartCapture(picker)
        end
    end)

    library:Connect(chip.MouseButton2Click, function()
        local order = { "Always", "Toggle", "Hold" }
        local current = table.find(order, picker.Mode) or 2
        picker:SetMode(order[(current % #order) + 1])
        library:Notify(picker.Text .. " · " .. picker.Mode, 2, "Keybind mode")
    end)

    picker:_Repaint()
    library._keybinds[#library._keybinds + 1] = picker
    library.Options[index] = picker
    return picker
end

---------------------------------------------------------------------------------
-- COLOUR PICKER
--
-- The one place colour is allowed, because it is the thing being edited.
---------------------------------------------------------------------------------
local function CreateColorPicker(groupbox, parentRow, index, options, offset)
    options = options or {}
    local library = groupbox.Library

    local swatch = Util.New("TextButton", {
        Name = "ColorPicker", Text = "", AutoButtonColor = false,
        BackgroundColor3 = options.Default or Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -(offset or 0), 0.5, 0),
        Size = UDim2.fromOffset(M.SwatchW, M.SwatchH),
        ZIndex = 6, Parent = parentRow,
    })
    Util.Corner(swatch, M.SwatchR)
    Util.Stroke(swatch, Theme.Line)

    local picker = {
        Type         = "ColorPicker",
        Index        = index,
        Text         = options.Text or index,
        Value        = options.Default or Color3.new(1, 1, 1),
        Transparency = options.Transparency or 0,
        HasAlpha     = options.Transparency ~= nil,
        IsOpen       = false,
        Library      = library,
        Callbacks    = {},
    }
    if options.Callback then picker.Callbacks[1] = options.Callback end
    picker.Hue, picker.Sat, picker.Val = picker.Value:ToHSV()

    -----------------------------------------------------------------
    -- Popup
    -----------------------------------------------------------------
    local SV_W, SV_H, HUE_W, BAR_H, GAP, PAD = 172, 148, 12, 10, 8, 10
    local popWidth  = PAD + SV_W + GAP + HUE_W + PAD
    local popHeight = PAD + SV_H + GAP + BAR_H + GAP + M.FieldH + PAD

    local popup = Util.New("Frame", {
        Name = "ColorPopup", BackgroundColor3 = Theme.Card, BorderSizePixel = 0,
        Size = UDim2.fromOffset(popWidth, popHeight),
        Visible = false, ZIndex = 60, Parent = library.PopupLayer,
    })
    Util.Corner(popup, M.CardRadius)
    Util.Stroke(popup, Theme.LineHi)

    -- SV square: white-to-hue across, transparent-to-black down.
    local svArea = Util.New("Frame", {
        Name = "SV", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
        Position = UDim2.fromOffset(PAD, PAD),
        Size = UDim2.fromOffset(SV_W, SV_H), ZIndex = 61, Parent = popup,
    })
    Util.Corner(svArea, M.FieldR)
    local svHue = Util.New("UIGradient", {
        Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHSV(0, 1, 1)),
        Parent = svArea,
    })

    local svShade = Util.New("Frame", {
        BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), ZIndex = 62, Parent = svArea,
    })
    Util.Corner(svShade, M.FieldR)
    Util.New("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(1, 0),
        }),
        Parent = svShade,
    })

    local svCursor = Util.New("Frame", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(12, 12), ZIndex = 64, Parent = svArea,
    })
    Util.Corner(svCursor, 6)
    Util.New("UIStroke", {
        Color = Color3.new(1, 1, 1), Thickness = 2, Parent = svCursor,
    })

    local hueBar = Util.New("Frame", {
        Name = "Hue", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
        Position = UDim2.fromOffset(PAD + SV_W + GAP, PAD),
        Size = UDim2.fromOffset(HUE_W, SV_H), ZIndex = 61, Parent = popup,
    })
    Util.Corner(hueBar, HUE_W / 2)
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
        Parent = hueBar,
    })

    local hueCursor = Util.New("Frame", {
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.new(1, 4, 0, 3), ZIndex = 63, Parent = hueBar,
    })
    Util.Corner(hueCursor, 2)
    Util.New("UIStroke", { Color = Theme.Bg, Thickness = 1, Parent = hueCursor })

    -- Alpha bar: the colour ramping over a flat mid-grey. A real checkerboard
    -- would be ~40 frames for a 10px strip.
    local alphaBar, alphaRamp, alphaCursor
    if picker.HasAlpha then
        alphaBar = Util.New("Frame", {
            Name = "Alpha", BackgroundColor3 = Theme.Hover, BorderSizePixel = 0,
            Position = UDim2.fromOffset(PAD, PAD + SV_H + GAP),
            Size = UDim2.fromOffset(SV_W, BAR_H), ZIndex = 61, Parent = popup,
        })
        Util.Corner(alphaBar, BAR_H / 2)

        alphaRamp = Util.New("Frame", {
            Name = "Ramp", BackgroundColor3 = picker.Value, BorderSizePixel = 0,
            Size = UDim2.fromScale(1, 1), ZIndex = 62, Parent = alphaBar,
        })
        Util.Corner(alphaRamp, BAR_H / 2)
        Util.New("UIGradient", {
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1),
                NumberSequenceKeypoint.new(1, 0),
            }),
            Parent = alphaRamp,
        })

        alphaCursor = Util.New("Frame", {
            BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(1, 0.5),
            Size = UDim2.new(0, 3, 1, 4), ZIndex = 63, Parent = alphaBar,
        })
        Util.Corner(alphaCursor, 2)
        Util.New("UIStroke", { Color = Theme.Bg, Thickness = 1, Parent = alphaCursor })
    end

    -- Hex field. Not in most pickers of this kind, but typing a known value is
    -- the one thing an HSV square is bad at.
    local hexField = Util.New("Frame", {
        BackgroundColor3 = Theme.Control, BorderSizePixel = 0,
        Position = UDim2.fromOffset(PAD, popHeight - PAD - M.FieldH),
        Size = UDim2.fromOffset(SV_W + GAP + HUE_W, M.FieldH),
        ZIndex = 61, Parent = popup,
    })
    Util.Corner(hexField, M.FieldR)
    Util.Stroke(hexField, Theme.Line)

    local hexPreview = Util.New("Frame", {
        BackgroundColor3 = picker.Value, BorderSizePixel = 0,
        Position = UDim2.fromOffset(8, (M.FieldH - 18) / 2),
        Size = UDim2.fromOffset(18, 18), ZIndex = 62, Parent = hexField,
    })
    Util.Corner(hexPreview, 5)
    Util.Stroke(hexPreview, Theme.Line)

    local hexBox = Util.New("TextBox", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        ClearTextOnFocus = false, Text = "",
        TextSize = M.TextSize, TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.fromOffset(34, 0), Size = UDim2.new(1, -42, 1, 0),
        ZIndex = 62, Weight = "Medium", Parent = hexField,
    })

    function picker:_Repaint()
        self.Value = Color3.fromHSV(self.Hue, self.Sat, self.Val)

        swatch.BackgroundColor3 = self.Value
        swatch.BackgroundTransparency = self.HasAlpha and self.Transparency or 0

        svHue.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHSV(self.Hue, 1, 1))
        svCursor.Position = UDim2.fromScale(self.Sat, 1 - self.Val)
        hueCursor.Position = UDim2.fromScale(0.5, self.Hue)
        hexPreview.BackgroundColor3 = self.Value

        if alphaRamp then
            alphaRamp.BackgroundColor3 = self.Value
            alphaCursor.Position = UDim2.fromScale(1 - self.Transparency, 0.5)
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
        if transparency ~= nil then
            self.Transparency = Util.Clamp(transparency, 0, 1)
        end
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
    function picker:SetRowOffset(value) swatch.Position = UDim2.new(1, -value, 0.5, 0) end
    function picker:Width() return M.SwatchW end

    function picker:Open()
        library:CloseAllPopups(self)
        self.IsOpen = true

        local origin = swatch.AbsolutePosition
        local viewport = library.ScreenGui.AbsoluteSize
        -- Right-aligned to the swatch and clamped, so a swatch near an edge
        -- still shows the whole popup.
        local x = Util.Clamp(origin.X + M.SwatchW - popWidth, 8,
                             math.max(viewport.X - popWidth - 8, 8))
        local y = origin.Y + M.SwatchH + 8
        if y + popHeight > viewport.Y then
            y = math.max(origin.Y - popHeight - 8, 8)
        end

        popup.Position = UDim2.fromOffset(x, y)
        popup.Visible = true
        popup.BackgroundTransparency = 1
        Motion.to(popup, { BackgroundTransparency = 0 }, Motion.Fast)
        self:_Repaint()
    end

    function picker:Close()
        if not self.IsOpen then return end
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

    -- One shared drag target rather than three sets of connections, so there is
    -- no way to end up dragging two regions at once.
    local dragging = nil

    local function beginDrag(target)
        return function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
            dragging = target
        end
    end

    library:Connect(svShade.InputBegan, beginDrag("sv"))
    library:Connect(svArea.InputBegan, beginDrag("sv"))
    library:Connect(hueBar.InputBegan, beginDrag("hue"))
    if alphaBar then library:Connect(alphaBar.InputBegan, beginDrag("alpha")) end

    library:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 and dragging then
            dragging = nil
            picker:_Fire()
        end
    end)

    library:Watch(function(point)
        if not dragging or not picker.IsOpen then return end

        if dragging == "sv" then
            local pos, size = svArea.AbsolutePosition, svArea.AbsoluteSize
            picker.Sat = Util.Clamp((point.X - pos.X) / size.X, 0, 1)
            picker.Val = 1 - Util.Clamp((point.Y - pos.Y) / size.Y, 0, 1)
        elseif dragging == "hue" then
            local pos, size = hueBar.AbsolutePosition, hueBar.AbsoluteSize
            picker.Hue = Util.Clamp((point.Y - pos.Y) / size.Y, 0, 1)
        elseif dragging == "alpha" and alphaBar then
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

---------------------------------------------------------------------------------
-- STANDALONE PICKERS
---------------------------------------------------------------------------------
function Groupbox:AddKeyPicker(index, options)
    options = options or {}
    local row = self:_Row(M.RowH)
    self.Library:Label(row, options.Text or index, {
        Color = Theme.Text2, Size = M.TextSize,
        Size2 = UDim2.new(1, -70, 1, 0),
    })
    return CreateKeyPicker(self, row, index, options, nil, 0)
end

function Groupbox:AddColorPicker(index, options)
    options = options or {}
    local row = self:_Row(M.RowH)
    self.Library:Label(row, options.Text or index, {
        Color = Theme.Text2, Size = M.TextSize,
        Size2 = UDim2.new(1, -50, 1, 0),
    })
    return CreateColorPicker(self, row, index, options, 0)
end

---------------------------------------------------------------------------------
-- TOGGLE ADDONS
--
-- Chainable, so a feature, its bind and its colour read as one statement:
--
--   Box:AddToggle("Boxes", { Text = "Boxes" })
--      :AddColorPicker("BoxColor", { Default = Color3.new(1, 1, 1) })
--      :AddKeyPicker("BoxKey", { Mode = "Toggle" })
--
-- Addons stack leftward from the switch. Recomputed from scratch on every
-- attach, because the chain can be written in either order and in the colour-
-- first form the swatch exists before the chip it has to make room for.
---------------------------------------------------------------------------------
local function RelayoutAddons(toggle)
    local offset = ADDON_BASE

    if toggle.KeyPicker then
        toggle.KeyPicker:SetRowOffset(offset)
        -- The chip is AutomaticSize, so its width is only known once rendered.
        -- Reserve a sane amount now and correct on the next frame.
        offset = offset + 34 + 8
    end

    local swatches = {}
    for _, addon in ipairs(toggle.Addons) do
        if addon.Type == "ColorPicker" then
            addon:SetRowOffset(offset)
            swatches[#swatches + 1] = addon
            offset = offset + M.SwatchW + 6
        end
    end

    if toggle.KeyPicker and #swatches > 0 then
        task.defer(function()
            local chipWidth = toggle.KeyPicker:Width()
            if chipWidth <= 0 then return end
            local corrected = ADDON_BASE + chipWidth + 8
            for _, swatch in ipairs(swatches) do
                swatch:SetRowOffset(corrected)
                corrected = corrected + M.SwatchW + 6
            end
        end)
    end

    -- Keep the label clear of whatever ended up on the row.
    if toggle._Label then
        toggle._Label.Size = UDim2.new(1, -(offset + 4), 1, 0)
        toggle._Hit.Size   = UDim2.new(1, -(offset + 4), 1, 0)
    end
end

local function AttachKeyPicker(self, index, options)
    options = options or {}
    options.Text = options.Text or self.Text
    local picker = CreateKeyPicker(self.Groupbox, self.Row, index, options, self, ADDON_BASE)
    self.Addons[#self.Addons + 1] = picker
    self.KeyPicker = picker
    RelayoutAddons(self)
    return self
end

local function AttachColorPicker(self, index, options)
    local picker = CreateColorPicker(self.Groupbox, self.Row, index, options, ADDON_BASE)
    self.Addons[#self.Addons + 1] = picker
    self.ColorPicker = self.ColorPicker or picker
    RelayoutAddons(self)
    return self
end

-- Split from _CreateToggle because the addon constructors are locals declared
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
--   <Folder>/settings/autoload.txt   name of the config to load on execute
--   <Folder>/configs/<name>.json     one file per config
--
-- Entries key off the explicit index passed at construction, never a widget's
-- visible text, so renaming a label does not orphan its saved value. Unknown
-- keys in a file are ignored and missing keys keep their defaults, so adding a
-- widget later is backwards compatible.
---------------------------------------------------------------------------------
local SaveManager = {}
SaveManager.__index = SaveManager

function Library:CreateSaveManager(config)
    config = config or {}
    local folder = config.Folder or "uilib"
    if config.SubFolder then folder = folder .. "/" .. config.SubFolder end

    local manager = setmetatable({
        Library = self,
        Folder  = folder,
        Ignore  = {},
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
    for _, index in ipairs(list or {}) do self.Ignore[index] = true end
end

function SaveManager:ConfigPath(name) return self.Folder .. "/configs/" .. name .. ".json" end
function SaveManager:AutoloadPath() return self.Folder .. "/settings/autoload.txt" end

-- Every option type serialises to a plain table: JSONEncode cannot represent a
-- Color3 or an Enum.
function SaveManager:Serialize()
    local data = { Toggles = {}, Options = {} }
    local library = self.Library

    for index, toggle in pairs(library.Toggles) do
        if not self.Ignore[index] then data.Toggles[index] = toggle.Value end
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
    if not fs.Write(self:ConfigPath(name), encoded) then return false, "write failed" end
    return true
end

function SaveManager:Load(name)
    if not name or name == "" then return false, "no config name" end
    local contents = fs.Read(self:ConfigPath(name))
    if not contents then return false, "config does not exist" end
    local ok, decoded = pcall(function() return HttpService:JSONDecode(contents) end)
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
    return name ~= "" and name or nil
end

function SaveManager:LoadAutoloadConfig()
    local name = self:GetAutoload()
    if not name then return false end

    local ok, err = self:Load(name)
    if ok then
        self.Library:Notify(name, 4, "Config loaded")
    else
        self.Library:Notify(tostring(err), 6, "Autoload failed")
    end
    if self._autoloadLabel then
        self._autoloadLabel:SetText("Autoload: " .. name)
    end
    return ok
end

---------------------------------------------------------------------------------
-- SAVE MANAGER UI
---------------------------------------------------------------------------------
function SaveManager:BuildConfigSection(tab, options)
    options = options or {}
    local library = self.Library

    local left  = tab:AddLeftGroupbox("Configs")
    local right = tab:AddRightGroupbox("Interface")

    local list = left:AddListbox("ConfigList", { Values = self:List(), Rows = 5 })
    local nameBox = left:AddInput("ConfigName", {
        Placeholder = "Config name", Finished = true,
    })

    -- The list and the name box drive each other: picking a config fills the
    -- box, so Save overwrites the selected one rather than quietly creating a
    -- near-duplicate.
    list:OnChanged(function(value)
        if value then nameBox:SetValueSilent(value) end
    end)

    local function refresh() list:SetValues(self:List(), true) end

    left:AddButton({ Text = "Save", Primary = true, Func = function()
        local name = nameBox.Value
        local ok, err = self:Save(name)
        if ok then
            refresh()
            library:Notify(name, 3, "Config saved")
        else
            library:Notify(tostring(err), 5, "Save failed")
        end
    end })

    left:AddButton({ Text = "Load", Func = function()
        local name = list.Value or nameBox.Value
        local ok, err = self:Load(name)
        if ok then
            library:Notify(tostring(name), 3, "Config loaded")
        else
            library:Notify(tostring(err), 5, "Load failed")
        end
    end })

    left:AddButton({ Text = "Delete", Confirm = true, Func = function()
        local name = list.Value or nameBox.Value
        local ok, err = self:Delete(name)
        if ok then
            refresh()
            library:Notify(tostring(name), 3, "Config deleted")
        else
            library:Notify(tostring(err), 5, "Delete failed")
        end
    end })

    left:AddButton({ Text = "Refresh list", Func = function()
        refresh()
        library:Notify("Config list refreshed", 2)
    end })

    left:AddDivider()

    self._autoloadLabel = left:AddLabel("Autoload: none")

    left:AddButton({ Text = "Set as autoload", Func = function()
        local name = list.Value or nameBox.Value
        if not name or name == "" then
            library:Notify("Select a config first", 3)
            return
        end
        self:SetAutoload(name)
        self._autoloadLabel:SetText("Autoload: " .. name)
        library:Notify(name .. " will load on execute", 3, "Autoload set")
    end })

    left:AddButton({ Text = "Clear autoload", Func = function()
        self:SetAutoload(nil)
        self._autoloadLabel:SetText("Autoload: none")
        library:Notify("Autoload cleared", 3)
    end })

    local current = self:GetAutoload()
    if current then self._autoloadLabel:SetText("Autoload: " .. current) end

    -----------------------------------------------------------------
    -- Interface
    -----------------------------------------------------------------
    if options.NoMenuSection then return self end

    right:AddDropdown("MenuKey", {
        Text = "Menu key",
        Values = { "Insert", "RightShift", "RightControl", "F1", "F2", "F4", "End" },
        Default = "Insert",
        Callback = function(value)
            local code = Enum.KeyCode[value]
            if code then library.MenuKey = code end
        end,
    })

    right:AddColorPicker("MenuAccent", {
        Text = "Accent", Default = Theme.Accent,
        Callback = function(color) library:SetAccent(color) end,
    })

    -- Defaults read live state, so a script that turned these on before
    -- building this page does not get a switch sitting off next to a visible
    -- panel.
    right:AddToggle("MenuKeybindList", {
        Text = "Keybind list", Default = library.ShowKeybinds,
        Callback = function(value) library:SetKeybindListVisible(value) end,
    })

    right:AddToggle("MenuWatermark", {
        Text = "Watermark",
        Default = (library.Watermark ~= nil) and library.Watermark.Visible or false,
        Callback = function(value) library:SetWatermarkVisible(value) end,
    })

    -- Only offered where CanvasGroup exists. On a client without it the control
    -- would move and nothing would change, which is worse than its absence.
    if library.CanFade then
        right:AddSlider("MenuOpacity", {
            Text = "Opacity", Default = 100, Min = 40, Max = 100, Suffix = "%",
            Callback = function(value)
                library.Opacity = value / 100
                library:Refresh()
            end,
        })
    end

    right:AddDivider()

    right:AddButton({ Text = "Unload", Confirm = true, Func = function()
        library:Unload()
    end })

    -- The menu's own settings are not part of a feature config.
    self:SetIgnoreIndexes({
        "MenuKey", "MenuAccent", "MenuKeybindList", "MenuWatermark", "MenuOpacity",
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

return Library
