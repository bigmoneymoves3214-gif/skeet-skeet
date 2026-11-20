--[[
    uilib - a port of the ATARAX ImGui framework to Roblox
    ===============================================================================

    Not "inspired by". Every colour, size, padding, radius and animation speed in
    here was read out of the C++ source rather than eyeballed from a screenshot:

        settings/colors.h      the palette
        settings/elements.h    every widget's metrics
        settings/variables.h   rounding, anim speed, window and child sizes
        gui.cpp                window composition and tab order
        elements/helpers.cpp   draw_decorations, set_style
        elements/child.cpp     the card
        elements/checkbox.cpp  elements/slider.cpp  elements/combo.cpp
        elements/buttons.cpp   tab_button
        elements/watermark.cpp elements/notify.cpp  elements/hue_slider.cpp
        elements/window.cpp    scrollbar colours

    Things that surprised me reading it, and that a from-a-screenshot guess
    would have got wrong:

      * ROUNDING IS 2. Not 8, not 12. Everything is very slightly softened and
        otherwise square. This single number is most of why the original reads
        as a cheat menu and my earlier attempt read as a web dashboard.
      * THE WINDOW IS TWO RECTS. A 650x80 titlebar and a separate content panel
        below it with a 10px GAP between them - they are not one surface.
      * SEPARATORS BELONG TO ROWS. Every checkbox, slider and combo draws a
        dark34 line across its own bottom edge. They are not group dividers;
        that is why the original looks evenly ruled.
      * DIM TEXT IS NOT DISABLED. An unchecked row is text_inactive (106,106,126)
        and a checked one is pure white, animated between. Nothing in the
        screenshot is greyed out - half of it is just switched off.
      * THE SLIDER GRAB IS A 5x10 WHITE PILL, not a circle, and the track is
        5px tall with a dark42 border over a dark33 fill.
      * CARD WIDTH IS FIXED at 302, and shrinks to 292 when the scrollbar
        appears. Two columns plus a 15px gap is exactly the 620px of content
        area that 650 minus 2x15 padding leaves.

    WHAT CANNOT BE 1:1
    ------------------
    BuilderSans, Roblox's own interface face. Type.init takes a chain of
    families and uses the first that builds, so Library.FontFamily set before
    CreateWindow is a preference rather than a bet: point it at an uploaded
    asset and that wins, give it a name that does not exist and it falls
    through to the next rather than dropping the menu into SourceSans.

    Blur: draw_background_blur() behind the titlebar and watermark needs the
    DX11 swapchain. Nothing in Roblox can blur what is behind a ScreenGui, so
    those surfaces use the same dark14 fill at the same 0.85 alpha without it.

    The public API is unchanged from the previous version, so Private.lua's ~120
    call sites keep working.
]]

local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local HttpService      = game:GetService("HttpService")
local Players          = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

---------------------------------------------------------------------------------
-- PALETTE  (settings/colors.h, verbatim)
---------------------------------------------------------------------------------
local Theme = {
    -- Periwinkle. Everything idle is grey, so the accent is the only hue in the
    -- menu and it marks exactly one thing: what is on, or where you are. Set
    -- Library:SetAccent(c) to change it - every surface that uses it registers,
    -- so it updates live rather than needing a reload.
    Accent = Color3.fromRGB(139, 139, 216),
    White  = Color3.fromRGB(255, 255, 255),
    Black  = Color3.fromRGB(0, 0, 0),

    Dark14 = Color3.fromRGB(14, 14, 17),
    Dark18 = Color3.fromRGB(18, 18, 23),
    Dark22 = Color3.fromRGB(22, 22, 29),
    Dark26 = Color3.fromRGB(26, 28, 36),
    Dark27 = Color3.fromRGB(27, 27, 36),
    Dark33 = Color3.fromRGB(33, 33, 43),
    Dark34 = Color3.fromRGB(34, 34, 45),
    Dark37 = Color3.fromRGB(37, 37, 49),
    Dark42 = Color3.fromRGB(42, 42, 58),
    Dark55 = Color3.fromRGB(55, 55, 75),

    -- Text, read off the reference rather than carried over.
    --
    -- The original's idle grey is (106,106,126), which is dim enough that a
    -- card of labels reads as disabled. In the reference the row labels are a
    -- clearly legible light grey and only the genuinely secondary text - unit
    -- suffixes, hints - drops below that. So TextInactive is lifted to where
    -- those labels actually sit, and TextMuted is added underneath it for the
    -- things that really are quiet.
    TextActive   = Color3.fromRGB(245, 245, 250),
    TextHovered  = Color3.fromRGB(215, 215, 225),
    TextInactive = Color3.fromRGB(165, 165, 178),
    TextMuted    = Color3.fromRGB(110, 110, 125),
}
---------------------------------------------------------------------------------
-- METRICS  (settings/elements.h + settings/variables.h, verbatim)
---------------------------------------------------------------------------------
local M = {
    -- Three radii, not one.
    --
    -- Rounding used to be a single number applied to the window, the cards and
    -- every control alike, which cannot be right: the radius that reads as a
    -- softly rounded panel at 500px across turns a 14px checkbox into a circle.
    -- The reference scales it down as the thing gets smaller, so this does too.
    --
    -- Rounding is the window, CardRounding the cards, CtrlRounding anything you
    -- click - toggles, slider tracks, dropdown fields and their popups. The
    -- control radius is deliberately almost square: in the reference a combo
    -- box and its open list have the corners barely taken off, which is what
    -- keeps a stack of options reading as one block.
    Rounding     = 6,
    CardRounding = 4,
    CtrlRounding = 2,
    AnimSpeed = 14,

    WindowW   = 650,
    WindowH   = 600,
    ScrollW   = 6,

    -- The window is ONE panel now. The original draws a titlebar and a content
    -- rect with a real gap between them; the reference has a single surface
    -- with the branding and tabs sitting on top of it, so the spacing is zero
    -- and the bar is less than half as tall.
    TitlebarH = 46,
    TitlebarSpacing = 0,
    TripleW   = 25,

    -- gui.cpp: dummy(25,0), dummy_line(50), then tabs with 20 spacing
    TabsStartGap = 25,
    TabsLineGap  = 50,
    TabSpacing   = 18,
    TabSplitGap  = 10,     -- the dummy_line after tab index 3
    TabSplitAfter = 4,     -- 0-based index 3, so after the 4th tab
    TabFontSize  = 13,

    ContentPad     = 14,
    ContentSpacing = 12,

    CardW        = 302,
    CardWScroll  = 292,
    CardPadX     = 10,

    RowFontSize  = 14,

    CheckboxH    = 28,
    CheckboxHueH = 50,
    CheckboxBox  = 14,
    CheckboxPadX = 10,
    CheckboxPadY = 10,
    CheckmarkSize = 7,

    SliderH      = 20,
    SliderTotalH = 48,
    SliderTrackH = 5,
    GrabW        = 5,
    GrabH        = 10,

    -- The heading band is the card's whole top strip, so its height is the
    -- card's, not a row's. Its type is a step ABOVE the row size below it:
    -- the reference sets the card name apart by size, not just by the band.
    CardTitleH    = 30,
    CardTitleSize = 15,

    ComboH       = 42,
    ComboBoxW    = 90,
    ComboBoxH    = 22,
    -- The name sits above the field with real air between them; at 2px they
    -- read as one object and the name looks like it is inside the box.
    ComboLabelH   = 16,
    ComboLabelGap = 6,
    ComboPad     = 5,
    ComboFrameX  = 8,
    ComboFrameY  = 6,
    SelectableH  = 20,

    HueH         = 5,

    ColorBtnR    = 6,
    HotkeyW      = 12,
    HotkeyH      = 12,

    ButtonW      = 136,
    ButtonH      = 23,

    FramePadY    = 10,     -- set_style: FramePadding = (0, 10)

    -- colorpicker
    CpWindow     = Vector2.new(164, 191),
    CpWindowNoA  = Vector2.new(164, 178),
    CpSV         = Vector2.new(130, 118),
    CpPad        = 8,
    CpBarH       = 5,
    CpGrabW      = 6,
    CpGrabH      = 8,
    CpCircleR    = 4,
}

-- TYPE
--
-- BuilderSans, Roblox's own interface face: a neo-grotesque, so its letters are
-- narrow and evenly weighted. The reference menu's font is the same kind of
-- face, which is why this reads closer than Montserrat did - Montserrat is a
-- geometric, with rounder bowls and wider caps, and at 12px in a dense card it
-- takes noticeably more horizontal room per word.
--
-- Everything is set Bold and the hierarchy comes from colour instead: a white
-- heading over grey rows. That is how the reference does it, and reserving
-- weight for headings is what made the body text look thin beside it.
--
-- Type.init takes a chain, so Library.FontFamily is a preference rather than a
-- bet - an uploaded face can be dropped in with one line and a bad value falls
-- through to the next instead of dumping the menu into SourceSans.
---------------------------------------------------------------------------------
local Type = { Family = nil, Faces = {}, Legacy = false }

function Type.build(family)
    local weights = {
        Regular  = Enum.FontWeight.Regular,
        Medium   = Enum.FontWeight.Medium,
        SemiBold = Enum.FontWeight.SemiBold,
        Bold     = Enum.FontWeight.Bold,
    }
    local built = {}
    for name, weight in pairs(weights) do
        local ok, face = pcall(function() return Font.new(family, weight) end)
        if not ok or not face then return nil end
        built[name] = face
    end
    return built
end

-- Families are tried in order and the first that builds wins.
--
-- The library used to take one family and drop straight to the legacy Enum.Font
-- path if it failed, which is a long way to fall: a single wrong name and the
-- whole menu renders in SourceSans. A chain means the preferred face is a
-- preference rather than a bet.
--
-- BuilderSans first. It is Roblox's own interface font and a neo-grotesque, so
-- its letterforms are narrow and even - which is what the reference menu's
-- font looks like. Montserrat, which this used to use, is a geometric: rounder
-- bowls, wider caps, noticeably more horizontal space per word. At 12px in a
-- dense card that difference is most of why the text did not match.
local TYPE_FAMILIES = {
    "rbxasset://fonts/families/BuilderSans.json",
    "rbxasset://fonts/families/Montserrat.json",
}

