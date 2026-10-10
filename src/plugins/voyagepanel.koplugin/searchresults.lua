--[[--
Kindle-style in-book search results: "Results for “word”" with the count, then one row per
match (chapter and page above the passage, the match in bold). Tap a row to go there; a bar
at the bottom of the page then steps to the previous / next match or back to the list.

    SearchResults:new{ plugin = plugin, index = first_item_to_show }
    SearchNav:new{ plugin = plugin, index = i }
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

-- The passage around a match, the match (whole word) in bold.
local function passage(item)
    local t = { TextBoxWidget.PTF_HEADER }
    if item.prev_text then
        table.insert(t, item.prev_text)
        if not item.prev_text:find("%s$") then table.insert(t, " ") end
    end
    table.insert(t, TextBoxWidget.PTF_BOLD_START)
    table.insert(t, item.matched_word_prefix or "")
    table.insert(t, item.matched_text or "")
    table.insert(t, item.matched_word_suffix or "")
    table.insert(t, TextBoxWidget.PTF_BOLD_END)
    if item.next_text then
        if not item.next_text:find("^[%s%p]") then table.insert(t, " ") end
        table.insert(t, item.next_text)
    end
    return table.concat(t)
end

local function closeKeys(widget, groups)
    if not Device:hasKeys() then return end
    widget.key_events = widget.key_events or {}
    for name, group in pairs(groups) do
        if Device.input.group[group] then widget.key_events[name] = { { Device.input.group[group] } } end
    end
end

-- Results list -------------------------------------------------------------------------

local SearchResults = InputContainer:extend{
    plugin = nil,
    index = nil,
    covers_fullscreen = true,
}

function SearchResults:init()
    self.ui = self.plugin.ui
    self.search = self.ui.search
    self.items = self.search.findall_results or {}
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    local u = self.W / 1072
    self.u = u
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    closeKeys(self, { NextPage = "PgFwd", PrevPage = "PgBack", Close = "Back" })
    self.widgets = {}

    self.pad = round(53 * u)
    self.line = math.max(1, round(2 * u))
    self.header_h = round(110 * u)
    self.sub_h = round(64 * u)
    self.list_y = self.header_h + self.sub_h
    self.footer_h = round(80 * u)
    self.face_header = Fonts.face("ui_bold", 21)
    self.face_action = Fonts.face("ui", 18)
    self.face_meta = Fonts.face("ui", 14)
    self.face_meta_bold = Fonts.face("ui_bold", 14)
    self.face_passage = Fonts.face("ui", 17)
    self.passage_lines = 3
    local probe = TextWidget:new{ text = "Ag", face = self.face_passage }
    self.passage_line_h = probe:getSize().h
    probe:free()
    self.row_h = round(42 * u) + self.passage_line_h * self.passage_lines + round(40 * u)
    self.per_page = math.max(1, math.floor((self.H - self.list_y - self.footer_h) / self.row_h))
    self.pages = math.max(1, math.ceil(#self.items / self.per_page))
    self.page = math.min(self.pages, math.ceil((self.index or 1) / self.per_page))
    self.back_hit = Geom:new{ x = 0, y = 0, w = round(self.W * 0.7), h = self.header_h }
    self.search_hit = Geom:new{ x = round(self.W * 0.7), y = 0, w = round(self.W * 0.3), h = self.header_h }
end

function SearchResults:keep(w)
    table.insert(self.widgets, w)
    return w
end

function SearchResults:freeWidgets()
    for __, w in ipairs(self.widgets) do w:free() end
    self.widgets = {}
end

function SearchResults:pageOf(item)
    local doc = self.ui.document
    local pageno = self.ui.rolling and doc:getPageFromXPointer(item.start) or item.start
    return self.ui.annotation:getPageRef(item.start, pageno) or pageno
end

function SearchResults:paintTo(bb, x, y)
    local ok, err = pcall(self.paintResults, self, bb, x, y)
    if not ok then
        logger.err("VoyageSearchResults: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

function SearchResults:paintResults(bb, x, y)
    self:freeWidgets()
    local u, W, pad = self.u, self.W, self.pad
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, W, self.H, Blitbuffer.COLOR_WHITE)

    -- Header: ‹ Results for “word”          Search
    local search = self:keep(TextWidget:new{ text = _("Search"), face = self.face_action })
    local sw = search:getSize()
    search:paintTo(bb, x + W - pad - sw.w, y + round((self.header_h - sw.h) / 2))
    local title = self:keep(TextWidget:new{
        text = "‹  " .. string.format(_("Results for “%s”"), self.search.last_search_text or ""),
        face = self.face_header, max_width = W - 3 * pad - sw.w,
    })
    title:paintTo(bb, x + pad, y + round((self.header_h - title:getSize().h) / 2))
    bb:paintRect(x, y + self.header_h - self.line, W, self.line, BLACK)
    local n = #self.items
    local count = self:keep(TextWidget:new{
        text = n == 1 and _("1 result in this book") or string.format(_("%d results in this book"), n),
        face = self.face_meta,
    })
    count:paintTo(bb, x + pad, y + self.header_h + round((self.sub_h - count:getSize().h) / 2))

    -- Rows
    local first = (self.page - 1) * self.per_page + 1
    local text_w = W - 2 * pad
    for i = first, math.min(n, first + self.per_page - 1) do
        local item = self.items[i]
        local ry = y + self.list_y + (i - first) * self.row_h
        bb:paintRect(x + pad, ry, text_w, self.line, Blitbuffer.COLOR_LIGHT_GRAY)
        local page = self:keep(TextWidget:new{ text = string.format(_("Page %s"), tostring(self:pageOf(item))), face = self.face_meta })
        local pw = page:getSize().w
        local chapter = self.ui.toc:getTocTitleByPage(item.start)
        local my = ry + round(22 * u)
        if chapter and chapter ~= "" then
            local ch = self:keep(TextWidget:new{ text = chapter, face = self.face_meta_bold, max_width = text_w - pw - pad })
            ch:paintTo(bb, x + pad, my)
        end
        page:paintTo(bb, x + W - pad - pw, my)
        local body = self:keep(TextBoxWidget:new{
            text = passage(item),
            face = self.face_passage,
            width = text_w,
            height = self.passage_line_h * self.passage_lines,
            height_overflow_show_ellipsis = true,
        })
        body:paintTo(bb, x + pad, my + page:getSize().h + round(10 * u))
    end

    -- Footer
    if self.pages > 1 then
        local pg = self:keep(TextWidget:new{ text = string.format(_("Page %d of %d"), self.page, self.pages), face = self.face_meta })
        pg:paintTo(bb, x + W - pad - pg:getSize().w, y + self.H - round((self.footer_h + pg:getSize().h) / 2))
    end
end

function SearchResults:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function SearchResults:goToPage(p)
    p = math.max(1, math.min(self.pages, p))
    if p ~= self.page then
        self.page = p
        self:refresh("partial")
    end
    return true
end

function SearchResults:onNextPage() return self:goToPage(self.page + 1) end
function SearchResults:onPrevPage() return self:goToPage(self.page - 1) end

function SearchResults:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.back_hit) then return self:onClose() end
    if inside(pos, self.search_hit) then
        self:onClose()
        self.plugin:showBookSearch(self.search.last_search_text)
        return true
    end
    if pos.y >= self.list_y then
        local row = math.floor((pos.y - self.list_y) / self.row_h)
        local i = (self.page - 1) * self.per_page + row + 1
        if row < self.per_page and self.items[i] then
            self:onClose()
            self.plugin:gotoSearchResult(i)
        end
    end
    return true
end

function SearchResults:onSwipe(__, ges)
    if ges.direction == "west" or ges.direction == "north" then return self:onNextPage() end
    if ges.direction == "east" or ges.direction == "south" then return self:onPrevPage() end
    return true
end

function SearchResults:onShow()
    self:refresh("flashui")
    return true
end

function SearchResults:onClose()
    UIManager:close(self)
    return true
end

function SearchResults:onCloseWidget()
    self:freeWidgets()
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

-- Navigation bar shown on the page after jumping to a match ------------------------------

local SearchNav = InputContainer:extend{
    plugin = nil,
    index = 1,
}

function SearchNav:init()
    self.ui = self.plugin.ui
    self.total = #(self.ui.search.findall_results or {})
    local W, H = Screen:getWidth(), Screen:getHeight()
    local u = W / 1072
    self.u = u
    self.line = math.max(1, round(2 * u))
    local h = round(112 * u)
    self.bar = Geom:new{ x = 0, y = H - h, w = W, h = h }
    self.dimen = self.bar
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = W, h = H } } } }
    closeKeys(self, { Close = "Back", Next = "PgFwd", Prev = "PgBack" })
    local third = round(W / 3)
    self.prev_hit = Geom:new{ x = 0, y = self.bar.y, w = third, h = h }
    self.list_hit = Geom:new{ x = third, y = self.bar.y, w = W - 2 * third, h = h }
    self.next_hit = Geom:new{ x = W - third, y = self.bar.y, w = third, h = h }
    local face, bold = Fonts.face("ui", 18), Fonts.face("ui_bold", 18)
    self.labels = {
        prev = TextWidget:new{ text = "‹  " .. _("Previous"), face = face,
            fgcolor = self.index > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY },
        list = TextWidget:new{ text = string.format(_("%d of %d"), self.index, self.total), face = bold },
        hint = TextWidget:new{ text = _("Back to results"), face = Fonts.face("ui", 13) },
        next = TextWidget:new{ text = _("Next") .. "  ›", face = face,
            fgcolor = self.index < self.total and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY },
    }
