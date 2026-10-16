--[[
    LegendUI
    A tabbed UI library with draggable sections.

    Elements: Toggle (with keybind / colour), Button, Slider, Dropdown,
    MultiDropdown, Colorpicker, Textbox, Keybind, Image, Label, Separator.

    Sections (boxes) can be dragged anywhere, including off the window.
    Dropping one back over the window returns it to its original slot.

    Running the script again removes every trace of the previous run.

    Usage:
        local LegendUI = loadstring(readfile("LegendUI.lua"))()
        local window = LegendUI:CreateWindow({ Title = "LegendUI" })
]]

local GENV = (getgenv and getgenv()) or _G
local CLEANUP_KEY = "__legendui_cleanup"
local OWNER_ATTRIBUTE = "LegendUIOwner"

-- tear down the previous run before anything new is created
local previous_cleanup = GENV[CLEANUP_KEY]
if previous_cleanup then
    pcall(previous_cleanup)
    GENV[CLEANUP_KEY] = nil
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------
-- THEME
----------------------------------------------------------

local THEME = {
    window = Color3.fromRGB(24, 24, 28),
    divider = Color3.fromRGB(40, 40, 47),
    card = Color3.fromRGB(30, 30, 35),
    card_stroke = Color3.fromRGB(46, 46, 54),
    field = Color3.fromRGB(38, 38, 44),
    field_hover = Color3.fromRGB(49, 49, 57),
    popup = Color3.fromRGB(28, 28, 33),
    selected = Color3.fromRGB(40, 40, 47),
    text = Color3.fromRGB(242, 242, 246),
    text_dim = Color3.fromRGB(150, 150, 160),
    accent = Color3.fromRGB(52, 199, 89),
}

local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold

local TWEEN_FAST = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_MEDIUM = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TWEEN_POP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local SIDEBAR_WIDTH = 176
local TABBAR_HEIGHT = 48
local COLUMN_GAP = 14

----------------------------------------------------------
-- TYPES
----------------------------------------------------------

type Maid = {
    connect: (RBXScriptSignal, (...any) -> ()) -> RBXScriptConnection,
    add: (any) -> any,
    clean: () -> (),
}

type KeyBinding = {
    get_key: () -> Enum.KeyCode?,
    on_press: () -> (),
    on_release: (() -> ())?,
}

type ActiveDrag = {
    start: Vector2,
    on_move: (Vector2, Vector2) -> (),
    on_end: (() -> ())?,
}

----------------------------------------------------------
-- MAID
----------------------------------------------------------

local function new_maid(): Maid
    local items: { any } = {}
    local maid: any = {}

    function maid.connect(signal: RBXScriptSignal, handler: (...any) -> ())
        local connection = signal:Connect(handler)
        table.insert(items, connection)
        return connection
    end

    function maid.add(item: any)
        table.insert(items, item)
        return item
    end

    function maid.clean()
        local pending = items
        items = {}

        for _, item in pending do
            local kind = typeof(item)

            if kind == "RBXScriptConnection" then
                item:Disconnect()
            elseif kind == "Instance" then
                item:Destroy()
            elseif kind == "function" then
                pcall(item)
            elseif kind == "thread" then
                pcall(task.cancel, item)
            end
        end
    end

    return maid
end

local root_maid = new_maid()

GENV[CLEANUP_KEY] = function()
    root_maid.clean()
end

----------------------------------------------------------
-- HELPERS
----------------------------------------------------------

local function safe_call(callback: ((...any) -> ())?, ...: any)
    if not callback then
        return
    end

    local ok, err = pcall(callback, ...)
    if not ok then
        warn("[LegendUI] callback error: " .. tostring(err))
    end
end

local function tween(instance: Instance, info: TweenInfo, properties: { [string]: any }): Tween
    local playing = TweenService:Create(instance, info, properties)
    playing:Play()
    return playing
end

-- properties are applied first and Parent last, which is cheaper than parenting early
local function create(class_name: string, properties: { [string]: any }?, children: { Instance }?): any
    local instance = Instance.new(class_name)
    local parent = nil

    for key, value in properties or {} do
        if key == "Parent" then
            parent = value
        else
            instance[key] = value
        end
    end

    for _, child in children or {} do
        child.Parent = instance
    end

    if parent then
        instance.Parent = parent
    end

    return instance
end