function Type.init(family)
    local tried = {}
    if family then tried[#tried + 1] = family end
    for _, name in ipairs(TYPE_FAMILIES) do tried[#tried + 1] = name end

    for _, name in ipairs(tried) do
        local built = Type.build(name)
        if built then
            Type.Family, Type.Faces, Type.Legacy = name, built, false
            return
        end
    end

    -- Floor for clients without FontFace. Gotham is officially removed, so
    -- SourceSans - which has existed since the beginning - is the guarantee.
    Type.Legacy = true
    local function pick(...)
        for _, name in ipairs({ ... }) do
            local ok, value = pcall(function() return Enum.Font[name] end)
            if ok and value then return value end
        end
        return Enum.Font.SourceSans
    end
    Type.Faces = {
        Regular  = pick("BuilderSans", "Gotham", "SourceSans"),
        Medium   = pick("BuilderSansMedium", "GothamMedium", "SourceSans"),
        SemiBold = pick("BuilderSansBold", "GothamBold", "SourceSansSemibold"),
        Bold     = pick("BuilderSansExtraBold", "GothamBlack", "SourceSansBold"),
    }
end

function Type.apply(label, weight)
    local face = Type.Faces[weight or "Medium"] or Type.Faces.Medium
    if Type.Legacy then
        label.Font = face
    else
        label.FontFace = face
    end
end

---------------------------------------------------------------------------------
-- UTIL
---------------------------------------------------------------------------------
local Util = {}

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

-- rounding is 2 everywhere, so this takes it as the default rather than making
-- every call site repeat it.
function Util.Corner(parent, radius)
    return Util.New("UICorner", {
        CornerRadius = UDim.new(0, radius or M.Rounding), Parent = parent,
    })
end

function Util.Stroke(parent, color, thickness)
    return Util.New("UIStroke", {
        Color = color or Theme.Dark34,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end

function Util.Pad(parent, top, bottom, left, right)
    return Util.New("UIPadding", {
        PaddingTop    = UDim.new(0, top or 0),
        PaddingBottom = UDim.new(0, bottom or 0),
        PaddingLeft   = UDim.new(0, left or 0),
        PaddingRight  = UDim.new(0, right or 0),
        Parent = parent,
    })
end

function Util.List(parent, gap, direction, align)
    return Util.New("UIListLayout", {
        FillDirection = direction or Enum.FillDirection.Vertical,
        HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, gap or 0),
        Parent = parent,
    })
end

-- Roblox has no box-shadow, and the usual workaround - a blurred PNG scaled to
-- fit - needs an asset and distorts on non-square boxes. Stacked translucent
-- rects do not: each layer is one step wider and one step more transparent than
-- the last, which approximates a falloff closely enough at this scale.
--
-- The layers go OUTSIDE the host's bounds, so the host must not clip and must
-- not AutomaticSize (it would measure the shadow and grow forever, which grows
-- the shadow). Give it a plain fixed-size host frame and size that to the box
-- being shadowed.
--
-- Takes pixels, not design units: this lives above S() so it cannot scale for
-- the caller.
function Util.Shadow(host, radius, layers, reach)
    layers = layers or 5
    reach  = reach or 2
    local out = {}
    for depth = 1, layers do
        local spread = depth * reach
        local layer = Util.New("Frame", {
            Name = "Shadow" .. depth,
            BackgroundColor3 = Theme.Black,
            -- 0.60 at the core out to ~0.90 at the edge. Past that it stops
            -- reading as a shadow and starts reading as a grey border.
            BackgroundTransparency = 0.6 + depth * 0.065,
            BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            -- Pushed down by a third of its spread so the light reads as
            -- coming from above rather than from dead centre.
            Position = UDim2.new(0.5, 0, 0.5, math.floor(spread * 0.4)),
            Size = UDim2.new(1, spread * 2, 1, spread * 2),
            ZIndex = -depth,
            Parent = host,
        })
        Util.Corner(layer, (radius or M.Rounding) + spread)
        out[depth] = layer
    end
    return out
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

function Util.PointInside(inst, point)
    if not inst or not inst.Parent or not inst.Visible then return false end
    local pos, size = inst.AbsolutePosition, inst.AbsoluteSize
    return point.X >= pos.X and point.X <= pos.X + size.X
       and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end

function Util.EscapeRich(text)
    local out = string.gsub(tostring(text), "&", "&amp;")
    out = string.gsub(out, "<", "&lt;")
    out = string.gsub(out, ">", "&gt;")
    return out
end

local KEY_LABELS = {
    LeftShift = "SHIFT", RightShift = "SHIFT",
    LeftAlt = "ALT", RightAlt = "ALT",
    LeftControl = "CTRL", RightControl = "CTRL",
    Space = "SPACE", Delete = "DEL", Tab = "TAB", CapsLock = "CAPS",
    Backspace = "BACK", Return = "ENTER", Escape = "ESC",
    MB1 = "MOUSE1", MB2 = "MOUSE2", MB3 = "MOUSE3",
    Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
    Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
}

function Util.KeyLabel(key)
    if not key or key == "" then return "NONE" end
    return KEY_LABELS[key] or string.upper(key)
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
-- ANIMATION
--
-- functions.h: easing(value, target, speed) steps by speed/framerate each frame,
-- i.e. framerate-independent exponential smoothing toward the target, at
-- anim_speed = 14. Not a tween with a duration - there is no "arrival", it just
-- converges, which is why hovering on and off the original feels continuous
-- rather than like two competing tweens.
--
-- Every animated property in the menu is registered here and driven by the one
-- shared RenderStepped pass, so a colour fade costs a lerp and a property write
-- rather than a TweenService object per state change.
---------------------------------------------------------------------------------
local Anim = { List = {} }

function Anim.track(inst, prop, initial, speed)
    local entry = {
        Inst = inst, Prop = prop,
        Value = initial, Target = initial,
        Speed = speed or M.AnimSpeed,
        IsColor = typeof(initial) == "Color3",
    }
    Anim.List[#Anim.List + 1] = entry
    inst[prop] = initial
    return entry
end

function Anim.set(entry, target)
    if entry then entry.Target = target end
end

function Anim.step(dt)
    for index = #Anim.List, 1, -1 do
        local entry = Anim.List[index]
        local inst = entry.Inst
        if not inst or not inst.Parent then
            table.remove(Anim.List, index)
        else
            local alpha = Util.Clamp(dt * entry.Speed, 0, 1)
            if entry.IsColor then
                if entry.Value ~= entry.Target then
                    entry.Value = entry.Value:Lerp(entry.Target, alpha)
                    inst[entry.Prop] = entry.Value
                end
            else
                local diff = entry.Target - entry.Value
                if math.abs(diff) > 0.0005 then
                    entry.Value = entry.Value + diff * alpha
                    inst[entry.Prop] = entry.Value
                elseif entry.Value ~= entry.Target then
                    entry.Value = entry.Target
                    inst[entry.Prop] = entry.Value
                end
            end
        end
    end
end

-- Values that drive geometry rather than an Instance property (a bar's fill
-- fraction, a dropdown's height) use this plain form.
local Scalar = { List = {} }

function Scalar.track(initial, apply, speed)
    local entry = {
        Value = initial, Target = initial,
        Apply = apply, Speed = speed or M.AnimSpeed, Alive = true,
    }
    Scalar.List[#Scalar.List + 1] = entry
    return entry
end

function Scalar.step(dt)
    for index = #Scalar.List, 1, -1 do
        local entry = Scalar.List[index]
        if not entry.Alive then
            table.remove(Scalar.List, index)
        else
            local diff = entry.Target - entry.Value
            if math.abs(diff) > 0.0005 then
                entry.Value = entry.Value + diff * Util.Clamp(dt * entry.Speed, 0, 1)
                local ok = pcall(entry.Apply, entry.Value)
                if not ok then entry.Alive = false end
            end
        end
    end
end

---------------------------------------------------------------------------------
-- FILESYSTEM SHIM
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
-- LIBRARY
---------------------------------------------------------------------------------
local Library = {
    Theme = Theme, Metrics = M, Util = Util, Type = Type, FS = fs, Anim = Anim,

    -- Preferred face. Type.init tries this first, then its own chain, so
    -- overriding it with an uploaded font is still a one-line change and a bad
    -- value costs nothing but the fallback.
    FontFamily = "rbxasset://fonts/families/BuilderSans.json",

    Toggles = {}, Options = {},

    Unloaded = false,
    Open = false,
    MenuKey = Enum.KeyCode.Insert,
    ShowKeybinds = false,

    -- var->gui.dpi is 1.35 in the original. 1 here so the menu is 650x600 as
    -- authored; raise it for a bigger menu on a high-DPI display.
    Scale = 1,

    _connections = {}, _renderBinds = {}, _popups = {},
    _keybinds = {}, _watchers = {}, _accent = {},
}
Library.__index = Library

-- SCALE() in the original. Every metric goes through it.
local function S(value)
    return math.floor(value * Library.Scale + 0.5)
end
Library.S = S

-- CanvasGroup renders its subtree to a texture and exposes a single
-- transparency for all of it, which is the only way to fade a whole panel -
-- text, strokes, borders and all - without walking every descendant and
-- animating it separately. It is not on every client, so where it is missing
-- the same surfaces are plain Frames and the transitions degrade to an instant
-- swap rather than breaking.
Library.CanFade = (function()
    local ok, inst = pcall(Instance.new, "CanvasGroup")
    if ok and inst then
        inst:Destroy()
        return true
    end
    return false
end)()

function Library:Surface(props, children)
    return Util.New(self.CanFade and "CanvasGroup" or "Frame", props, children)
end

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

    for _, callback in ipairs(self._unloadCallbacks or {}) do pcall(callback) end

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

    -- Everything below the ScreenGui is gone now, so the handles to it have to
    -- go too: each of the _Create* builders returns early when its handle is
    -- set, and a destroyed Instance is still truthy. Without this, a second
    -- load on the same Library table would silently come up with no watermark,
    -- no keybind list and no notifications.
    self.KeybindFrame, self.KeybindRows = nil, nil
    self.Watermark, self.NotifyLayer = nil, nil
    self.Modal, self.PopupLayer, self.Window = nil, nil, nil
    self._keybindSignature = nil
    -- The topbar's own "already built" handles, for the same reason: they gate
    -- the rebuild, and the watcher they gate was dropped with _watchers.
    self.Topbar, self._topbar = nil, nil
    self._topbarWatcher, self._topbarNext, self._fps = nil, nil, nil

    Anim.List, Scalar.List = {}, {}
    self.Toggles, self.Options = {}, {}
    self._popups, self._keybinds, self._watchers, self._accent = {}, {}, {}, {}
end

-- Accent is a live colour in the original (there is a colour picker for it on
-- the MISC tab), so anything painted with it registers rather than baking it.
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

function Library:Refresh() end

---------------------------------------------------------------------------------
-- TEXT
---------------------------------------------------------------------------------
function Library:Label(parent, text, opts)
    opts = opts or {}
    return Util.New("TextLabel", {
        BackgroundTransparency = 1,
        Text = text or "",
        TextSize = S(opts.Size or M.RowFontSize),
        TextColor3 = opts.Color or Theme.TextInactive,
        TextXAlignment = opts.XAlign or Enum.TextXAlignment.Left,
        TextYAlignment = opts.YAlign or Enum.TextYAlignment.Center,
        TextTruncate = opts.Truncate ~= false
            and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
        RichText = opts.Rich or false,
        Position = opts.Position or UDim2.new(),
        Size = opts.Size2 or UDim2.fromScale(1, 1),
        AnchorPoint = opts.AnchorPoint or Vector2.new(),
        AutomaticSize = opts.AutoSize or Enum.AutomaticSize.None,
        ZIndex = opts.ZIndex or 2,
        -- Bold by default, not Medium.
        --
        -- Every label in the reference is heavy - row names, card headings,
        -- tabs alike - and the hierarchy between them is carried by COLOUR: a
        -- white heading over grey rows. Setting type at Medium and reserving
        -- weight for headings is the other way of building the same hierarchy,
        -- and it is the one that made the text look thin beside the reference.
        Weight = opts.Weight or "Bold",
        Parent = parent,
    })
end

---------------------------------------------------------------------------------
-- HOVER WATCHERS
---------------------------------------------------------------------------------
function Library:Watch(fn)
    self._watchers[#self._watchers + 1] = fn
    return fn
end

function Library:_StartLoop()
    self:Connect(RunService.RenderStepped, function(dt)
        if self.Unloaded then return end

        Anim.step(dt)
        Scalar.step(dt)

        local mouse = UserInputService:GetMouseLocation()
        local point = Vector2.new(mouse.X, mouse.Y - self._guiInset)
        for index = #self._watchers, 1, -1 do
            local ok, keep = pcall(self._watchers[index], point, dt)
            if not ok or keep == false then table.remove(self._watchers, index) end
        end
    end)
end

---------------------------------------------------------------------------------
-- POPUPS
---------------------------------------------------------------------------------
-- Absolute screen coordinates into PopupLayer's own local space.
--
-- This is why every popup landed low. They are positioned from the control's
-- AbsolutePosition, but Position is set in the PARENT's local space, and those
-- two are not the same here: the layer sits in a ScreenGui with IgnoreGuiInset
-- on, so its local origin is the true top-left of the screen while
-- AbsolutePosition is reported from below the topbar. Feeding one into the
-- other dropped every popup by the height of that inset - about 36px - so a
-- dropdown opened a card's width below its own field instead of against it.
--
-- Subtracting the layer's own AbsolutePosition cancels it without anyone
-- having to know what the inset is, or which way round to apply it: both
-- values are in the same space, so their difference is the local offset.
function Library:ToLayer(x, y)
    local layer = self.PopupLayer
    if not layer then return x, y end
    local origin = layer.AbsolutePosition
    return x - origin.X, y - origin.Y
end

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

    Type.init(self.FontFamily)

    self.ScreenGui = Util.New("ScreenGui", {
        Name = HttpService:GenerateGUID(false),
        DisplayOrder = 999,
        IgnoreGuiInset = true,
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })

    if syn and syn.protect_gui then pcall(syn.protect_gui, self.ScreenGui) end
    if protect_gui then pcall(protect_gui, self.ScreenGui) end
    self.ScreenGui.Parent = self:_Parent()

    self._guiInset = 0
    pcall(function()
        self._guiInset = game:GetService("GuiService"):GetGuiInset().Y
    end)

    self.Modal = Util.New("TextButton", {
        Name = "Modal", Text = "", Modal = false, AutoButtonColor = false,
        BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 1), ZIndex = 0,
        Parent = self.ScreenGui,
    })

    self.PopupLayer = Util.New("Frame", {
        Name = "Popups", BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), ZIndex = 5000, Parent = self.ScreenGui,
    })

    self:_StartLoop()

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

function Library:Draggable(handle, targets)
    local dragging, origin, startPos = false, nil, nil

    self:Connect(handle.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if self:AnyPopupOpen() then return end
        dragging, origin = true, input.Position
        startPos = {}
        for index, target in ipairs(targets) do startPos[index] = target.Position end
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
        for index, target in ipairs(targets) do
            local base = startPos[index]
            target.Position = UDim2.new(
                base.X.Scale, base.X.Offset + delta.X,
                base.Y.Scale, base.Y.Offset + delta.Y
            )
        end
    end)
end

---------------------------------------------------------------------------------
-- WINDOW  (helpers.cpp draw_decorations + gui.cpp composition)
--
-- The window is TWO rects, not one:
--
--   titlebar   650 x 80   dark14 @ 0.85   rounded 3
--     (10px gap - genuinely empty, the desktop shows through)
--   content    650 x 510  dark18          rounded 3
--
-- A transparent root holds both so dragging moves them together; in the
-- original they are one ImGui window drawn as two rects.
---------------------------------------------------------------------------------
local Window = {}
Window.__index = Window

function Library:CreateWindow(config)
    config = config or {}
    self:_CreateRoot()

    if config.Accent then Theme.Accent = config.Accent end
    if config.MenuKey then self.MenuKey = config.MenuKey end
    if config.Scale then self.Scale = config.Scale end

    local window = setmetatable({
        Library = self, Tabs = {}, TabCount = 0,
        Title = config.Title or "ATARAX",
    }, Window)
    self.Window = window

    -- The original is a fixed 650x600 for six short tabs. A consumer with more
    -- or longer tabs can widen it; the tab strip also auto-fits below.
    local winW, winH = S(config.Width or M.WindowW), S(config.Height or M.WindowH)
    local barH = S(M.TitlebarH)
    local gap  = S(M.TitlebarSpacing)
    local wr   = S(M.Rounding + 1)   -- set_style: WindowRounding = rounding + 1

    -- A CanvasGroup so the whole menu can fade as one surface on open and
    -- close. Popups live in their own layer outside it, so a dropdown is not
    -- clipped by the group's texture.
    local root = self:Surface({
        Name = "Window", BackgroundTransparency = 1,
        AnchorPoint = config.Center == false and Vector2.new() or Vector2.new(0.5, 0.5),
        Position = config.Center == false
            and (config.Position or UDim2.fromOffset(120, 120))
            or UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(winW, winH),
        Visible = false, ZIndex = 100, Parent = self.ScreenGui,
    })
    window.Root = root

    -----------------------------------------------------------------
    -- One panel.
    --
    -- The original draws two rects with a real gap between them, a titlebar
    -- plane above a content plane. The reference is a single surface with the
    -- branding and the tabs sitting ON it, which is why its titlebar has no
    -- edge of its own and no colour of its own - so there is one filled,
    -- rounded, stroked frame here, and the bar is a transparent region of it.
    -----------------------------------------------------------------
    local panel = Util.New("Frame", {
        Name = "Panel", BackgroundColor3 = Theme.Dark14, BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), Parent = root,
    })
    Util.Corner(panel, wr)
    Util.Stroke(panel, Theme.Dark27)
    window.Panel = panel

    local titlebar = Util.New("Frame", {
        Name = "Titlebar", BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, barH), ZIndex = 2, Parent = panel,
    })
    self:Draggable(titlebar, { root })

    -----------------------------------------------------------------
    -- Branding: your avatar, then the name.
    --
    -- The three-dot grip the original had is gone. It was a drag affordance for
    -- a bar that is already draggable along its whole length, so it only ever
    -- marked the corner - and the corner is better spent saying whose menu
    -- this is.
    --
    -- The avatar is fetched from the thumbnail service rather than hardcoded,
    -- in a pcall and on its own thread: it is a web request, it can fail or be
    -- slow, and a menu that blocks on a picture looks broken on a cold join.
    -- The circle is drawn either way and fills in when the image arrives.
    -----------------------------------------------------------------
    local brandPadX = S(16)
    local avatarD   = S(32)

    local avatar = Util.New("ImageLabel", {
        Name = "Avatar", BackgroundColor3 = Theme.Dark27, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, brandPadX, 0.5, 0),
        Size = UDim2.fromOffset(avatarD, avatarD),
        Image = "", ZIndex = 3, Parent = titlebar,
    })
    Util.Corner(avatar, math.floor(avatarD / 2))
    Util.Stroke(avatar, Theme.Dark42)
    window.Avatar = avatar

    task.spawn(function()
        pcall(function()
            local players = game:GetService("Players")
            local me = players.LocalPlayer
            if not me then return end
            local url = players:GetUserThumbnailAsync(
                me.UserId,
                Enum.ThumbnailType.HeadShot,
                Enum.ThumbnailSize.Size100x100)
            if url and avatar.Parent then avatar.Image = url end
        end)
    end)

    -- Beside the avatar: how long is left on your key.
    --
    -- This corner used to carry the script's name, which is the one thing you
    -- already know - you opened it. Time remaining is the thing you would
    -- otherwise have to leave the game to find out.
    --
    -- The value is a placeholder until something real feeds it. SetBrandText
    -- is the hook: call it with whatever the key server returns and the label
    -- updates in place, no rebuild.
    window.BrandLabel = self:Label(titlebar, config.BrandText or "-- --", {
        Color = Theme.TextActive, Size = 15, Weight = "Bold", Truncate = false,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, brandPadX + avatarD + S(10), 0.5, 0),
        Size2 = UDim2.fromOffset(0, S(18)),
        AutoSize = Enum.AutomaticSize.X, ZIndex = 3,
    })

    function window:SetBrandText(text)
        self.BrandLabel.Text = tostring(text or "")
    end

    -- Right-aligned. The branding owns the left of the bar, so the tabs run to
    -- the right edge and grow leftward as they are added - which also means the
    -- tab you are on never moves when a later one is added.
    window.TabStrip = Util.New("Frame", {
        Name = "Tabs", BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -S(20), 0, 0),
        -- Starts after the branding so auto-fit measures the space it really
        -- has, not the whole bar.
        Size = UDim2.new(1, -S(16 + 32 + 10 + 140), 1, 0),
        ZIndex = 2, Parent = titlebar,
    })
    window.TabLayout = Util.List(
        window.TabStrip, S(M.TabSpacing),
        Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Right)

    -----------------------------------------------------------------
    -- Tab auto-fit
    --
    -- Six short tabs fit 650px; eight longer ones do not, and the overflow just
    -- runs off the titlebar because a UIListLayout does not wrap or shrink.
    --
    -- This converges over a few frames rather than solving in one: a label's
    -- width comes from AutomaticSize, and neither that nor the layout's
    -- AbsoluteContentSize updates within the frame that changed TextSize - so
    -- there is nothing to measure against until the next one. It gives up
    -- spacing first (cheap) and only then type size, and grows back the same
    -- way if tabs are removed or the window widens.
    -----------------------------------------------------------------
    local fitFont, fitSpacing = M.TabFontSize, M.TabSpacing

    self:Watch(function()
        if not window.TabStrip.Parent then return false end
        if #window.Tabs == 0 then return end

        local avail = window.TabStrip.AbsoluteSize.X
        local content = window.TabLayout.AbsoluteContentSize.X
        if avail <= 0 or content <= 0 then return end

        local changed = false
        if content > avail then
            if fitSpacing > 6 then
                fitSpacing = fitSpacing - 1
                changed = true
            elseif fitFont > 11 then
                fitFont = fitFont - 1
                changed = true
            end
        -- The 0.9 slack is hysteresis: growing back the instant there is a
        -- pixel spare would oscillate forever one step either side of the fit.
        elseif content < avail * 0.9 then
            if fitFont < M.TabFontSize then
                fitFont = fitFont + 1
                changed = true
            elseif fitSpacing < M.TabSpacing then
                fitSpacing = fitSpacing + 1
                changed = true
            end
        end

        if changed then
            window.TabLayout.Padding = UDim.new(0, S(fitSpacing))
            for _, tab in ipairs(window.Tabs) do
                tab.Label.TextSize = S(fitFont)
            end
        end
    end)

    -----------------------------------------------------------------
    -- Content panel
    -----------------------------------------------------------------
    -- A transparent region of the panel, not a plane of its own. In the
    -- reference the cards are the only thing below the titlebar that has a
    -- fill, so the area behind them is simply the window.
    local content = Util.New("Frame", {
        Name = "Content", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, barH + gap),
        Size = UDim2.fromOffset(winW, winH - barH - gap),
        ZIndex = 2, Parent = panel,
    })
    window.ContentFrame = content

    -- ScrollingFrame has no track colour, so the dark26 track the original
    -- draws behind its grab is a frame of its own.
    window.ScrollTrack = Util.New("Frame", {
        Name = "ScrollTrack", BackgroundColor3 = Theme.Dark26, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -S(M.ContentPad) + S(M.ScrollW), 0, S(M.ContentPad)),
        Size = UDim2.new(0, S(M.ScrollW), 1, -S(M.ContentPad * 2)),
        Visible = false, ZIndex = 2, Parent = content,
    })
    Util.Corner(window.ScrollTrack, S(M.CtrlRounding))

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

    if not self.Open then
        self:CloseAllPopups()
        self:_StopCapture()
    end

    if not self.CanFade then
        root.Visible = self.Open
        return
    end

    -- Shown immediately on the way in so the first frame of the fade has
    -- something to draw; hidden on the way out only once the fade has run,
    -- which the setter below handles.
    if self.Open then root.Visible = true end

    if not self._openFade then
        self._openFade = Scalar.track(0, function(value)
            root.GroupTransparency = 1 - value
            if value <= 0.02 and not self.Open then root.Visible = false end
        end, M.AnimSpeed * 1.5)
        root.GroupTransparency = 1
    end

    self._openFade.Target = self.Open and 1 or 0
end

---------------------------------------------------------------------------------
-- TABS  (buttons.cpp tab_button)
--
-- Text only, font 18, width is the text's width, full titlebar height. Colour
-- eases accent / hovered / inactive. No underline, no pill, no background -
-- the colour IS the state.
---------------------------------------------------------------------------------
local Tab = {}
Tab.__index = Tab

