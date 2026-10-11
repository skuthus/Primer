--[[--
The quick panel widget: device name, clock and battery; Airplane / Dark / Sync /
All Settings buttons; a Brightness slider with Auto Brightness. Painted by hand
so it can match the Kindle's layout closely.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen


local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local QuickPanel = InputContainer:extend{
    plugin = nil,
    icon_dir = nil,
}

-- Usable light range. The Voyage can't switch its light fully off, so KOReader adds a
-- synthetic "off" step 0; skip it so the slider matches the Kindle's 0-24.
function QuickPanel.frontlightRange()
    local powerd = Device:getPowerDevice()
    local lo = (Device.canTurnFrontlightOff ~= nil and Device:canTurnFrontlightOff()) and powerd.fl_min or powerd.fl_min + 1
    return lo, powerd.fl_max
end

function QuickPanel:init()
    self.ui = self.plugin.ui
    self.powerd = Device:getPowerDevice()
    self.fl_lo, self.fl_hi = QuickPanel.frontlightRange()
    self.has_auto = self.plugin:hasLightSensor()
    self.text_cache = {}

    self.width = Screen:getWidth()
    local screen = Geom:new{ x = 0, y = 0, w = self.width, h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Pan = { GestureRange:new{ ges = "pan", range = screen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        -- Back and the page-turn buttons close the panel.
        local close = {}
        for __, group in ipairs({ "Back", "PgFwd", "PgBack" }) do
            if Device.input.group[group] then table.insert(close, { Device.input.group[group] }) end
        end
        self.key_events = self.key_events or {}
        self.key_events.Close = close
    end

    self.face_title = Fonts.face("ui_bold", 21)
    self.face_text = Fonts.face("ui", 20)
    self.face_small = Fonts.face("ui", 15)
    self.face_sign = Fonts.face("ui", 26)

    self:layout()
end

-- TextWidgets are cached by (text, face) and freed with the panel.
function QuickPanel:text(str, f)
    local key = str .. "\0" .. tostring(f)
    local w = self.text_cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f }
        self.text_cache[key] = w
    end
    return w
end

function QuickPanel:layout()
    local W = self.width
    local pad = round(W * 0.055)
    local y = round(W * 0.04)
    self.pad = pad

    -- Header: name and clock on the left, battery on the right.
    self.header_y = y
    local name_h = self:text("Ag", self.face_title):getSize().h
    y = y + name_h + round(W * 0.006)
    self.clock_y = y
    y = y + self:text("Ag", self.face_text):getSize().h + round(W * 0.065)

    -- Round buttons in four equal columns.
    local d = round(W * 0.088)
    self.btn_r = round(d / 2)
    self.btn_border = math.max(2, round(W * 0.0028))
    self.btn_icon = round(d * 0.5)
    self.btn_cy = y + self.btn_r
    self.btn_label_y = y + d + round(W * 0.022)
    local label_h = self:text("Ag", self.face_text):getSize().h
    self.buttons = {}
    for i, id in ipairs({ "airplane", "dark", "sync", "settings" }) do
        local cx = round(W * (2 * i - 1) / 8)
        self.buttons[i] = {
            id = id,
            cx = cx,
            hit = Geom:new{ x = cx - round(W / 8), y = y - round(W * 0.02), w = round(W / 4), h = d + label_h + round(W * 0.06) },
        }
    end
    y = self.btn_label_y + label_h + round(W * 0.05)

    self.divider_y = y
    y = y + round(W * 0.05)

    -- Brightness label row, with Auto Brightness on the right.
    self.bright_label_y = y
    local row_h = self:text("Ag", self.face_text):getSize().h
    local box = round(W * 0.042)
    self.check_box = Geom:new{ x = W - pad - box, y = y + round((row_h - box) / 2), w = box, h = box }
    self.auto_hit = Geom:new{ x = round(W / 2), y = y - round(W * 0.02), w = round(W / 2), h = row_h + round(W * 0.04) }
    y = y + row_h + round(W * 0.04)

    -- Value above the knob, then the slider row.
    self.value_y = y
    y = y + self:text("24", self.face_small):getSize().h + round(W * 0.01)
    self.knob_r = round(W * 0.03)
    self.slider_cy = y + self.knob_r
    local minus = self:text("−", self.face_sign):getSize()
    local plus = self:text("+", self.face_sign):getSize()
    self.minus_x = pad
    self.plus_x = W - pad - plus.w
    self.track_x0 = pad + minus.w + round(W * 0.06) + self.knob_r
    self.track_x1 = self.plus_x - round(W * 0.06) - self.knob_r
    local hit_h = self.knob_r * 4
    self.minus_hit = Geom:new{ x = 0, y = self.slider_cy - hit_h / 2, w = self.track_x0 - self.knob_r, h = hit_h }
    self.plus_hit = Geom:new{ x = self.track_x1 + self.knob_r, y = self.slider_cy - hit_h / 2, w = W - self.track_x1 - self.knob_r, h = hit_h }
    self.slider_hit = Geom:new{ x = self.track_x0 - self.knob_r, y = self.slider_cy - hit_h / 2,
        w = self.track_x1 - self.track_x0 + 2 * self.knob_r, h = hit_h }
    self.brightness_area = Geom:new{ x = 0, y = self.value_y, w = W, h = self.slider_cy + hit_h / 2 - self.value_y }
    y = self.slider_cy + self.knob_r + round(W * 0.075)

    -- Closing chevron.
    self.chevron_w = round(W * 0.1)
    self.chevron_h = round(self.chevron_w / 4)
    self.chevron_y = y
    self.chevron_hit = Geom:new{ x = round(W * 0.3), y = y - round(W * 0.04), w = round(W * 0.4), h = self.chevron_h + round(W * 0.08) }
    y = y + self.chevron_h + round(W * 0.035)

    self.border = math.max(2, round(W * 0.002))
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = y + self.border }
end

function QuickPanel:buttonState(id)
    if id == "airplane" then
        local on = not self.plugin:isWirelessOn()
        return on, on and _("On") or _("Off")
    elseif id == "dark" then
        local on = G_reader_settings:isTrue("night_mode")
        return on, on and _("On") or _("Off")
    elseif id == "sync" then
        return false, _("Sync")
    else
        return false, _("All Settings")
    end
end

-- Icons render black on white; `invert` gives a white glyph on black for active buttons.
function QuickPanel:icon(name, w, h, invert)
    return IconWidget:new{ file = self.icon_dir .. "/" .. name .. ".svg", width = w, height = h, invert = invert }
end

function QuickPanel:knobX()
    local level = math.min(math.max(self.powerd:frontlightIntensity(), self.fl_lo), self.fl_hi)
    local frac = (level - self.fl_lo) / math.max(self.fl_hi - self.fl_lo, 1)
    return round(self.track_x0 + frac * (self.track_x1 - self.track_x0)), level
end

function QuickPanel:paintTo(bb, x, y)
    local ok, err = pcall(self.paintPanel, self, bb, x, y)
    if not ok then
        logger.err("VoyagePanel: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function QuickPanel:paintPanel(bb, x, y)
    local W, pad = self.width, self.pad
    local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, W, self.dimen.h, WHITE)

    -- Header
    local name = self.plugin:deviceName()
    self:text(name, self.face_title):paintTo(bb, x + pad, y + self.header_y)
    local now = os.time()
    local clock = datetime.secondsToHour(now, G_reader_settings:isTrue("twelve_hour_clock"))
        .. " • " .. os.date("%d %b %Y", now):gsub("^0", "")
    local clock_w = TextWidget:new{ text = clock, face = self.face_text }
    clock_w:paintTo(bb, x + pad, y + self.clock_y)
    clock_w:free()
    local name_h = self:text(name, self.face_title):getSize().h
    self.plugin:paintBattery(bb, x + W - pad, y + self.header_y + round(name_h / 2), round(W * 0.022), self.face_text)

    -- Buttons
    for __, b in ipairs(self.buttons) do
        local active, label = self:buttonState(b.id)
        local cy = y + self.btn_cy
        if active then
            bb:paintCircle(x + b.cx, cy, self.btn_r, BLACK)
        else
            bb:paintCircle(x + b.cx, cy, self.btn_r, BLACK, self.btn_border)
        end
        local icon = self:icon(b.id, self.btn_icon, self.btn_icon, active)
        icon:paintTo(bb, x + b.cx - round(self.btn_icon / 2), cy - round(self.btn_icon / 2))
        icon:free()
        local lw = self:text(label, self.face_text)
        lw:paintTo(bb, x + b.cx - round(lw:getSize().w / 2), y + self.btn_label_y)
    end

    bb:paintRect(x, y + self.divider_y, W, self.border, Blitbuffer.COLOR_LIGHT_GRAY)

    -- Brightness
    self:text(_("Brightness"), self.face_text):paintTo(bb, x + pad, y + self.bright_label_y)
    if self.has_auto then
        local cb = self.check_box
        local auto_w = self:text(_("Auto Brightness"), self.face_text)
        auto_w:paintTo(bb, x + cb.x - round(W * 0.025) - auto_w:getSize().w, y + self.bright_label_y)
        bb:paintBorder(x + cb.x, y + cb.y, cb.w, cb.h, self.btn_border, BLACK, round(cb.w * 0.12))
        if self.plugin.auto then
            local inset = round(cb.w * 0.12)
            local check = self:icon("check", cb.w - 2 * inset, cb.h - 2 * inset, false)
            check:paintTo(bb, x + cb.x + inset, y + cb.y + inset)
            check:free()
        end
    end
    self:paintSlider(bb, x, y)

    -- Chevron and bottom edge
    local chevron = self:icon("chevron", self.chevron_w, self.chevron_h, false)
    chevron:paintTo(bb, x + round((W - self.chevron_w) / 2), y + self.chevron_y)
    chevron:free()
    bb:paintRect(x, y + self.dimen.h - self.border, W, self.border, Blitbuffer.COLOR_DARK_GRAY)
end

function QuickPanel:paintSlider(bb, x, y)
    local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local area = self.brightness_area
    bb:paintRect(x + area.x, y + area.y, area.w, area.h, WHITE)

    local cy = y + self.slider_cy
    local sign_h = self:text("+", self.face_sign):getSize().h
    self:text("−", self.face_sign):paintTo(bb, x + self.minus_x, cy - round(sign_h / 2))
    self:text("+", self.face_sign):paintTo(bb, x + self.plus_x, cy - round(sign_h / 2))

    local kx, level = self:knobX()
    local thin, thick = self.border, math.max(4, round(self.width * 0.0075))
    bb:paintRect(x + self.track_x0, cy - round(thin / 2), self.track_x1 - self.track_x0, thin, BLACK)
    bb:paintRect(x + self.track_x0, cy - round(thick / 2), kx - self.track_x0, thick, BLACK)
    bb:paintCircle(x + kx, cy, self.knob_r, WHITE)
    bb:paintCircle(x + kx, cy, self.knob_r, BLACK, self.btn_border)

    local value = self:text(tostring(level - self.fl_lo), self.face_small)
    value:paintTo(bb, x + kx - round(value:getSize().w / 2), y + self.value_y)
end

function QuickPanel:refresh(mode, region)
    UIManager:setDirty(self, function() return mode or "ui", region or self.dimen end)
end

function QuickPanel:refreshBrightness(mode)
    self:refresh(mode, self.brightness_area)
end

function QuickPanel:setLevel(level, mode)
    level = math.min(math.max(level, self.fl_lo), self.fl_hi)
    if self.plugin.auto then
        -- Moving the slider takes over from Auto Brightness.
        self.plugin:setAuto(false)
        self:refresh()
    end
    if level ~= self.powerd:frontlightIntensity() then
        self.powerd:setIntensity(level)
        self.powerd:updateResumeFrontlightState()
    end
    self:refreshBrightness(mode)
end

function QuickPanel:levelAt(pos_x)
    local frac = (pos_x - self.track_x0) / math.max(self.track_x1 - self.track_x0, 1)
    return self.fl_lo + round(math.min(math.max(frac, 0), 1) * (self.fl_hi - self.fl_lo))
end

function QuickPanel:onTap(__, ges)
    local pos = ges.pos
    if not inside(pos, self.dimen) or inside(pos, self.chevron_hit) then
        return self:onClose()
    end
    for __, b in ipairs(self.buttons) do
        if inside(pos, b.hit) then
            self:pressButton(b.id)
            return true
        end
    end
    if self.has_auto and inside(pos, self.auto_hit) then
        self.plugin:setAuto(not self.plugin.auto)
        self:refresh()
    elseif inside(pos, self.minus_hit) then
        self:setLevel(self.powerd:frontlightIntensity() - 1)
    elseif inside(pos, self.plus_hit) then
        self:setLevel(self.powerd:frontlightIntensity() + 1)
    elseif inside(pos, self.slider_hit) then
        self:setLevel(self:levelAt(pos.x))
    end
    return true
end

function QuickPanel:onPan(__, ges)
    if inside(ges.pos, self.slider_hit) or self.dragging then
        self.dragging = true
        self:setLevel(self:levelAt(ges.pos.x), "fast")
    end
    return true
end

function QuickPanel:onPanRelease()
    if self.dragging then
        self.dragging = false
        self:refreshBrightness("ui")
    end
    return true
end

function QuickPanel:onSwipe(__, ges)
    if ges.direction == "north" then
        return self:onClose()
    end
    return true
end

function QuickPanel:pressButton(id)
    if id == "airplane" then
        self.plugin:setWireless(not self.plugin:isWirelessOn())
        self:refresh()
    elseif id == "dark" then
        UIManager:broadcastEvent(Event:new("ToggleNightMode"))
        self:refresh("full")
    elseif id == "sync" then
        self:onClose()
        self.plugin:sync()
    elseif id == "settings" then
        self:onClose()
        self.plugin:openAllSettings()
    end
end

function QuickPanel:onShow()
    self:refresh()
    return true
end

function QuickPanel:onClose()
    UIManager:close(self)
    return true
end

function QuickPanel:onCloseWidget()
    for __, w in pairs(self.text_cache) do w:free() end
    self.text_cache = {}
    self.plugin.panel = nil
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return QuickPanel