local function corner(radius: number): UICorner
    return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color: Color3, thickness: number?, transparency: number?): UIStroke
    return create("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function padding(top: number, bottom: number, left: number, right: number): UIPadding
    return create("UIPadding", {
        PaddingTop = UDim.new(0, top),
        PaddingBottom = UDim.new(0, bottom),
        PaddingLeft = UDim.new(0, left),
        PaddingRight = UDim.new(0, right),
    })
end

local function list_layout(
    gap: number,
    direction: Enum.FillDirection?,
    horizontal: Enum.HorizontalAlignment?,
    vertical: Enum.VerticalAlignment?
): UIListLayout
    return create("UIListLayout", {
        Padding = UDim.new(0, gap),
        FillDirection = direction or Enum.FillDirection.Vertical,
        HorizontalAlignment = horizontal or Enum.HorizontalAlignment.Left,
        VerticalAlignment = vertical or Enum.VerticalAlignment.Top,
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
end

local function is_press(input: InputObject): boolean
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

-- Convert pointer coordinates into the same coordinate space used by this library's
-- ScreenGuis (IgnoreGuiInset = true / ScreenInsets.None). GetMouseLocation includes
-- the GUI inset on Roblox clients, so subtract it or the picker cursor sits too low.
local function pointer_position(input: InputObject): Vector2
    if input.UserInputType == Enum.UserInputType.Touch then
        local inset = GuiService:GetGuiInset()
        return Vector2.new(input.Position.X - inset.X, input.Position.Y - inset.Y)
    end

    local mouse = UserInputService:GetMouseLocation()
    local inset = GuiService:GetGuiInset()
    return Vector2.new(mouse.X - inset.X, mouse.Y - inset.Y)
end

local function center_inside(frame: GuiObject, container: GuiObject): boolean
    local center = frame.AbsolutePosition + frame.AbsoluteSize / 2
    local min = container.AbsolutePosition
    local max = min + container.AbsoluteSize

    return center.X >= min.X and center.X <= max.X and center.Y >= min.Y and center.Y <= max.Y
end

local function decimals_of(increment: number): number
    local count = 0
    local scaled = increment

    while count < 6 and math.abs(scaled - math.floor(scaled + 0.5)) > 1e-6 do
        scaled *= 10
        count += 1
    end

    return count
end

-- accepts either a config table or positional arguments in the order of `names`
local function parse_args(names: { string }, ...: any): { [string]: any }
    local first = ...
    if select("#", ...) == 1 and type(first) == "table" then
        return first
    end

    local values = table.pack(...)
    local config = {}

    for index, name in names do
        config[name] = values[index]
    end

    -- (text, default, callback) style shortcuts
    if config.Callback == nil then
        for _, name in names do
            if type(config[name]) == "function" then
                config.Callback = config[name]
                config[name] = nil
                break
            end
        end
    end

    return config
end

local KEY_ALIASES = {
    LeftShift = "LShift",
    RightShift = "RShift",
    LeftControl = "LCtrl",
    RightControl = "RCtrl",
    LeftAlt = "LAlt",
    RightAlt = "RAlt",
    Return = "Enter",
    Backspace = "Bksp",
    Escape = "Esc",
    Insert = "Ins",
    Delete = "Del",
    PageUp = "PgUp",
    PageDown = "PgDn",
    CapsLock = "Caps",
    Zero = "0",
    One = "1",
    Two = "2",
    Three = "3",
    Four = "4",
    Five = "5",
    Six = "6",
    Seven = "7",
    Eight = "8",
    Nine = "9",
}

local function key_name(key: Enum.KeyCode?): string
    if not key then
        return "None"
    end

    return KEY_ALIASES[key.Name] or key.Name
end

local function color_to_hex(color: Color3): string
    return string.format(
        "#%02X%02X%02X",
        math.floor(color.R * 255 + 0.5),
        math.floor(color.G * 255 + 0.5),
        math.floor(color.B * 255 + 0.5)
    )
end

local function hex_to_color(text: string): Color3?
    local hex = text:gsub("#", ""):gsub("%s", "")
    if not hex:match("^%x%x%x%x%x%x$") then
        return nil
    end

    return Color3.fromRGB(
        tonumber(hex:sub(1, 2), 16) :: number,
        tonumber(hex:sub(3, 4), 16) :: number,
        tonumber(hex:sub(5, 6), 16) :: number
    )
end

-- puts the gui in the safest parent the executor offers
local function mount_gui(gui: ScreenGui)
    gui:SetAttribute(OWNER_ATTRIBUTE, true)

    pcall(function()
        if syn and syn.protect_gui then
            syn.protect_gui(gui)
        end
    end)

    local parents = {}

    pcall(function()
        if gethui then
            table.insert(parents, gethui())
        end
    end)

    table.insert(parents, CoreGui)

    local player_gui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if player_gui then
        table.insert(parents, player_gui)
    end

    for _, parent in parents do
        local ok = pcall(function()
            gui.Parent = parent
        end)

        if ok and gui.Parent == parent then
            return
        end
    end
end

-- removes guis left behind by runs whose cleanup function was lost
local function purge_stale_guis()
    local parents = { CoreGui }

    local player_gui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if player_gui then
        table.insert(parents, player_gui)
    end

    pcall(function()
        if gethui then
            table.insert(parents, gethui())
        end
    end)

    for _, parent in parents do
        pcall(function()
            for _, child in parent:GetChildren() do
                if child:GetAttribute(OWNER_ATTRIBUTE) then
                    child:Destroy()
                end
            end
        end)
    end
end

purge_stale_guis()

----------------------------------------------------------
-- INPUT: DRAGGING, KEYBINDS, KEY CAPTURE
----------------------------------------------------------

local active_drag: ActiveDrag? = nil
local key_bindings: { [KeyBinding]: boolean } = {}
local key_capture: ((InputObject) -> ())? = nil

local function finish_drag()
    local drag = active_drag
    active_drag = nil

    if drag and drag.on_end then
        safe_call(drag.on_end)
    end
end

local function start_drag(input: InputObject, on_move: (Vector2, Vector2) -> (), on_end: (() -> ())?)
    if active_drag then
        finish_drag()
    end

    active_drag = {
        start = pointer_position(input),
        on_move = on_move,
        on_end = on_end,
    }
end

local function register_binding(binding: KeyBinding)
    key_bindings[binding] = true
end

root_maid.connect(UserInputService.InputChanged, function(input: InputObject)
    local drag = active_drag
    if not drag then
        return
    end

    local kind = input.UserInputType
    if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then
        return
    end

    safe_call(drag.on_move, pointer_position(input), drag.start)
end)

root_maid.connect(UserInputService.InputEnded, function(input: InputObject)
    if active_drag and is_press(input) then
        finish_drag()
    end

    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end

    for binding in key_bindings do
        if binding.on_release and binding.get_key() == input.KeyCode then
            safe_call(binding.on_release)
        end
    end
end)

root_maid.connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end

    -- a keybind button is waiting for the next key
    local capture = key_capture
    if capture then
        key_capture = nil
        capture(input)
        return
    end

    if processed then
        return
    end

    for binding in key_bindings do
        if binding.get_key() == input.KeyCode then
            safe_call(binding.on_press)
        end
    end
end)

root_maid.add(function()
    active_drag = nil
    key_capture = nil
    table.clear(key_bindings)
end)

----------------------------------------------------------
-- CLASSES
----------------------------------------------------------

local Library = { Version = "1.0.0" }

local Window = {}
Window.__index = Window

local Nav = {}
Nav.__index = Nav

local Page = {}
Page.__index = Page

local Column = {}
Column.__index = Column

local Box = {}
Box.__index = Box

----------------------------------------------------------
-- SHARED CONTROLS
----------------------------------------------------------

local function new_right(row: Frame): Frame
    return create("Frame", {
        Name = "Right",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(0, 22),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        ZIndex = 3,
        Parent = row,
    }, {
        list_layout(6, Enum.FillDirection.Horizontal, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center),
    })
end

local function new_label(parent: Instance, text: string, properties: { [string]: any }?): TextLabel
    local label = create("TextLabel", {
        BackgroundTransparency = 1,
        Text = text,
        Font = FONT,
        TextSize = 13,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })

    for key, value in properties or {} do
        label[key] = value
    end

    label.Parent = parent
    return label
end

-- a small button that waits for a key press. Escape and Backspace clear the bind
local function build_keybind_button(parent: Instance, initial: Enum.KeyCode?, on_change: ((Enum.KeyCode?) -> ())?)
    local key = initial
    local listening = false
    local control: any = {}

    local button = create("TextButton", {
        Name = "Keybind",
        Size = UDim2.fromOffset(0, 20),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = THEME.field,
        AutoButtonColor = false,
        Font = FONT,
        TextSize = 11,
        TextColor3 = THEME.text_dim,
        Text = key_name(key),
        Parent = parent,
    }, {
        corner(4),
        stroke(THEME.card_stroke),
        padding(0, 0, 7, 7),
    })

    local function refresh()
        button.Text = listening and "..." or key_name(key)
        tween(button, TWEEN_FAST, { TextColor3 = listening and THEME.accent or THEME.text_dim })
    end

    function control.get(): Enum.KeyCode?
        return key
    end

    function control.set(new_key: Enum.KeyCode?, silent: boolean?)
        key = new_key
        listening = false
        refresh()

        if not silent then
            safe_call(on_change, key)
        end
    end

    button.MouseButton1Click:Connect(function()
        if listening then
            listening = false
            key_capture = nil
            refresh()
            return
        end

        listening = true
        refresh()

        key_capture = function(input: InputObject)
            if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Backspace then
                control.set(nil)
            else
                control.set(input.KeyCode)
            end
        end
    end)

    button.MouseButton2Click:Connect(function()
        control.set(nil)
    end)

    control.button = button
    return control
end

-- Shared colour copied from any swatch; right-click another swatch to paste it.
local copied_swatch_color: Color3? = nil

-- a colour swatch that opens the colour picker popup
local function build_swatch(parent: Instance, window: any, initial: Color3, on_change: ((Color3) -> ())?)
    local color = initial
    local control: any = {}

    local swatch = create("TextButton", {
        Name = "Swatch",
        Size = UDim2.fromOffset(24, 14),
        BackgroundColor3 = color,
        Text = "",
        AutoButtonColor = false,
        Parent = parent,
    }, {
        corner(4),
        stroke(Color3.new(1, 1, 1), 1, 0.85),
    })

    function control.get(): Color3
        return color
    end

    function control.set(new_color: Color3, silent: boolean?, instant: boolean?)
        color = new_color

        if instant then
            swatch.BackgroundColor3 = color
        else
            tween(swatch, TWEEN_FAST, { BackgroundColor3 = color })
        end

        if not silent then
            safe_call(on_change, color)
        end
    end

    swatch.MouseButton1Click:Connect(function()
        window:_open_color_popup(swatch, control.get, function(picked: Color3)
            control.set(picked, false, true)
        end)
    end)

    -- Right-click a swatch to copy its colour or paste a previously copied one.
    swatch.MouseButton2Click:Connect(function()
        window:_open_popup(swatch, Vector2.new(132, 62), "right", function(popup, close)
            local function menu_button(text: string, y: number, enabled: boolean, callback: () -> ())
                local button = create("TextButton", {
                    Name = text:gsub("%s+", ""),
                    Position = UDim2.fromOffset(6, y),
                    Size = UDim2.new(1, -12, 0, 24),
                    BackgroundColor3 = THEME.field,
                    TextColor3 = enabled and THEME.text or THEME.text_dim,
                    Text = text,
                    Font = FONT,
                    TextSize = 12,
                    AutoButtonColor = enabled,
                    Active = enabled,
                    Parent = popup,
                }, { corner(5) })
                button.MouseButton1Click:Connect(function()
                    if enabled then
                        callback()
                        close()
                    end
                end)
            end

            menu_button("Copy colour", 6, true, function()
                copied_swatch_color = control.get()
            end)
            menu_button("Paste colour", 32, copied_swatch_color ~= nil, function()
                if copied_swatch_color then
                    control.set(copied_swatch_color, false, true)
                end
            end)
        end)
    end)

    control.button = swatch
    return control
end

----------------------------------------------------------
-- POPUPS
----------------------------------------------------------

-- opens one popup at a time below (or above) the anchor.
-- build(popup, close) fills it. The popup grows open and shrinks closed.
function Window:_open_popup(
    anchor: GuiObject,
    size: Vector2,
    align: string,
    build: (Frame, () -> ()) -> (),
    on_close: (() -> ())?
)
    self:_close_popup()

    local maid = new_maid()
    local closing = false

    local blocker = create("TextButton", {
        Name = "Blocker",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 1,
        Parent = self.overlay,
    })

    local popup = create("Frame", {
        Name = "Popup",
        Size = UDim2.fromOffset(size.X, 0),
        BackgroundColor3 = THEME.popup,
        ClipsDescendants = true,
        ZIndex = 2,
        Parent = self.overlay,
    }, {
        corner(8),
        stroke(THEME.card_stroke),
    })

    maid.add(blocker)
    maid.add(popup)

    local function close()
        if closing then
            return
        end

        closing = true

        if self.popup_close == close then
            self.popup_close = nil
        end

        blocker.Visible = false
        tween(popup, TWEEN_FAST, { Size = UDim2.fromOffset(size.X, 0) })
        safe_call(on_close)

        task.delay(0.18, function()
            maid.clean()
        end)
    end

    local viewport = self.overlay.AbsoluteSize
    local origin = anchor.AbsolutePosition
    local anchor_size = anchor.AbsoluteSize
    local below_end = origin.Y + anchor_size.Y + 4 + size.Y
    local above = below_end > viewport.Y - 4 and origin.Y - size.Y - 4 > 4

    local function reposition()
        if not anchor:IsDescendantOf(game) then
            close()
            return
        end

        local position = anchor.AbsolutePosition
        local extent = anchor.AbsoluteSize
        local x = align == "right" and (position.X + extent.X - size.X) or position.X
        x = math.clamp(x, 4, math.max(viewport.X - size.X - 4, 4))

        local y = position.Y + extent.Y + 4
        if above then
            y = position.Y - popup.Size.Y.Offset - 4
        end

        popup.Position = UDim2.fromOffset(x, y)
    end

    reposition()
    maid.connect(RunService.RenderStepped, reposition)
    blocker.MouseButton1Click:Connect(close)

    self.popup_close = close

    build(popup, close)
    tween(popup, TWEEN_MEDIUM, { Size = UDim2.fromOffset(size.X, size.Y) })
end

function Window:_close_popup()
    local close = self.popup_close
    if close then
        close()
    end
end

-- options, is_selected(option), on_pick(option), keep_open, multi, on_close
function Window:_open_list_popup(field: GuiObject, config: { [string]: any })
    local options = config.options
    local item_height = 26
    local height = math.clamp(#options * item_height + 8, 34, 200)
    local width = math.max(field.AbsoluteSize.X, 120)

    self:_open_popup(field, Vector2.new(width, height), "left", function(popup, close)
        local list = create("ScrollingFrame", {
            Name = "List",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 3,
            ScrollBarImageColor3 = THEME.card_stroke,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Parent = popup,
        }, {
            padding(4, 4, 4, 4),
            list_layout(0),
        })

        local refreshers: { () -> () } = {}

        for index, option in options do
            local item = create("TextButton", {
                Name = tostring(option),
                Size = UDim2.new(1, 0, 0, item_height),
                BackgroundColor3 = THEME.field_hover,
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = index,
                Parent = list,
            }, { corner(5) })

            local text_x = config.multi and 28 or 10

            local label = new_label(item, tostring(option), {
                Position = UDim2.fromOffset(text_x, 0),
                Size = UDim2.new(1, -text_x - 8, 1, 0),
                TextColor3 = THEME.text_dim,
            })

            local mark = create("Frame", {
                Name = "Mark",
                AnchorPoint = Vector2.new(0.5, 0.5),
                BackgroundColor3 = THEME.accent,
                Parent = item,
            }, { corner(config.multi and 3 or 4) })

            if config.multi then
                mark.Position = UDim2.fromOffset(16, item_height / 2)
            else
                mark.Position = UDim2.new(1, -14, 0.5, 0)
            end

            local function refresh()
                local selected = config.is_selected(option)
                local mark_size = config.multi and 12 or 6

                tween(label, TWEEN_FAST, { TextColor3 = selected and THEME.text or THEME.text_dim })
                tween(mark, TWEEN_POP, {
                    Size = selected and UDim2.fromOffset(mark_size, mark_size) or UDim2.fromOffset(0, 0),
                })
            end

            mark.Size = UDim2.fromOffset(0, 0)
            table.insert(refreshers, refresh)
            refresh()

            item.MouseEnter:Connect(function()
                tween(item, TWEEN_FAST, { BackgroundTransparency = 0 })
            end)

            item.MouseLeave:Connect(function()
                tween(item, TWEEN_FAST, { BackgroundTransparency = 1 })
            end)

            item.MouseButton1Click:Connect(function()
                config.on_pick(option)

                if config.keep_open then
                    for _, refresh_item in refreshers do
                        refresh_item()
                    end
                else
                    close()
                end
            end)
        end
    end, config.on_close)
end

-- saturation/value square, hue bar, hex box, and explicit Apply/Cancel controls.
-- Colour edits are previewed inside the popup and committed only when Apply is clicked.
function Window:_open_color_popup(anchor: GuiObject, get_color: () -> Color3, set_color: (Color3) -> ())
    local hue, saturation, value = get_color():ToHSV()
    local original_color = get_color()

    self:_open_popup(anchor, Vector2.new(200, 206), "right", function(popup, close)
        local square = create("TextButton", {
            Name = "Square",
            Position = UDim2.fromOffset(8, 8),
            Size = UDim2.fromOffset(184, 100),
            BackgroundColor3 = Color3.fromHSV(hue, 1, 1),
            Text = "",
            AutoButtonColor = false,
            ClipsDescendants = true,
            Active = true,
            Parent = popup,
        }, { corner(4) })

        create("Frame", {
            Name = "White",
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
            Active = false,
            Parent = square,
        }, {
            create("UIGradient", {
                Transparency = NumberSequence.new({
                    NumberSequenceKeypoint.new(0, 0),
                    NumberSequenceKeypoint.new(1, 1),
                }),
            }),
        })

        create("Frame", {
            Name = "Black",
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = Color3.new(0, 0, 0),
            BorderSizePixel = 0,
            Active = false,
            Parent = square,
        }, {
            create("UIGradient", {
                Rotation = 90,
                Transparency = NumberSequence.new({
                    NumberSequenceKeypoint.new(0, 1),
                    NumberSequenceKeypoint.new(1, 0),
                }),
            }),
        })

        local square_cursor = create("Frame", {
            Name = "Cursor",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(10, 10),
            BackgroundTransparency = 1,
            Active = false,
            Parent = square,
        }, {
            corner(5),
            stroke(Color3.new(1, 1, 1), 2),
        })

        local hue_bar = create("TextButton", {
            Name = "Hue",
            Position = UDim2.fromOffset(8, 116),
            Size = UDim2.fromOffset(184, 12),
            BackgroundColor3 = Color3.new(1, 1, 1),
            Text = "",
            AutoButtonColor = false,
            Active = true,
            Parent = popup,
        }, {
            corner(6),
            create("UIGradient", {
                Color = ColorSequence.new({
                    ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)),
                    ColorSequenceKeypoint.new(1 / 6, Color3.fromHSV(1 / 6, 1, 1)),
                    ColorSequenceKeypoint.new(2 / 6, Color3.fromHSV(2 / 6, 1, 1)),
                    ColorSequenceKeypoint.new(3 / 6, Color3.fromHSV(3 / 6, 1, 1)),
                    ColorSequenceKeypoint.new(4 / 6, Color3.fromHSV(4 / 6, 1, 1)),
                    ColorSequenceKeypoint.new(5 / 6, Color3.fromHSV(5 / 6, 1, 1)),
                    ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 1, 1)),
                }),
            }),
        })

        local hue_cursor = create("Frame", {
            Name = "Cursor",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(6, 16),
            BackgroundColor3 = Color3.new(1, 1, 1),
            Active = false,
            Parent = hue_bar,
        }, {
            corner(3),
            stroke(Color3.new(0, 0, 0), 1, 0.6),
        })

        local hex_box = create("TextBox", {
            Name = "Hex",
            Position = UDim2.fromOffset(8, 144),
            Size = UDim2.fromOffset(184, 24),
            BackgroundColor3 = THEME.field,
            Font = FONT,
            TextSize = 13,
            TextColor3 = THEME.text,
            ClearTextOnFocus = false,
            Text = "",
            Parent = popup,
        }, {
            corner(5),
            stroke(THEME.card_stroke),
        })

        local function current_color(): Color3
            return Color3.fromHSV(hue, saturation, value)
        end

        local function refresh()
            square.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
            square_cursor.Position = UDim2.fromScale(saturation, 1 - value)
            hue_cursor.Position = UDim2.fromScale(hue, 0.5)

            if not hex_box:IsFocused() then
                hex_box.Text = color_to_hex(current_color())
            end
        end

        -- Use the current pointer coordinates for every update. Clamping prevents
        -- the cursor jumping outside the picker if the mouse moves quickly.
        local function update_square(position: Vector2)
            local absolute = square.AbsolutePosition
            local size = square.AbsoluteSize
            if size.X <= 0 or size.Y <= 0 then
                return
            end
            local relative = (position - absolute) / size
            saturation = math.clamp(relative.X, 0, 1)
            value = 1 - math.clamp(relative.Y, 0, 1)
            refresh()
        end

        local function update_hue(position: Vector2)
            local width = hue_bar.AbsoluteSize.X
            if width <= 0 then
                return
            end
            hue = math.clamp((position.X - hue_bar.AbsolutePosition.X) / width, 0, 1)
            refresh()
        end

        square.InputBegan:Connect(function(input: InputObject)
            if not is_press(input) then
                return
            end
            update_square(pointer_position(input))
            start_drag(input, function(position: Vector2)
                update_square(position)
            end)
        end)

        hue_bar.InputBegan:Connect(function(input: InputObject)
            if not is_press(input) then
                return
            end
            update_hue(pointer_position(input))
            start_drag(input, function(position: Vector2)
                update_hue(position)
            end)
        end)

        hex_box.FocusLost:Connect(function()
            local parsed = hex_to_color(hex_box.Text)
            if parsed then
                hue, saturation, value = parsed:ToHSV()
            end
            refresh()
        end)

        local cancel_button = create("TextButton", {
            Name = "Cancel",
            Position = UDim2.fromOffset(8, 174),
            Size = UDim2.fromOffset(88, 24),
            BackgroundColor3 = THEME.field,
            TextColor3 = THEME.text,
            Text = "Cancel",
            Font = FONT,
            TextSize = 12,
            AutoButtonColor = true,
            Parent = popup,
        }, { corner(5), stroke(THEME.card_stroke) })

        local apply_button = create("TextButton", {
            Name = "Apply",
            Position = UDim2.fromOffset(104, 174),
            Size = UDim2.fromOffset(88, 24),
            BackgroundColor3 = THEME.accent,
            TextColor3 = Color3.new(1, 1, 1),
            Text = "Confirm",
            Font = FONT,
            TextSize = 12,
            AutoButtonColor = true,
            Parent = popup,
        }, { corner(5) })

        cancel_button.MouseButton1Click:Connect(function()
            -- No changes have been committed, so closing is a true cancel.
            close()
        end)

        apply_button.MouseButton1Click:Connect(function()
            set_color(current_color())
            close()
        end)

        refresh()
    end)
