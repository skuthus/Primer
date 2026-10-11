--[[--
Book map, Kindle-style: the whole book at a glance. Under the header, one bar for the book
(chapter breaks as ticks, your place as a marker, the read part filled); then the chapters,
each with its page and a bar of its own: filled as far as you've read, with small marks
under it where your highlights, notes and bookmarks are. Tap a chapter to go there.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local BookMap = InputContainer:extend{
    plugin = nil,
    covers_fullscreen = true,
}

function BookMap:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    -- Sizes scale from the shorter side, so landscape keeps portrait proportions.
    local u = math.min(self.W, self.H) / 1072
    self.u = u
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input.group.PgFwd then self.key_events.NextPage = { { Device.input.group.PgFwd } } end
        if Device.input.group.PgBack then self.key_events.PrevPage = { { Device.input.group.PgBack } } end
        if Device.input.group.Back then self.key_events.Close = { { Device.input.group.Back } } end
    end
    self.cache = {}
    self.pages = self.ui.document:getPageCount()
    self.current = self.ui:getCurrentPage()
    self:gather()

    self.face_header = Fonts.face("ui_bold", 21)
    self.face_info = Fonts.face("ui", 16)
    self.face_row = Fonts.face("ui", 18)
    self.face_row_on = Fonts.face("ui_bold", 18)
    self.face_page = Fonts.face("ui", 15)
    self.face_small = Fonts.face("ui", 14)

    self.pad = round(53 * u)
    self.line = math.max(1, round(2 * u))
    self.header_h = round(110 * u)
    self.overview_h = round(150 * u)
    self.list_y = self.header_h + self.overview_h
    self.row_h = round(118 * u)
    self.footer_h = round(80 * u)
    self.per_page = math.max(1, math.floor((self.H - self.list_y - self.footer_h) / self.row_h))
    self.pages_list = math.max(1, math.ceil(#self.chapters / self.per_page))
    self.page = self.current_chapter and math.ceil(self.current_chapter / self.per_page) or 1
    self.back_hit = Geom:new{ x = 0, y = 0, w = round(self.W * 0.65), h = self.header_h }
end

-- Top-level chapters with their page spans, and the pages that carry annotations.
function BookMap:gather()
    self.ui.toc:fillToc()
    local toc = self.ui.toc.toc or {}
    local min_depth = math.huge
    for __, item in ipairs(toc) do
        if item.page then min_depth = math.min(min_depth, item.depth or 1) end
    end
    self.chapters = {}
    for __, item in ipairs(toc) do
        if item.page and (item.depth or 1) == min_depth then
            table.insert(self.chapters, { title = item.title, first = item.page })
        end
    end
    if #self.chapters == 0 or self.chapters[1].first > 1 then
        table.insert(self.chapters, 1, { title = _("Beginning"), first = 1 })
    end
    for i, c in ipairs(self.chapters) do
        local next_c = self.chapters[i + 1]
        c.last = math.max(c.first, (next_c and next_c.first - 1) or self.pages)
        if self.current >= c.first and self.current <= c.last then self.current_chapter = i end
    end
    -- Annotation pages: highlights / notes, and bookmarks.
    self.marks = {}
    for __, a in ipairs(self.ui.annotation and self.ui.annotation.annotations or {}) do
        local p = a.pageno or (self.ui.rolling and a.page and self.ui.document:getPageFromXPointer(a.page)) or a.page
        if type(p) == "number" then
            table.insert(self.marks, { page = p, bookmark = not a.drawer })
        end
    end
end

function BookMap:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

function BookMap:paintTo(bb, x, y)
    local ok, err = pcall(self.paintMap, self, bb, x, y)
    if not ok then
        logger.err("VoyageBookMap: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

-- A bar for pages first..last: outline, filled up to the current page, annotation marks under it.
function BookMap:paintBar(bb, bx, by, bw, bh, first, last, ticks)
    local BLACK = Blitbuffer.COLOR_BLACK
    local span = math.max(1, last - first + 1)
    local function px(p) return bx + round(bw * (p - first) / span) end
    if self.current > last then
        bb:paintRect(bx, by, bw, bh, BLACK)
    elseif self.current >= first then
        bb:paintRect(bx, by, math.max(self.line, px(self.current + 1) - bx), bh, BLACK)
    end
    bb:paintBorder(bx, by, bw, bh, self.line, BLACK)
    for __, t in ipairs(ticks or {}) do
        local tx = px(t)
        bb:paintRect(tx, by, self.line, bh, Blitbuffer.COLOR_WHITE)
    end
    local mh = round(12 * self.u)
    for __, m in ipairs(self.marks) do
        if m.page >= first and m.page <= last then
            local mx = px(m.page)
            if m.bookmark then
                bb:paintRect(mx, by + bh + round(4 * self.u), self.line * 2, mh, BLACK)
            else
                bb:paintRect(mx, by + bh + round(4 * self.u) + round(mh / 3), self.line * 2, mh - round(mh / 3), Blitbuffer.COLOR_DARK_GRAY)
            end
        end
    end
end

function BookMap:paintMap(bb, x, y)
    local u, W, pad = self.u, self.W, self.pad
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, W, self.H, Blitbuffer.COLOR_WHITE)

    -- Header: ‹ Book Map                 42% read
    local footer = self.ui.view and self.ui.view.footer
    local pct = math.floor(((footer and footer.percent_finished) or (self.current / math.max(1, self.pages))) * 100)
    local info = self:text(string.format(_("%d%% read"), pct), self.face_info)
    info:paintTo(bb, x + W - pad - info:getSize().w, y + round((self.header_h - info:getSize().h) / 2))
    local t = self:text("‹  " .. _("Book Map"), self.face_header)
    t:paintTo(bb, x + pad, y + round((self.header_h - t:getSize().h) / 2))
    bb:paintRect(x, y + self.header_h - self.line, W, self.line, BLACK)

    -- Whole book: chapter breaks as gaps, your place as a marker above.
    local ticks = {}
    for i = 2, #self.chapters do table.insert(ticks, self.chapters[i].first) end
    local bar_y = y + self.header_h + round(56 * u)
    local bar_h = round(22 * u)
    local bw = W - 2 * pad
    self:paintBar(bb, x + pad, bar_y, bw, bar_h, 1, self.pages, ticks)
    local cx = x + pad + round(bw * (self.current - 1) / math.max(1, self.pages))
    local k = round(14 * u)
    for i = 0, k - 1 do -- small triangle pointing at the bar
        local half = round((k - i) * 0.8)
        bb:paintRect(cx - half, bar_y - round(8 * u) - k + i, 2 * half + 1, 1, BLACK)
    end
    local legend = self:text(string.format(_("Page %d of %d"), self.current, self.pages), self.face_small)
    legend:paintTo(bb, x + pad, bar_y + bar_h + round(26 * u))
    bb:paintRect(x, y + self.list_y - self.line, W, self.line, Blitbuffer.COLOR_LIGHT_GRAY)

    -- Chapters
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.chapters, first + self.per_page - 1) do
        local c = self.chapters[i]
        local ry = y + self.list_y + (i - first) * self.row_h
        local on = i == self.current_chapter
        local page = self:text(tostring(c.first), self.face_page)
        local pw = page:getSize().w
        local name = self:text(c.title or "", on and self.face_row_on or self.face_row, W - 3 * pad - pw)
        local ty = ry + round(20 * u)
        name:paintTo(bb, x + pad, ty)
        page:paintTo(bb, x + W - pad - pw, ty + round((name:getSize().h - page:getSize().h) / 2))
        self:paintBar(bb, x + pad, ty + name:getSize().h + round(12 * u), bw, round(12 * u), c.first, c.last)
        bb:paintRect(x + pad, ry + self.row_h - self.line, bw, self.line, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    if self.pages_list > 1 then
        local pg = self:text(string.format(_("Page %d of %d"), self.page, self.pages_list), self.face_small)
        pg:paintTo(bb, x + W - pad - pg:getSize().w, y + self.H - round((self.footer_h + pg:getSize().h) / 2))
    end
end

function BookMap:goToPage(p)
    p = math.max(1, math.min(self.pages_list, p))
    if p ~= self.page then
        self.page = p
        UIManager:setDirty(self, function() return "partial", self.dimen end)
    end
    return true
end

function BookMap:onNextPage() return self:goToPage(self.page + 1) end
function BookMap:onPrevPage() return self:goToPage(self.page - 1) end

function BookMap:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.back_hit) then return self:onClose() end
    if pos.y >= self.list_y then
        local row = math.floor((pos.y - self.list_y) / self.row_h)
        local c = row < self.per_page and self.chapters[(self.page - 1) * self.per_page + row + 1]
        if c then
            self:onClose()
            self.ui.link:addCurrentLocationToStack()
            self.ui:handleEvent(Event:new("GotoPage", c.first))
        end
    end
    return true
end

function BookMap:onSwipe(__, ges)
    if ges.direction == "west" or ges.direction == "north" then return self:onNextPage() end
    if ges.direction == "east" or ges.direction == "south" then return self:onPrevPage() end
    return true
end

-- Paint the whole screen on opening: otherwise only the parts that change later (e.g. thumbnails
-- arriving) would be refreshed, leaving the book page showing around them.
function BookMap:onShow()
    UIManager:setDirty(self, function() return "flashui", self.dimen end)
    return true
end

function BookMap:onClose()
    UIManager:close(self)
    return true
end

function BookMap:onCloseWidget()
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.plugin.bookmap = nil
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return BookMap