function Window:AddTab(name, _icon)
    local library = self.Library
    self.TabCount = self.TabCount + 1
    local index = self.TabCount

    -- gui.cpp puts a dummy_line between tab index 3 and 4 (MISC | CONFIG).
    -- LayoutOrder is doubled so a divider can sit on the odd number between.
    if index == M.TabSplitAfter + 1 then
        local holder = Util.New("Frame", {
            Name = "TabDivider", BackgroundTransparency = 1,
            Size = UDim2.new(0, S(M.TabSplitGap), 1, 0),
            LayoutOrder = index * 2 - 1, Parent = self.TabStrip,
        })
        Util.New("Frame", {
            BackgroundColor3 = Theme.Dark34, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(1, S(16)), Parent = holder,
        })
    end

    local tab = setmetatable({
        Library = library, Window = self, Name = name, Index = index,
        Cards = {},
    }, Tab)

    local button = Util.New("TextButton", {
        Name = "Tab" .. index, Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
        LayoutOrder = index * 2, Parent = self.TabStrip,
    })
    tab.Button = button

    tab.Label = library:Label(button, name, {
        Weight = "Bold", Size = M.TabFontSize, Color = Theme.TextInactive,
        XAlign = Enum.TextXAlignment.Center, Truncate = false,
        Size2 = UDim2.new(0, 0, 1, 0), AutoSize = Enum.AutomaticSize.X,
    })
    tab.LabelAnim = Anim.track(tab.Label, "TextColor3", Theme.TextInactive)

    -- The glow under the active tab.
    --
    -- A 2px accent bar whose gradient runs transparent at both ends and opaque
    -- in the middle, so it reads as light bleeding out from under the tab
    -- rather than an underline with two hard stops. UIGradient.Transparency
    -- takes a NumberSequence, which is the only way to fade a frame along an
    -- axis without stacking parts.
    --
    -- Eased rather than switched, so changing tabs fades one out while the next
    -- comes up instead of jumping between them.
    tab.Glow = Util.New("Frame", {
        Name = "Glow", BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -S(12)),
        Size = UDim2.new(1, S(18), 0, S(2)),
        BackgroundTransparency = 1,
        ZIndex = 2, Parent = button,
    })
    library:Accent(tab.Glow)
    Util.New("UIGradient", {
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.5, 0),
            NumberSequenceKeypoint.new(1, 1),
        }),
        Parent = tab.Glow,
    })
    tab.GlowAnim = Anim.track(tab.Glow, "BackgroundTransparency", 1)

    -----------------------------------------------------------------
    -- Page: two columns inside one scrolling region, exactly as
    -- gui.cpp does with begin_group / sameline / begin_group.
    -----------------------------------------------------------------
    -- The page lives inside a group so the whole thing - cards, rules, text -
    -- fades as one surface on a tab change. The ScrollingFrame cannot do that
    -- itself: fading it would mean animating every descendant.
    tab.Wrap = library:Surface({
        Name = "Page" .. index, BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), Visible = false,
        Parent = self.ContentFrame,
    })

    tab.Page = Util.New("ScrollingFrame", {
        Name = "Scroll", BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = S(M.ScrollW),
        ScrollBarImageColor3 = Theme.Accent,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        VerticalScrollBarInset = Enum.ScrollBarInset.None,
        Parent = tab.Wrap,
    })
    library:Accent(tab.Page, "ScrollBarImageColor3")

    -- Fade and a short rise on entry. Driven by the same Scalar easing as every
    -- other animation in the library, so the tab change shares a curve with the
    -- toggles and sliders rather than being a tween with its own feel.
    tab.Fade = Scalar.track(0, function(value)
        if library.CanFade then
            tab.Wrap.GroupTransparency = 1 - value
        end
        tab.Wrap.Position = UDim2.fromOffset(0, math.floor((1 - value) * S(10)))
    end, M.AnimSpeed * 1.3)
    Util.Pad(tab.Page, S(M.ContentPad), S(M.ContentPad), S(M.ContentPad), S(M.ContentPad))
    Util.List(tab.Page, S(M.ContentSpacing), Enum.FillDirection.Horizontal)

    -- Two columns and one gap inside the padded content area. The original
    -- hardcodes 302 because its window is a fixed 650 - deriving it instead
    -- gives the same 302 at 650 and still fills a window the consumer widened.
    local function columnWidth(scrolls)
        local inner = self.ContentFrame.AbsoluteSize.X - S(M.ContentPad * 2)
        if inner <= 0 then inner = S(M.WindowW - M.ContentPad * 2) end
        if scrolls then inner = inner - S(M.ScrollW + 4) end
        return math.max((inner - S(M.ContentSpacing)) / 2, S(80))
    end

    -- Takes a parent, so a subtab can make its pair inside its own surface
    -- rather than directly in the scroll.
    local function column(order, parent)
        local frame = Util.New("Frame", {
            Name = "Column" .. order, BackgroundTransparency = 1,
            Size = UDim2.fromOffset(columnWidth(false), 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            LayoutOrder = order, Parent = parent or tab.Page,
        })
        Util.List(frame, S(M.ContentSpacing))
        return frame
    end
    tab.Left  = column(1)
    tab.Right = column(2)

    -- Exposed so subtabs can make more of the same, and tracked in one list so
    -- the width easing below resizes every column rather than only the first
    -- pair. A subtab is just another pair hidden until it is selected.
    tab._Column  = column
    tab._Columns = { tab.Left, tab.Right }
    tab.Columns  = tab._Columns

    -- init_child_anim: the width eases rather than snapping when the scrollbar
    -- appears, so the content does not jump sideways the moment a card grows.
    tab.WidthAnim = Scalar.track(columnWidth(false), function(value)
        local width = UDim2.fromOffset(math.floor(value), 0)
        for _, col in ipairs(tab._Columns) do col.Size = width end
    end)

    library:Watch(function()
        -- Visibility moved to the wrapper when the page gained its fade group;
        -- the ScrollingFrame itself is now always Visible inside it.
        if not tab.Page.Parent then return false end
        if not tab.Wrap.Visible then return end
        local scrolls = tab.Page.AbsoluteCanvasSize.Y > tab.Page.AbsoluteWindowSize.Y
        tab.WidthAnim.Target = columnWidth(scrolls)
        self.ScrollTrack.Visible = scrolls
    end)

    local hovered = false
    library:Watch(function(point)
        if not button.Parent then return false end
        local over = Util.PointInside(button, point) and library.Open
        if over ~= hovered then
            hovered = over
            tab:_Repaint()
        end
    end)
    tab._Hovered = function() return hovered end

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
    local hovered = self._Hovered and self._Hovered() or false
    Anim.set(self.LabelAnim,
        active and Theme.Accent
        or (hovered and Theme.TextHovered or Theme.TextInactive))
    Anim.set(self.GlowAnim, active and 0 or 1)
end

function Window:SetActiveTab(tab)
    if self.ActiveTab == tab then return end

    local library = self.Library
    library:CloseAllPopups()

    local previous = self.ActiveTab
    self.ActiveTab = tab

    if previous then
        previous.Wrap.Visible = false
        previous:_Repaint()
    end
    tab:_Repaint()

    -- The outgoing page is cut rather than cross-faded. Both pages occupy the
    -- same rectangle, so fading them through each other shows two sets of cards
    -- overlapping at half opacity for the duration - which reads as a glitch,
    -- not a transition. Cutting the old one and lifting the new one in is what
    -- actually looks deliberate.
    tab.Wrap.Visible = true
    tab.Fade.Value = 0
    tab.Fade.Target = 1
    if library.CanFade then tab.Wrap.GroupTransparency = 1 end
    tab.Wrap.Position = UDim2.fromOffset(0, S(10))
end

---------------------------------------------------------------------------------
-- CARD  (child.cpp)
--
-- dark22 fill, dark34 border, rounding 2, 10px horizontal padding and ZERO
-- vertical padding or item spacing - rows butt against each other and are
-- separated by the line each one draws along its own bottom edge.
---------------------------------------------------------------------------------
local Groupbox = {}
Groupbox.__index = Groupbox

function Tab:_NewCard(column)
    local library = self.Library

    local box = setmetatable({
        Library = library, Tab = self, Order = 0, Rows = {},
    }, Groupbox)

    -- Dark18 on the panel's Dark14, with a Dark27 edge: barely lighter than
    -- what it sits on. That restraint is most of why the reference reads as a
    -- quiet sheet of panels rather than a stack of boxes - Dark22 with a Dark34
    -- edge was a step too strong on both counts.
    local frame = Util.New("Frame", {
        Name = "Card", BackgroundColor3 = Theme.Dark18, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = #self.Cards + 1, Parent = column,
    })
    Util.Corner(frame, S(M.CardRounding))
    Util.Stroke(frame, Theme.Dark27)
    -- The card itself holds exactly two things, stacked and flush: the heading
    -- band and the body. It carries NO padding of its own, because the band has
    -- to reach the card's edges - the padding belongs to the body below.
    Util.List(frame, 0)
    box.Frame = frame

    -- THE HEADING IS THE CARD'S ENTIRE TOP STRIP: a lighter band running the
    -- full width, corner to corner, with the title sitting in it and the dark
    -- body below. Not a stripe floating inside the card with card fill showing
    -- around it - that is what this was, and it was wrong.
    --
    -- WHY IT WAS WRONG, because it is not obvious from reading the old code: the
    -- band was a child of the card, the card had a UIListLayout, and a
    -- UIListLayout POSITIONS its children. The negative Position meant to pull
    -- the band out to the card's edges was simply discarded, so it rendered as
    -- an ordinary row - inset by the card's 12px side padding and sitting below
    -- its 10px top padding. No offset could have fixed that; the band has to be
    -- outside the padded region altogether, which is why the body is now its own
    -- frame and the padding moved onto it.
    box.TitleRow = Util.New("Frame", {
        Name = "Title", BackgroundColor3 = Theme.Dark33, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, S(M.CardTitleH)),
        Visible = false, LayoutOrder = 1, Parent = frame,
    })
    Util.Corner(box.TitleRow, S(M.CardRounding))

    -- UICorner rounds all four, and only the top two should be: the band meets
    -- the body below it on a straight edge. A patch the height of the radius
    -- squares the bottom off again.
    Util.New("Frame", {
        Name = "TitleFoot", BackgroundColor3 = Theme.Dark33, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, S(M.CardRounding)),
        Parent = box.TitleRow,
    })

    box.TitleLabel = library:Label(box.TitleRow, "", {
        Color = Theme.TextActive, Size = M.CardTitleSize, Weight = "Bold",
        Position = UDim2.fromOffset(S(12), 0),
        Size2 = UDim2.new(1, -S(24), 1, 0), ZIndex = 2,
    })

    -- The body. Everything that is not the heading lives here, and this is what
    -- carries the padding the card used to.
    local body = Util.New("Frame", {
        Name = "Body", BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = 2, Parent = frame,
    })
    Util.Pad(body, S(10), S(10), S(12), S(12))
    Util.List(body, S(2))
    box.Body = body

    function box:SetTitle(text)
        text = text and tostring(text) or ""
        self.TitleLabel.Text = text
        self.TitleRow.Visible = text ~= ""
    end

    self.Cards[#self.Cards + 1] = box
    return box
end

-- The original has no card titles at all - a card is an unlabelled container
-- and the rows inside carry all the text. A name is accepted for API
-- compatibility and used only as the instance name.
function Tab:AddLeftGroupbox(name, _weight)
    local box = self:_NewCard(self.Left)
    if name then
        box.Frame.Name = tostring(name)
        box:SetTitle(name)
    end
    return box
end

function Tab:AddRightGroupbox(name, _weight)
    local box = self:_NewCard(self.Right)
    if name then
        box.Frame.Name = tostring(name)
        box:SetTitle(name)
    end
    return box
end

function Tab:AddGroupbox(name, grid)
    local right = type(grid) == "table" and (grid.X or 0) >= 4.5
    return right and self:AddRightGroupbox(name) or self:AddLeftGroupbox(name)
end

-- Every row owns the separator beneath it, and the LAST row in a card hides
-- its own - that is what `if (content_avail().y > 0)` does in the C++. Tracked
-- here so adding a row re-shows the previous one's line.
function Groupbox:_Row(height, noSeparator)
    self.Order = self.Order + 1

    local row = Util.New("Frame", {
        Name = "Row", BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, S(height)),
        LayoutOrder = self.Order, Parent = self.Body,
    })
    self.Rows[#self.Rows + 1] = row

    -- No rule between rows any more.
    --
    -- The original rules every row, which suits its denser spacing; the
    -- reference separates rows with air alone, and at this row height a line
    -- between each one turns a card into a table. The separator object is still
    -- returned, hidden, because AddDivider and a few callers hold onto it - so
    -- nothing downstream has to know this changed.
    local separator = Util.New("Frame", {
        Name = "Separator", BackgroundColor3 = Theme.Dark27, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, 1),
        Visible = false, Parent = row,
    })

    if noSeparator then return row, nil end
    return row, separator
end

---------------------------------------------------------------------------------
-- SHARED PIECES
---------------------------------------------------------------------------------

-- The combo's trailing glyph: ONE down chevron, built from two rotated bars
-- rather than a font glyph (an arrow character is absent from most families and
-- would render as a box).
--
-- It used to be a stacked pair - an up chevron above a down one, the way a
-- spinner is drawn - and at this size the two merged into something that read
-- as a caret pointing up. A dropdown opens downward, so it gets one arrow
-- pointing that way and nothing else.
--
-- Rotation direction matters and is easy to get backwards: a horizontal bar at
-- +45 runs DOWN to the right, so the DOWN chevron is +45 on its left half and
-- -45 on its right. Reversed, the halves meet at the wrong ends and render
-- as an X.
local function comboArrow(parent, x)
    local holder = Util.New("Frame", {
        Name = "Arrow", BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -S(x or 8), 0.5, 0),
        Size = UDim2.fromOffset(S(8), S(8)), ZIndex = 3, Parent = parent,
    })
    for _, spec in ipairs({
        { 0.22, 45 }, { 0.78, -45 },
    }) do
        Util.New("Frame", {
            BackgroundColor3 = Theme.TextInactive, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(spec[1], 0, 0.5, 0),
            Size = UDim2.fromOffset(S(5), math.max(1, S(1))),
            Rotation = spec[2], Parent = holder,
        })
    end
    return holder
end

-- Both the slider track and the combo box are a dark33 fill inside a dark42
-- hairline at rounding 2.
local function framedBox(parent, props)
    local box = Util.New("Frame", props, nil)
    box.BackgroundColor3 = Theme.Dark33
    box.BorderSizePixel = 0
    box.Parent = props.Parent
    Util.Corner(box, S(M.CtrlRounding))
    Util.Stroke(box, Theme.Dark42)
    return box
end

---------------------------------------------------------------------------------
-- LABEL / DIVIDER
---------------------------------------------------------------------------------
function Groupbox:AddLabel(text, options)
    if type(options) == "boolean" then options = { Special = options } end
    options = options or {}

    local library = self.Library
    local row = self:_Row(M.CheckboxH)

    local label = library:Label(row, text, {
        Color = options.Special and Theme.TextActive or Theme.TextInactive,
        Wrapped = options.Wrapped,
        Size2 = UDim2.new(1, 0, 1, 0),
    })

    local object = {
        Type = "Label", Row = row, Label = label,
        SetText = function(_, value) label.Text = tostring(value) end,
        SetVisible = function(_, visible) row.Visible = visible and true or false end,
    }
    return object
end

function Groupbox:AddDivider()
    -- Every row already rules its own bottom edge, so an explicit divider is
    -- just a short empty row rather than another line.
    local row = self:_Row(10, true)
    return { Type = "Divider", Row = row }
end

---------------------------------------------------------------------------------
-- TOGGLE  (checkbox.cpp)
--
-- 15x15 box, dark33 -> accent, black checkmark fading in, label at x=25 easing
-- inactive -> hovered -> white. The whole row is the hit target.
---------------------------------------------------------------------------------
local ADDON_GAP = 10

function Groupbox:_CreateToggle(index, options)
    options = options or {}
    local library = self.Library
    local row = self:_Row(M.CheckboxH)

    -- Label left, box right.
    --
    -- The original puts the checkbox first and the name after it, reading like
    -- a form. Every row in the reference reads the other way: the name owns the
    -- left of the row and the control sits hard against the right edge, so a
    -- card is a column of names with a column of states beside it and the eye
    -- can run straight down either one. Addons - the gear, the colour swatch -
    -- stack leftward from the box.
    --
    -- No checkmark. The box simply fills: dark33 when off, accent when on. A
    -- tick inside a 14px square is mostly noise at this size, and the fill
    -- already carries the state unambiguously.
    local box = Util.New("Frame", {
        Name = "Box", BackgroundColor3 = Theme.Dark33, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(S(M.CheckboxBox), S(M.CheckboxBox)),
        ZIndex = 2, Parent = row,
    })
    Util.Corner(box, S(M.CtrlRounding))
    Util.Stroke(box, Theme.Dark42)

    local label = library:Label(row, options.Text or index, {
        Color = Theme.TextInactive,
        Size2 = UDim2.new(1, -S(M.CheckboxBox + 12), 1, 0),
        ZIndex = 2,
    })

    local hit = Util.New("TextButton", {
        Name = "Hit", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, S(M.CheckboxH)), ZIndex = 3, Parent = row,
    })

    local toggle = {
        Type = "Toggle", Index = index, Text = options.Text or index,
        Value = options.Default and true or false,
        Row = row, Groupbox = self, Library = library,
        Callbacks = {}, Addons = {}, _hovered = false,
        _BoxAnim = Anim.track(box, "BackgroundColor3", Theme.Dark33),
        _TextAnim = Anim.track(label, "TextColor3", Theme.TextInactive),
    }
    if options.Callback then toggle.Callbacks[1] = options.Callback end

    function toggle:_Repaint()
        Anim.set(self._BoxAnim, self.Value and Theme.Accent or Theme.Dark33)
        Anim.set(self._TextAnim, self.Value and Theme.TextActive
            or (self._hovered and Theme.TextHovered or Theme.TextInactive))
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
        self.Text = tostring(value); label.Text = self.Text
    end

    library:Watch(function(point)
        if not row.Parent then return false end
        local over = Util.PointInside(hit, point)
        if over ~= toggle._hovered then
            toggle._hovered = over
            toggle:_Repaint()
        end
    end)

    library:Connect(hit.MouseButton1Click, function()
        if library:AnyPopupOpen() then return end
        toggle:SetValue(not toggle.Value)
    end)

    toggle._Label, toggle._Hit, toggle._Row = label, hit, row
    toggle:_Repaint()

    library.Toggles[index] = toggle
    return toggle
end

---------------------------------------------------------------------------------
-- SLIDER  (slider.cpp)
--
-- Name left in inactive grey, value right in white, both at y=10. A 5px track
-- at y=33 - dark33 fill, dark42 hairline - with an accent fill and a 5x10 white
-- grab. Total row height 48.
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

    local row = self:_Row(M.SliderTotalH)

    local label = library:Label(row, options.Text or index, {
        Color = Theme.TextInactive,
        Position = UDim2.fromOffset(0, S(M.FramePadY)),
        Size2 = UDim2.new(1, -S(70), 0, S(13)),
    })

    local valueLabel = library:Label(row, "", {
        Color = Theme.TextActive, XAlign = Enum.TextXAlignment.Right,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, S(M.FramePadY)),
        Size2 = UDim2.fromOffset(S(70), S(13)), Truncate = false,
    })

    local trackY = S(M.FramePadY) + S(13) + S(M.FramePadY)

    local track = framedBox(row, {
        Name = "Track",
        Position = UDim2.fromOffset(0, trackY),
        Size = UDim2.new(1, 0, 0, S(M.SliderTrackH)),
        ZIndex = 2, Parent = row,
    })

    local fill = library:Accent(Util.New("Frame", {
        Name = "Fill", BorderSizePixel = 0,
        Size = UDim2.fromScale(0, 1), ZIndex = 3, Parent = track,
    }), "BackgroundColor3")
    Util.Corner(fill, S(M.CtrlRounding))

    local grab = Util.New("Frame", {
        Name = "Grab", BackgroundColor3 = Theme.White, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(S(M.GrabW), S(M.GrabH)),
        ZIndex = 4, Parent = track,
    })
    Util.Corner(grab, S(M.CtrlRounding))

    -- The invisible drag target spans the whole row below the labels, matching
    -- the InvisibleButton of (width, total_y - y) in the original - a 5px track
    -- would be unusable otherwise.
    local hit = Util.New("TextButton", {
        Name = "Hit", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, S(M.SliderH)),
        Size = UDim2.new(1, 0, 0, S(M.SliderTotalH - M.SliderH)),
        ZIndex = 5, Parent = row,
    })

    local slider = {
        Type = "Slider", Index = index, Text = options.Text or index,
        Min = minimum, Max = maximum,
        Value = Util.Clamp(options.Default or minimum, minimum, maximum),
        Row = row, Library = library, Callbacks = {}, _dragging = false,
    }
    if options.Callback then slider.Callbacks[1] = options.Callback end

    local function format(value)
        local text = rounding > 0
            and string.format("%." .. rounding .. "f", value)
            or tostring(math.floor(value + 0.5))
        return prefix .. text .. suffix
    end

    -- The fill and grab ease toward the value (anim_w in the original) rather
    -- than snapping, so a click at the far end slides instead of jumping.
    slider._Anim = Scalar.track(0, function(alpha)
        fill.Size = UDim2.new(alpha, S(2), 1, 0)
        -- grab_rect.Max.x is pos + (width - grab_size.x) * t in the original, so
        -- the grab's LEFT edge travels over (width - 5), not width. Without the
        -- correction term it overhangs the track by its own width at 100%.
        grab.Position = UDim2.new(alpha, -S(M.GrabW) * alpha, 0.5, 0)
    end)

    function slider:_Repaint()
        local span = self.Max - self.Min
        self._Anim.Target = span > 0 and ((self.Value - self.Min) / span) or 0
        valueLabel.Text = format(self.Value)
    end

    function slider:SetValue(value, silent)
        -- Coerced before clamping. Clamp compares the value against Min, so a
        -- nil or a numeric string - from a caller, or from a config file,
        -- which is just text on disk - threw inside that comparison rather
        -- than anywhere that named the slider.
        value = tonumber(value)
        if not value then return end

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
        local width = math.max(track.AbsoluteSize.X - 1, 1)
        local alpha = Util.Clamp((x - left) / width, 0, 1)
        return slider.Min + alpha * (slider.Max - slider.Min)
    end

    library:Connect(hit.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        if library:AnyPopupOpen() then return end
        slider._dragging = true
        slider:SetValue(valueFromX(UserInputService:GetMouseLocation().X))
    end)

    library:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            slider._dragging = false
        end
    end)

    library:Watch(function(point)
        if not row.Parent then return false end
        if slider._dragging then slider:SetValue(valueFromX(point.X)) end
    end)

    slider:_Repaint()
    slider._Anim.Value = slider._Anim.Target
    pcall(slider._Anim.Apply, slider._Anim.Value)

    library.Options[index] = slider
    return slider
end