end

----------------------------------------------------------
-- WINDOW
----------------------------------------------------------

function Library.CreateWindow(_library: any, config: { [string]: any }?)
    config = config or {}

    if config.Accent then
        THEME.accent = config.Accent
    end

    local self = setmetatable({}, Window)
    self.navs = {}
    self.selected_nav = nil
    self.visible = true
    self.toggle_key = config.ToggleKey or Enum.KeyCode.RightShift
    self.float_order = 0
    self.popup_close = nil
    self.button_gui = nil

    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
    local requested = config.Size or Vector2.new(720, 560)
    local width = math.min(requested.X, viewport.X - 24)
    local height = math.min(requested.Y, viewport.Y - 24)

    local gui = create("ScreenGui", {
        Name = HttpService:GenerateGUID(false),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 1000,
    })

    pcall(function()
        gui.ScreenInsets = Enum.ScreenInsets.None
    end)

    mount_gui(gui)
    root_maid.add(gui)
    self.gui = gui

    ------------------------------------------------------
    -- main frame
    ------------------------------------------------------

    local main = create("Frame", {
        Name = "Window",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(width, height),
        BackgroundColor3 = THEME.window,
        BorderSizePixel = 0,
        Active = true,
        ClipsDescendants = true,
        Parent = gui,
    }, {
        corner(8),
        stroke(THEME.divider),
    })

    local scale = create("UIScale", { Scale = 0.94, Parent = main })
    local user_scale = create("UIScale", { Name = "UserUIScale", Scale = 1, Parent = main })
    self.main = main
    self.scale = scale -- open/close animation scale
    self.user_scale = user_scale -- persistent user-selected UI size

    ------------------------------------------------------
    -- sidebar
    ------------------------------------------------------

    local sidebar = create("Frame", {
        Name = "Sidebar",
        Size = UDim2.new(0, SIDEBAR_WIDTH, 1, 0),
        BackgroundTransparency = 1,
        Parent = main,
    })

    create("Frame", {
        Name = "Divider",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        Size = UDim2.new(0, 1, 1, 0),
        BackgroundColor3 = THEME.divider,
        BorderSizePixel = 0,
        Parent = sidebar,
    })

    local header = create("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 64),
        BackgroundTransparency = 1,
        Active = true,
        Parent = sidebar,
    })

    new_label(header, config.Title or "LegendUI", {
        Position = UDim2.fromOffset(18, 0),
        Size = UDim2.new(1, -36, 1, 0),
        Font = FONT_BOLD,
        TextSize = 18,
    })

    self.nav_list = create("Frame", {
        Name = "Navs",
        Position = UDim2.fromOffset(0, 64),
        Size = UDim2.new(1, 0, 1, -64 - 56),
        BackgroundTransparency = 1,
        Parent = sidebar,
    }, {
        padding(0, 0, 10, 10),
        list_layout(4),
    })

    local footer = create("Frame", {
        Name = "Footer",
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.fromScale(0, 1),
        Size = UDim2.new(1, 0, 0, 56),
        BackgroundTransparency = 1,
        Parent = sidebar,
    })

    create("Frame", {
        Name = "Line",
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = THEME.divider,
        BorderSizePixel = 0,
        Parent = footer,
    })

    new_label(footer, config.SubText or LocalPlayer.Name, {
        Position = UDim2.fromOffset(18, 12),
        Size = UDim2.new(1, -36, 0, 16),
        Font = FONT_BOLD,
        TextSize = 12,
    })

    new_label(footer, config.SubText2 or "session", {
        Position = UDim2.fromOffset(18, 30),
        Size = UDim2.new(1, -36, 0, 14),
        TextSize = 11,
        TextColor3 = THEME.text_dim,
    })

    ------------------------------------------------------
    -- content area
    ------------------------------------------------------

    local content = create("Frame", {
        Name = "Content",
        Position = UDim2.fromOffset(SIDEBAR_WIDTH, 0),
        Size = UDim2.new(1, -SIDEBAR_WIDTH, 1, 0),
        BackgroundTransparency = 1,
        Parent = main,
    })

    self.tabbar = create("Frame", {
        Name = "Tabs",
        Size = UDim2.new(1, 0, 0, TABBAR_HEIGHT),
        BackgroundTransparency = 1,
        Active = true,
        Parent = content,
    })

    self.underline = create("Frame", {
        Name = "Underline",
        Position = UDim2.fromOffset(0, 40),
        Size = UDim2.fromOffset(0, 2),
        BackgroundColor3 = THEME.text,
        BorderSizePixel = 0,
        Parent = self.tabbar,
    }, { corner(1) })

    self.pages_holder = create("Frame", {
        Name = "Pages",
        Position = UDim2.fromOffset(0, TABBAR_HEIGHT),
        Size = UDim2.new(1, 0, 1, -TABBAR_HEIGHT),
        BackgroundTransparency = 1,
        Parent = content,
    })

    ------------------------------------------------------
    -- layers above the window: floating sections, then popups
    ------------------------------------------------------

    -- Floating boxes live in their own ScreenGui so hiding the main window
    -- does not hide a box that has been dragged outside the window.
    local float_gui = create("ScreenGui", {
        Name = HttpService:GenerateGUID(false),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 1001,
    })

    pcall(function()
        float_gui.ScreenInsets = Enum.ScreenInsets.None
    end)

    mount_gui(float_gui)
    root_maid.add(float_gui)
    self.float_gui = float_gui

    self.float_layer = create("Frame", {
        Name = "Floating",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        ZIndex = 10,
        Parent = float_gui,
    })

    self.overlay = create("Frame", {
        Name = "Overlay",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        ZIndex = 20,
        Parent = gui,
    })

    ------------------------------------------------------
    -- dragging the window by its header and tab bar
    ------------------------------------------------------

    local function make_window_handle(handle: GuiObject)
        handle.InputBegan:Connect(function(input: InputObject)
            if not is_press(input) then
                return
            end

            self:_close_popup()

            local origin = main.Position

            start_drag(input, function(position: Vector2, start: Vector2)
                local delta = position - start
                main.Position = UDim2.new(
                    origin.X.Scale,
                    origin.X.Offset + delta.X,
                    origin.Y.Scale,
                    origin.Y.Offset + delta.Y
                )
            end)
        end)
    end

    make_window_handle(header)
    make_window_handle(self.tabbar)

    ------------------------------------------------------
    -- menu key and open animation
    ------------------------------------------------------

    register_binding({
        get_key = function()
            return self.toggle_key
        end,
        on_press = function()
            self:Toggle()
        end,
    })

    tween(scale, TWEEN_MEDIUM, { Scale = 1 })

    return self
