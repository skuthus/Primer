--[[--
Kindle-style dropdown menu hanging from a button: a white box with a thick black border and
light rules between rows, right-aligned under the button. Tapping a row closes the menu and
runs it; tapping anywhere else just closes the menu.

    Dropdown:new{ anchor = button_rect, items = { { text = "Notebook", callback = fn }, … } }
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = Device.screen

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local Dropdown = InputContainer:extend{
    anchor = nil,  -- Geom of the button it hangs from
    items = nil,   -- { text, callback }
    modal = true,
}

function Dropdown:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- Sizes scale from the shorter side, so landscape keeps portrait proportions.
    local u = math.min(W, H) / 1072
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = W, h = H } } } }
    if Device:hasKeys() and Device.input.group.Back then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.pad = round(47 * u)
    self.thick = math.max(2, round(3 * u))
    self.line = math.max(1, round(2 * u))
    self.row_h = round(96 * u)
    local face = Fonts.face("ui", 18)
    local w = round(420 * u)
    for __, item in ipairs(self.items) do
        item.widget = TextWidget:new{ text = item.text, face = face }
        w = math.max(w, item.widget:getSize().w + 2 * self.pad)
    end
    local a = self.anchor
    local margin = round(16 * u)
    local x = math.max(margin, math.min(a.x + a.w - margin, W - margin) - w)
    local h = self.row_h * #self.items
    local y = a.y + a.h - round(4 * u)
    if y + h > H - margin then y = a.y - h + round(4 * u) end
    self.box = Geom:new{ x = x, y = y, w = w, h = h }
    self.dimen = self.box
end

function Dropdown:paintTo(bb)
    local ok, err = pcall(self.paintMenu, self, bb)
    if not ok then
        logger.err("VoyageDropdown: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

function Dropdown:paintMenu(bb)
    local m, thick = self.box, self.thick
    bb:paintRect(m.x, m.y, m.w, m.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(m.x, m.y, m.w, m.h, thick, Blitbuffer.COLOR_BLACK)
    for i, item in ipairs(self.items) do
        local ry = m.y + (i - 1) * self.row_h
        if i > 1 then bb:paintRect(m.x + self.pad, ry, m.w - 2 * self.pad, self.line, Blitbuffer.COLOR_LIGHT_GRAY) end
        item.widget:paintTo(bb, m.x + self.pad, ry + round((self.row_h - item.widget:getSize().h) / 2))
        if self.pressed == i then
            local top, bottom = i == 1 and thick or 0, i == #self.items and thick or 0
            bb:invertRect(m.x + thick, ry + top, m.w - 2 * thick, self.row_h - top - bottom)
        end
    end
end

function Dropdown:onTap(__, ges)
    if self.pressed then return true end
    local m = self.box
    if not inside(ges.pos, m) then return self:onClose() end
    local i = math.floor((ges.pos.y - m.y) / self.row_h) + 1
    local item = self.items[i]
    if item then
        self.pressed = i
        UIManager:setDirty(self, function() return "fast", m end)
        UIManager:forceRePaint()
        UIManager:scheduleIn(0.12, function()
            self:onClose()
            if item.callback then item.callback() end
        end)
    end
    return true
end

function Dropdown:onShow()
    UIManager:setDirty(self, function() return "ui", self.box end)
    return true
end

function Dropdown:onClose()
    UIManager:close(self)
    return true
end

function Dropdown:onCloseWidget()
    for __, item in ipairs(self.items) do
        if item.widget then item.widget:free() item.widget = nil end
    end
    UIManager:setDirty(nil, function() return "ui", self.box end)
end

return Dropdown