end

function SearchNav:paintTo(bb)
    local ok, err = pcall(self.paintBar, self, bb)
    if not ok then
        logger.err("VoyageSearchNav: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

function SearchNav:paintBar(bb)
    local b, u = self.bar, self.u
    bb:paintRect(b.x, b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(b.x, b.y, b.w, self.line, Blitbuffer.COLOR_BLACK)
    local function center(w, r, dy)
        local s = w:getSize()
        w:paintTo(bb, r.x + round((r.w - s.w) / 2), r.y + round((r.h - s.h) / 2) + (dy or 0))
    end
    center(self.labels.prev, self.prev_hit)
    center(self.labels.next, self.next_hit)
    local lh, hh = self.labels.list:getSize().h, self.labels.hint:getSize().h
    center(self.labels.list, self.list_hit, -round(hh / 2))
    center(self.labels.hint, self.list_hit, round(lh / 2))
    bb:paintRect(self.list_hit.x, b.y + round(24 * u), self.line, b.h - round(48 * u), Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(self.next_hit.x, b.y + round(24 * u), self.line, b.h - round(48 * u), Blitbuffer.COLOR_LIGHT_GRAY)
end

function SearchNav:step(delta)
    local i = self.index + delta
    if i < 1 or i > self.total then return true end
    UIManager:close(self)
    self.plugin:gotoSearchResult(i)
    return true
end

function SearchNav:onNext() return self:step(1) end
function SearchNav:onPrev() return self:step(-1) end

function SearchNav:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.prev_hit) then return self:step(-1) end
    if inside(pos, self.next_hit) then return self:step(1) end
    if inside(pos, self.list_hit) then
        self:onClose()
        self.plugin:showSearchResults(self.index)
        return true
    end
    -- Anywhere on the page: done searching, keep reading here.
    return self:onClose()
end

function SearchNav:onClose()
    UIManager:close(self)
    self.ui.search:restorePageView()
    return true
end

function SearchNav:onShow()
    UIManager:setDirty(self, function() return "ui", self.bar end)
    return true
end

function SearchNav:onCloseWidget()
    for __, w in pairs(self.labels) do w:free() end
    UIManager:setDirty(nil, function() return "ui", self.bar end)
end

return { Results = SearchResults, Nav = SearchNav }