end

function Window:SetVisible(visible: boolean)
    if self.visible == visible then
        return
    end

    self.visible = visible
    self:_close_popup()

    if visible then
        self.gui.Enabled = true
        self.scale.Scale = 0.94
        tween(self.scale, TWEEN_MEDIUM, { Scale = 1 })
        return
    end

    tween(self.scale, TWEEN_FAST, { Scale = 0.94 })

    task.delay(0.16, function()
        if not self.visible then
            self.gui.Enabled = false
        end
    end)
end

function Window:Toggle()
    self:SetVisible(not self.visible)
end

-- Accepts either a multiplier (1.25) or a percentage number (125).
function Window:SetUIScale(value: number)
    local scale_value = value > 10 and value / 100 or value
    self.user_scale.Scale = math.clamp(scale_value, 0.5, 2.5)
end

function Window:GetUIScale(): number
    return self.user_scale.Scale
end

function Window:SetToggleKey(key: Enum.KeyCode)
    self.toggle_key = key
end

function Window:GetToggleKey(): Enum.KeyCode
    return self.toggle_key
end

-- a small round button that opens and closes the window (useful on mobile)
function Window:SetToggleButtonVisible(visible: boolean)
    if not visible then
        if self.button_gui then
            self.button_gui:Destroy()
            self.button_gui = nil
        end

        return
    end

    if self.button_gui then
        return
    end

    local button_gui = create("ScreenGui", {
        Name = HttpService:GenerateGUID(false),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 999,
    })

    pcall(function()
        button_gui.ScreenInsets = Enum.ScreenInsets.None
    end)

    mount_gui(button_gui)
    root_maid.add(button_gui)
    self.button_gui = button_gui

    local button = create("TextButton", {
        Name = "Toggle",
        Position = UDim2.fromOffset(16, 64),
        Size = UDim2.fromOffset(40, 40),
        BackgroundColor3 = THEME.window,
        AutoButtonColor = false,
        Text = "L",
        Font = FONT_BOLD,
        TextSize = 18,
        TextColor3 = THEME.text,
        Parent = button_gui,
    }, {
        corner(20),
        stroke(THEME.card_stroke),
    })

    button.MouseEnter:Connect(function()
        tween(button, TWEEN_FAST, { BackgroundColor3 = THEME.field_hover })
    end)

    button.MouseLeave:Connect(function()
        tween(button, TWEEN_FAST, { BackgroundColor3 = THEME.window })
    end)

    button.MouseButton1Click:Connect(function()
        self:Toggle()
    end)