---------------------------------------------------------------------------------
-- DROPDOWN  (combo.cpp)
--
-- Name on the left easing with hover, a 90x22 dark33 box on the right holding
-- the preview in white at font 12 with a double-arrow glyph. The popup is the
-- same width as the box - narrow, which is how the original reads.
---------------------------------------------------------------------------------
function Groupbox:AddDropdown(index, options)
    options = options or {}
    local library = self.Library

    local multi = options.Multi and true or false

    -- Stacked, not side by side.
    --
    -- The original puts the name on the left of the row and a 90px box on the
    -- right. The reference puts the name ABOVE a full-width field, which is
    -- what lets the open list line up with the field edge-to-edge instead of
    -- hanging off one end of the row - and gives long option names somewhere
    -- to go. The row is taller to pay for it.
    local row = self:_Row(M.ComboLabelH + M.ComboLabelGap + M.ComboBoxH + 6)

    local label = library:Label(row, options.Text or index, {
        Color = Theme.TextInactive, Size = 12,
        Size2 = UDim2.new(1, 0, 0, S(M.ComboLabelH)),
    })

    local box = framedBox(row, {
        Name = "Box",
        Position = UDim2.fromOffset(0, S(M.ComboLabelH + M.ComboLabelGap)),
        Size = UDim2.new(1, 0, 0, S(M.ComboBoxH)),
        ZIndex = 2, Parent = row,
    })

    -- The value reads in the accent, the way the reference shows a selection.
    -- It is the only text on the row that is not grey or white, which is what
    -- makes a glance down a card land on what is actually set.
    local preview = library:Label(box, "", {
        Color = Theme.Accent, Size = 12,
        Position = UDim2.fromOffset(S(M.ComboFrameX), 0),
        Size2 = UDim2.new(1, -S(M.ComboFrameX + 22), 1, 0), ZIndex = 3,
    })
    library:Accent(preview, "TextColor3")
    comboArrow(box, 10)

    local hit = Util.New("TextButton", {
        Name = "Hit", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
        ZIndex = 4, Parent = box,
    })

    local dropdown = {
        Type = "Dropdown", Index = index, Text = options.Text or index,
        Multi = multi, Values = options.Values or {},
        Value = multi and {} or nil,
        IsOpen = false, Row = row, Library = library,
        Callbacks = {}, _rows = {}, _hovered = false,
        _TextAnim = Anim.track(label, "TextColor3", Theme.TextInactive),
    }
    if options.Callback then dropdown.Callbacks[1] = options.Callback end

    -----------------------------------------------------------------
    -- Popup
    -----------------------------------------------------------------
    -- Dark22 on the field's Dark33, so the open list reads as a well sunk into
    -- the menu rather than a lighter card floating over it - which is how the
    -- reference shows it, and what lets a highlighted row be the brightest
    -- thing in the list.
    local popup = Util.New("Frame", {
        Name = "Popup", BackgroundColor3 = Theme.Dark22, BorderSizePixel = 0,
        Visible = false, ClipsDescendants = true, ZIndex = 50,
        Parent = library.PopupLayer,
    })
    Util.Corner(popup, S(M.CtrlRounding))
    Util.Stroke(popup, Theme.Dark42)

    -- Tight. The options in the reference are stacked with no air between them
    -- and only a few pixels of inset at the walls - the list is a block of
    -- choices, not a spaced-out menu - so the gap between rows is zero and the
    -- highlight band on one runs straight into its neighbour.
    local LIST_PAD = 4

    local list = Util.New("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(S(LIST_PAD), S(LIST_PAD)),
        Size = UDim2.new(1, -S(LIST_PAD * 2), 1, -S(LIST_PAD * 2)),
        ZIndex = 51, Parent = popup,
    })
    Util.List(list, 0)

    function dropdown:_Height()
        -- Rows butt up against each other, so the height is just the rows plus
        -- the wall inset. It was computing a gap per row that no longer exists,
        -- which left a growing band of dead space at the bottom of long lists.
        local count = math.max(#self.Values, 1)
        return count * S(M.SelectableH) + S(LIST_PAD * 2)
    end

    function dropdown:_PreviewText()
        if self.Multi then
            local parts = {}
            for _, value in ipairs(self.Values) do
                if self.Value[value] then parts[#parts + 1] = tostring(value) end
            end
            return #parts == 0 and "None" or table.concat(parts, ", ")
        end
        return self.Value == nil and (options.Placeholder or "None") or tostring(self.Value)
    end

    function dropdown:_RebuildRows()
        for _, record in ipairs(self._rows) do record.Frame:Destroy() end
        self._rows = {}

        for order, value in ipairs(self.Values) do
            -- Options read near-white, not grey.
            --
            -- These were TextInactive, the same dim tone as a row label, which
            -- is wrong for a list: a row label sits beside the thing it names
            -- and can afford to recede, but every line of an open list is a
            -- choice and they all have to be readable at once. In the reference
            -- the unpicked options are as bright as body text and only the
            -- picked one changes colour.
            local entry = Util.New("TextButton", {
                Name = "Option", Text = "", AutoButtonColor = false,
                BackgroundColor3 = Theme.Dark37,
                BackgroundTransparency = 1, BorderSizePixel = 0,
                Size = UDim2.new(1, 0, 0, S(M.SelectableH)),
                LayoutOrder = order, ZIndex = 52, Parent = list,
            })
            Util.Corner(entry, S(M.CtrlRounding))

            local text = library:Label(entry, tostring(value), {
                Color = Theme.TextActive, Size = 12,
                Position = UDim2.fromOffset(S(8), 0),
                Size2 = UDim2.new(1, -S(12), 1, 0), ZIndex = 53,
            })

            local record = {
                Frame = entry, Label = text, Value = value,
                Anim = Anim.track(text, "TextColor3", Theme.TextActive),
                Fill = Anim.track(entry, "BackgroundTransparency", 1),
            }
            self._rows[#self._rows + 1] = record

            library:Connect(entry.MouseEnter, function()
                record.Hover = true; self:_Repaint()
            end)
            library:Connect(entry.MouseLeave, function()
                record.Hover = false; self:_Repaint()
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
            local selected = self.Multi
                and (self.Value[record.Value] and true or false)
                or (self.Value == record.Value)
            -- Picked: accent text on a clear band. Hovered: the same band,
            -- weaker, with the text left alone - so hover says "this is under
            -- the cursor" and only the colour says "this is the one set".
            Anim.set(record.Anim, selected and Theme.Accent or Theme.TextActive)
            Anim.set(record.Fill, selected and 0.15
                or (record.Hover and 0.45 or 1))
        end

        Anim.set(self._TextAnim, self.IsOpen and Theme.TextActive
            or (self._hovered and Theme.TextHovered or Theme.TextInactive))
    end

    function dropdown:_Fire()
        for _, callback in ipairs(self.Callbacks) do pcall(callback, self.Value) end
    end

    function dropdown:SetValue(value, silent)
        if self.Multi then
            local set = {}
            if type(value) == "table" then
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
        local height = self:_Height()
        local origin = box.AbsolutePosition
        -- Flush under the field, not floating off it: 2px, so the list reads as
        -- the field opening rather than a separate panel appearing nearby.
        local below = origin.Y + box.AbsoluteSize.Y + S(2)
        local viewport = library.ScreenGui.AbsoluteSize.Y

        if below + height > viewport and origin.Y - height - S(2) > 0 then
            below = origin.Y - height - S(2)
        end

        popup.Position = UDim2.fromOffset(library:ToLayer(origin.X, below))
        self._HeightValue = height
        popup.Size = UDim2.fromOffset(box.AbsoluteSize.X, self._Anim and self._Anim.Value or height)
    end

    -- dropdown_y eases open and shut in the original, so the popup grows out of
    -- the box rather than appearing whole.
    dropdown._Anim = Scalar.track(0, function(value)
        popup.Size = UDim2.fromOffset(box.AbsoluteSize.X, math.max(value, 0))
        popup.Visible = value > 0.5
    end)

    function dropdown:Open()
        library:CloseAllPopups(self)
        self.IsOpen = true
        self:_Position()
        popup.Visible = true
        self._Anim.Target = self._HeightValue
        self:_Repaint()
    end

    function dropdown:Close()
        if not self.IsOpen then return end
        self.IsOpen = false
        self._Anim.Target = 0
        self:_Repaint()
    end

    function dropdown:HitTest(point)
        return Util.PointInside(popup, point) or Util.PointInside(box, point)
    end

    library:RegisterPopup(dropdown)

    library:Watch(function(point)
        if not row.Parent then return false end
        local over = Util.PointInside(box, point) or Util.PointInside(row, point)
        if over ~= dropdown._hovered then
            dropdown._hovered = over
            dropdown:_Repaint()
        end
        if dropdown.IsOpen then dropdown:_Position() end
    end)

    library:Connect(hit.MouseButton1Click, function()
        if dropdown.IsOpen then dropdown:Close() else dropdown:Open() end
    end)

    dropdown:_RebuildRows()
    if options.Default ~= nil then dropdown:SetValue(options.Default, true) end

    library.Options[index] = dropdown
    return dropdown
end

---------------------------------------------------------------------------------
-- BUTTON  (buttons.cpp, elements->button.size = 136x23)
---------------------------------------------------------------------------------
function Groupbox:AddButton(options, func)
    if type(options) == "string" then options = { Text = options, Func = func } end
    options = options or {}

    local library = self.Library
    local row = self:_Row(M.ButtonH + M.FramePadY * 2)

    local button = framedBox(row, {
        Name = "Button",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, S(M.ButtonH)),
        ZIndex = 2, Parent = row,
    })

    local hit = Util.New("TextButton", {
        Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), ZIndex = 4, Parent = button,
    })

    local label = library:Label(button, options.Text or "Button", {
        Color = Theme.TextInactive, XAlign = Enum.TextXAlignment.Center,
        ZIndex = 3,
    })
    local textAnim = Anim.track(label, "TextColor3", Theme.TextInactive)
    local fillAnim = Anim.track(button, "BackgroundColor3", Theme.Dark33)

    local armed, hovered, held = false, false, false

    -- The fill moves as well as the text. Text-only feedback on a button the
    -- size of this one is easy to miss, and a press that does not visibly
    -- depress reads as a click that did not land.
    local function repaint()
        Anim.set(textAnim, (hovered or held) and Theme.TextActive or Theme.TextInactive)
        Anim.set(fillAnim, held and Theme.Dark27
            or (hovered and Theme.Dark37 or Theme.Dark33))
    end

    library:Watch(function(point)
        if not row.Parent then return false end
        local over = Util.PointInside(button, point)
        if over ~= hovered then
            hovered = over
            if not over then held = false end
            repaint()
        end
    end)

    library:Connect(hit.MouseButton1Down, function()
        held = true
        repaint()
    end)
    library:Connect(hit.MouseButton1Up, function()
        held = false
        repaint()
    end)

    library:Connect(hit.MouseButton1Click, function()
        if library:AnyPopupOpen() then return end

        if options.Confirm and not armed then
            armed = true
            label.Text = "ARE YOU SURE?"
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
            if not ok then library:Notify(tostring(err), 6) end
        end
    end)

    local object = { Type = "Button", Row = row, Button = button, Label = label }
    function object:SetText(value)
        options.Text = tostring(value); label.Text = options.Text
    end
    function object:SetVisible(visible) row.Visible = visible and true or false end
    return object
end

---------------------------------------------------------------------------------
-- LISTBOX
---------------------------------------------------------------------------------
function Groupbox:AddListbox(index, options)
    options = options or {}
    local library = self.Library

    local rows = options.Rows or math.max(#(options.Values or {}), 3)
    -- Kept in unscaled units and scaled once at the end: _Row scales what it is
    -- given, so handing it an already-scaled number and dividing it back out
    -- loses a pixel to rounding at every DPI but 1.
    local inner = rows * M.SelectableH + M.ComboPad * 2
    local row = self:_Row(inner + M.FramePadY)

    local box = framedBox(row, {
        Name = "Listbox",
        Position = UDim2.fromOffset(0, S(M.FramePadY / 2)),
        Size = UDim2.new(1, 0, 0, S(inner)),
        ZIndex = 2, Parent = row,
    })

    local list = Util.New("ScrollingFrame", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(S(M.ComboPad), S(M.ComboPad)),
        Size = UDim2.new(1, -S(M.ComboPad * 2), 1, -S(M.ComboPad * 2)),
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = S(3), ScrollBarImageColor3 = Theme.Accent,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ElasticBehavior = Enum.ElasticBehavior.Never,
        ZIndex = 3, Parent = box,
    })
    library:Accent(list, "ScrollBarImageColor3")
    Util.List(list, 0)

    local listbox = {
        Type = "Listbox", Index = index, Text = options.Text or index,
        Values = options.Values or {}, Value = nil,
        Row = row, Library = library, Callbacks = {}, _rows = {},
    }
    if options.Callback then listbox.Callbacks[1] = options.Callback end

    function listbox:_Rebuild()
        for _, record in ipairs(self._rows) do record.Frame:Destroy() end
        self._rows = {}

        for order, value in ipairs(self.Values) do
            local entry = Util.New("TextButton", {
                Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, S(M.SelectableH)),
                LayoutOrder = order, ZIndex = 4, Parent = list,
            })
            local text = library:Label(entry, tostring(value), {
                Color = Theme.TextInactive, Size = 12, ZIndex = 5,
            })

            local record = {
                Frame = entry, Label = text, Value = value,
                Anim = Anim.track(text, "TextColor3", Theme.TextInactive),
            }
            self._rows[#self._rows + 1] = record

            library:Connect(entry.MouseEnter, function()
                record.Hover = true; self:_Repaint()
            end)
            library:Connect(entry.MouseLeave, function()
                record.Hover = false; self:_Repaint()
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
            Anim.set(record.Anim, selected and Theme.Accent
                or (record.Hover and Theme.TextHovered or Theme.TextInactive))
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
-- INPUT  (input_text.cpp padding 9,6)
---------------------------------------------------------------------------------
function Groupbox:AddInput(index, options)
    options = options or {}
    local library = self.Library
    local row = self:_Row(M.ComboH)

    local field = framedBox(row, {
        Name = "Field",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 0, S(M.ComboBoxH)),
        ZIndex = 2, Parent = row,
    })

    local textbox = Util.New("TextBox", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        ClearTextOnFocus = false, Text = options.Default or "",
        PlaceholderText = options.Placeholder or options.Text or "",
        PlaceholderColor3 = Theme.TextInactive,
        TextSize = S(12), TextColor3 = Theme.TextActive,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.fromOffset(S(9), 0),
        Size = UDim2.new(1, -S(18), 1, 0),
        ZIndex = 3, Weight = "Medium", Parent = field,
    })

    local input = {
        Type = "Input", Index = index, Text = options.Text or index,
        Value = options.Default or "", Row = row, Library = library, Callbacks = {},
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

    library.Options[index] = input
    return input
end

---------------------------------------------------------------------------------
-- KEY PICKER  (hotkey.cpp, 12x12 cog at the row's right edge)
--
-- The original's cog is a glyph from an icon font. Fonts cannot be added here,
-- so it is drawn: a ring plus six radial teeth. Each tooth is positioned on the
-- circle and rotated to match, because Roblox rotates a frame about its own
-- centre rather than about a parent origin.
---------------------------------------------------------------------------------
-- The gear.
--
-- A real icon, with the drawn one kept as a fallback.
--
-- Six rotated rectangles around a ring is a recognisable cog at 20px and a
-- smudge at 12, which is the size it actually renders at here. Roblox ships an
-- icon set as ordinary image assets, so the first choice is one of those.
--
-- The catch is that an asset id either resolves on a given client or silently
-- renders nothing, and a settings button that is invisible is worse than one
-- drawn out of frames. So the image is tried, and if it has not loaded shortly
-- after it is asked for, the drawn cog is switched on in its place. Both exist
-- from the start and only visibility changes, which means no rebuilding and no
-- flicker in the common case where the image is already cached.
local COG_IMAGE = "rbxassetid://10734950309"

local function cogDrawn(parent, color)
    local holder = Util.New("Frame", {
        Name = "CogDrawn", BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1), ZIndex = 6, Parent = parent,
    })

    local parts = {}
    for index = 0, 5 do
        local angle = math.rad(index * 60)
        local radius = S(4)
        local tooth = Util.New("Frame", {
            BackgroundColor3 = color, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, math.cos(angle) * radius, 0.5, math.sin(angle) * radius),
            Size = UDim2.fromOffset(S(4), S(2.5)),
            Rotation = index * 60, Parent = holder,
        })
        parts[#parts + 1] = { Inst = tooth, Prop = "BackgroundColor3" }
    end

    local ring = Util.New("Frame", {
        BackgroundColor3 = color, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(S(8), S(8)), ZIndex = 7, Parent = holder,
    })
    Util.Corner(ring, S(4))
    parts[#parts + 1] = { Inst = ring, Prop = "BackgroundColor3" }

    -- The hole has to match whatever is behind the cog, so it is filled with
    -- the card colour rather than being transparent.
    local hole = Util.New("Frame", {
        BackgroundColor3 = Theme.Dark22, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(S(3.5), S(3.5)), ZIndex = 8, Parent = holder,
    })
    Util.Corner(hole, S(2))

    return holder, parts
end

-- Returns the holder and the list of things to tint, exactly as the drawn
-- version did, so CreateKeyPicker below needs no changes: the image is just
-- another entry in that list and Anim.track drives ImageColor3 the same way it
-- drives BackgroundColor3.
local function cog(parent, color)
    local holder = Util.New("Frame", {
        Name = "Cog", BackgroundTransparency = 1,
        Size = UDim2.fromOffset(S(M.HotkeyW), S(M.HotkeyH)),
        ZIndex = 6, Parent = parent,
    })

    local icon = Util.New("ImageLabel", {
        Name = "CogIcon", BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Image = COG_IMAGE, ImageColor3 = color,
        ZIndex = 6, Parent = holder,
    })

    local drawn, parts = cogDrawn(holder, color)
    drawn.Visible = false

    -- Give the asset a moment, then settle on whichever one works. IsLoaded is
    -- the only honest test: a bad id neither errors nor draws.
    task.spawn(function()
        for _ = 1, 20 do
            if not holder.Parent then return end
            if icon.IsLoaded then return end
            task.wait(0.1)
        end
        if holder.Parent and not icon.IsLoaded then
            icon.Visible = false
            drawn.Visible = true
        end
    end)

    parts[#parts + 1] = { Inst = icon, Prop = "ImageColor3" }
    return holder, parts
end

local function CreateKeyPicker(groupbox, parentRow, index, options, parentToggle, offset)
    options = options or {}
    local library = groupbox.Library

    local button = Util.New("TextButton", {
        Name = "KeyPicker", Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -(offset or 0), 0.5, 0),
        Size = UDim2.fromOffset(S(M.HotkeyW), S(M.HotkeyH)),
        ZIndex = 6, Parent = parentRow,
    })

    -- cog returns {Inst, Prop} pairs rather than bare frames, because the icon
    -- tints through ImageColor3 and the drawn fallback through
    -- BackgroundColor3. Tracking the property each part actually uses is what
    -- lets both answer to one colour.
    local _, teeth = cog(button, Theme.TextInactive)
    local anims = {}
    for i, part in ipairs(teeth) do
        anims[i] = Anim.track(part.Inst, part.Prop, Theme.TextInactive)
    end

    local picker = {
        Type = "KeyPicker", Index = index,
        Text = options.Text or (parentToggle and parentToggle.Text) or index,
        Value = options.Default or "", Mode = options.Mode or "Toggle",
        Active = false, ShowInList = options.NoUI ~= true,
        SyncToggle = options.SyncToggleState and true or false,
        Parent = parentToggle, Library = library, Callbacks = {},
        IsOpen = false, _capturing = false, _hovered = false,
    }
    if options.Callback then picker.Callbacks[1] = options.Callback end

    function picker:_Repaint()
        local color
        if self._capturing then
            color = Theme.TextActive
        elseif self.Value == "" then
            color = self._hovered and Theme.TextHovered or Theme.TextInactive
        elseif self:GetState() then
            color = Theme.Accent
        else
            color = self._hovered and Theme.TextHovered or Theme.TextInactive
        end
        for _, anim in ipairs(anims) do Anim.set(anim, color) end
    end

    function picker:SetCapturing(state)
        self._capturing = state and true or false
        self:_Repaint()
        self:_Sync()
    end

    -- The key's own state, ignoring the toggle it hangs off. SyncToggleState
    -- drives the toggle from THIS: GetState folds the toggle in, so syncing
    -- from it would write "off" back to an off toggle and the bind could never
    -- switch its own feature on.
    function picker:GetRawState()
        if self.Value == "" then return true end
        if self.Mode == "Always" then return true end
        if self.Mode == "Hold" then return Util.IsKeyDown(self.Value) end
        return self.Active
    end

    function picker:GetState()
        local parentOn = true
        if self.Parent then parentOn = self.Parent.Value and true or false end
        return parentOn and self:GetRawState()
    end

    function picker:_Fire()
        local state = self:GetState()
        for _, callback in ipairs(self.Callbacks) do
            pcall(callback, state, self.Value, self.Mode)
        end

        -- Only a BOUND key syncs its toggle. GetRawState answers true for an
        -- unbound picker, and that answer is right for what it is for - gating,
        -- where "no key" must not block the feature - but it is not a keybind
        -- state, and pushing it into the toggle switched the feature ON.
        --
        -- Which is what made loading a config turn things on by itself: the
        -- restore assigns the saved key, that fires, and a picker with no key
        -- reported "on" and forced its toggle true. Every feature with a
        -- SyncToggleState bind and no key set came up enabled on every load,
        -- autoload included.
        if self.SyncToggle and self.Parent and self.Value ~= "" then
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
        self:_Sync()
        if not silent then self:_Fire() end
    end

    function picker:SetValueSilent(key) self:SetValue(key, true) end

    function picker:SetMode(mode, silent)
        self.Mode = mode or "Toggle"
        self.Active = false
        self:_Repaint()
        self:_Sync()
        if not silent then self:_Fire() end
    end

    function picker:OnChanged(callback)
        self.Callbacks[#self.Callbacks + 1] = callback
        pcall(callback, self:GetState(), self.Value, self.Mode)
        return self
    end

    function picker:SetVisible(visible) button.Visible = visible and true or false end
    function picker:SetRowOffset(value) button.Position = UDim2.new(1, -value, 0.5, 0) end
    function picker:Width() return S(M.HotkeyW) end

    -- The panel is built further down, so every state change routes through
    -- here rather than calling it directly and exploding on the ones that fire
    -- during construction.
    function picker:_Sync()
        if self._RefreshPanel then self:_RefreshPanel() end
    end

    library:Watch(function(point)
        if not button.Parent then return false end
        local over = Util.PointInside(button, point)
        local state = picker:GetState()
        if over ~= picker._hovered or state ~= picker._lastState then
            picker._hovered, picker._lastState = over, state
            picker:_Repaint()
        end
    end)

    -----------------------------------------------------------------
    -- Hotkey panel
    --
    -- The cog used to arm key capture directly, with the only feedback being a
    -- 12px icon changing colour - which reads as the button doing nothing, and
    -- gave no way at all to reach the mode. elements->hotkey_window in the
    -- original is a 175x105 popup, so this is that, with three things the first
    -- pass got wrong:
    --
    --   * It never said WHICH bind you were editing. Open two cogs in a row and
    --     the panel is identical both times. The feature name is now the panel's
    --     header, which is also what lets the rest of the chrome go away: once
    --     the title says "Silent Aim" the eyebrow reading "KEYBIND" is noise,
    --     and so is the one reading "MODE" above three buttons labelled Always,
    --     Toggle and Hold.
    --   * The three modes were three separate buttons that each lit up on their
    --     own, so the control read as three things rather than one choice. It is
    --     a segmented control now - one track, one selection pill that SLIDES
    --     between the cells, which is the thing that makes a choice feel like a
    --     choice.
    --   * Arming capture changed one word and nothing else. There is a hint
    --     line under the button now that says how to cancel and how to clear,
    --     and the button's own outline goes to the accent while it listens.
    --
    -- The panel is an outer box SH larger on every side than the visible body,
    -- because the drop shadow is drawn outside the body's bounds and a
    -- CanvasGroup clips to its own. Open() positions by the body, not the box.
    -----------------------------------------------------------------
    -- HK_SH is the margin the shadow needs: 5 layers at 2px of reach extend
    -- 10px sideways and, with the downward bias, 14px below. 16 clears it.
    local HK_W, HK_H, HK_SH = S(196), S(129), S(16)
    local HK_PAD = S(10)

    local panel = library:Surface({
        Name = "HotkeyPanel", BackgroundTransparency = 1,
        Size = UDim2.fromOffset(HK_W + HK_SH * 2, HK_H + HK_SH * 2),
        Visible = false, ZIndex = 70, Parent = library.PopupLayer,
    })

    local shadowHost = Util.New("Frame", {
        Name = "ShadowHost", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(HK_SH, HK_SH),
        Size = UDim2.fromOffset(HK_W, HK_H),
        ZIndex = 1, Parent = panel,
    })
    Util.Shadow(shadowHost, S(M.CardRounding), 5, S(2))

    local body = Util.New("Frame", {
        -- Dark33 + Dark42: the same surface the dropdown and colour popups use,
        -- so all three read as the one layer floating above the window.
        Name = "Body", BackgroundColor3 = Theme.Dark33, BorderSizePixel = 0,
        Position = UDim2.fromOffset(HK_SH, HK_SH),
        Size = UDim2.fromOffset(HK_W, HK_H),
        ZIndex = 2, Parent = panel,
    })
    Util.Corner(body, S(M.CardRounding))
    Util.Stroke(body, Theme.Dark42)
    Util.Pad(body, HK_PAD, HK_PAD, HK_PAD, HK_PAD)

    -- Header: accent tick, feature name, hairline. "Enable Silent Aim" is a
    -- toggle's wording; as a title the prefix is dead weight.
    library:Accent(Util.New("Frame", {
        Name = "Tick", BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, S(2)),
        Size = UDim2.fromOffset(S(2), S(11)),
        ZIndex = 3, Parent = body,
    }))

    library:Label(body, string.gsub(tostring(picker.Text), "^Enable ", ""), {
        Color = Theme.TextActive, Size = 13, Weight = "SemiBold",
        Position = UDim2.fromOffset(S(8), 0),
        Size2 = UDim2.new(1, -S(8), 0, S(15)), ZIndex = 3,
    })

    Util.New("Frame", {
        BackgroundColor3 = Theme.Dark42, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, S(23)),
        Size = UDim2.new(1, 0, 0, 1), ZIndex = 3, Parent = body,
    })

    local bindButton = Util.New("TextButton", {
        Text = "", AutoButtonColor = false,
        BackgroundColor3 = Theme.Dark22, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, S(33)),
        Size = UDim2.new(1, 0, 0, S(28)), ZIndex = 3, Parent = body,
    })
    Util.Corner(bindButton, S(M.CtrlRounding))
    local bindStroke = Util.Stroke(bindButton, Theme.Dark42)

    local bindLabel = library:Label(bindButton, "NONE", {
        Color = Theme.TextActive, Size = 13, Weight = "SemiBold",
        XAlign = Enum.TextXAlignment.Center, Truncate = false, ZIndex = 4,
    })

    local hintLabel = library:Label(body, "", {
        Color = Theme.TextInactive, Size = 10,
        XAlign = Enum.TextXAlignment.Center, Truncate = false,
        Position = UDim2.fromOffset(0, S(67)),
        Size2 = UDim2.new(1, 0, 0, S(11)), ZIndex = 3,
    })

    local bindFill   = Anim.track(bindButton, "BackgroundColor3", Theme.Dark22)
    local bindOutline = Anim.track(bindStroke, "Color", Theme.Dark42)
    local hoverBind  = false

    -- Every control on the panel is DARKER than the panel, so it reads as cut
    -- into the surface rather than sitting on it; hovering and arming lift it
    -- toward the panel's own tone rather than away from it.
    local function paintBind()
        if library._capturing == picker then
            Anim.set(bindFill, Theme.Dark37)
            Anim.set(bindOutline, Theme.Accent)
        else
            Anim.set(bindFill, hoverBind and Theme.Dark27 or Theme.Dark22)
            Anim.set(bindOutline, hoverBind and Theme.Dark55 or Theme.Dark42)
        end
    end

    -----------------------------------------------------------------
    -- Mode: one track, one sliding pill, three invisible hit cells.
    -----------------------------------------------------------------
    local MODES = { "Always", "Toggle", "Hold" }

    local track = Util.New("Frame", {
        Name = "Modes", BackgroundColor3 = Theme.Dark22, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, S(87)),
        Size = UDim2.new(1, 0, 0, S(22)), ZIndex = 3, Parent = body,
    })
    Util.Corner(track, S(M.CtrlRounding))

    local pill = Util.New("Frame", {
        Name = "Selection", BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
        Position = UDim2.new(0, S(2), 0, S(2)),
        Size = UDim2.new(1 / #MODES, -S(4), 1, -S(4)),
        ZIndex = 2, Parent = track,
    })
    Util.Corner(pill, S(M.CtrlRounding))
    library:Accent(pill)

    -- Driven as a cell index rather than a scale so the easing is in the same
    -- units as the thing being chosen; the apply divides it back out.
    local pillSlide = Scalar.track(0, function(value)
        pill.Position = UDim2.new(value / #MODES, S(2), 0, S(2))
    end)

    local modeCells = {}
    for order, mode in ipairs(MODES) do
        local cell = Util.New("TextButton", {
            Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
            Position = UDim2.new((order - 1) / #MODES, 0, 0, 0),
            Size = UDim2.new(1 / #MODES, 0, 1, 0),
            ZIndex = 3, Parent = track,
        })

        local text = library:Label(cell, mode, {
            Color = Theme.TextInactive, Size = 11, Weight = "SemiBold",
            XAlign = Enum.TextXAlignment.Center, Truncate = false, ZIndex = 4,
        })

        modeCells[order] = {
            Mode = mode, Frame = cell, Hovered = false,
            Text = Anim.track(text, "TextColor3", Theme.TextInactive),
        }

        library:Connect(cell.MouseButton1Click, function()
            picker:SetMode(mode)
        end)
    end

    local function paintModes()
        for _, record in ipairs(modeCells) do
            local selected = picker.Mode == record.Mode
            local color
            if selected then
                color = Theme.Black
            elseif record.Hovered then
                color = Theme.TextActive
            else
                color = Theme.TextInactive
            end
            Anim.set(record.Text, color)
        end
    end

    -- One watcher for the whole panel instead of one per control: it is three
    -- rectangle tests and it only runs while the panel is open.
    library:Watch(function(point)
        if not panel.Parent then return false end
        if not panel.Visible then return end

        local over = Util.PointInside(bindButton, point)
        if over ~= hoverBind then
            hoverBind = over
            paintBind()
        end

        for _, record in ipairs(modeCells) do
            local hovered = Util.PointInside(record.Frame, point)
            if hovered ~= record.Hovered then
                record.Hovered = hovered
                paintModes()
            end
        end
    end)

    function picker:_RefreshPanel()
        local capturing = library._capturing == self
        bindLabel.Text = capturing and "PRESS A KEY" or Util.KeyLabel(self.Value)
        -- Kept under ~24 characters: at 10px that is the widest string that
        -- still fits the body's 176px of inner width, and the label does not
        -- truncate (a truncated hint is worse than no hint).
        hintLabel.Text = capturing
            and "ESC cancel    BACK clear"
            or  "Right-click cog for mode"
        paintBind()

        pillSlide.Target = (table.find(MODES, self.Mode) or 2) - 1
        paintModes()
    end

    -- Where the body wants to sit, kept out here so the slide's apply can add
    -- its offset to it every frame without recomputing the placement.
    local panelX, panelY = 0, 0

    local panelSlide = Scalar.track(0, function(value)
        panel.Position = UDim2.fromOffset(panelX, panelY + value)
    end)

    local panelFade = library.CanFade
        and Anim.track(panel, "GroupTransparency", 1) or nil

    function picker:HitTest(point)
        return Util.PointInside(body, point) or Util.PointInside(button, point)
    end

    function picker:Close()
        self.IsOpen = false
        panel.Visible = false
        if library._capturing == self then library:_StopCapture() end
    end

    function picker:Open()
        library:CloseAllPopups(self)
        self.IsOpen = true

        -- Placed against the body's rect. The panel itself is HK_SH larger on
        -- every side, so it hangs back and up by that much.
        local origin = button.AbsolutePosition
        local viewport = library.ScreenGui.AbsoluteSize
        local x = Util.Clamp(origin.X + S(M.HotkeyW) - HK_W, 8,
                             math.max(viewport.X - HK_W - 8, 8))
        local y = origin.Y + S(M.HotkeyH) + S(6)
        if y + HK_H > viewport.Y then y = math.max(origin.Y - HK_H - S(6), 8) end
        panelX, panelY = library:ToLayer(x - HK_SH, y - HK_SH)

        self:_RefreshPanel()

        -- The pill animates when you pick a mode, not when the panel appears,
        -- so it is snapped to the current one on open.
        pillSlide.Value = pillSlide.Target
        pill.Position = UDim2.new(pillSlide.Value / #MODES, S(2), 0, S(2))

        -- Rises into place as it fades up. Both have to be seeded by hand:
        -- Scalar skips the apply once it has converged, and the fade would
        -- otherwise still be sitting at the last open's finished value.
        panelSlide.Value = S(6)
        panelSlide.Target = 0
        panel.Position = UDim2.fromOffset(panelX, panelY + panelSlide.Value)

        if panelFade then
            panelFade.Value = 1
            panel.GroupTransparency = 1
            Anim.set(panelFade, 0)
        end

        panel.Visible = true
    end

    library:RegisterPopup(picker)

    library:Connect(button.MouseButton1Click, function()
        if picker.IsOpen then picker:Close() else picker:Open() end
    end)

    library:Connect(bindButton.MouseButton1Click, function()
        if library._capturing == picker then
            library:_StopCapture()
        else
            library:_StopCapture()
            library:_StartCapture(picker)
        end
        picker:_RefreshPanel()
    end)

    -- Right-clicking the cog still cycles the mode without opening anything.
    library:Connect(button.MouseButton2Click, function()
        local order = { "Always", "Toggle", "Hold" }
        local current = table.find(order, picker.Mode) or 2
        picker:SetMode(order[(current % #order) + 1])
    end)

    picker:_Repaint()
    picker:_RefreshPanel()
    library._keybinds[#library._keybinds + 1] = picker
    library.Options[index] = picker
    return picker
end

---------------------------------------------------------------------------------
-- COLOUR PICKER  (color_button.cpp radius 6 -> a 12px circle)
---------------------------------------------------------------------------------
local function CreateColorPicker(groupbox, parentRow, index, options, offset)
    options = options or {}
    local library = groupbox.Library

    -- A rounded square the size of a checkbox, not a circle.
    --
    -- Every other control on a row is a rounded rectangle at CtrlRounding, and
    -- a 12px disc beside them was the one shape in the menu that did not belong
    -- to the set. Matching the toggle's size as well means a card whose rows
    -- carry a mix of toggles and swatches has one clean column of controls down
    -- the right rather than two slightly different ones.
    local swatch = Util.New("TextButton", {
        Name = "ColorPicker", Text = "", AutoButtonColor = false,
        BackgroundColor3 = options.Default or Theme.White, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -(offset or 0), 0.5, 0),
        Size = UDim2.fromOffset(S(M.CheckboxBox), S(M.CheckboxBox)),
        ZIndex = 6, Parent = parentRow,
    })
    Util.Corner(swatch, S(M.CtrlRounding))

    -- The outline matters more here than on a toggle: a swatch set to something
    -- near the card colour would otherwise have no edge at all.
    Util.Stroke(swatch, Theme.Dark42)

    local picker = {
        Type = "ColorPicker", Index = index, Text = options.Text or index,
        Value = options.Default or Theme.White,
        Transparency = options.Transparency or 0,
        HasAlpha = options.Transparency ~= nil,
        IsOpen = false, Library = library, Callbacks = {},
    }
    if options.Callback then picker.Callbacks[1] = options.Callback end
    picker.Hue, picker.Sat, picker.Val = picker.Value:ToHSV()

    local SV = M.CpSV
    local popW = S(M.CpWindow.X)
    local popH = S(picker.HasAlpha and M.CpWindow.Y or M.CpWindowNoA.Y)
    local pad  = S(M.CpPad)

    -- Dark22, the same sunk surface the dropdown list uses, so both popups read
    -- as the menu opening rather than a lighter card arriving on top of it.
    local popup = Util.New("Frame", {
        Name = "ColorPopup", BackgroundColor3 = Theme.Dark22, BorderSizePixel = 0,
        Size = UDim2.fromOffset(popW, popH), Visible = false, ZIndex = 60,
        Parent = library.PopupLayer,
    })
    Util.Corner(popup, S(M.CardRounding))
    Util.Stroke(popup, Theme.Dark42)

    -- The shadow is a SIBLING, not a child.
    --
    -- Util.Shadow draws outside the bounds of whatever it is given, and with
    -- Roblox's sibling Z ordering a child always renders in front of its
    -- parent - so shadow layers parented to the popup would sit on top of its
    -- own fill however negative their ZIndex. The hotkey panel solves this with
    -- an outer box; here a separate host tracked to the popup's rect in Open()
    -- is less surgery for the same result.
    local shadowHost = Util.New("Frame", {
        Name = "ColorPopupShadow", BackgroundTransparency = 1,
        Size = UDim2.fromOffset(popW, popH), Visible = false, ZIndex = 59,
        Parent = library.PopupLayer,
    })
    Util.Shadow(shadowHost, S(M.CardRounding), 4, S(2))

    local sv = Util.New("Frame", {
        BackgroundColor3 = Theme.White, BorderSizePixel = 0,
        Position = UDim2.fromOffset(pad, pad),
        Size = UDim2.fromOffset(S(SV.X), S(SV.Y)), ZIndex = 61, Parent = popup,
    })
    Util.Corner(sv, S(M.CtrlRounding))
    local svHue = Util.New("UIGradient", {
        Color = ColorSequence.new(Theme.White, Color3.fromHSV(0, 1, 1)), Parent = sv,
    })
    local shade = Util.New("Frame", {
        BackgroundColor3 = Theme.Black, BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1), ZIndex = 62, Parent = sv,
    })
    Util.Corner(shade, S(M.CtrlRounding))
    Util.New("UIGradient", {
        Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0),
        }),
        Parent = shade,
    })

    local svCursor = Util.New("Frame", {
        BackgroundTransparency = 1, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(S(M.CpCircleR * 2), S(M.CpCircleR * 2)),
        ZIndex = 64, Parent = sv,
    })
    Util.Corner(svCursor, S(M.CpCircleR))
    Util.New("UIStroke", { Color = Theme.White, Thickness = S(1.5), Parent = svCursor })

    -- Hue runs down the strip to the right of the square, grabbed by the same
    -- 6x8 white pill the original uses.
    local hueBar = Util.New("Frame", {
        BackgroundColor3 = Theme.White, BorderSizePixel = 0,
        Position = UDim2.fromOffset(pad + S(SV.X) + pad, pad),
        Size = UDim2.fromOffset(popW - (pad * 3) - S(SV.X), S(SV.Y)),
        ZIndex = 61, Parent = popup,
    })
    Util.Corner(hueBar, S(M.CtrlRounding))
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
    local hueGrab = Util.New("Frame", {
        BackgroundColor3 = Theme.White, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0),
        Size = UDim2.fromOffset(S(M.CpGrabH), S(M.CpGrabW)),
        ZIndex = 63, Parent = hueBar,
    })
    Util.Corner(hueGrab, S(M.CtrlRounding))

    local alphaBar, alphaRamp, alphaGrab
    if picker.HasAlpha then
        alphaBar = Util.New("Frame", {
            BackgroundColor3 = Theme.Dark42, BorderSizePixel = 0,
            Position = UDim2.fromOffset(pad, pad + S(SV.Y) + pad),
            Size = UDim2.fromOffset(S(SV.X), S(M.CpBarH * 2)),
            ZIndex = 61, Parent = popup,
        })
        Util.Corner(alphaBar, S(M.CtrlRounding))
        alphaRamp = Util.New("Frame", {
            BackgroundColor3 = picker.Value, BorderSizePixel = 0,
            Size = UDim2.fromScale(1, 1), ZIndex = 62, Parent = alphaBar,
        })
        Util.Corner(alphaRamp, S(M.CtrlRounding))
        Util.New("UIGradient", {
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0),
            }),
            Parent = alphaRamp,
        })
        alphaGrab = Util.New("Frame", {
            BackgroundColor3 = Theme.White, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(1, 0.5),
            Size = UDim2.fromOffset(S(M.CpGrabW), S(M.CpGrabH)),
            ZIndex = 63, Parent = alphaBar,
        })
        Util.Corner(alphaGrab, S(M.CtrlRounding))
    end

    -- Dark33 on the popup's Dark22. Fields in this menu are LIGHTER than what
    -- they sit on - the dropdown field is Dark33 on a Dark18 card - and the hex
    -- box was Dark22, the same tone as the popup it sits in, so it had no edge
    -- of its own beyond the stroke.
    local hexBox = Util.New("TextBox", {
        BackgroundColor3 = Theme.Dark33, BorderSizePixel = 0,
        ClearTextOnFocus = false, Text = "",
        TextSize = S(12), TextColor3 = Theme.TextActive,
        TextXAlignment = Enum.TextXAlignment.Center,
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, pad, 1, -pad),
        Size = UDim2.new(1, -pad * 2, 0, S(18)),
        ZIndex = 62, Weight = "Bold", Parent = popup,
    })
    Util.Corner(hexBox, S(M.CtrlRounding))
    Util.Stroke(hexBox, Theme.Dark42)

    function picker:_Repaint()
        self.Value = Color3.fromHSV(self.Hue, self.Sat, self.Val)
        swatch.BackgroundColor3 = self.Value
        swatch.BackgroundTransparency = self.HasAlpha and self.Transparency or 0

        svHue.Color = ColorSequence.new(Theme.White, Color3.fromHSV(self.Hue, 1, 1))
        svCursor.Position = UDim2.fromScale(self.Sat, 1 - self.Val)
        hueGrab.Position = UDim2.fromScale(0.5, self.Hue)

        if alphaRamp then
            alphaRamp.BackgroundColor3 = self.Value
            alphaGrab.Position = UDim2.fromScale(1 - self.Transparency, 0.5)
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
    function picker:Width() return S(M.CheckboxBox) end

    function picker:Open()
        library:CloseAllPopups(self)
        self.IsOpen = true
        local origin = swatch.AbsolutePosition
        local viewport = library.ScreenGui.AbsoluteSize
        local x = Util.Clamp(origin.X + swatch.AbsoluteSize.X - popW, 8,
                             math.max(viewport.X - popW - 8, 8))
        -- 2px below the swatch, the same gap the dropdown list uses, so both
        -- open the same distance from what opened them.
        local y = origin.Y + swatch.AbsoluteSize.Y + S(2)
        if y + popH > viewport.Y then y = math.max(origin.Y - popH - S(2), 8) end

        popup.Position = UDim2.fromOffset(library:ToLayer(x, y))
        shadowHost.Position = popup.Position
        shadowHost.Visible = true
        popup.Visible = true
        self:_Repaint()
    end

    function picker:Close()
        if not self.IsOpen then return end
        self.IsOpen = false
        popup.Visible = false
        shadowHost.Visible = false
    end

    function picker:HitTest(point)
        return Util.PointInside(popup, point) or Util.PointInside(swatch, point)
    end

    library:RegisterPopup(picker)
    library:Connect(swatch.MouseButton1Click, function()
        if picker.IsOpen then picker:Close() else picker:Open() end
    end)

    local dragging = nil
    local function beginDrag(target)
        return function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
            dragging = target
        end
    end
    library:Connect(shade.InputBegan, beginDrag("sv"))
    library:Connect(sv.InputBegan, beginDrag("sv"))
    library:Connect(hueBar.InputBegan, beginDrag("hue"))
    if alphaBar then library:Connect(alphaBar.InputBegan, beginDrag("alpha")) end

    library:Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 and dragging then
            dragging = nil
            picker:_Fire()
        end
    end)

    library:Watch(function(point)
        if not popup.Parent then return false end
        if not dragging or not picker.IsOpen then return end

        if dragging == "sv" then
            local pos, size = sv.AbsolutePosition, sv.AbsoluteSize
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
-- ADDONS
--
-- checkbox.cpp stacks them from the right edge: the colour circle sits at
-- rect.Max.x - radius, and the hotkey cog moves left by (radius + padding +
-- hotkey width) when a colour button is present.
---------------------------------------------------------------------------------
local function RelayoutAddons(toggle)
    -- Addons stack leftward from the box, which now owns the right edge, so
    -- every offset starts past the box instead of at zero.
    local offset = S(M.CheckboxBox) + S(M.CheckboxPadX)

    local swatches = {}
    for _, addon in ipairs(toggle.Addons) do
        if addon.Type == "ColorPicker" then swatches[#swatches + 1] = addon end
    end

    for _, swatch in ipairs(swatches) do
        swatch:SetRowOffset(offset)
        offset = offset + S(M.CheckboxBox) + S(M.CheckboxPadX)
    end

    if toggle.KeyPicker then
        toggle.KeyPicker:SetRowOffset(offset)
        offset = offset + S(M.HotkeyW) + S(M.CheckboxPadX)
    end

    if toggle._Label then
        local reserve = offset + S(8)
        toggle._Label.Size = UDim2.new(1, -reserve, 1, 0)
        toggle._Hit.Size = UDim2.new(1, -reserve, 0, S(M.CheckboxH))
    end
end

local function AttachKeyPicker(self, index, options)
    options = options or {}
    options.Text = options.Text or self.Text
    local picker = CreateKeyPicker(self.Groupbox, self.Row, index, options, self, 0)
    self.Addons[#self.Addons + 1] = picker
    self.KeyPicker = picker
    RelayoutAddons(self)
    return self
end

local function AttachColorPicker(self, index, options)
    local picker = CreateColorPicker(self.Groupbox, self.Row, index, options, 0)
    self.Addons[#self.Addons + 1] = picker
    self.ColorPicker = self.ColorPicker or picker
    RelayoutAddons(self)
    return self
end

function Groupbox:AddToggle(index, options)
    local toggle = self:_CreateToggle(index, options)
    toggle.AddKeyPicker = AttachKeyPicker
    toggle.AddColorPicker = AttachColorPicker
    return toggle
end

function Groupbox:AddKeyPicker(index, options)
    options = options or {}
    local row = self:_Row(M.CheckboxH)
    self.Library:Label(row, options.Text or index, {
        Color = Theme.TextInactive, Size2 = UDim2.new(1, -S(40), 1, 0),
    })
    return CreateKeyPicker(self, row, index, options, nil, 0)
end

function Groupbox:AddColorPicker(index, options)
    options = options or {}
    local row = self:_Row(M.CheckboxH)
    self.Library:Label(row, options.Text or index, {
        Color = Theme.TextInactive, Size2 = UDim2.new(1, -S(30), 1, 0),
    })
    return CreateColorPicker(self, row, index, options, 0)
end

---------------------------------------------------------------------------------
-- SUBTABS
--
-- A second level of navigation inside one tab, drawn as a row along the bottom
-- right of the content panel - the mirror of the tab strip along the top right,
-- so both levels read as the same mechanism at different scales.
--
-- Entirely opt-in. A tab with no subtabs has no row and behaves exactly as it
-- did, so nothing existing has to change; the row appears the first time a tab
-- is asked for a subtab, and the first one added becomes the active one.
--
-- A subtab is not a new page. It is another pair of columns in the SAME scroll,
-- hidden unless selected - which is why it needs no layout of its own, inherits
-- the width easing for free, and cannot drift out of step with the tab's own
-- padding and spacing. A UIListLayout skips invisible children, so the hidden
-- pairs take up no room.
---------------------------------------------------------------------------------
local SubTab = {}
SubTab.__index = SubTab

function Tab:_EnsureSubStrip()
    if self.SubStrip then return self.SubStrip end

    -- Parented to Wrap rather than the scroll, so it stays put while the page
    -- scrolls underneath it.
    self.SubStrip = Util.New("Frame", {
        Name = "SubTabs", BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -S(18), 1, -S(6)),
        Size = UDim2.fromOffset(0, S(20)),
        AutomaticSize = Enum.AutomaticSize.X,
        Visible = false, ZIndex = 40, Parent = self.Wrap,
    })
    Util.New("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, S(M.TabSpacing)),
        Parent = self.SubStrip,
    })

    -- The scroll stops short of the row, or the last card sits under it.
    self.Page.Size = UDim2.new(1, 0, 1, -S(26))

    -- The tab's OWN pair of columns goes away the moment it has subtabs, and
    -- this is what was breaking them: those columns are fixed to half the
    -- content width each whether or not anything is in them, so two empty ones
    -- sat there holding the full width and pushed every subtab column off the
    -- right-hand edge. A tab with subtabs puts its cards on the subtabs, so its
    -- own pair has nothing left to do.
    self.Left.Visible, self.Right.Visible = false, false

    return self.SubStrip
end

function Tab:AddSubTab(name)
    local library = self.Library
    local strip = self:_EnsureSubStrip()

    self.SubTabs = self.SubTabs or {}
    local index = #self.SubTabs + 1

    local sub = setmetatable({
        Library = library, Tab = self, Name = name, Index = index,
    }, SubTab)

    local button = Util.New("TextButton", {
        Name = "SubTab" .. index, Text = "", AutoButtonColor = false,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
        LayoutOrder = index, Parent = strip,
    })
    sub.Button = button

    sub.Label = library:Label(button, name, {
        Weight = "Bold", Size = 13, Color = Theme.TextInactive,
        XAlign = Enum.TextXAlignment.Center, Truncate = false,
        Size2 = UDim2.new(0, 0, 1, 0), AutoSize = Enum.AutomaticSize.X,
    })
    sub.LabelAnim = Anim.track(sub.Label, "TextColor3", Theme.TextInactive)

    -- The same glow as the top strip, mirrored above the label: this row sits
    -- on the bottom edge, and a glow below it would be half off the panel.
    sub.Glow = Util.New("Frame", {
        Name = "Glow", BackgroundColor3 = Theme.Accent, BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, -S(3)),
        Size = UDim2.new(1, S(18), 0, S(2)),
        BackgroundTransparency = 1,
        ZIndex = 2, Parent = button,
    })
    library:Accent(sub.Glow)
    Util.New("UIGradient", {
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.5, 0),
            NumberSequenceKeypoint.new(1, 1),
        }),
        Parent = sub.Glow,
    })
    sub.GlowAnim = Anim.track(sub.Glow, "BackgroundTransparency", 1)

    -- A subtab's pair of columns lives inside a surface of its own.
    --
    -- They used to be two bare frames dropped straight into the tab's scroll,
    -- which works for layout but leaves nothing to fade: a plain Frame has no
    -- GroupTransparency, so the pair could only ever be shown or hidden. One
    -- CanvasGroup holding both gives the swap the same entry a tab change has,
    -- and keeps the two columns moving together - fading or lifting one without
    -- the other would tear the page in half down the middle.
    sub.Wrap = library:Surface({
        Name = "SubPage" .. index, BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Visible = false, LayoutOrder = index, Parent = self.Page,
    })
    Util.List(sub.Wrap, S(M.ContentSpacing), Enum.FillDirection.Horizontal)

    sub.Left  = self._Column(1, sub.Wrap)
    sub.Right = self._Column(2, sub.Wrap)
    self._Columns[#self._Columns + 1] = sub.Left
    self._Columns[#self._Columns + 1] = sub.Right

    sub.Fade = Scalar.track(1, function(value)
        sub.Wrap.Position = UDim2.fromOffset(0, math.floor((1 - value) * S(10)))
        if library.CanFade then
            sub.Wrap.GroupTransparency = 1 - value
        end
    end, M.AnimSpeed * 1.3)

    local hovered = false
    library:Watch(function(point)
        if not button.Parent then return false end
        local over = Util.PointInside(button, point) and library.Open
        if over ~= hovered then
            hovered = over
            sub:_Repaint()
        end
    end)
    sub._Hovered = function() return hovered end

    library:Connect(button.MouseButton1Click, function()
        if library:AnyPopupOpen() then return end
        self:SetActiveSubTab(sub)
    end)

    self.SubTabs[index] = sub
    strip.Visible = true

    if not self.ActiveSubTab then self:SetActiveSubTab(sub) end
    return sub
end

function SubTab:_Repaint()
    local active = self.Tab.ActiveSubTab == self
    local hovered = self._Hovered and self._Hovered() or false
    Anim.set(self.LabelAnim,
        active and Theme.Accent
        or (hovered and Theme.TextHovered or Theme.TextInactive))
    Anim.set(self.GlowAnim, active and 0 or 1)
end

function Tab:SetActiveSubTab(sub)
    if self.ActiveSubTab == sub then return end

    local previous = self.ActiveSubTab
    self.ActiveSubTab = sub

    -- The outgoing page is cut, the incoming one lifts and fades up - the same
    -- entry a tab change has, and the same reason only one side animates:
    -- cross-fading would show both subtabs' cards stacked on top of each other
    -- for the length of the fade.
    if previous then
        previous.Wrap.Visible = false
        previous:_Repaint()
    end

    sub.Wrap.Visible = true
    sub.Fade.Value = 0
    sub.Fade.Target = 1
    if sub.Library.CanFade then
        pcall(function() sub.Wrap.GroupTransparency = 1 end)
    end
    sub:_Repaint()

    -- Back to the top: the new pair's content has nothing to do with how far
    -- down the old one you were.
    pcall(function() self.Page.CanvasPosition = Vector2.new() end)
end

function SubTab:AddLeftGroupbox(name)
    local box = self.Tab:_NewCard(self.Left)
    if name then
        box.Frame.Name = tostring(name)
        box:SetTitle(name)
    end
    return box
end

function SubTab:AddRightGroupbox(name)
    local box = self.Tab:_NewCard(self.Right)
    if name then
        box.Frame.Name = tostring(name)
        box:SetTitle(name)
    end
    return box
end

Library.SubTabClass = SubTab

---------------------------------------------------------------------------------
-- WATERMARK  (watermark.cpp)
--
-- A dark14 strip of dark18 blocks, 3px padding, 8px between them. Each block is
-- its own text sized to content + (30, 20), and the trailing word is drawn in
-- the accent colour - "ATARAX [EFT]", "360 FPS", "96 PING".
---------------------------------------------------------------------------------
function Library:SetWatermarkVisible(visible)
    if self.Watermark then self.Watermark.Visible = visible and true or false end
end

function Library:SetWatermarkBlocks(blocks)
    self:_CreateRoot()

    if self.Watermark then self.Watermark:Destroy() end

    local bar = Util.New("Frame", {
        Name = "Watermark", BackgroundColor3 = Theme.Dark14,
        BackgroundTransparency = 0.15, BorderSizePixel = 0,
        Position = UDim2.fromOffset(S(20), S(20)),
        Size = UDim2.fromOffset(0, 0),
        AutomaticSize = Enum.AutomaticSize.XY,
        ZIndex = 4000, Parent = self.ScreenGui,
    })
    Util.Corner(bar, S(M.CardRounding))
    Util.Pad(bar, S(3), S(3), S(3), S(3))
    Util.List(bar, S(8), Enum.FillDirection.Horizontal)
    self.Watermark = bar

    for order, block in ipairs(blocks) do
        local main = tostring(block[1] or block.Text or "")
        local accent = tostring(block[2] or block.Accent or "")

        local cell = Util.New("Frame", {
            BackgroundColor3 = Theme.Dark18, BorderSizePixel = 0,
            Size = UDim2.fromOffset(0, 0),
            AutomaticSize = Enum.AutomaticSize.XY,
            LayoutOrder = order, Parent = bar,
        })
        Util.Corner(cell, S(M.CtrlRounding))
        Util.Pad(cell, S(10), S(10), S(15), S(15))
        Util.List(cell, 0, Enum.FillDirection.Horizontal)

        -- RichText would be one label, but the accent colour has to stay live
        -- for SetAccent, so the two runs are separate labels.
        local white = self:Label(cell, main, {
            Color = Theme.TextActive, Size = 16, Weight = "SemiBold",
            Truncate = false, Size2 = UDim2.fromOffset(0, S(18)),
            AutoSize = Enum.AutomaticSize.X,
        })
        white.LayoutOrder = 1

        if accent ~= "" then
            local tint = self:Label(cell, accent, {
                Color = Theme.Accent, Size = 16, Weight = "SemiBold",
                Truncate = false, Size2 = UDim2.fromOffset(0, S(18)),
                AutoSize = Enum.AutomaticSize.X,
            })
            tint.LayoutOrder = 2
            self:Accent(tint, "TextColor3")
        end
    end

    bar.Visible = true
    return bar
end

-- Keeps the old single-string signature working: "name | v1.0" splits on the
-- last space so the trailing token picks up the accent, which is what every
-- block in the original does.
function Library:SetWatermark(text)
    text = tostring(text)
    local head, tail = string.match(text, "^(.*)%s(%S+)$")
    if head then
        return self:SetWatermarkBlocks({ { head .. " ", tail } })
    end
    return self:SetWatermarkBlocks({ { text, "" } })
end

---------------------------------------------------------------------------------
-- TOPBAR
--
-- "SYS [PVP]  |  142 fps  |  38 ms  |  21:30:45", live.
--
-- This used to BE the watermark with live text poured into it, which is exactly
-- why it looked like a row of detached stickers: watermark.cpp draws discrete
-- blocks with gaps between them, because that is what the original menu wants
-- from it. A HUD readout wants the opposite - ONE bar, fields divided by
-- hairlines inside it, so it reads as a single instrument.
--
-- Four things carry most of the difference:
--
--   * Fixed-width number fields. The giveaway of a cheap readout is the bar
--     twitching as "99 fps" becomes "100 fps" and everything to its right
--     shifts along. Numbers are right-aligned in a fixed cell, units are
--     left-aligned in theirs, so nothing moves - ever.
--   * A value/unit hierarchy: big white number, small grey unit, rather than
--     one run of 16px text giving "142" and "FPS" equal weight.
--   * Colour only as information. The bar is monochrome while everything is
--     fine, and FPS and ping go amber then red as they degrade - eased, not
--     snapped. Nothing is coloured for decoration, which is what keeps this
--     inside a black-and-white menu.
--   * A top-lit gradient and a hairline edge, so a translucent strip over
--     gameplay still has an edge to read against a bright sky.
--
-- It no longer touches self.Watermark at all; that API is left for anyone using
-- it directly.
---------------------------------------------------------------------------------
local TB_H      = 28
local TB_PAD    = 11
local TB_GAP    = 9
local TB_NUM_W  = 32    -- fits "9999"; right-aligned
local TB_UNIT_W = 22
local TB_NUM_GAP = 3

local TB_WARN = Color3.fromRGB(235, 180, 90)
local TB_BAD  = Color3.fromRGB(235, 95, 95)

local function tbFpsColor(value)
    if value < 30 then return TB_BAD end
    if value < 60 then return TB_WARN end
    return Theme.TextActive
end

local function tbPingColor(value)
    if value > 160 then return TB_BAD end
    if value > 90 then return TB_WARN end
    return Theme.TextActive
end

function Library:_CreateTopbar()
    if self._topbar then return end

    local bar = Util.New("Frame", {
        Name = "Topbar", BackgroundColor3 = Theme.Dark14,
        BackgroundTransparency = 0.12, BorderSizePixel = 0,
        Position = UDim2.fromOffset(S(20), S(20)),
        Size = UDim2.fromOffset(0, S(TB_H)),
        AutomaticSize = Enum.AutomaticSize.X,
        ZIndex = 4000, Active = true, Visible = false,
        Parent = self.ScreenGui,
    })
    Util.Corner(bar, S(M.Rounding + 1))
    Util.Stroke(bar, Theme.Dark34)
    Util.Pad(bar, 0, 0, S(TB_PAD), S(TB_PAD))

    -- Multiplies the bar's own Dark14, so the top stays Dark14 and the bottom
    -- darkens. One gradient is the difference between a flat rectangle and
    -- something that reads as a lit surface.
    Util.New("UIGradient", {
        Rotation = 90,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 150, 150)),
        }),
        Parent = bar,
    })

    Util.New("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, S(TB_GAP)),
        Parent = bar,
    })

    local order = 0
    local function nextOrder()
        order = order + 1
        return order
    end

    -- 1px vertical hairline. Short of full height on purpose: a divider that
    -- runs edge to edge cuts the bar into separate boxes again, which is the
    -- thing this is getting away from.
    local function divider()
        local line = Util.New("Frame", {
            Name = "Divider", BackgroundColor3 = Theme.Dark42, BorderSizePixel = 0,
            Size = UDim2.fromOffset(1, S(12)),
            LayoutOrder = nextOrder(), ZIndex = 2, Parent = bar,
        })
        return line
    end

    -----------------------------------------------------------------
    -- Brand. The only auto-sized cell, and it is static after build, so the
    -- bar's own automatic width never changes at runtime.
    -----------------------------------------------------------------
    local brand = Util.New("Frame", {
        Name = "Brand", BackgroundTransparency = 1,
        Size = UDim2.new(0, 0, 1, 0),
        AutomaticSize = Enum.AutomaticSize.X,
        LayoutOrder = nextOrder(), ZIndex = 2, Parent = bar,
    })
    Util.New("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, S(6)),
        Parent = brand,
    })

    local tick = Util.New("Frame", {
        Name = "Tick", BorderSizePixel = 0,
        Size = UDim2.fromOffset(S(2), S(12)),
        LayoutOrder = 1, ZIndex = 3, Parent = brand,
    })
    Util.Corner(tick, S(1))
    self:Accent(tick)

    -- Trailing space trimmed: the consumer passes "SYS " because the old block
    -- layout had no gap of its own, and the list provides one now.
    local title = string.match(tostring(self.TopbarTitle or "SYS"), "^%s*(.-)%s*$")
    local tag   = string.match(tostring(self.TopbarTag or ""), "^%s*(.-)%s*$")

    local titleLabel = self:Label(brand, title, {
        Color = Theme.TextActive, Size = 13, Weight = "SemiBold", Truncate = false,
        Size2 = UDim2.fromOffset(0, S(16)), AutoSize = Enum.AutomaticSize.X, ZIndex = 3,
    })
    titleLabel.LayoutOrder = 2

    if tag ~= "" then
        local tagLabel = self:Label(brand, tag, {
            Color = Theme.Accent, Size = 13, Weight = "SemiBold", Truncate = false,
            Size2 = UDim2.fromOffset(0, S(16)), AutoSize = Enum.AutomaticSize.X, ZIndex = 3,
        })
        tagLabel.LayoutOrder = 3
        self:Accent(tagLabel, "TextColor3")
    end

    -----------------------------------------------------------------
    -- Metric cells. Absolutely positioned inside a fixed-width cell rather
    -- than laid out, which is what makes the width immune to the digits.
    -----------------------------------------------------------------
    local function metric(unit)
        divider()

        local cell = Util.New("Frame", {
            Name = unit, BackgroundTransparency = 1,
            Size = UDim2.new(0, S(TB_NUM_W + TB_NUM_GAP + TB_UNIT_W), 1, 0),
            LayoutOrder = nextOrder(), ZIndex = 2, Parent = bar,
        })

        local value = self:Label(cell, "0", {
            Color = Theme.TextActive, Size = 13, Weight = "SemiBold", Truncate = false,
            XAlign = Enum.TextXAlignment.Right,
            Size2 = UDim2.new(0, S(TB_NUM_W), 1, 0), ZIndex = 3,
        })

        -- Nudged down a pixel: a 9px label centred against a 13px number sits
        -- visibly high of its baseline.
        self:Label(cell, unit, {
            Color = Theme.TextInactive, Size = 9, Weight = "SemiBold", Truncate = false,
            Position = UDim2.fromOffset(S(TB_NUM_W + TB_NUM_GAP), S(1)),
            Size2 = UDim2.new(0, S(TB_UNIT_W), 1, 0), ZIndex = 3,
        })

        return value, Anim.track(value, "TextColor3", Theme.TextActive)
    end

    local fpsLabel,  fpsAnim  = metric("fps")
    local pingLabel, pingAnim = metric("ms")

    -----------------------------------------------------------------
    -- Clock. The seconds go grey - it is the digit pair that changes every
    -- tick, so dimming it stops the bar reading as something flickering.
    -----------------------------------------------------------------
    divider()

    local clockCell = Util.New("Frame", {
        Name = "Clock", BackgroundTransparency = 1,
        Size = UDim2.new(0, S(58), 1, 0),
        LayoutOrder = nextOrder(), ZIndex = 2, Parent = bar,
    })

    local clockLabel = self:Label(clockCell, "00:00", {
        Color = Theme.TextActive, Size = 12, Weight = "Medium", Truncate = false,
        XAlign = Enum.TextXAlignment.Right,
        Size2 = UDim2.new(0, S(36), 1, 0), ZIndex = 3,
    })

    local secsLabel = self:Label(clockCell, ":00", {
        Color = Theme.TextInactive, Size = 12, Weight = "Medium", Truncate = false,
        Position = UDim2.fromOffset(S(36), 0),
        Size2 = UDim2.new(0, S(22), 1, 0), ZIndex = 3,
    })

    self:Draggable(bar, { bar })

    self.Topbar = bar
    self._topbar = {
        Fps = fpsLabel, FpsAnim = fpsAnim,
        Ping = pingLabel, PingAnim = pingAnim,
        Clock = clockLabel, Secs = secsLabel,
    }
