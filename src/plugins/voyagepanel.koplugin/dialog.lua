--[[--
Kindle-style dialog: a centered white box with a thin black border, a bold Amazon Ember
title, wrapped Ember body text, and a row of buttons split by thin dividers.

    Dialog:new{ title = "…", text = "…", buttons = {
        { text = "Not Now" },                              -- closes
        { text = "Connect", bold = true, callback = fn },  -- closes, then calls fn
    } }
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FontChooser = require("ui/widget/fontchooser")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = Device.screen

local EMBER = "/usr/java/lib/fonts/Amazon-Ember-Regular.ttf"
local EMBER_BOLD = "/usr/java/lib/fonts/Amazon-Ember-Bold.ttf"

local function face(file, size)
    if FontChooser.isFontRegistered(file) then return Font:getFace(file, size) end
    return Font:getFace("cfont", size)
end

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local Dialog = InputContainer:extend{
    title = nil,
    text = "",
    buttons = nil,
    modal = true,
}

function Dialog:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local u = W / 1072
    self.u = u
    self.screen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.screen } } }

    local box_w = round(W * 0.82)
    local pad = round(48 * u)
    self.pad = pad
    self.border = math.max(2, round(3 * u))
    self.line = math.max(1, round(2 * u))

    self.title_w = self.title and TextBoxWidget:new{
        text = self.title, face = face(EMBER_BOLD, 21), width = box_w - 2 * pad,
    }
    self.body_w = TextBoxWidget:new{
        text = self.text, face = face(EMBER, 18), width = box_w - 2 * pad,
    }
    self.button_h = round(110 * u)
    self.labels = {}
    for i, b in ipairs(self.buttons) do
        self.labels[i] = TextWidget:new{ text = b.text, face = face(b.bold and EMBER_BOLD or EMBER, 19) }
    end

    local title_h = self.title_w and (self.title_w:getSize().h + round(24 * u)) or 0
    local box_h = pad + title_h + self.body_w:getSize().h + pad + self.button_h
    self.box = Geom:new{ x = round((W - box_w) / 2), y = round((H - box_h) / 2), w = box_w, h = box_h }
    self.title_h = title_h
    self.dimen = self.box
end

function Dialog:paintTo(bb, x, y)
    local ok, err = pcall(self.paintDialog, self, bb)
    if not ok then
        logger.err("VoyageDialog: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function Dialog:paintDialog(bb)
    local b, pad = self.box, self.pad
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(b.x, b.y, b.w, b.h, self.border, BLACK)

    local ty = b.y + pad
    if self.title_w then
        self.title_w:paintTo(bb, b.x + pad, ty)
        ty = ty + self.title_h
    end
    self.body_w:paintTo(bb, b.x + pad, ty)

    -- Buttons: a full-width rule above, thin dividers between.
    local by = b.y + b.h - self.button_h
    bb:paintRect(b.x, by, b.w, self.line, BLACK)
    local n = #self.buttons
    local col_w = b.w / n
    self.button_hits = {}
    for i, label in ipairs(self.labels) do
        local cx = b.x + round(col_w * (i - 0.5))
        local size = label:getSize()
        label:paintTo(bb, cx - round(size.w / 2), by + round((self.button_h - size.h) / 2))
        if i > 1 then
            bb:paintRect(b.x + round(col_w * (i - 1)), by, self.line, self.button_h, BLACK)
        end
        self.button_hits[i] = Geom:new{ x = b.x + round(col_w * (i - 1)), y = by, w = round(col_w), h = self.button_h }
    end
    if self.pressed then
        local hit = self.button_hits[self.pressed]
        bb:invertRect(hit.x + self.line, hit.y + self.line, hit.w - self.line, hit.h - self.border)
    end
end

function Dialog:onTap(__, ges)
    if self.pressed then return true end
    for i, hit in ipairs(self.button_hits or {}) do
        if inside(ges.pos, hit) then
            -- Show the press (inverted button) before acting, like the Kindle.
            self.pressed = i
            UIManager:setDirty(self, function() return "fast", hit end)
            UIManager:forceRePaint()
            UIManager:scheduleIn(0.15, function()
                local callback = self.buttons[i].callback
                UIManager:close(self)
                if callback then callback() end
            end)
            return true
        end
    end
    return true -- modal: taps elsewhere do nothing
end

function Dialog:onShow()
    UIManager:setDirty(self, function() return "ui", self.box end)
    return true
end

function Dialog:onCloseWidget()
    if self.title_w then self.title_w:free() end
    self.body_w:free()
    for __, l in ipairs(self.labels) do l:free() end
    UIManager:setDirty(nil, function() return "ui", self.box end)
end

return Dialog