end

function Window:Destroy()
    self:_close_popup()

    if self.button_gui then
        self.button_gui:Destroy()
        self.button_gui = nil
    end

    if self.float_gui then
        self.float_gui:Destroy()
        self.float_gui = nil
    end

    self.gui:Destroy()
end

----------------------------------------------------------
-- NAV TABS AND PAGE TABS
----------------------------------------------------------

function Window:AddNavTab(name: string)
    local nav = setmetatable({
        window = self,
        name = name,
        pages = {},
        selected_page = nil,
    }, Nav)

    nav.button = create("TextButton", {
        Name = name,
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = THEME.selected,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = name,
        Font = FONT,
        TextSize = 14,
        TextColor3 = THEME.text_dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = #self.navs + 1,
        Parent = self.nav_list,
    }, {
        corner(6),
        padding(0, 0, 14, 8),
    })

    nav.strip = create("Frame", {
        Name = name .. "Tabs",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = self.tabbar,
    }, {
        padding(8, 0, 12, 0),
        list_layout(4, Enum.FillDirection.Horizontal),
    })

    nav.button.MouseEnter:Connect(function()
        if self.selected_nav ~= nav then
            tween(nav.button, TWEEN_FAST, { TextColor3 = THEME.text })
        end
    end)

    nav.button.MouseLeave:Connect(function()
        if self.selected_nav ~= nav then
            tween(nav.button, TWEEN_FAST, { TextColor3 = THEME.text_dim })
        end
    end)

    nav.button.MouseButton1Click:Connect(function()
        if self.selected_nav ~= nav then
            self:_close_popup()
            self:_activate_nav(nav)
        end
    end)

    table.insert(self.navs, nav)

    if #self.navs == 1 then
        self:_activate_nav(nav)
    end

    return nav
end

function Window:AddPageTab(nav: any, name: string)
    return nav:AddPageTab(name)
end

function Nav:AddPageTab(name: string)
    local window = self.window

    local page = setmetatable({
        window = window,
        nav = self,
        name = name,
        columns = {},
    }, Page)

    page.button = create("TextButton", {
        Name = name,
        Size = UDim2.fromOffset(0, 30),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = name,
        Font = FONT,
        TextSize = 14,
        TextColor3 = THEME.text_dim,
        LayoutOrder = #self.pages + 1,
        Parent = self.strip,
    }, { padding(0, 0, 8, 8) })

    page.canvas = create("CanvasGroup", {
        Name = name,
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        GroupTransparency = 1,
        Visible = false,
        Parent = window.pages_holder,
    })

    page.scroll = create("ScrollingFrame", {
        Name = "Scroll",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = THEME.card_stroke,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Parent = page.canvas,
    }, { padding(4, 16, 16, 16) })

    page.columns_frame = create("Frame", {
        Name = "Columns",
        -- ScrollingFrame has 16px left/right UIPadding; subtract both from
        -- the child width so the last column cannot spill past the content edge.
        Size = UDim2.new(1, -32, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = page.scroll,
    }, {
        list_layout(COLUMN_GAP, Enum.FillDirection.Horizontal),
    })

    page.button.MouseEnter:Connect(function()
        if self.selected_page ~= page then
            tween(page.button, TWEEN_FAST, { TextColor3 = THEME.text })
        end
    end)

    page.button.MouseLeave:Connect(function()
        if self.selected_page ~= page then
            tween(page.button, TWEEN_FAST, { TextColor3 = THEME.text_dim })
        end
    end)

    page.button.MouseButton1Click:Connect(function()
        window:_close_popup()
        window:_select_page(page)
    end)

    -- the underline follows the text width once layout has run
    page.button:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        if window.selected_nav == self and self.selected_page == page then
            window:_move_underline(page, false)
        end
    end)

    table.insert(self.pages, page)

    if #self.pages == 1 then
        if window.selected_nav == self then
            window:_show_page(page)
        else
            self.selected_page = page
        end
    end

    return page
end

function Window:_move_underline(page: any, animate: boolean)
    local button = page.button
    local bar = self.tabbar
    local ui_scale = math.max(self.scale.Scale, 0.01)

    local x = (button.AbsolutePosition.X - bar.AbsolutePosition.X) / ui_scale + 8
    local line_width = math.max(button.AbsoluteSize.X / ui_scale - 16, 0)
    local goal = {
        Position = UDim2.fromOffset(x, 40),
        Size = UDim2.fromOffset(line_width, 2),
    }

    if animate and self.underline.Size.X.Offset > 0 then
        tween(self.underline, TWEEN_MEDIUM, goal)
    else
        self.underline.Position = goal.Position
        self.underline.Size = goal.Size
    end
end

function Window:_show_page(page: any)
    local nav = page.nav

    if nav.selected_page == page and page.canvas.Visible then
        return
    end

    for _, other in nav.pages do
        local active = other == page

        tween(other.button, TWEEN_FAST, { TextColor3 = active and THEME.text or THEME.text_dim })

        if not active and other.canvas.Visible then
            other.canvas.Visible = false
            other.canvas.GroupTransparency = 1
        end
    end

    nav.selected_page = page

    page.canvas.Position = UDim2.fromOffset(0, 10)
    page.canvas.Visible = true
    tween(page.canvas, TWEEN_MEDIUM, {
        GroupTransparency = 0,
        Position = UDim2.fromOffset(0, 0),
    })

    task.defer(function()
        self:_move_underline(page, true)
    end)
end

function Window:_activate_nav(nav: any, page: any?)
    local previous = self.selected_nav
    self.selected_nav = nav

    for _, other in self.navs do
        local active = other == nav

        other.strip.Visible = active
        other.button.Font = active and FONT_BOLD or FONT

        tween(other.button, TWEEN_FAST, {
            BackgroundTransparency = active and 0 or 1,
            TextColor3 = active and THEME.text or THEME.text_dim,
        })
    end

    if previous and previous ~= nav and previous.selected_page then
        local old = previous.selected_page.canvas
        old.Visible = false
        old.GroupTransparency = 1
    end

    local target = page or nav.selected_page or nav.pages[1]
    if target then
        self:_show_page(target)
    end
end

function Window:_select_page(page: any)
    if self.selected_nav ~= page.nav then
        self:_activate_nav(page.nav, page)
        return
    end

    self:_show_page(page)
end

----------------------------------------------------------
-- COLUMNS AND BOXES
----------------------------------------------------------

function Page:AddColumn()
    local column = setmetatable({
        window = self.window,
        page = self,
        boxes = {},
    }, Column)

    column.frame = create("Frame", {
        Name = "Column",
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = #self.columns + 1,
        Parent = self.columns_frame,
    }, { list_layout(12) })

    table.insert(self.columns, column)

    -- columns share the width equally
    local count = #self.columns
    -- Split the available content width evenly and subtract each column's
    -- share of the inter-column gap, so two or more columns stay inside the page.
    local widthScale = 1 / count
    local widthOffset = -(COLUMN_GAP * (count - 1) / count)

    for _, other in self.columns do
        other.frame.Size = UDim2.new(widthScale, widthOffset, 0, 0)
    end

    return column
end

function Column:AddBox(title: string)
    local window = self.window

    local box = setmetatable({
        window = window,
        page = self.page,
        column = self,
        order = 0,
        floating = false,
        over_library = false,
        placeholder = nil,
        placeholder_stroke = nil,
    }, Box)

    box.frame = create("Frame", {
        Name = title,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        LayoutOrder = #self.boxes + 1,
        Parent = self.frame,
    }, {
        corner(8),
        stroke(THEME.card_stroke),
        padding(12, 12, 12, 12),
        list_layout(10),
    })

    box.header = create("TextButton", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = 1,
        Parent = box.frame,
    })

    box.title_label = new_label(box.header, title, {
        Size = UDim2.fromScale(1, 1),
        Font = FONT_BOLD,
        TextSize = 14,
    })

    box.content = create("Frame", {
        Name = "Content",
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 2,
        Parent = box.frame,
    }, { list_layout(8) })

    box.header.MouseEnter:Connect(function()
        tween(box.title_label, TWEEN_FAST, { TextColor3 = THEME.accent })
    end)

    box.header.MouseLeave:Connect(function()
        tween(box.title_label, TWEEN_FAST, { TextColor3 = THEME.text })
    end)

    box.header.InputBegan:Connect(function(input: InputObject)
        if is_press(input) then
            box:_begin_drag(input)
        end
    end)

    table.insert(self.boxes, box)
    return box