end

function Library:SetTopbarVisible(visible)
    self.TopbarEnabled = visible and true or false

    if not self.TopbarEnabled then
        if self.Topbar then self.Topbar.Visible = false end
        return
    end

    self:_CreateRoot()
    self:_CreateTopbar()
    self.Topbar.Visible = true

    if self._topbarWatcher then return end

    self._topbarWatcher = self:Watch(function(_, dt)
        local cells = self._topbar
        if not self.TopbarEnabled or not cells then return end

        -- Smoothed, or the readout flickers through a 20-frame spread every
        -- time it is sampled. Accumulated every frame even though the text is
        -- only written twice a second, so the average covers the whole window
        -- rather than whichever frame happened to land on the sample.
        if dt and dt > 0 then
            local instant = 1 / dt
            self._fps = self._fps and (self._fps + (instant - self._fps) * 0.1) or instant
        end

        local now = os.clock()
        if self._topbarNext and now < self._topbarNext then return end
        self._topbarNext = now + 0.5

        local ping = 0
        pcall(function()
            ping = math.floor(game:GetService("Stats").Network
                .ServerStatsItem["Data Ping"]:GetValue() + 0.5)
        end)

        local fps = math.floor((self._fps or 0) + 0.5)
        cells.Fps.Text = tostring(fps)
        Anim.set(cells.FpsAnim, tbFpsColor(fps))

        cells.Ping.Text = tostring(ping)
        Anim.set(cells.PingAnim, tbPingColor(ping))

        cells.Clock.Text = os.date("%H:%M")
        cells.Secs.Text  = os.date(":%S")
    end)
