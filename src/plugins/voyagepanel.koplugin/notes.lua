--[[--
Kindle-style note popup, anchored to its highlight with a notch:

    Note   ALL NOTES                         ✕
    ─────────────────────────────────────────
    the note text
    ─────────────────────────────────────────
                           COPY   DELETE   EDIT

EDIT (or adding a note) turns the body into a text field above the on-screen keyboard,
with CANCEL / SAVE. Saving follows KOReader's own note saving (annotation counts, PDF write-back).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen


local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local NotePopup = InputContainer:extend{
    -- The on-screen keyboard is modal: without this, taps outside it (CANCEL, SAVE, ✕) never
    -- reach us while editing. KOReader's own InputDialog sets the same flag.
    is_always_active = true,
    plugin = nil,
    highlight = nil,   -- ReaderHighlight
    index = nil,       -- annotation index
    boxes = nil,       -- screen boxes of the highlight (for the notch)
    editing = false,   -- start in edit mode
    is_new = false,    -- note for a highlight saved just for it: cancelling removes the highlight
}

function NotePopup:init()
    self.ui = self.highlight.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.u = math.min(self.W, self.H) / 1072 -- sizes follow the short side (landscape too)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.cache = {}

    local screen = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    -- Page-turn buttons always get you out (cancel while editing).
    if Device:hasKeys() then
        local keys = {}
        for __, group in ipairs({ "Back", "PgFwd", "PgBack" }) do
            if Device.input.group[group] then table.insert(keys, { Device.input.group[group] }) end
        end
        self.key_events = self.key_events or {}
        self.key_events.Escape = keys
    end

    self.face_title = Fonts.face("ui_bold", 22)
    self.face_link = Fonts.face("ui", 18)
    self.face_body = Fonts.face("ui", 18)
    self.face_action = Fonts.face("ui", 18)

    if self.editing then self:startEditing() else self:layoutView() end
end

function NotePopup:annotation()
    return self.ui.annotation.annotations[self.index]
end

function NotePopup:text(str, f)
    local key = str .. "\0" .. tostring(f)
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f }
        self.cache[key] = w
    end
    return w
end

-- Box geometry: header / body / footer, below the highlight (or above it, or at the top while editing).
function NotePopup:layoutBox(body_h)
    local u, W, H = self.u, self.W, self.H
    -- Landscape: cap the width so lines stay readable, and centre the box.
    local span = math.min(W, H * 1.2)
    local margin = round(span * 0.06)
    self.header_h, self.footer_h = round(128 * u), round(118 * u)
    self.notch = round(26 * u)
    local w = round(span) - 2 * margin
    local bx = round((W - w) / 2)
    local sel = self.boxes and self.boxes[1] and Geom.boundingBox(self.boxes)
    if sel and not self.editing and W > H then
        -- Landscape is short: shrink the body to fit the roomier side of the highlight.
        local room = math.max(H - round(20 * u) - (sel.y + sel.h), sel.y - round(20 * u))
        body_h = math.max(round(160 * u), math.min(body_h, room - self.notch - self.header_h - self.footer_h))
    end
    local h = self.header_h + body_h + self.footer_h
    local y, notch_up
    if self.editing or not sel then
        y, notch_up = round(H * 0.03), nil
    elseif sel.y + sel.h + self.notch + h <= H - round(20 * u) then
        y, notch_up = sel.y + sel.h + self.notch, true
    else
        y, notch_up = math.max(round(20 * u), sel.y - self.notch - h), false
    end
    self.box = Geom:new{ x = bx, y = round(y), w = w, h = h }
    self.notch_up = notch_up
    if sel then
        local last = self.boxes[#self.boxes]
        self.notch_x = math.min(math.max(last.x + last.w - round(20 * u), bx + self.notch * 2), bx + w - self.notch * 2)
    end
    self.body_y = self.box.y + self.header_h
    self.body_h = body_h
    self.pad = round(80 * u)
    self.close_hit = Geom:new{ x = self.box.x + w - round(150 * u), y = self.box.y, w = round(150 * u), h = self.header_h }
    self.all_hit = Geom:new{ x = self.box.x + round(220 * u), y = self.box.y, w = round(360 * u), h = self.header_h }
    -- Region to refresh, including the notch.
    self.region = Geom:new{ x = 0, y = self.box.y - self.notch - 2, w = W, h = h + 2 * self.notch + 4 }
end

function NotePopup:layoutView()
    local u = self.u
    self:layoutBox(round(330 * u))
    if self.body then self.body:free() end
    local anno = self:annotation()
    self.body = TextBoxWidget:new{
        text = anno and anno.note or "",
        face = self.face_body,
        width = self.box.w - 2 * self.pad,
        height = self.body_h - round(60 * u),
    }
    self.actions = { { "copy", _("COPY") }, { "delete", _("DELETE") }, { "edit", _("EDIT") } }
end

function NotePopup:startEditing()
    local u = self.u
    self.editing = true
    self:layoutBox(round(340 * u))
    if self.body then self.body:free() self.body = nil end
    local anno = self:annotation()
    -- InputText draws its padding/border outside width/height, so size the text area for the
    -- whole field to fit the body with even gaps, then centre it by its real size.
    local padding, border = round(14 * u), math.max(1, round(2 * u))
    local frame = 2 * (padding + border)
    local gap = round(28 * u)
    self.input = InputText:new{
        text = anno and anno.note or "",
        face = self.face_body,
        width = self.box.w - 2 * round(56 * u) - frame,
        height = self.body_h - 2 * gap - frame,
        padding = padding,
        margin = 0,
        bordersize = border,
        scroll = true,
        allow_newline = true,
        focused = true,
        parent = self,
    }
    if self.W > self.H then
        -- Landscape: the keyboard (sized from the short side) can reach the box, so shrink the
        -- body until the box clears it. The text area is rebuilt at the new height.
        local over = self.box.y + self.box.h + round(20 * u) - (self.H - self.input:getKeyboardDimen().h)
        if over > 0 then
            self:layoutBox(math.max(round(140 * u), self.body_h - over))
            self.input.height = self.body_h - 2 * gap - frame
            self.input:initTextBox()
        end
    end
    local size = self.input:getSize()
    self.input_x = self.box.x + round((self.box.w - size.w) / 2)
    self.input_y = self.body_y + round((self.body_h - size.h) / 2)
    self[1] = self.input -- so the keyboard's edits reach it
    self.actions = { { "cancel", _("CANCEL") }, { "save", _("SAVE") } }
end

-- Paint ------------------------------------------------------------------------------

function NotePopup:paintTo(bb, x, y)
    local ok, err = pcall(self.paintPopup, self, bb, x, y)
    if not ok then
        logger.err("VoyageNote: paint failed:", err)
        UIManager:nextTick(function() self:close() end)
    end
end

-- Thick-ish line between two points (for the notch).
local function drawLine(bb, x0, y0, x1, y1, t, c)
    local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
    for i = 0, steps do
        local px = round(x0 + (x1 - x0) * i / steps)
        local py = round(y0 + (y1 - y0) * i / steps)
        bb:paintRect(px - math.floor(t / 2), py - math.floor(t / 2), t, t, c)
    end
end

function NotePopup:paintPopup(bb, x, y)
    local u, b = self.u, self.box
    local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local border = math.max(2, round(4 * u))
    local line = math.max(1, round(2 * u))

    bb:paintRect(x + b.x, y + b.y, b.w, b.h, WHITE)
    bb:paintBorder(x + b.x, y + b.y, b.w, b.h, border, BLACK, round(10 * u))

    -- Notch pointing at the end of the highlight.
    if self.notch_up ~= nil and self.notch_x then
        local n, nx = self.notch, x + self.notch_x
        local edge = self.notch_up and (y + b.y) or (y + b.y + b.h - 1)
        local tip = self.notch_up and (edge - n) or (edge + n)
        bb:paintRect(nx - n + border, self.notch_up and edge or (edge - border + 1), 2 * n - 2 * border, border, WHITE)
        for i = 0, n do -- fill
            local yy = self.notch_up and (edge - i) or (edge + i)
            bb:paintRect(nx - (n - i), yy, 2 * (n - i), 1, WHITE)
        end
        drawLine(bb, nx - n, edge, nx, tip, border, BLACK)
        drawLine(bb, nx, tip, nx + n, edge, border, BLACK)
    end

    -- Header: Note  ALL NOTES  ✕
    local hy = y + b.y
    local title = self:text(_("Note"), self.face_title)
    title:paintTo(bb, x + b.x + self.pad, hy + round((self.header_h - title:getSize().h) / 2))
    if not self.editing then
        local all = self:text(_("ALL NOTES"), self.face_link)
        local ax = x + b.x + round(290 * u)
        local ay = hy + round((self.header_h - all:getSize().h) / 2)
        all:paintTo(bb, ax, ay)
        bb:paintRect(ax, ay + all:getSize().h - round(2 * u), all:getSize().w, line, BLACK)
    end
    local s = round(46 * u)
    local close = self.plugin:icon("close", s)
    close:paintTo(bb, x + b.x + b.w - self.pad - s, hy + round((self.header_h - s) / 2))
    close:free()
    bb:paintRect(x + b.x + border, y + self.body_y, b.w - 2 * border, line, Blitbuffer.COLOR_GRAY)

    -- Body
    if self.editing and self.input then
        self.input:paintTo(bb, x + self.input_x, y + self.input_y)
    elseif self.body then
        self.body:paintTo(bb, x + b.x + self.pad, y + self.body_y + round(36 * u))
    end
    local fy = y + self.body_y + self.body_h
    bb:paintRect(x + b.x + border, fy, b.w - 2 * border, line, Blitbuffer.COLOR_GRAY)

    -- Footer actions, right-aligned.
    local right = x + b.x + b.w - self.pad
    self.action_hits = {}
    for i = #self.actions, 1, -1 do
        local a = self.actions[i]
        local t = self:text(a[2], self.face_action)
        local tx = right - t:getSize().w
        t:paintTo(bb, tx, fy + round((self.footer_h - t:getSize().h) / 2))
        self.action_hits[i] = { id = a[1], rect = Geom:new{ x = tx - x - round(30 * u), y = fy - y, w = t:getSize().w + round(60 * u), h = self.footer_h } }
        if self.pressed == a[1] then
            local r = self.action_hits[i].rect
            bb:invertRect(x + r.x, y + r.y + line, r.w, r.h - border - line)
        end
        right = tx - round(110 * u)
    end
end

-- Actions ----------------------------------------------------------------------------

function NotePopup:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.region end)
end

-- Save the note the way KOReader's own editor does.
function NotePopup:saveNote(value)
    local hl, anno = self.highlight, self:annotation()
    if not anno then return end
    local bookmark = self.ui.bookmark
    local type_before = bookmark.getBookmarkType(anno)
    hl:writePdfAnnotation("content", anno, value or "")
    anno.note = (value and value:match("%S")) and value or nil
    local type_after = bookmark.getBookmarkType(anno)
    if type_before ~= type_after then
        if type_before == "highlight" then
            self.ui:handleEvent(Event:new("AnnotationsModified", { anno, nb_highlights_added = -1, nb_notes_added = 1 }))
        else
            self.ui:handleEvent(Event:new("AnnotationsModified", { anno, nb_highlights_added = 1, nb_notes_added = -1 }))
        end
    end
    if hl.view.highlight.note_mark then UIManager:setDirty(hl.dialog, "ui") end
end

function NotePopup:act(id)
    local anno = self:annotation()
    if id == "copy" then
        Device.input.setClipboardText(anno and anno.note or "")
        self:close()
        UIManager:show(InfoMessage:new{ text = _("Copied"), timeout = 1 })
    elseif id == "delete" then
        self:saveNote(nil)
        self:close()
    elseif id == "edit" then
        UIManager:setDirty(nil, function() return "ui", self.region end)
        self:startEditing()
        self:refresh()
        self.input:onShowKeyboard()
    elseif id == "save" then
        self:saveNote(self.input:getText())
        self:close()
    elseif id == "cancel" then
        if self.is_new then
            -- The highlight was only saved to carry this note.
            self.ui.bookmark:removeItemByIndex(self.index)
        end
        self:close()
    end
end

function NotePopup:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.close_hit) then
        if self.editing then return self:act("cancel") end
        return self:close()
    end
    if not self.editing and inside(pos, self.all_hit) then
        self:close()
        self.plugin:showNotebook("note")
        return true
    end
    for __, hit in ipairs(self.action_hits or {}) do
        if inside(pos, hit.rect) then
            self.pressed = hit.id
            self:refresh("fast")
            UIManager:forceRePaint()
            UIManager:scheduleIn(0.12, function()
                self.pressed = nil
                self:act(hit.id)
            end)
            return true
        end
    end
    if self.editing then
        -- Taps in the text field place the cursor; anywhere else does nothing while editing.
        if self.input and inside(pos, self.input.dimen) then
            return self.input:onTapTextBox(nil, ges)
        end
        return true
    end
    if not inside(pos, self.box) then self:close() end
    return true
end

function NotePopup:onSwipe(__, ges)
    if not self.editing and self.body and inside(ges.pos, self.box) then
        if ges.direction == "north" then self.body:scrollDown() self:refresh()
        elseif ges.direction == "south" then self.body:scrollUp() self:refresh() end
    end
    return true
end

function NotePopup:close()
    if self.input then self.input:onCloseKeyboard() end
    UIManager:close(self)
    return true
end

function NotePopup:onClose()
    return self:close()
end

function NotePopup:onEscape()
    if self.editing then return self:act("cancel") end
    return self:close()
end

function NotePopup:onShow()
    self:refresh()
    if self.editing and self.input then self.input:onShowKeyboard() end
    return true
end

function NotePopup:onCloseWidget()
    if self.body then self.body:free() end
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.plugin.note_popup = nil
    UIManager:setDirty(nil, function() return "flashui", self.region end)
    if self.highlight then self.highlight:clear() end
end

return NotePopup