end

function Box:SetTitle(title: string)
    self.title_label.Text = title
end

function Box:_next_order(): number
    self.order += 1
    return self.order
end

-- lifts the box out of its column (leaving a slot behind) and follows the pointer
function Box:_begin_drag(input: InputObject)
    local window = self.window
    local frame = self.frame
    local float_layer = window.float_layer

    window:_close_popup()

    if not self.floating then
        local size = frame.AbsoluteSize
        local origin = frame.AbsolutePosition - float_layer.AbsolutePosition

        local slot_stroke = stroke(THEME.card_stroke, 1, 0.45)

        self.placeholder = create("Frame", {
            Name = "Slot",
            Size = UDim2.new(1, 0, 0, size.Y),
            BackgroundTransparency = 1,
            LayoutOrder = frame.LayoutOrder,
            Parent = self.column.frame,
        }, {
            corner(8),
            slot_stroke,
        })

        self.placeholder_stroke = slot_stroke

        frame.Size = UDim2.fromOffset(size.X, 0)
        frame.Position = UDim2.fromOffset(origin.X, origin.Y)
        frame.Parent = float_layer
        self.floating = true
    end

    window.float_order += 1
    frame.ZIndex = window.float_order

    local start_position = frame.Position

    start_drag(input, function(position: Vector2, start: Vector2)
        local delta = position - start
        local viewport = float_layer.AbsoluteSize
        local width = frame.AbsoluteSize.X

        local x = math.clamp(start_position.X.Offset + delta.X, -width + 60, viewport.X - 60)
        local y = math.clamp(start_position.Y.Offset + delta.Y, 0, viewport.Y - 30)
        frame.Position = UDim2.fromOffset(x, y)

        -- the slot lights up while the box is over the window
        local over = center_inside(frame, window.main)
        if over ~= self.over_library then
            self.over_library = over

            if self.placeholder_stroke then
                tween(self.placeholder_stroke, TWEEN_FAST, {
                    Color = over and THEME.accent or THEME.card_stroke,
                    Transparency = over and 0 or 0.45,
                })
            end
        end
    end, function()
        if self.over_library then
            self:_dock()
        end
    end)
end

-- slides the box back into its original slot and resets the layout
function Box:_dock()
    if not self.floating or not self.placeholder then
        return
    end

    local window = self.window
    local frame = self.frame

    self.over_library = false
    self.floating = false

    task.spawn(function()
        window:_select_page(self.page)

        -- one frame so the page layout is up to date before measuring the slot
        RunService.Heartbeat:Wait()

        local slot = self.placeholder
        if not slot or not slot.Parent then
            return
        end

        local goal = slot.AbsolutePosition - window.float_layer.AbsolutePosition
        local slide = tween(frame, TWEEN_MEDIUM, { Position = UDim2.fromOffset(goal.X, goal.Y) })
        slide.Completed:Wait()

        if not frame.Parent then
            return
        end

        frame.Size = UDim2.new(1, 0, 0, 0)
        frame.Position = UDim2.new()
        frame.ZIndex = 1
        frame.LayoutOrder = slot.LayoutOrder
        frame.Parent = self.column.frame

        slot:Destroy()
        self.placeholder = nil
        self.placeholder_stroke = nil
    end)
end

----------------------------------------------------------
-- ELEMENTS
----------------------------------------------------------

local function new_row(box: any, height: number): Frame
    return create("Frame", {
        Name = "Row",
        Size = UDim2.new(1, 0, 0, height),
        BackgroundTransparency = 1,
        LayoutOrder = box:_next_order(),
        Parent = box.content,
    })
end

-- label above a full-width field
local function field_row(box: any, text: string?, field_height: number): (Frame, number)
    local top = 0
    local height = field_height

    local row = new_row(box, 0)

    if text and text ~= "" then
        new_label(row, text, {
            Size = UDim2.new(1, 0, 0, 16),
            TextSize = 12,
            TextColor3 = THEME.text_dim,
        })

        top = 20
        height = field_height + top
    end

    row.Size = UDim2.new(1, 0, 0, height)
    return row, top
end

local function build_field_stroke(field: GuiObject): UIStroke
    local field_stroke = stroke(THEME.card_stroke)
    field_stroke.Parent = field
    return field_stroke
end

----------------------------------------------------------
-- TOGGLE
----------------------------------------------------------

local TOGGLE_ARGS = { "Text", "Default", "Keybind", "Callback" }

function Box:AddToggle(...)
    local config = parse_args(TOGGLE_ARGS, ...)
    local callback = config.Callback
    local row = new_row(self, 24)

    local toggle: any = {
        Type = "Toggle",
        Value = false,
        Mode = config.Mode or "Toggle",
        Key = typeof(config.Keybind) == "EnumItem" and config.Keybind or nil,
    }

    local hit = create("TextButton", {
        Name = "Hit",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 1,
        Parent = row,
    })

    local checkbox = create("Frame", {
        Name = "Checkbox",
        Position = UDim2.new(0, 0, 0.5, -8),
        Size = UDim2.fromOffset(16, 16),
        BackgroundColor3 = THEME.field,
        Parent = row,
    }, { corner(4) })

    local checkbox_stroke = stroke(THEME.card_stroke)
    checkbox_stroke.Parent = checkbox

    local fill = create("Frame", {
        Name = "Fill",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(0, 0),
        BackgroundColor3 = THEME.accent,
        Parent = checkbox,
    }, { corner(4) })

    new_label(row, config.Text or "Toggle", {
        Position = UDim2.fromOffset(26, 0),
        Size = UDim2.new(1, -26, 1, 0),
    })

    local right = new_right(row)

    local function apply(value: boolean)
        tween(fill, TWEEN_POP, {
            Size = value and UDim2.fromOffset(16, 16) or UDim2.fromOffset(0, 0),
        })

        tween(checkbox_stroke, TWEEN_FAST, {
            Color = value and THEME.accent or THEME.card_stroke,
        })
    end

    function toggle:Set(value: boolean, silent: boolean?)
        value = value == true

        if self.Value == value then
            return
        end

        self.Value = value
        apply(value)

        if not silent then
            safe_call(callback, value)
        end
    end

    function toggle:Get(): boolean
        return self.Value
    end

    hit.MouseButton1Click:Connect(function()
        toggle:Set(not toggle.Value)
    end)

    hit.MouseEnter:Connect(function()
        tween(checkbox, TWEEN_FAST, { BackgroundColor3 = THEME.field_hover })
    end)

    hit.MouseLeave:Connect(function()
        tween(checkbox, TWEEN_FAST, { BackgroundColor3 = THEME.field })
    end)

    -- optional keybind
    if config.Keybind ~= nil and config.Keybind ~= false then
        local bind = build_keybind_button(right, toggle.Key, function(key: Enum.KeyCode?)
            toggle.Key = key
            safe_call(config.KeybindCallback, key)
        end)

        function toggle:SetKeybind(key: Enum.KeyCode?)
            bind.set(key, true)
            self.Key = key
        end

        register_binding({
            get_key = function()
                return toggle.Key
            end,
            on_press = function()
                if toggle.Mode == "Hold" then
                    toggle:Set(true)
                else
                    toggle:Set(not toggle.Value)
                end
            end,
            on_release = function()
                if toggle.Mode == "Hold" then
                    toggle:Set(false)
                end
            end,
        })

        hit.MouseButton2Click:Connect(function()
            window:_open_popup(hit, Vector2.new(156, 72), "right", function(popup, close)
                local function add_mode_option(label_text: string, mode: string, y: number)
                    local selected = toggle.Mode == mode
                    local option = create("TextButton", {
                        Name = mode .. "Mode",
                        Position = UDim2.fromOffset(5, y),
                        Size = UDim2.new(1, -10, 0, 29),
                        BackgroundColor3 = selected and THEME.field_hover or THEME.popup,
                        BorderSizePixel = 0,
                        AutoButtonColor = false,
                        Text = label_text .. (selected and "  ✓" or ""),
                        TextColor3 = THEME.text,
                        TextSize = 12,
                        Font = FONT,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        ZIndex = 3,
                        Parent = popup,
                    }, { corner(5) })
                    create("UIPadding", { PaddingLeft = UDim.new(0, 9), Parent = option })
                    option.MouseEnter:Connect(function()
                        tween(option, TWEEN_FAST, { BackgroundColor3 = THEME.field_hover })
                    end)
                    option.MouseLeave:Connect(function()
                        tween(option, TWEEN_FAST, { BackgroundColor3 = toggle.Mode == mode and THEME.field_hover or THEME.popup })
                    end)
                    option.MouseButton1Click:Connect(function()
                        toggle.Mode = mode
                        close()
                    end)
                end

                add_mode_option("Toggle", "Toggle", 5)
                add_mode_option("Hold", "Hold", 38)
            end)
        end)
    end

    -- optional colour swatch
    if typeof(config.Color) == "Color3" then
        local swatch = build_swatch(right, self.window, config.Color, config.ColorCallback)
        toggle.Swatch = swatch.button

        function toggle:SetColor(color: Color3)
            swatch.set(color, true)
        end

        function toggle:GetColor(): Color3
            return swatch.get()
        end
    end

    if config.Default == true then
        toggle.Value = true
        fill.Size = UDim2.fromOffset(16, 16)
        checkbox_stroke.Color = THEME.accent
    end

    return toggle
