--[[--
End of book, Kindle-style: turning past the last page marks the book as finished (as the
Kindle does) and shows a card with the book and Mark as Unread / Go to Beginning / Library.
Tapping outside the card stays on the last page.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local EndCard = InputContainer:extend{
    plugin = nil,
    modal = true,
}

function EndCard:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.u = self.W / 1072
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() and Device.input.group.Back then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if not self:finished() then self.ui.status:markBook(true) end
    self:layout()
end

function EndCard:finished()
    local summary = self.ui.doc_settings:readSetting("summary")
    return summary and summary.status == "complete"
end

function EndCard:layout()
    self:freeWidgets()
    local u = self.u
    self.pad = round(48 * u)
    self.line = math.max(1, round(2 * u))
    self.border = math.max(2, round(3 * u))
    local w = round(self.W * 0.88)
    local inner = w - 2 * self.pad
    self.widgets = {}
    self.lines = {}
    local function line(text, role, size, gap)
        if not text or text == "" then return end
        local widget = TextBoxWidget:new{ text = text, face = Fonts.face(role, size), width = inner, alignment = "center" }
        table.insert(self.widgets, widget)
        table.insert(self.lines, { widget = widget, gap = gap or 0 })
    end
    local props = self.ui.doc_props or {}
    line(_("You've finished"), "ui", 17)
    line(props.display_title, "serif_bold", 24, round(18 * u))
    line(props.authors and props.authors:gsub("\n", ", "), "ui", 17, round(8 * u))
    line(self:finished() and _("Marked as finished") or _("Marked as unread"), "ui_italic", 15, round(30 * u))

    local finished = self:finished()
    self.buttons = {
        { id = "toggle", text = finished and _("Mark as Unread") or _("Mark as Finished") },
        { id = "beginning", text = _("Go to Beginning") },
        { id = "library", text = _("Library"), bold = true },
    }
    for __, b in ipairs(self.buttons) do
        b.widget = TextWidget:new{ text = b.text, face = Fonts.face(b.bold and "ui_bold" or "ui", 18), max_width = round(w / 3) - round(16 * u) }
        table.insert(self.widgets, b.widget)
    end
    self.button_h = round(104 * u)
    local text_h = 0
    for __, l in ipairs(self.lines) do text_h = text_h + l.gap + l.widget:getSize().h end
    local h = self.pad + text_h + self.pad + self.button_h
    self.card = Geom:new{ x = round((self.W - w) / 2), y = round((self.H - h) / 2), w = w, h = h }
end

function EndCard:freeWidgets()
    for __, widget in ipairs(self.widgets or {}) do widget:free() end
    self.widgets = {}
end

function EndCard:paintTo(bb, x, y)
    local ok, err = pcall(self.paintCard, self, bb, x, y)
    if not ok then
        logger.err("VoyageEndCard: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

function EndCard:paintCard(bb, x, y)
    local c = self.card
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x + c.x, y + c.y, c.w, c.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x + c.x, y + c.y, c.w, c.h, self.border, BLACK)
    local ty = y + c.y + self.pad
    for __, l in ipairs(self.lines) do
        ty = ty + l.gap
        l.widget:paintTo(bb, x + c.x + self.pad, ty)
        ty = ty + l.widget:getSize().h
    end
    local by = y + c.y + c.h - self.button_h
    bb:paintRect(x + c.x, by, c.w, self.line, BLACK)
    local col = c.w / #self.buttons
    for i, b in ipairs(self.buttons) do
        local bx = x + c.x + round(col * (i - 1))
        if i > 1 then bb:paintRect(bx, by, self.line, self.button_h, BLACK) end
        local s = b.widget:getSize()
        b.widget:paintTo(bb, bx + round((col - s.w) / 2), by + round((self.button_h - s.h) / 2))
        b.rect = Geom:new{ x = bx - x, y = by - y, w = round(col), h = self.button_h }
        if self.pressed == i then
            bb:invertRect(bx + self.line, by + self.line, round(col) - self.line, self.button_h - self.border)
        end
    end
end

function EndCard:act(id)
    if id == "toggle" then
        self.ui.status:markBook()
        local old = self.card
        self:layout()
        UIManager:setDirty(nil, function() return "ui", old end)
        UIManager:setDirty(self, function() return "ui", self.card end)
    elseif id == "beginning" then
        self:onClose()
        self.ui.gotopage:onGoToBeginning()
    elseif id == "library" then
        self:onClose()
        self.ui:onHome()
    end
end

function EndCard:onTap(__, ges)
    if not inside(ges.pos, self.card) then return self:onClose() end
    for i, b in ipairs(self.buttons) do
        if b.rect and inside(ges.pos, b.rect) then
            self.pressed = i
            UIManager:setDirty(self, function() return "fast", b.rect end)
            UIManager:forceRePaint()
            UIManager:scheduleIn(0.12, function()
                self.pressed = nil
                self:act(b.id)
            end)
            return true
        end
    end
    return true
end

function EndCard:onShow()
    UIManager:setDirty(self, function() return "ui", self.card end)
    return true
end

function EndCard:onClose()
    UIManager:close(self)
    return true
end

function EndCard:onCloseWidget()
    self:freeWidgets()
    self.plugin.endcard = nil
    UIManager:setDirty(nil, function() return "ui", self.card end)
end

return EndCard
