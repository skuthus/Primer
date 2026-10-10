--[[--
Kindle-style library search: a bar across the top (magnifier, text field, Cancel) over the
library, with the keyboard below. The book list filters as you type; Enter (or closing the
keyboard) keeps the results, Cancel clears them.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local SearchBar = InputContainer:extend{
    -- The keyboard is modal: without this, taps on Cancel never arrive.
    is_always_active = true,
    plugin = nil,
    text = "",
    on_change = nil,  -- function(text): live filtering
    on_done = nil,    -- function(text): kept
    on_cancel = nil,
}

function SearchBar:init()
    local W = Screen:getWidth()
    local u = W / 1072
    self.u = u
    self.bar = Geom:new{ x = 0, y = 0, w = W, h = round(118 * u) }
    self.dimen = self.bar
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.bar } } }

    self.cancel_w = TextWidget:new{ text = _("Cancel"), face = Fonts.face("ui", 18) }
    local pad = round(32 * u)
    self.pad = pad
    self.cancel_hit = Geom:new{ x = W - pad * 2 - self.cancel_w:getSize().w, y = 0,
        w = pad * 2 + self.cancel_w:getSize().w, h = self.bar.h }
    -- Field: rounded box from the left edge to Cancel, magnifier inside on the left.
    self.field = Geom:new{ x = pad, y = round(22 * u), w = self.cancel_hit.x - pad - round(10 * u), h = self.bar.h - round(44 * u) }
    local icon_room = round(64 * u)
    self.input = InputText:new{
        text = self.text,
        hint = _("Search your library"),
        face = Fonts.face("ui", 18),
        width = self.field.w - icon_room - round(20 * u),
        height = nil,
        padding = 0, margin = 0, bordersize = 0,
        focused = true,
        parent = self,
        edit_callback = function(edited)
            if edited then self:changed() end
        end,
        enter_callback = function() self:done() end,
    }
    self[1] = self.input
    self.icon_room = icon_room
end

-- Debounced live filtering, so typing stays snappy on e-ink.
function SearchBar:changed()
    UIManager:unschedule(self.change_task)
    self.change_task = self.change_task or function()
        if self.on_change and not self.closed then self.on_change(self.input:getText()) end
    end
    UIManager:scheduleIn(0.4, self.change_task)
end

function SearchBar:paintTo(bb, x, y)
    local ok, err = pcall(self.paintBar, self, bb, x, y)
    if not ok then
        logger.err("VoyageSearch: paint failed:", err)
        UIManager:nextTick(function() self:cancel() end)
    end
end

function SearchBar:paintBar(bb, x, y)
    local u, b, f = self.u, self.bar, self.field
    local line = math.max(1, round(2 * u))
    bb:paintRect(x + b.x, y + b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x + b.x, y + b.y + b.h - line, b.w, line, Blitbuffer.COLOR_GRAY)
    bb:paintBorder(x + f.x, y + f.y, f.w, f.h, line, Blitbuffer.COLOR_BLACK, round(f.h / 2))
    local s = round(f.h * 0.55)
    local icon = self.plugin:icon("search", s)
    icon:paintTo(bb, x + f.x + round((self.icon_room - s) / 2) + round(10 * u), y + f.y + round((f.h - s) / 2))
    icon:free()
    local isz = self.input:getSize()
    self.input:paintTo(bb, x + f.x + self.icon_room + round(6 * u), y + f.y + round((f.h - isz.h) / 2))
    local c = self.cancel_w
    c:paintTo(bb, x + self.cancel_hit.x + self.pad, y + round((b.h - c:getSize().h) / 2))
end

function SearchBar:onTap(__, ges)
    if inside(ges.pos, self.cancel_hit) then
        self:cancel()
    elseif self.input and self.input.dimen and inside(ges.pos, self.input.dimen) then
        self.input:onTapTextBox(nil, ges)
    end
    return true
end

function SearchBar:close()
    self.closed = true
    UIManager:unschedule(self.change_task)
    if self.input then self.input:onCloseKeyboard() end
    UIManager:close(self)
end

function SearchBar:done()
    local text = self.input:getText()
    self:close()
    if self.on_done then self.on_done(text) end
end

function SearchBar:cancel()
    self:close()
    if self.on_cancel then self.on_cancel() end
end

function SearchBar:onShow()
    UIManager:setDirty(self, function() return "ui", self.bar end)
    self.input:onShowKeyboard()
    return true
end

function SearchBar:onCloseWidget()
    if self.cancel_w then self.cancel_w:free() end
    UIManager:setDirty(nil, function() return "ui", self.bar end)
end

return SearchBar