end

Box.AddCheckbox = Box.AddToggle

----------------------------------------------------------
-- BUTTON
----------------------------------------------------------

local BUTTON_ARGS = { "Text", "Callback" }

function Box:AddButton(...)
    local config = parse_args(BUTTON_ARGS, ...)
    local row = new_row(self, 28)

    local button = create("TextButton", {
        Name = "Button",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = THEME.field,
        AutoButtonColor = false,
        Text = config.Text or "Button",
        Font = FONT,
        TextSize = 13,
        TextColor3 = THEME.text,
        Parent = row,
    }, {
        corner(5),
        stroke(THEME.card_stroke),
    })

    local press_scale = create("UIScale", { Parent = button })

    button.MouseEnter:Connect(function()
        tween(button, TWEEN_FAST, { BackgroundColor3 = THEME.field_hover })
    end)

    button.MouseLeave:Connect(function()
        tween(button, TWEEN_FAST, { BackgroundColor3 = THEME.field })
        tween(press_scale, TWEEN_FAST, { Scale = 1 })
    end)

    button.MouseButton1Down:Connect(function()
        tween(press_scale, TWEEN_FAST, { Scale = 0.97 })
    end)

    button.MouseButton1Up:Connect(function()
        tween(press_scale, TWEEN_POP, { Scale = 1 })
    end)

    local control: any = { Type = "Button" }

    function control:Fire()
        safe_call(config.Callback)
    end

    function control:SetText(text: string)
        button.Text = text
    end

    button.MouseButton1Click:Connect(function()
        control:Fire()
    end)

    return control
end

----------------------------------------------------------
-- SLIDER
----------------------------------------------------------

local SLIDER_ARGS = { "Text", "Min", "Max", "Default", "Callback" }