end

---------------------------------------------------------------------------------
-- NOTIFICATIONS  (notify.cpp)
--
-- Top right, 10px in. dark18 card, text, and a dark33 rail underneath whose
-- accent fill GROWS as the notification ages - it is a progress bar toward
-- dismissal, not a countdown draining away.
---------------------------------------------------------------------------------
function Library:_NotifyLayer()
    if self.NotifyLayer and self.NotifyLayer.Parent then return self.NotifyLayer end
    -- Bottom right, stacking upward. The original puts them top right, but the
    -- top right is where the topbar lives and two stacks fighting for the same
    -- corner is how you end up reading neither.
    self.NotifyLayer = Util.New("Frame", {
        Name = "Notifications", BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -S(10), 1, -S(10)),
        Size = UDim2.new(0, S(300), 1, -S(20)),
        ZIndex = 6000, Parent = self.ScreenGui,
    }, {
        Util.New("UIListLayout", {
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            VerticalAlignment = Enum.VerticalAlignment.Bottom,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, S(8)),
        }),
    })
    return self.NotifyLayer
end

function Library:Notify(text, duration, title)
    if self.Unloaded or not self.ScreenGui then return end
    duration = duration or 3.75

    local layer = self:_NotifyLayer()
    local pad = S(10)

    local card = Util.New("Frame", {
        BackgroundColor3 = Theme.Dark18, BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(0, 0),
        AutomaticSize = Enum.AutomaticSize.XY,
        Parent = layer,
    })
    Util.Corner(card, S(M.CardRounding))
    Util.Pad(card, pad, pad, pad, pad)
    Util.List(card, pad)

    local label = self:Label(card, title and (title .. ": " .. text) or text, {
        Color = Theme.TextActive, Size = 13, Truncate = false,
        Size2 = UDim2.fromOffset(0, S(16)), AutoSize = Enum.AutomaticSize.X,
    })
    label.LayoutOrder = 1
    label.TextTransparency = 1

    local rail = Util.New("Frame", {
        BackgroundColor3 = Theme.Dark33, BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, S(M.CpBarH)), LayoutOrder = 2, Parent = card,
    })
    Util.Corner(rail, S(M.CtrlRounding))

    local fill = self:Accent(Util.New("Frame", {
        BorderSizePixel = 0, BackgroundTransparency = 1,
        Size = UDim2.fromScale(0, 1), Parent = rail,
    }), "BackgroundColor3")
    Util.Corner(fill, S(M.CtrlRounding))

    local function fade(to)
        for _, inst in ipairs({ card, rail, fill }) do
            TweenService:Create(inst, TweenInfo.new(0.18), {
                BackgroundTransparency = to,
            }):Play()
        end
        TweenService:Create(label, TweenInfo.new(0.18), { TextTransparency = to }):Play()
    end

    fade(0)

    task.spawn(function()
        local started = os.clock()
        while card.Parent do
            local alpha = Util.Clamp((os.clock() - started) / duration, 0, 1)
            fill.Size = UDim2.fromScale(alpha, 1)
            if alpha >= 1 then break end
            RunService.RenderStepped:Wait()
        end
        if not card.Parent then return end
        fade(1)
        task.wait(0.25)
        pcall(function() card:Destroy() end)
    end)
