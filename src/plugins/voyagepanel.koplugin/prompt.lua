--[[--
Kindle-style text entry: a white box near the top (bold title, optional line of text, a
bordered field, Cancel | OK) with the keyboard below. Used for Go To page, theme and device
names, and Wi-Fi passwords.

    Prompt:new{ title = "Go to Page", hint = "1–320", input_type = "number", ok_text = "Go",
        on_ok = function(text, prompt) ... return true end }  -- true (or nil) closes
    prompt:setMessage("No such page")  -- shown under the field, e.g. after a bad entry
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
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

local Prompt = InputContainer:extend{
    -- The keyboard is modal: without this, taps on Cancel / OK never arrive.
    is_always_active = true,
    title = "",
    description = nil,  -- line of text above the field
    text = "",
    hint = nil,
    input_type = nil,   -- "number" for the number keyboard
    text_type = nil,    -- "password"
    ok_text = nil,
    on_ok = nil,
    on_cancel = nil,
}

function Prompt:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- Sizes scale from the shorter side, so landscape keeps portrait proportions.
    local u = math.min(W, H) / 1072
    self.u = u
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = W, h = H } } } }
    if Device:hasKeys() and Device.input.group.Back then
        self.key_events = self.key_events or {}
        self.key_events.Cancel = { { Device.input.group.Back } }
    end
    self.pad = round(48 * u)
    self.border = math.max(2, round(3 * u))
    self.line = math.max(1, round(2 * u))
    local w = round(math.min(W, H) * 0.88) -- portrait width, also in landscape
    local inner = w - 2 * self.pad
    self.widgets = {}
    local function keep(widget) table.insert(self.widgets, widget) return widget end

    self.title_w = keep(TextBoxWidget:new{ text = self.title, face = Fonts.face("ui_bold", 21), width = inner })
    self.desc_w = self.description and keep(TextBoxWidget:new{ text = self.description, face = Fonts.face("ui", 17), width = inner })
    local padding, fborder = round(14 * u), math.max(1, round(2 * u))
    self.input = InputText:new{
        text = self.text,
        hint = self.hint,
        face = Fonts.face("ui", 19),
        width = inner - 2 * (padding + fborder),
        input_type = self.input_type,
        text_type = self.text_type,
        padding = padding,
        margin = 0,
        bordersize = fborder,
        focused = true,
        parent = self,
        enter_callback = function() self:ok() end,
    }
    self[1] = self.input -- so the keyboard's edits reach it
    self.button_h = round(104 * u)
    self.buttons = {
        { id = "cancel", widget = keep(TextWidget:new{ text = _("Cancel"), face = Fonts.face("ui", 19) }) },
        { id = "ok", widget = keep(TextWidget:new{ text = self.ok_text or _("OK"), face = Fonts.face("ui_bold", 19) }) },
    }
    self.msg_h = round(Fonts.face("ui", 16).size * 1.6)
    self:layout(w)
end

function Prompt:layout(w)
    local u = self.u
    local h = self.pad + self.title_w:getSize().h
    if self.desc_w then h = h + round(14 * u) + self.desc_w:getSize().h end
    h = h + round(28 * u) + self.input:getSize().h + round(12 * u) + self.msg_h + self.button_h
    -- Near the top, so the keyboard fits below.
    self.box = Geom:new{ x = round((Screen:getWidth() - w) / 2), y = round(Screen:getHeight() * 0.05), w = w, h = h }
    self.dimen = self.box
end

function Prompt:setMessage(text)
    if self.msg_w then self.msg_w:free() end
    self.msg_w = text and TextWidget:new{ text = text, face = Fonts.face("ui", 16), max_width = self.box.w - 2 * self.pad }
    UIManager:setDirty(self, function() return "ui", self.box end)
end

function Prompt:getText()
    return self.input:getText()
end

function Prompt:paintTo(bb, x, y)
    local ok, err = pcall(self.paintPrompt, self, bb)
    if not ok then
        logger.err("VoyagePrompt: paint failed:", err)
        UIManager:nextTick(function() self:close() end)
    end
end

function Prompt:paintPrompt(bb)
    local u, b, pad = self.u, self.box, self.pad
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(b.x, b.y, b.w, b.h, self.border, BLACK)
    local ty = b.y + pad
    self.title_w:paintTo(bb, b.x + pad, ty)
    ty = ty + self.title_w:getSize().h
    if self.desc_w then
        ty = ty + round(14 * u)
        self.desc_w:paintTo(bb, b.x + pad, ty)
        ty = ty + self.desc_w:getSize().h
    end
    ty = ty + round(28 * u)
    self.input:paintTo(bb, b.x + pad, ty)
    ty = ty + self.input:getSize().h + round(12 * u)
    if self.msg_w then self.msg_w:paintTo(bb, b.x + pad, ty) end

    local by = b.y + b.h - self.button_h
    bb:paintRect(b.x, by, b.w, self.line, BLACK)
    local col = b.w / #self.buttons
    for i, btn in ipairs(self.buttons) do
        local bx = b.x + round(col * (i - 1))
        if i > 1 then bb:paintRect(bx, by, self.line, self.button_h, BLACK) end
        local s = btn.widget:getSize()
        btn.widget:paintTo(bb, bx + round((col - s.w) / 2), by + round((self.button_h - s.h) / 2))
        btn.rect = Geom:new{ x = bx, y = by, w = round(col), h = self.button_h }
        if self.pressed == i then
            bb:invertRect(bx + self.line, by + self.line, round(col) - self.line, self.button_h - self.border)
        end
    end
end

function Prompt:ok()
    local close = true
    if self.on_ok then close = self.on_ok(self.input:getText(), self) ~= false end
    if close then self:close() end
end

function Prompt:onCancel()
    self:close()
    if self.on_cancel then self.on_cancel() end
    return true
end

function Prompt:onTap(__, ges)
    local pos = ges.pos
    for i, btn in ipairs(self.buttons) do
        if btn.rect and inside(pos, btn.rect) then
            self.pressed = i
            UIManager:setDirty(self, function() return "fast", btn.rect end)
            UIManager:forceRePaint()
            UIManager:scheduleIn(0.12, function()
                self.pressed = nil
                UIManager:setDirty(self, function() return "ui", btn.rect end)
                if btn.id == "ok" then self:ok() else self:onCancel() end
            end)
            return true
        end
    end
    if self.input.dimen and inside(pos, self.input.dimen) then
        return self.input:onTapTextBox(nil, ges)
    end
    return true
end

function Prompt:close()
    if self.closed then return end
    self.closed = true
    self.input:onCloseKeyboard()
    UIManager:close(self)
end

function Prompt:onShow()
    UIManager:setDirty(self, function() return "ui", self.box end)
    self.input:onShowKeyboard()
    return true
end

function Prompt:onCloseWidget()
    for __, w in ipairs(self.widgets) do w:free() end
    if self.msg_w then self.msg_w:free() end
    UIManager:setDirty(nil, function() return "ui", self.box end)
end

return Prompt