function Box:AddSlider(...)
    local config = parse_args(SLIDER_ARGS, ...)
    local min = config.Min or 0
    local max = config.Max or 100
    local increment = config.Increment or 1
    local suffix = config.Suffix or ""
    local decimals = decimals_of(increment)
    local row = new_row(self, 40)

    local slider: any = { Type = "Slider", Value = min }

    new_label(row, config.Text or "Slider", {
        Size = UDim2.new(1, -60, 0, 16),
    })

    local value_label = new_label(row, "", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(60, 16),
        TextXAlignment = Enum.TextXAlignment.Right,
        TextColor3 = THEME.text_dim,
        TextSize = 12,
    })

    local hit = create("TextButton", {
        Name = "Hit",
        Position = UDim2.fromOffset(0, 20),
        Size = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        Parent = row,
    })

    local track = create("Frame", {
        Name = "Track",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.new(1, 0, 0, 4),
        BackgroundColor3 = THEME.field_hover,
        BorderSizePixel = 0,
        Parent = hit,
    }, { corner(2) })

    local fill = create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = THEME.text,
        BorderSizePixel = 0,
        Parent = track,
    }, { corner(2) })

    local knob = create("Frame", {
        Name = "Knob",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(12, 12),
        BackgroundColor3 = THEME.text,
        ZIndex = 2,
        Parent = track,
    }, { corner(6) })

    local dragging = false

    local function snap(raw: number): number
        local steps = math.floor((raw - min) / increment + 0.5)
        local snapped = math.clamp(min + steps * increment, min, max)
        return tonumber(string.format("%.6f", snapped)) :: number
    end

    local function render(animate: boolean)
        local alpha = max == min and 0 or (slider.Value - min) / (max - min)
        value_label.Text = string.format("%." .. decimals .. "f", slider.Value) .. suffix

        if animate then
            tween(fill, TWEEN_FAST, { Size = UDim2.fromScale(alpha, 1) })
            tween(knob, TWEEN_FAST, { Position = UDim2.fromScale(alpha, 0.5) })
        else
            fill.Size = UDim2.fromScale(alpha, 1)
            knob.Position = UDim2.fromScale(alpha, 0.5)
        end
    end

    function slider:Set(value: number, silent: boolean?)
        local snapped = snap(tonumber(value) or min)

        if snapped == self.Value then
            return
        end

        self.Value = snapped
        render(not dragging)

        if not silent then
            safe_call(config.Callback, snapped)
        end
    end

    function slider:Get(): number
        return self.Value
    end

    local function update_from(position: Vector2)
        local alpha = math.clamp((position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        slider:Set(min + alpha * (max - min))
    end

    hit.InputBegan:Connect(function(input: InputObject)
        if not is_press(input) then
            return
        end

        dragging = true
        tween(knob, TWEEN_POP, { Size = UDim2.fromOffset(15, 15) })

        update_from(pointer_position(input))

        start_drag(input, update_from, function()
            dragging = false
            tween(knob, TWEEN_FAST, { Size = UDim2.fromOffset(12, 12) })
        end)
    end)

    hit.MouseEnter:Connect(function()
        if not dragging then
            tween(knob, TWEEN_FAST, { Size = UDim2.fromOffset(14, 14) })
        end
    end)

    hit.MouseLeave:Connect(function()
        if not dragging then
            tween(knob, TWEEN_FAST, { Size = UDim2.fromOffset(12, 12) })
        end
    end)

    slider.Value = snap(config.Default or min)
    render(false)

    return slider
end

----------------------------------------------------------
-- DROPDOWN
----------------------------------------------------------

local DROPDOWN_ARGS = { "Text", "Options", "Default", "Callback" }

local function build_dropdown_field(row: Frame, top: number): (TextButton, TextLabel, TextLabel, UIStroke)
    local field = create("TextButton", {
        Name = "Field",
        Position = UDim2.fromOffset(0, top),
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundColor3 = THEME.field,
        AutoButtonColor = false,
        Text = "",
        Parent = row,
    }, { corner(5) })

    local field_stroke = build_field_stroke(field)

    local value_label = new_label(field, "", {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.new(1, -32, 1, 0),
    })

    local arrow = new_label(field, "▾", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.fromOffset(14, 14),
        TextXAlignment = Enum.TextXAlignment.Center,
        TextColor3 = THEME.text_dim,
        TextSize = 14,
    })

    field.MouseEnter:Connect(function()
        tween(field, TWEEN_FAST, { BackgroundColor3 = THEME.field_hover })
    end)

    field.MouseLeave:Connect(function()
        tween(field, TWEEN_FAST, { BackgroundColor3 = THEME.field })
    end)

    return field, value_label, arrow, field_stroke
end

function Box:AddDropdown(...)
    local config = parse_args(DROPDOWN_ARGS, ...)
    local window = self.window
    local callback = config.Callback

    local is_size_dropdown = string.upper(tostring(config.Text or "")) == "UI-SIZE"
    local dropdown_options = config.Options
    if is_size_dropdown and dropdown_options == nil then
        dropdown_options = { "100%", "125%", "150%", "200%" }
    end

    local dropdown: any = {
        Type = "Dropdown",
        Options = dropdown_options or {},
        Value = config.Default,
    }

    local function apply_ui_size(value: any)
        if not is_size_dropdown or value == nil then
            return
        end
        local percentage = tonumber(string.match(tostring(value), "[%d%.]+"))
        if percentage then
            window:SetUIScale(percentage)
        end
    end

    local row, top = field_row(self, config.Text, 26)
    local field, value_label, arrow, field_stroke = build_dropdown_field(row, top)

    local function render()
        local has_value = dropdown.Value ~= nil and dropdown.Value ~= ""
        value_label.Text = has_value and tostring(dropdown.Value) or "None"
        value_label.TextColor3 = has_value and THEME.text or THEME.text_dim
    end

    function dropdown:Set(value: any, silent: boolean?)
        if self.Value == value then
            return
        end

        self.Value = value
        render()
        apply_ui_size(value)

        if not silent then
            safe_call(callback, value)
        end
    end

    function dropdown:Get(): any
        return self.Value
    end

    function dropdown:SetOptions(options: { any })
        self.Options = options
    end

    field.MouseButton1Click:Connect(function()
        tween(arrow, TWEEN_FAST, { Rotation = 180 })
        tween(field_stroke, TWEEN_FAST, { Color = THEME.text_dim })

        window:_open_list_popup(field, {
            options = dropdown.Options,
            multi = false,
            keep_open = false,
            is_selected = function(option: any)
                return option == dropdown.Value
            end,
            on_pick = function(option: any)
                dropdown:Set(option)
            end,
            on_close = function()
                tween(arrow, TWEEN_FAST, { Rotation = 0 })
                tween(field_stroke, TWEEN_FAST, { Color = THEME.card_stroke })
            end,
        })
    end)

    render()
    apply_ui_size(dropdown.Value)
    return dropdown
end

function Box:AddMultiDropdown(...)
    local config = parse_args(DROPDOWN_ARGS, ...)
    local window = self.window
    local callback = config.Callback

    local dropdown: any = {
        Type = "MultiDropdown",
        Options = config.Options or {},
        Selected = {},
    }

    local row, top = field_row(self, config.Text, 26)
    local field, value_label, arrow, field_stroke = build_dropdown_field(row, top)

    -- selected names in option order
    local function collect(): { any }
        local list = {}

        for _, option in dropdown.Options do
            if dropdown.Selected[option] then
                table.insert(list, option)
            end
        end

        return list
    end

    local function render()
        local list = collect()
        local has_value = #list > 0

        value_label.Text = has_value and table.concat(list, ", ") or "None"
        value_label.TextColor3 = has_value and THEME.text or THEME.text_dim
    end

    function dropdown:Get(): { any }
        return collect()
    end

    function dropdown:Has(option: any): boolean
        return self.Selected[option] == true
    end

    -- accepts an array of names or a { name = bool } map
    function dropdown:Set(values: { any }, silent: boolean?)
        local selected = {}

        for key, value in values or {} do
            if type(key) == "number" then
                selected[value] = true
            elseif value then
                selected[key] = true
            end
        end

        self.Selected = selected
        render()

        if not silent then
            safe_call(callback, collect())
        end
    end

    function dropdown:SetOptions(options: { any })
        self.Options = options
        render()
    end

    field.MouseButton1Click:Connect(function()
        tween(arrow, TWEEN_FAST, { Rotation = 180 })
        tween(field_stroke, TWEEN_FAST, { Color = THEME.text_dim })

        window:_open_list_popup(field, {
            options = dropdown.Options,
            multi = true,
            keep_open = true,
            is_selected = function(option: any)
                return dropdown.Selected[option] == true
            end,
            on_pick = function(option: any)
                dropdown.Selected[option] = not dropdown.Selected[option] or nil
                render()
                safe_call(callback, collect())
            end,
            on_close = function()
                tween(arrow, TWEEN_FAST, { Rotation = 0 })
                tween(field_stroke, TWEEN_FAST, { Color = THEME.card_stroke })
            end,
        })
    end)

    dropdown:Set(config.Default or {}, true)
    return dropdown
end

----------------------------------------------------------
-- COLORPICKER
----------------------------------------------------------

local COLORPICKER_ARGS = { "Text", "Default", "Callback" }

function Box:AddColorpicker(...)
    local config = parse_args(COLORPICKER_ARGS, ...)
    local row = new_row(self, 24)

    new_label(row, config.Text or "Colour", {
        Size = UDim2.new(1, -40, 1, 0),
    })

    local right = new_right(row)
    local swatch = build_swatch(right, self.window, config.Default or Color3.fromRGB(236, 32, 160), config.Callback)

    local picker: any = { Type = "Colorpicker", Swatch = swatch.button }

    function picker:Set(color: Color3, silent: boolean?)
        swatch.set(color, silent)
    end

    function picker:Get(): Color3
        return swatch.get()
    end

    return picker
end

Box.AddColorPicker = Box.AddColorpicker

----------------------------------------------------------
-- TEXTBOX
----------------------------------------------------------

local TEXTBOX_ARGS = { "Text", "Default", "Callback" }

function Box:AddTextbox(...)
    local config = parse_args(TEXTBOX_ARGS, ...)
    local row, top = field_row(self, config.Text, 26)

    local box: any = { Type = "Textbox", Value = config.Default or "" }

    local input = create("TextBox", {
        Name = "Input",
        Position = UDim2.fromOffset(0, top),
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundColor3 = THEME.field,
        Font = FONT,
        TextSize = 13,
        TextColor3 = THEME.text,
        PlaceholderText = config.Placeholder or "",
        PlaceholderColor3 = THEME.text_dim,
        Text = box.Value,
        ClearTextOnFocus = config.ClearOnFocus == true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    }, {
        corner(5),
        padding(0, 0, 10, 10),
    })

    local input_stroke = build_field_stroke(input)

    input.Focused:Connect(function()
        tween(input_stroke, TWEEN_FAST, { Color = THEME.accent })
    end)

    input.FocusLost:Connect(function(enter_pressed: boolean)
        tween(input_stroke, TWEEN_FAST, { Color = THEME.card_stroke })

        box.Value = input.Text
        safe_call(config.Callback, input.Text, enter_pressed)
    end)

    input:GetPropertyChangedSignal("Text"):Connect(function()
        if config.Numeric then
            local cleaned = input.Text:gsub("[^%d%.%-]", "")
            if cleaned ~= input.Text then
                input.Text = cleaned
                return
            end
        end

        box.Value = input.Text

        if config.Live then
            safe_call(config.Callback, input.Text, false)
        end
    end)

    function box:Set(text: string)
        self.Value = tostring(text)
        input.Text = self.Value
    end

    function box:Get(): string
        return self.Value
    end

    return box
end

----------------------------------------------------------
-- KEYBIND
----------------------------------------------------------

local KEYBIND_ARGS = { "Text", "Default", "Callback" }

function Box:AddKeybind(...)
    local config = parse_args(KEYBIND_ARGS, ...)
    local row = new_row(self, 24)

    new_label(row, config.Text or "Keybind", {
        Size = UDim2.new(1, -60, 1, 0),
    })

    local keybind: any = { Type = "Keybind", Key = config.Default }

    local bind = build_keybind_button(new_right(row), keybind.Key, function(key: Enum.KeyCode?)
        keybind.Key = key
        safe_call(config.Callback, key)
    end)

    function keybind:Set(key: Enum.KeyCode?, silent: boolean?)
        self.Key = key
        bind.set(key, silent)
    end

    function keybind:Get(): Enum.KeyCode?
        return self.Key
    end

    -- OnPress runs whenever the bound key is pressed
    if config.OnPress then
        register_binding({
            get_key = function()
                return keybind.Key
            end,
            on_press = function()
                safe_call(config.OnPress)
            end,
        })
    end

    return keybind
end

----------------------------------------------------------
-- IMAGE
----------------------------------------------------------

local IMAGE_ARGS = { "Image", "Height" }

local function resolve_image(image: any): string
    if type(image) == "number" then
        return "rbxassetid://" .. tostring(image)
    end

    local text = tostring(image or "")
    if text:match("^%d+$") then
        return "rbxassetid://" .. text
    end

    return text
end

function Box:AddImage(...)
    local config = parse_args(IMAGE_ARGS, ...)
    local row = new_row(self, config.Height or 100)

    local holder = create("Frame", {
        Name = "Holder",
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = THEME.field,
        BackgroundTransparency = config.Background == false and 1 or 0,
        ClipsDescendants = true,
        Parent = row,
    }, { corner(config.Corner or 6) })

    local image = create("ImageLabel", {
        Name = "Image",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Image = resolve_image(config.Image),
        ImageColor3 = config.Color or Color3.new(1, 1, 1),
        ScaleType = config.ScaleType or Enum.ScaleType.Fit,
        Parent = holder,
    })

    local control: any = { Type = "Image" }

    function control:Set(new_image: any)
        image.Image = resolve_image(new_image)
    end

    function control:SetColor(color: Color3)
        image.ImageColor3 = color
    end

    return control
end

----------------------------------------------------------
-- LABEL
----------------------------------------------------------

local LABEL_ARGS = { "Text" }

function Box:AddLabel(...)
    local config = parse_args(LABEL_ARGS, ...)

    local label = new_label(self.content, config.Text or "", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = config.Wrap ~= false,
        TextTruncate = Enum.TextTruncate.None,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = config.Color or THEME.text_dim,
        TextSize = config.Size or 12,
        Font = config.Bold and FONT_BOLD or FONT,
        LayoutOrder = self:_next_order(),
    })

    local control: any = { Type = "Label" }

    function control:Set(text: string)
        label.Text = tostring(text)
    end

    function control:SetColor(color: Color3)
        label.TextColor3 = color
    end

    return control
end

----------------------------------------------------------
-- SEPARATOR
----------------------------------------------------------

local SEPARATOR_ARGS = { "Text" }

function Box:AddSeparator(...)
    local config = parse_args(SEPARATOR_ARGS, ...)
    local text = config.Text
    local row = new_row(self, text and 16 or 8)

    create("Frame", {
        Name = "Line",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = THEME.card_stroke,
        BorderSizePixel = 0,
        Parent = row,
    })

    if text then
        -- the label sits on top of the line and hides the part behind it
        local label = new_label(row, text, {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(0, 16),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 0,
            BackgroundColor3 = THEME.card,
            BorderSizePixel = 0,
            TextSize = 11,
            TextColor3 = THEME.text_dim,
            TextTruncate = Enum.TextTruncate.None,
            ZIndex = 2,
        })

        padding(0, 0, 8, 8).Parent = label
    end

    return { Type = "Separator" }
end

----------------------------------------------------------
-- UNLOAD
----------------------------------------------------------

function Library:Unload()
    root_maid.clean()
    GENV[CLEANUP_KEY] = nil
end

return Library