end

---------------------------------------------------------------------------------
-- KEYBIND LIST
--
-- Not part of the original framework, but Private.lua expects one. Built in the
-- same vocabulary: dark18 panel, a hairline under the heading, a chip per key
-- and the accent for anything currently live.
--
-- The first pass rebuilt the whole list whenever ANYTHING changed, including a
-- bind going on or off - which is most of what this panel ever does. Destroying
-- a row and making a new one in the new colour is a hard cut, and a list that
-- hard-cuts ten times a fight is the thing that reads as cheap no matter how it
-- is styled.
--
-- So the signature that triggers a rebuild covers membership only: which binds
-- exist and what they are bound to. State is pushed onto the rows that are
-- already there, every frame, through the same easing everything else uses, so
-- a bind coming live fades up instead of blinking.
--
-- Height is driven rather than auto-sized, for two reasons: the shadow is drawn
-- outside the body's bounds and AutomaticSize would measure it and grow
-- forever, and a driven height can ease, so binding something new makes the
-- panel grow into the row instead of jumping.
---------------------------------------------------------------------------------
function Library:_CreateKeybindList()
    self:_CreateRoot()
    if self.KeybindFrame then return end

    -- Design units, scaled at use. KB_HEAD is everything above the first row:
    -- the 14px heading, 7px of air, the 1px hairline, then 8px more.
    local KB_PAD, KB_HEAD = 10, 30
    local KB_ROW, KB_GAP  = 20, 4

    -- SH is the margin the shadow needs; see the hotkey panel for the maths.
    local W, SH = S(196), S(16)

    local function bodyHeight(count)
        local inner = count > 0
            and (count * S(KB_ROW) + (count - 1) * S(KB_GAP))
            or S(KB_ROW)
        return S(KB_PAD) * 2 + S(KB_HEAD) + inner
    end

    local height = bodyHeight(0)

    local holder = Util.New("Frame", {
        Name = "Keybinds", BackgroundTransparency = 1,
        Position = UDim2.new(0, S(20) - SH, 0.42, -SH),
        Size = UDim2.fromOffset(W + SH * 2, height + SH * 2),
        ZIndex = 4000, Visible = false, Active = true, Parent = self.ScreenGui,
    })
    self.KeybindFrame = holder

    local shadowHost = Util.New("Frame", {
        Name = "ShadowHost", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(SH, SH),
        Size = UDim2.fromOffset(W, height),
        ZIndex = 1, Parent = holder,
    })
    Util.Shadow(shadowHost, S(M.CardRounding), 5, S(2))

    local body = Util.New("Frame", {
        Name = "Body", BackgroundColor3 = Theme.Dark18, BorderSizePixel = 0,
        Position = UDim2.fromOffset(SH, SH),
        Size = UDim2.fromOffset(W, height),
        ClipsDescendants = true, ZIndex = 2, Parent = holder,
    })
    Util.Corner(body, S(M.CardRounding))
    Util.Stroke(body, Theme.Dark34)
    Util.Pad(body, S(KB_PAD), S(KB_PAD), S(KB_PAD), S(KB_PAD))

    -- Eases the three rects that make up the panel together.
    local grow = Scalar.track(height, function(value)
        local rounded = math.floor(value + 0.5)
        holder.Size     = UDim2.fromOffset(W + SH * 2, rounded + SH * 2)
        shadowHost.Size = UDim2.fromOffset(W, rounded)
        body.Size       = UDim2.fromOffset(W, rounded)
    end)

    -----------------------------------------------------------------
    -- Header: accent tick, label, live count, hairline.
    -----------------------------------------------------------------
    self:Accent(Util.New("Frame", {
        Name = "Tick", BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, S(2)),
        Size = UDim2.fromOffset(S(2), S(11)),
        ZIndex = 3, Parent = body,
    }))

    self:Label(body, "KEYBINDS", {
        Color = Theme.TextInactive, Size = 11, Weight = "SemiBold",
        Position = UDim2.fromOffset(S(8), 0),
        Size2 = UDim2.new(1, -S(32), 0, S(14)), ZIndex = 3,
    })

    -- Not decoration: with the panel this small the count is how you tell
    -- "nothing is bound" from "the list is scrolled off", and it is where your
    -- eye already is after reading the heading.
    local countLabel = self:Label(body, "", {
        Color = Theme.TextInactive, Size = 11, Weight = "SemiBold",
        XAlign = Enum.TextXAlignment.Right, Truncate = false,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, 0),
        Size2 = UDim2.fromOffset(S(24), S(14)), ZIndex = 3,
    })

    Util.New("Frame", {
        BackgroundColor3 = Theme.Dark34, BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, S(21)),
        Size = UDim2.new(1, 0, 0, 1), ZIndex = 3, Parent = body,
    })

    local list = Util.New("Frame", {
        Name = "Rows", BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, S(KB_HEAD)),
        Size = UDim2.new(1, 0, 1, -S(KB_HEAD)),
        ZIndex = 3, Parent = body,
    })
    Util.List(list, S(KB_GAP))
    self.KeybindRows = list

    local empty = Util.New("Frame", {
        Name = "Empty", BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, S(KB_ROW)),
        LayoutOrder = 1, Visible = false, ZIndex = 4, Parent = list,
    })
    self:Label(empty, "Nothing bound", {
        Color = Theme.TextInactive, Size = 12, ZIndex = 5,
    })

    self:Draggable(holder, { holder })

    -----------------------------------------------------------------
    -- Rows
    -----------------------------------------------------------------
    local records, nextPoll = {}, 0

    local function buildRow(picker, order)
        local row = Util.New("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, S(KB_ROW)),
            LayoutOrder = order, ZIndex = 4, Parent = list,
        })

        -- A 3px pip rather than the word ON. You are reading presence at a
        -- glance, and it keeps the row to three things wide.
        local pip = Util.New("Frame", {
            Name = "Pip", BackgroundColor3 = Theme.Dark42, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0),
            Size = UDim2.fromOffset(S(3), S(3)), ZIndex = 5, Parent = row,
        })
        Util.Corner(pip, S(2))

        -- 92px of the 176px row is reserved for the chip, which auto-sizes and
        -- grows leftward: a long KeyCode name ("RIGHTBRACKET") is about 84px,
        -- so anything less and the chip would overlap the truncated name.
        local name = self:Label(row, "", {
            Color = Theme.TextInactive, Size = 12,
            Position = UDim2.fromOffset(S(10), 0),
            Size2 = UDim2.new(1, -S(92), 1, 0), ZIndex = 5,
        })

        local chip = Util.New("Frame", {
            Name = "Chip", BackgroundColor3 = Theme.Dark33, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, 0, 0.5, 0),
            Size = UDim2.fromOffset(0, S(16)),
            AutomaticSize = Enum.AutomaticSize.X, ZIndex = 5, Parent = row,
        })
        Util.Corner(chip, S(M.CtrlRounding))
        Util.Pad(chip, 0, 0, S(6), S(6))
        local chipStroke = Util.Stroke(chip, Theme.Dark42)

        local chipLabel = self:Label(chip, "", {
            Color = Theme.TextHovered, Size = 11, Weight = "SemiBold",
            Truncate = false, XAlign = Enum.TextXAlignment.Center,
            Size2 = UDim2.fromOffset(0, S(16)),
            AutoSize = Enum.AutomaticSize.X, ZIndex = 6,
        })

        return {
            Picker = picker, Frame = row,
            Name = name, ChipLabel = chipLabel, On = nil,
            Pip    = Anim.track(pip, "BackgroundColor3", Theme.Dark42),
            Text   = Anim.track(name, "TextColor3", Theme.TextInactive),
            Fill   = Anim.track(chip, "BackgroundColor3", Theme.Dark33),
            Key    = Anim.track(chipLabel, "TextColor3", Theme.TextHovered),
            Stroke = Anim.track(chipStroke, "Transparency", 0),
        }
    end

    self:Watch(function()
        if not self.ShowKeybinds then
            if holder.Visible then holder.Visible = false end
            return
        end
        if not holder.Visible then holder.Visible = true end

        -- Membership is scanned on a timer; state below is applied every frame,
        -- because a bind you just pressed has to answer immediately.
        local now = os.clock()
        if now >= nextPoll then
            nextPoll = now + 0.1

            local live, parts = {}, {}
            for _, picker in ipairs(self._keybinds) do
                if picker.Value and picker.Value ~= "" and picker.ShowInList then
                    live[#live + 1] = picker
                    parts[#parts + 1] = tostring(picker.Text) .. "|" .. picker.Value
                end
            end

            local signature = table.concat(parts, ";")
            if signature ~= self._keybindSignature then
                self._keybindSignature = signature

                for _, record in ipairs(records) do record.Frame:Destroy() end
                records = {}

                for order, picker in ipairs(live) do
                    local record = buildRow(picker, order + 1)
                    -- "Enable Silent Aim" reads as "Silent Aim": the prefix
                    -- earns its place on a toggle, not in a list where every
                    -- row is already a feature.
                    record.Name.Text = string.gsub(tostring(picker.Text), "^Enable ", "")
                    record.ChipLabel.Text = Util.KeyLabel(picker.Value)
                    records[order] = record
                end

                empty.Visible = #live == 0
                countLabel.Text = #live > 0 and tostring(#live) or ""
                grow.Target = bodyHeight(#live)
            end
        end

        for _, record in ipairs(records) do
            local on = record.Picker:GetState() and true or false
            if on ~= record.On then
                record.On = on
                Anim.set(record.Pip,    on and Theme.Accent or Theme.Dark42)
                Anim.set(record.Text,   on and Theme.TextActive or Theme.TextInactive)
                Anim.set(record.Fill,   on and Theme.Accent or Theme.Dark33)
                Anim.set(record.Key,    on and Theme.Black or Theme.TextHovered)
                Anim.set(record.Stroke, on and 1 or 0)
            end
        end
    end)
end

function Library:SetKeybindListVisible(visible)
    self:_CreateKeybindList()
    self.ShowKeybinds = visible and true or false
    self._keybindSignature = nil
end

---------------------------------------------------------------------------------
-- SAVE MANAGER
---------------------------------------------------------------------------------
local SaveManager = {}
SaveManager.__index = SaveManager

-- A config name becomes a filename, so it is checked rather than trusted.
-- Unchecked it could do two things: a name containing a slash or ".." writes
-- outside the configs folder (and then never shows up in List, because the
-- pattern there only matches one path segment), and a name containing a colon
-- or a quote makes writefile throw on Windows - which the fs shim swallows into
-- a bare "write failed" with nothing saying why.
local NAME_MAX = 40

local function cleanName(name)
    if type(name) ~= "string" then return nil, "no config name" end

    -- Trimmed, not stripped. See GetAutoload for what stripping cost.
    name = string.match(name, "^%s*(.-)%s*$")
    if name == "" then return nil, "no config name" end
    if #name > NAME_MAX then return nil, "name is longer than " .. NAME_MAX end
    if not string.match(name, "^[%w%-_%. ]+$") then
        return nil, "use only letters, numbers, spaces, - _ ."
    end

    -- "." and ".." are directory entries, and Windows drops a trailing dot -
    -- so "pvp." and "pvp" are the same file and would collide invisibly.
    if string.match(name, "^%.+$") or string.match(name, "%.$") then
        return nil, "invalid name"
    end

    return name
end

local function hasValue(list, value)
    if value == nil then return false end
    for _, item in ipairs(list or {}) do
        if item == value then return true end
    end
    return false
end

-- One option to its stored form. Returns nil for a control with nothing worth
-- storing, and is called under pcall so a control in a broken state costs its
-- own setting rather than the whole save.
local function encodeOption(option)
    local kind = option.Type

    if kind == "Slider" then
        return { type = "Slider", value = option.Value }

    elseif kind == "Dropdown" then
        if option.Multi then
            local selected = {}
            for value, on in pairs(option.Value or {}) do
                if on then selected[#selected + 1] = value end
            end
            table.sort(selected, function(a, b) return tostring(a) < tostring(b) end)
            return { type = "MultiDropdown", value = selected }
        end
        return { type = "Dropdown", value = option.Value }

    elseif kind == "Listbox" then
        return { type = "Listbox", value = option.Value }

    elseif kind == "Input" then
        return { type = "Input", value = option.Value }

    elseif kind == "KeyPicker" then
        return { type = "KeyPicker", key = option.Value, mode = option.Mode }

    elseif kind == "ColorPicker" then
        return {
            type = "ColorPicker",
            r = math.floor(option.Value.R * 255 + 0.5),
            g = math.floor(option.Value.G * 255 + 0.5),
            b = math.floor(option.Value.B * 255 + 0.5),
            a = option.Transparency,
        }
    end

    return nil
end

function Library:CreateSaveManager(config)
    config = config or {}
    local folder = config.Folder or "uilib"
    if config.SubFolder then folder = folder .. "/" .. config.SubFolder end

    local manager = setmetatable({
        Library = self, Folder = folder, Ignore = {},
    }, SaveManager)

    for _, ignored in ipairs(config.Ignore or {}) do manager.Ignore[ignored] = true end

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

function SaveManager:Exists(name)
    local clean = cleanName(name)
    return clean ~= nil and fs.IsFile(self:ConfigPath(clean))
end

function SaveManager:Serialize()
    local data = { Toggles = {}, Options = {} }
    local library = self.Library

    -- String indexes only. JSONEncode refuses a table with both string and
    -- number keys, so one numerically-indexed control would fail the whole save
    -- with nothing but "encode failed" to go on.
    for index, toggle in pairs(library.Toggles) do
        if type(index) == "string" and not self.Ignore[index] then
            data.Toggles[index] = toggle.Value and true or false
        end
    end

    for index, option in pairs(library.Options) do
        if type(index) == "string" and not self.Ignore[index] then
            local ok, record = pcall(encodeOption, option)
            if ok and record then data.Options[index] = record end
        end
    end

    return data
end

-- Restores one option. Split out so each one runs under its own pcall in
-- Deserialize, and so the per-type validation has room to be readable.
--
-- Everything here is defensive about the stored value, because a config file is
-- just text on disk: it can predate a control, outlive one, be hand-edited, or
-- be truncated by a crash mid-write.
function SaveManager:_Restore(option, record)
    local kind = option.Type

    if kind == "ColorPicker" then
        local function channel(v) return math.clamp(tonumber(v) or 255, 0, 255) end
        local alpha = tonumber(record.a)
        option:SetValue(
            Color3.fromRGB(channel(record.r), channel(record.g), channel(record.b)),
            alpha and math.clamp(alpha, 0, 1) or nil)

    elseif kind == "KeyPicker" then
        -- A mode the library does not know would leave the picker in a state no
        -- code path handles, so anything unrecognised becomes Toggle.
        local mode = record.mode
        if mode ~= "Always" and mode ~= "Toggle" and mode ~= "Hold" then
            mode = "Toggle"
        end

        -- Silent, both of them. A keybind is a BIND; whether the feature is on
        -- is the toggle's business, and the toggle has already been restored
        -- from data.Toggles by the loop above. Firing here let the picker
        -- overwrite that - true when no key was set, false when one was,
        -- because assigning a key clears Active - so the saved toggle value was
        -- destroyed either way on every single load.
        option:SetMode(mode, true)
        option:SetValue(type(record.key) == "string" and record.key or "", true)

        -- A Toggle-mode picker keeps its own on/off in Active, and after a
        -- restore that has to agree with the toggle it drives. Otherwise the
        -- first press of the key re-asserts the state the feature is already in
        -- and reads as the bind doing nothing.
        if option.SyncToggle and option.Parent and option.Mode == "Toggle" then
            option.Active = option.Parent.Value and true or false
        end

    elseif kind == "Slider" then
        -- The one that actually threw: SetValue runs Util.Clamp, which compares
        -- the value against Min, and a missing `value` made that nil < number.
        local value = tonumber(record.value)
        if value then option:SetValue(value) end

    elseif kind == "Dropdown" and option.Multi then
        local wanted = {}
        if type(record.value) == "table" then
            for _, item in ipairs(record.value) do
                if hasValue(option.Values, item) then wanted[#wanted + 1] = item end
            end
        end
        option:SetValue(wanted)

    elseif kind == "Dropdown" or kind == "Listbox" then
        -- A stored value that is no longer one of the choices would be shown as
        -- selected and handed to the callback, which has no branch for it.
        if hasValue(option.Values, record.value) then
            option:SetValue(record.value)
        end

    elseif kind == "Input" then
        if record.value ~= nil then option:SetValue(tostring(record.value)) end
    end
end

-- Returns ok, applied, failed - or false plus a message.
function SaveManager:Deserialize(data)
    if type(data) ~= "table" then return false, "malformed config" end

    local library = self.Library

    -- Type-checked rather than `or {}`: a truncated or hand-edited file can
    -- leave these as a string or a number, and pairs() on one of those throws.
    local toggles = type(data.Toggles) == "table" and data.Toggles or {}
    local options = type(data.Options) == "table" and data.Options or {}

    local applied, failed = 0, 0

    -- Every set is isolated. A control's callback runs real work in the host
    -- script - spawning loops, touching the workspace - and one that throws
    -- used to abort the rest of the load, leaving the menu half in the config
    -- and half not with nothing saying which half.
    local function apply(fn)
        if pcall(fn) then applied = applied + 1 else failed = failed + 1 end
    end

    for index, value in pairs(toggles) do
        local toggle = library.Toggles[index]
        if toggle and not self.Ignore[index] then
            apply(function() toggle:SetValue(value and true or false) end)
        end
    end

    for index, record in pairs(options) do
        local option = library.Options[index]
        if option and not self.Ignore[index] and type(record) == "table" then
            -- The stored type has to still match the live control. Dispatching
            -- on the live type alone means a setting that changed from a
            -- dropdown to a slider between versions gets handed a string to do
            -- arithmetic on.
            local want = option.Type
            if want == "Dropdown" and option.Multi then want = "MultiDropdown" end

            if record.type == nil or record.type == want then
                apply(function() self:_Restore(option, record) end)
            else
                failed = failed + 1
            end
        end
    end

    if applied == 0 and failed > 0 then
        return false, "nothing in this config could be applied"
    end
    return true, applied, failed
end

-- Creating. Refuses to clobber, because that is what Overwrite is for: Save
-- used to write unconditionally, so hitting it while a config you had selected
-- was still in the name box silently destroyed that config.
function SaveManager:Save(name, overwrite)
    local clean, err = cleanName(name)
    if not clean then return false, err end

    if not overwrite and fs.IsFile(self:ConfigPath(clean)) then
        return false, "'" .. clean .. "' already exists"
    end

    local ok, encoded = pcall(function() return HttpService:JSONEncode(self:Serialize()) end)
    if not ok then return false, "could not encode settings" end
    if not fs.Write(self:ConfigPath(clean), encoded) then return false, "write failed" end

    return true, clean
end

function SaveManager:Overwrite(name)
    local clean, err = cleanName(name)
    if not clean then return false, err end
    if not fs.IsFile(self:ConfigPath(clean)) then
        return false, "'" .. clean .. "' does not exist"
    end
    return self:Save(clean, true)
end

function SaveManager:Load(name)
    local clean, err = cleanName(name)
    if not clean then return false, err end

    local contents = fs.Read(self:ConfigPath(clean))
    if not contents then return false, "'" .. clean .. "' does not exist" end

    local ok, decoded = pcall(function() return HttpService:JSONDecode(contents) end)
    if not ok then return false, "'" .. clean .. "' is not valid JSON" end

    return self:Deserialize(decoded)
end

function SaveManager:Delete(name)
    local clean, err = cleanName(name)
    if not clean then return false, err end
    if not fs.IsFile(self:ConfigPath(clean)) then
        return false, "'" .. clean .. "' does not exist"
    end
    if not fs.Delete(self:ConfigPath(clean)) then return false, "delete failed" end

    -- An autoload still pointing at the deleted config would fail on every
    -- future launch with a notification the user cannot act on.
    if self:GetAutoload() == clean then self:SetAutoload(nil) end

    return true, clean
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
    if name == nil or name == "" then
        if fs.IsFile(self:AutoloadPath()) then fs.Delete(self:AutoloadPath()) end
        return true
    end

    local clean, err = cleanName(name)
    if not clean then return false, err end
    -- Pointing autoload at a config that is not there just defers the failure
    -- to the next launch, where there is no UI to correct it from.
    if not fs.IsFile(self:ConfigPath(clean)) then
        return false, "'" .. clean .. "' does not exist"
    end
    if not fs.Write(self:AutoloadPath(), clean) then return false, "write failed" end

    return true, clean
end

function SaveManager:GetAutoload()
    local contents = fs.Read(self:AutoloadPath())
    if not contents then return nil end

    -- Trimmed, not stripped. gsub("%s", "") removed spaces from the middle too,
    -- so a config called "my config" was written correctly and then read back
    -- as "myconfig" - which autoloaded nothing, every launch, forever.
    local name = string.match(contents, "^%s*(.-)%s*$")
    return (name ~= "" and name) or nil
end

function SaveManager:LoadAutoloadConfig()
    local name = self:GetAutoload()
    if not name then return false end

    local ok, applied, failed = self:Load(name)
    if ok then
        local note = "Loaded " .. name .. " (" .. tostring(applied) .. " settings)"
        if (failed or 0) > 0 then note = note .. ", " .. tostring(failed) .. " skipped" end
        self.Library:Notify(note, 3)
    else
        -- `applied` carries the message on failure.
        self.Library:Notify("Autoload failed: " .. tostring(applied), 5)
    end

    if self._autoloadLabel then self._autoloadLabel:SetText("Autoload: " .. name) end
    return ok
end

function SaveManager:BuildConfigSection(tab, options)
    options = options or {}
    local library = self.Library

    local left  = tab:AddLeftGroupbox("Configs")
    local right = tab:AddRightGroupbox("Interface")

    local list = left:AddListbox("ConfigList", { Values = self:List(), Rows = 5 })
    local nameBox = left:AddInput("ConfigName", {
        Text = "Config name", Placeholder = "Config name", Finished = true,
        MaxLength = NAME_MAX,
    })

    -- Ignored here rather than with the Menu* indexes at the bottom, which sit
    -- after the NoMenuSection early return: a caller passing that option got a
    -- config that stored its own name box and list selection, and then restored
    -- them on load - including a selection naming a config that no longer
    -- existed.
    self:SetIgnoreIndexes({ "ConfigList", "ConfigName" })

    -- The name box is the single source of truth for which config every button
    -- acts on, and the list writes into it. Taking the name from `list.Value or
    -- nameBox.Value` instead meant that selecting a config and then typing a
    -- new name still acted on the selected one, because the list selection
    -- never cleared.
    list:OnChanged(function(value)
        if value then nameBox:SetValueSilent(value) end
    end)

    -- keep = false, so a config that no longer exists stops being the list's
    -- selection. With keep = true a deleted config stayed selected, and
    -- everything pointed at it afterwards reported "does not exist".
    local function refresh(select)
        list:SetValues(self:List(), false)
        if select then list:SetValueSilent(select) end
    end

    local function say(ok, detail, good)
        library:Notify(ok and good or tostring(detail), ok and 3 or 5)
    end

    left:AddButton({ Text = "Create", Func = function()
        local ok, detail = self:Save(nameBox.Value)
        if ok then refresh(detail) end
        say(ok, detail, "Created " .. tostring(detail))
    end })

    left:AddButton({ Text = "Load", Func = function()
        local ok, applied, failed = self:Load(nameBox.Value)
        if not ok then
            library:Notify(tostring(applied), 5)
            return
        end
        local note = "Loaded " .. tostring(applied) .. " settings"
        if (failed or 0) > 0 then note = note .. ", " .. tostring(failed) .. " skipped" end
        library:Notify(note, 3)
    end })

    -- Confirmed, because it destroys the stored config and there is no undo.
    left:AddButton({ Text = "Overwrite", Confirm = true, Func = function()
        local ok, detail = self:Overwrite(nameBox.Value)
        if ok then refresh(detail) end
        say(ok, detail, "Overwrote " .. tostring(detail))
    end })

    left:AddButton({ Text = "Delete", Confirm = true, Func = function()
        local ok, detail = self:Delete(nameBox.Value)
        if ok then
            refresh()
            nameBox:SetValueSilent("")
            if self._autoloadLabel then
                self._autoloadLabel:SetText("Autoload: " .. (self:GetAutoload() or "none"))
            end
        end
        say(ok, detail, "Deleted " .. tostring(detail))
    end })

    left:AddButton({ Text = "Refresh list", Func = function()
        refresh(nameBox.Value ~= "" and nameBox.Value or nil)
        library:Notify("Config list refreshed", 2)
    end })

    self._autoloadLabel = left:AddLabel("Autoload: none")

    left:AddButton({ Text = "Set autoload", Func = function()
        local ok, detail = self:SetAutoload(nameBox.Value)
        if ok then self._autoloadLabel:SetText("Autoload: " .. tostring(detail)) end
        say(ok, detail, "Autoload set to " .. tostring(detail))
    end })

    left:AddButton({ Text = "Clear autoload", Func = function()
        self:SetAutoload(nil)
        self._autoloadLabel:SetText("Autoload: none")
        library:Notify("Autoload cleared", 3)
    end })

    local current = self:GetAutoload()
    if current then self._autoloadLabel:SetText("Autoload: " .. current) end

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
        Text = "Accent color", Default = Theme.Accent,
        Callback = function(color) library:SetAccent(color) end,
    })

    right:AddToggle("MenuKeybindList", {
        Text = "Keybind list", Default = library.ShowKeybinds,
        Callback = function(value) library:SetKeybindListVisible(value) end,
    })

    right:AddToggle("MenuTopbar", {
        Text = "Topbar",
        Default = library.TopbarEnabled and true or false,
        Callback = function(value) library:SetTopbarVisible(value) end,
    })

    right:AddSlider("MenuAnimSpeed", {
        Text = "Animations speed", Default = M.AnimSpeed, Min = 1, Max = 30,
        Callback = function(value)
            M.AnimSpeed = value
            for _, entry in ipairs(Anim.List) do entry.Speed = value end
            for _, entry in ipairs(Scalar.List) do entry.Speed = value end
        end,
    })

    right:AddButton({ Text = "Unload", Confirm = true, Func = function()
        library:Unload()
    end })

    -- Nothing ignored here any more. These were excluded on the theory that
    -- menu appearance is not part of a loadout, but they are the settings you
    -- set once and expect to stay set - the menu key above all - and leaving
    -- them out meant a config could never record them, so every load silently
    -- put the menu key, the accent and the keybind list back to defaults.

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
