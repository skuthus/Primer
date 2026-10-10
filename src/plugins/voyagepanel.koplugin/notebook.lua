--[[--
Kindle-style Notebook: the book's highlights, notes and bookmarks in page order, each
labelled with its type and page, the highlighted text in Bookerly and the note under it.
Filters: All / Highlights / Notes / Bookmarks. Tap an entry to go there; long-press it to
edit its note or delete it.
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
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen


local FILTERS = { "all", "highlight", "note", "bookmark" }
local FILTER_LABELS = { all = _("All"), highlight = _("Highlights"), note = _("Notes"), bookmark = _("Bookmarks") }
local TYPE_LABELS = { highlight = _("Highlight"), note = _("Note"), bookmark = _("Bookmark") }

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- Keep rows to a few lines: Kindle's Notebook trims long passages too.
local function clip(text, max_chars)
    text = util.cleanupSelectedText(text or ""):gsub("%s+", " ")
    if #text > max_chars then
        text = text:sub(1, max_chars):gsub("[\128-\191]*$", ""):gsub("%s+%S*$", "") .. "…"
    end
    return text
end

local Notebook = InputContainer:extend{
    plugin = nil,
    filter = "all",
    covers_fullscreen = true,
}

function Notebook:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.u = self.W / 1072
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.cache = {}

    local screen = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Hold = { GestureRange:new{ ges = "hold", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input.group.PgFwd then self.key_events.NextPage = { { Device.input.group.PgFwd } } end
        if Device.input.group.PgBack then self.key_events.PrevPage = { { Device.input.group.PgBack } } end
        if Device.input.group.Back then self.key_events.Close = { { Device.input.group.Back } } end
    end

    self.face_header = Fonts.face("ui_bold", 21)
    self.face_title = Fonts.face("ui", 15)
    self.face_tab = Fonts.face("ui", 17)
    self.face_tab_on = Fonts.face("ui_bold", 17)
    self.face_meta = Fonts.face("ui_bold", 14)
    self.face_text = Fonts.face("serif", 17)
    self.face_note = Fonts.face("ui", 16)
    self.face_small = Fonts.face("ui", 14)

    local u = self.u
    self.pad = round(53 * u)
    self.line = math.max(1, round(2 * u))
    self.header_h = round(110 * u)
    self.tabs_y, self.tab_h = self.header_h, round(96 * u)
    self.list_y = self.tabs_y + self.tab_h + self.line
    self.footer_h = round(76 * u)
    self.list_h = self.H - self.list_y - self.footer_h
    self.text_w = self.W - 2 * self.pad

    self.back_hit = Geom:new{ x = 0, y = 0, w = round(self.W * 0.6), h = self.header_h }
    self:load()
end

-- Entries for the current filter, with their annotation index.
function Notebook:load()
    self:freeRows()
    local bookmark = self.ui.bookmark
    self.entries = {}
    for i, item in ipairs(self.ui.annotation.annotations or {}) do
        local kind = bookmark.getBookmarkType(item)
        if self.filter == "all" or self.filter == kind then
            table.insert(self.entries, { index = i, item = item, kind = kind })
        end
    end
    self.page_starts = { 1 }
    self.page = 1
end

function Notebook:pageLabel(item)
    local pagemap = self.ui.pagemap
    if pagemap and pagemap:wantsPageLabels() and pagemap.getXPointerPageLabel and type(item.page) == "string" then
        local label = pagemap:getXPointerPageLabel(item.page, true)
        if label then return label end
    end
    return tostring(self.ui.bookmark:getBookmarkPageNumber(item))
end

-- Widgets for one entry, laid out on demand.
function Notebook:layoutEntry(e)
    if e.h then return e end
    local u = self.u
    e.meta = TextWidget:new{
        text = string.format(_("%s · Page %s"), TYPE_LABELS[e.kind], self:pageLabel(e.item)),
        face = self.face_meta,
    }
    local h = round(26 * u) + e.meta:getSize().h + round(10 * u)
    local excerpt = e.kind == "bookmark" and (e.item.chapter or "") or e.item.text
    if excerpt and excerpt ~= "" then
        e.text = TextBoxWidget:new{ text = clip(excerpt, 260), face = self.face_text, width = self.text_w }
        h = h + e.text:getSize().h
    end
    if e.item.note and e.item.note:match("%S") then
        e.note = TextBoxWidget:new{ text = clip(e.item.note, 200), face = self.face_note, width = self.text_w - round(28 * u) }
        h = h + round(12 * u) + e.note:getSize().h
    end
    e.h = h + round(26 * u)
    return e
end

function Notebook:pageEnd(first)
    local used, last = 0, first - 1
    for i = first, #self.entries do
        local h = self:layoutEntry(self.entries[i]).h
        if used > 0 and used + h > self.list_h then break end
        used, last = used + h, i
    end
    return last
end

function Notebook:freeRows()
    for __, e in ipairs(self.entries or {}) do
        for __, key in ipairs({ "meta", "text", "note" }) do
            if e[key] then e[key]:free() e[key] = nil end
        end
        e.h = nil
    end
end

function Notebook:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

function Notebook:paintTo(bb, x, y)
    local ok, err = pcall(self.paintNotebook, self, bb, x, y)
    if not ok then
        logger.err("VoyageNotebook: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function Notebook:paintNotebook(bb, x, y)
    local u, W, pad = self.u, self.W, self.pad
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, W, self.H, Blitbuffer.COLOR_WHITE)

    -- Header: "‹  Notebook", book title on the right.
    local header = self:text("‹  " .. _("Notebook"), self.face_header)
    header:paintTo(bb, x + pad, y + round((self.header_h - header:getSize().h) / 2))
    local title = self.ui.doc_props and self.ui.doc_props.display_title or ""
    local tw = self:text(title, self.face_title, round(W * 0.45))
    tw:paintTo(bb, x + W - pad - tw:getSize().w, y + round((self.header_h - tw:getSize().h) / 2))
    bb:paintRect(x, y + self.header_h - self.line, W, self.line, Blitbuffer.COLOR_LIGHT_GRAY)

    -- Filter tabs
    self.tab_hits = {}
    local tx = x + pad
    for __, id in ipairs(FILTERS) do
        local active = id == self.filter
        local label = self:text(FILTER_LABELS[id], active and self.face_tab_on or self.face_tab)
        label:paintTo(bb, tx, y + self.tabs_y + round((self.tab_h - label:getSize().h) / 2))
        local tab_pad = round(14 * u)
        if active then
            bb:paintRect(tx - tab_pad, y + self.list_y - self.line - round(10 * u), label:getSize().w + 2 * tab_pad, round(10 * u), BLACK)
        end
        table.insert(self.tab_hits, { id = id, rect = Geom:new{ x = tx - x - tab_pad, y = self.tabs_y, w = label:getSize().w + 2 * tab_pad, h = self.tab_h } })
        tx = tx + label:getSize().w + round(56 * u)
    end
    bb:paintRect(x, y + self.list_y - self.line, W, self.line, BLACK)

    -- Entries
    self.row_hits = {}
    if #self.entries == 0 then
        local msg = self.filter == "all" and _("No highlights, notes or bookmarks in this book yet.")
            or string.format(_("No %s in this book yet."), FILTER_LABELS[self.filter]:lower())
        local m = self:text(msg, self.face_note, W - 2 * pad)
        m:paintTo(bb, x + round((W - m:getSize().w) / 2), y + self.list_y + round(120 * u))
    end
    local first = self.page_starts[self.page]
    local last = self:pageEnd(first)
    local ry = self.list_y
    for i = first, last do
        local e = self.entries[i]
        local ey = y + ry + round(26 * u)
        e.meta:paintTo(bb, x + pad, ey)
        ey = ey + e.meta:getSize().h + round(10 * u)
        if e.text then
            e.text:paintTo(bb, x + pad, ey)
            ey = ey + e.text:getSize().h
        end
        if e.note then
            ey = ey + round(12 * u)
            -- A bar in the margin sets the note apart from the passage.
            bb:paintRect(x + pad, ey, round(5 * u), e.note:getSize().h, BLACK)
            e.note:paintTo(bb, x + pad + round(28 * u), ey)
        end
        table.insert(self.row_hits, { entry = e, rect = Geom:new{ x = 0, y = ry, w = W, h = e.h } })
        ry = ry + e.h
        bb:paintRect(x + pad, y + ry - self.line, W - 2 * pad, self.line, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    -- Footer: count, and page position when there's more than one page.
    local count = #self.entries
    local more = first > 1 or last < count
    local footer = count == 1 and _("1 item") or string.format(_("%d items"), count)
    if more then footer = footer .. "  ·  " .. string.format(_("Page %d"), self.page) end
    local f = self:text(footer, self.face_small)
    f:paintTo(bb, x + round((W - f:getSize().w) / 2), y + self.H - self.footer_h + round((self.footer_h - f:getSize().h) / 2))
end

function Notebook:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function Notebook:onNextPage()
    local last = self:pageEnd(self.page_starts[self.page])
    if last < #self.entries then
        self.page = self.page + 1
        self.page_starts[self.page] = last + 1
        self:refresh("partial")
    end
    return true
end

function Notebook:onPrevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:refresh("partial")
    end
    return true
end

function Notebook:entryAt(pos)
    for __, hit in ipairs(self.row_hits or {}) do
        if inside(pos, hit.rect) then return hit.entry end
    end
end

function Notebook:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.back_hit) then return self:onClose() end
    for __, tab in ipairs(self.tab_hits or {}) do
        if inside(pos, tab.rect) then
            if tab.id ~= self.filter then
                self.filter = tab.id
                self:load()
                self:refresh("partial")
            end
            return true
        end
    end
    local e = self:entryAt(pos)
    if e then
        self:onClose()
        self.ui.link:addCurrentLocationToStack()
        self.ui.bookmark:gotoBookmark(e.item.page, e.item.pos0)
    end
    return true
end

-- Long-press: edit the note / delete, in the Kindle-style dialog.
function Notebook:onHold(__, ges)
    local e = self:entryAt(ges.pos)
    if not e then return true end
    local Dialog = require("dialog")
    local buttons = { { text = _("Cancel") } }
    if e.kind ~= "bookmark" then
        table.insert(buttons, { text = e.kind == "note" and _("Edit Note") or _("Add Note"), callback = function()
            self:onClose()
            self.plugin:showNote{ highlight = self.ui.highlight, index = e.index, editing = true }
        end })
    end
    table.insert(buttons, { text = _("Delete"), bold = true, callback = function()
        if e.kind == "bookmark" then
            self.ui.bookmark:removeItemByIndex(e.index)
            self.ui.view.dogear:onSetDogearVisibility(self.ui.bookmark:isPageBookmarked())
        else
            self.ui.highlight:deleteHighlight(e.index)
        end
        self:load()
        self:refresh("partial")
    end })
    UIManager:show(Dialog:new{
        title = TYPE_LABELS[e.kind],
        text = clip(e.kind == "bookmark" and (e.item.chapter or "") or (e.item.text or ""), 160),
        buttons = buttons,
    })
    return true
end

function Notebook:onSwipe(__, ges)
    if ges.direction == "west" or ges.direction == "north" then return self:onNextPage() end
    if ges.direction == "east" or ges.direction == "south" then return self:onPrevPage() end
    return true
end

function Notebook:onShow()
    self:refresh("ui")
    return true
end

function Notebook:onClose()
    UIManager:close(self)
    return true
end

function Notebook:onCloseWidget()
    self:freeRows()
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.plugin.notebook = nil
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return Notebook
