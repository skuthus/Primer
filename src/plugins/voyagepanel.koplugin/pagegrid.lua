--[[--
Kindle-style page grid (the toolbar's and page flip's grid button): the book's pages as
thumbnails, three by three, with page numbers under them and the page you're reading
outlined. The chapter of the first page shows above the grid; a track at the bottom shows
where you are in the book (tap it to jump). Swipe or use the page buttons for the next
or previous nine; tap a page to go there.
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

local COLS, ROWS = 3, 3

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local PageGrid = InputContainer:extend{
    plugin = nil,
    covers_fullscreen = true,
}

function PageGrid:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    local u = self.W / 1072
    self.u = u
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input.group.PgFwd then self.key_events.NextScreen = { { Device.input.group.PgFwd } } end
        if Device.input.group.PgBack then self.key_events.PrevScreen = { { Device.input.group.PgBack } } end
        if Device.input.group.Back then self.key_events.Close = { { Device.input.group.Back } } end
    end
    self.cache = {}
    self.tiles = {}
    self.pages = self.ui.document:getPageCount()
    self.current = self.ui:getCurrentPage()
    self.per_screen = COLS * ROWS
    self.first = math.floor((self.current - 1) / self.per_screen) * self.per_screen + 1

    self.face_header = Fonts.face("ui_bold", 21)
    self.face_info = Fonts.face("ui", 16)
    self.face_chapter = Fonts.face("ui_bold", 16)
    self.face_num = Fonts.face("ui", 14)
    self.face_num_on = Fonts.face("ui_bold", 14)

    self.pad = round(53 * u)
    self.line = math.max(1, round(2 * u))
    self.thick = math.max(3, round(5 * u))
    self.header_h = round(110 * u)
    self.chapter_h = round(76 * u)
    self.footer_h = round(130 * u)
    -- Cells: thumbnail (page proportions) with its number underneath.
    local grid_y = self.header_h + self.chapter_h
    local grid_h = self.H - grid_y - self.footer_h
    self.num_h = round(52 * u)
    self.gap_x = round(44 * u)
    local cell_w = (self.W - 2 * self.pad - (COLS - 1) * self.gap_x) / COLS
    local cell_h = grid_h / ROWS
    self.thumb_h = math.floor(math.min(cell_h - self.num_h - round(24 * u), cell_w * self.H / self.W))
    self.thumb_w = math.floor(self.thumb_h * self.W / self.H)
    self.cell_w, self.cell_h, self.grid_y = cell_w, cell_h, grid_y
    self.back_hit = Geom:new{ x = 0, y = 0, w = round(self.W * 0.65), h = self.header_h }
    self.track_x0, self.track_x1 = self.pad, self.W - self.pad
    self.track_cy = self.H - round(self.footer_h / 2)
    self.track_hit = Geom:new{ x = 0, y = self.H - self.footer_h, w = self.W, h = self.footer_h }
    self.batch = nil
    self:requestThumbnails()
end

function PageGrid:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

function PageGrid:cellRect(i)
    local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
    local cx = self.pad + col * (self.cell_w + self.gap_x)
    local cy = self.grid_y + row * self.cell_h
    return Geom:new{ x = round(cx + (self.cell_w - self.thumb_w) / 2), y = round(cy + round(12 * self.u)),
        w = self.thumb_w, h = self.thumb_h }
end

function PageGrid:requestThumbnails()
    local thumbnail = self.ui.thumbnail
    if not thumbnail then return end
    if self.batch then thumbnail:cancelPageThumbnailRequests(self.batch) end
    self.batch = "VoyagePageGrid" .. tostring(os.time()) .. "-" .. self.first
    local batch = self.batch
    for p = self.first, math.min(self.pages, self.first + self.per_screen - 1) do
        if not self.tiles[p] then
            thumbnail:getPageThumbnail(p, self.thumb_w, self.thumb_h, batch, function(tile, batch_id, async)
                if not tile or batch_id ~= self.batch or self.closed then return end
                self.tiles[p] = tile.bb
                if async then
                    local r = self:cellRect(p - self.first + 1)
                    UIManager:setDirty(self, function() return "ui", r end)
                end
            end)
        end
    end
end

function PageGrid:paintTo(bb, x, y)
    local ok, err = pcall(self.paintGrid, self, bb, x, y)
    if not ok then
        logger.err("VoyagePageGrid: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

function PageGrid:paintGrid(bb, x, y)
    local u, W, pad = self.u, self.W, self.pad
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, W, self.H, Blitbuffer.COLOR_WHITE)

    -- Header: ‹ Title                 Page 12 of 300
    local info = self:text(string.format(_("Page %d of %d"), self.current, self.pages), self.face_info)
    info:paintTo(bb, x + W - pad - info:getSize().w, y + round((self.header_h - info:getSize().h) / 2))
    local title = (self.ui.doc_props and self.ui.doc_props.display_title) or ""
    local t = self:text("‹  " .. title, self.face_header, W - 3 * pad - info:getSize().w)
    t:paintTo(bb, x + pad, y + round((self.header_h - t:getSize().h) / 2))
    bb:paintRect(x, y + self.header_h - self.line, W, self.line, BLACK)

    -- Chapter of the first page on screen.
    local chapter = self.ui.toc:getTocTitleByPage(self.first)
    if chapter and chapter ~= "" then
        local c = self:text(chapter, self.face_chapter, W - 2 * pad)
        c:paintTo(bb, x + pad, y + self.header_h + round((self.chapter_h - c:getSize().h) / 2))
    end

    for i = 1, self.per_screen do
        local p = self.first + i - 1
        if p > self.pages then break end
        local r = self:cellRect(i)
        local tile = self.tiles[p]
        if tile then
            bb:blitFrom(tile, x + r.x + round((r.w - tile.w) / 2), y + r.y + round((r.h - tile.h) / 2), 0, 0, tile.w, tile.h)
        end
        local on = p == self.current
        bb:paintBorder(x + r.x, y + r.y, r.w, r.h, on and self.thick or self.line, on and BLACK or Blitbuffer.COLOR_GRAY)
        local n = self:text(tostring(p), on and self.face_num_on or self.face_num)
        n:paintTo(bb, x + r.x + round((r.w - n:getSize().w) / 2), y + r.y + r.h + round((self.num_h - n:getSize().h) / 2))
    end

    -- Track: the whole book, the nine pages on screen as a bar, your page as a knob.
    local x0, x1, cy = self.track_x0, self.track_x1, y + self.track_cy
    bb:paintRect(x + x0, cy - self.line, x1 - x0, 2 * self.line, Blitbuffer.COLOR_GRAY)
    local function px(p) return x0 + round((x1 - x0) * (p - 1) / math.max(1, self.pages - 1)) end
    local last = math.min(self.pages, self.first + self.per_screen - 1)
    local bar_h = round(14 * u)
    bb:paintRect(x + px(self.first), cy - round(bar_h / 2), math.max(self.thick, px(last) - px(self.first)), bar_h, BLACK)
    local k = round(14 * u)
    bb:paintRect(x + px(self.current) - round(self.line / 2), cy - k - round(bar_h / 2), self.line * 2, k, BLACK)
end

function PageGrid:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function PageGrid:showFirst(first)
    first = math.max(1, math.min(first, math.floor((self.pages - 1) / self.per_screen) * self.per_screen + 1))
    if first == self.first then return true end
    self.first = first
    self:requestThumbnails()
    self:refresh("partial")
    return true
end

function PageGrid:onNextScreen() return self:showFirst(self.first + self.per_screen) end
function PageGrid:onPrevScreen() return self:showFirst(self.first - self.per_screen) end

function PageGrid:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.back_hit) then return self:onClose() end
    if inside(pos, self.track_hit) then
        local frac = math.max(0, math.min(1, (pos.x - self.track_x0) / (self.track_x1 - self.track_x0)))
        local p = 1 + round(frac * (self.pages - 1))
        return self:showFirst(math.floor((p - 1) / self.per_screen) * self.per_screen + 1)
    end
    for i = 1, self.per_screen do
        local p = self.first + i - 1
        local r = self:cellRect(i)
        if p <= self.pages and inside(pos, Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h + self.num_h }) then
            self:onClose()
            if p ~= self.current then
                self.ui.link:addCurrentLocationToStack()
                self.ui:handleEvent(Event:new("GotoPage", p))
            end
            return true
        end
    end
    return true
end

function PageGrid:onSwipe(__, ges)
    if ges.direction == "west" or ges.direction == "north" then return self:onNextScreen() end
    if ges.direction == "east" or ges.direction == "south" then return self:onPrevScreen() end
    return true
end

-- Paint the whole screen on opening: otherwise only the parts that change later (e.g. thumbnails
-- arriving) would be refreshed, leaving the book page showing around them.
function PageGrid:onShow()
    UIManager:setDirty(self, function() return "flashui", self.dimen end)
    return true
end

function PageGrid:onClose()
    UIManager:close(self)
    return true
end

function PageGrid:onCloseWidget()
    self.closed = true
    if self.ui.thumbnail and self.batch then self.ui.thumbnail:cancelPageThumbnailRequests(self.batch) end
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.tiles = {} -- owned by the thumbnail cache
    self.plugin.pagegrid = nil
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return PageGrid
