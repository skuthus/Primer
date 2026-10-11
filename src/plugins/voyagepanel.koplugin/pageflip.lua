--[[--
Kindle-style page flip (swipe up from the bottom while reading): the current page as a
large thumbnail with its neighbours peeking in from the sides, a scrubber to move through
the book, chapter jumps, and "Back to page N". Nothing moves in the book until you tap a
page. Proportions follow a photo of a Kindle's page flip (1282px-wide screen).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dropdown = require("dropdown")
local Event = require("ui/event")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen


local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local PageFlip = InputContainer:extend{
    plugin = nil,
    covers_fullscreen = true,
}

function PageFlip:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.P = self.W / 1282
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.cache = {}
    self.tiles = {}
    self.batch = "VoyagePageFlip" .. tostring(os.time())

    self.pages = self.ui.document:getPageCount()
    self.orig = self.ui:getCurrentPage()
    self.page = self.orig

    local screen = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Pan = { GestureRange:new{ ges = "pan", range = screen } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input.group.PgFwd then self.key_events.NextPage = { { Device.input.group.PgFwd } } end
        if Device.input.group.PgBack then self.key_events.PrevPage = { { Device.input.group.PgBack } } end
        if Device.input.group.Back then self.key_events.Close = { { Device.input.group.Back } } end
    end

    self.face_status = Fonts.face("ui", 16)
    self.face_library = Fonts.face("ui", 21)
    self.face_aa = Fonts.face("ui", 21)
    self.face_title = Fonts.face("ui_bold", 19)
    self.face_button = Fonts.face("ui", 17)
    self.face_chapter = Fonts.face("ui", 19)
    self.face_label = Fonts.face("ui", 15)

    self:layout()
    self:requestThumbnails()
end

function PageFlip:layout()
    local P, W = self.P, self.W
    self.line = math.max(1, round(2 * P))
    self.thick = math.max(2, round(4 * P))

    -- Taller screens than the photo's (e.g. the reMarkable): the page thumbnails take the extra
    -- height and everything from "Back to page" down moves to the bottom. Zero on the Voyage.
    local ex = math.max(0, self.H - round(1732 * P))
    self.extra = ex

    -- Thumbnails keep the page's proportions; the centre one is ~790x1045 on the photo.
    self.thumb_h = round(1045 * P) + ex
    self.thumb_w = round(self.thumb_h * W / self.H)
    self.gap = round(47 * P)
    self.thumb_y = round(405 * P)
    self.center_x = round((W - self.thumb_w) / 2)
    self.carousel = Geom:new{ x = 0, y = round(370 * P), w = W, h = round(1112 * P) + ex }

    -- Toolbar icons (centres on the photo, minus its 88px left bezel)
    self.tool_cy = round(180 * P)
    self.tools = {}
    for i, t in ipairs({ { "aa", 693 }, { "contents", 798 }, { "pageflip", 902 }, { "bookmark", 1009 }, { "search", 1114 }, { "kebab", 1222 } }) do
        self.tools[i] = { id = t[1], cx = round(t[2] * P),
            hit = Geom:new{ x = round((t[2] - 52) * P), y = round(120 * P), w = round(104 * P), h = round(120 * P) } }
    end
    self.library_hit = Geom:new{ x = 0, y = round(120 * P), w = round(360 * P), h = round(120 * P) }
    self.chevron_hit = Geom:new{ x = round(W * 0.35), y = 0, w = round(W * 0.3), h = round(115 * P) }

    -- Bottom
    self.back_btn = Geom:new{ x = round(67 * P), y = round(1360 * P) + ex, w = round(292 * P), h = round(82 * P) }
    self.chapter_cy = round(1540 * P) + ex
    self.prev_hit = Geom:new{ x = 0, y = round(1490 * P) + ex, w = round(190 * P), h = round(95 * P) }
    self.next_hit = Geom:new{ x = W - round(190 * P), y = round(1490 * P) + ex, w = round(190 * P), h = round(95 * P) }
    self.grid_hit = Geom:new{ x = 0, y = round(1590 * P) + ex, w = round(160 * P), h = round(100 * P) }
    self.track_x0, self.track_x1 = round(182 * P), round(1097 * P)
    self.track_cy = round(1640 * P) + ex
    self.knob_r = round(30 * P)
    self.track_hit = Geom:new{ x = self.track_x0 - self.knob_r * 2, y = self.track_cy - round(70 * P),
        w = self.track_x1 - self.track_x0 + self.knob_r * 4, h = round(130 * P) }
    self.bottom_area = Geom:new{ x = 0, y = round(1488 * P) + ex, w = W, h = self.H - round(1488 * P) - ex }
end

-- Thumbnails -----------------------------------------------------------------------

function PageFlip:requestThumbnails()
    local thumbnail = self.ui.thumbnail
    if not thumbnail then return end
    thumbnail:cancelPageThumbnailRequests(self.batch)
    self.batch = "VoyagePageFlip" .. tostring(os.time()) .. "-" .. self.page
    local batch = self.batch
    -- Current page first, then its neighbours.
    for __, p in ipairs({ self.page, self.page + 1, self.page - 1 }) do
        if p >= 1 and p <= self.pages and not self.tiles[p] then
            thumbnail:getPageThumbnail(p, self.thumb_w, self.thumb_h, batch, function(tile, batch_id, async)
                if not tile or batch_id ~= self.batch or self.closed then return end
                self.tiles[p] = tile.bb
                if async then self:refresh(self.carousel) end
            end)
        end
    end
end

-- Draw a tile at (x, y), clipped to the screen.
function PageFlip:blitTile(bb, tile, x, y)
    local sx = x < 0 and -x or 0
    local w = math.min(tile.w - sx, self.W - math.max(x, 0))
    if w > 0 then
        bb:blitFrom(tile, math.max(x, 0), y, sx, 0, w, tile.h)
    end
end

function PageFlip:paintPage(bb, p, x, y, is_center)
    local w, h = self.thumb_w, self.thumb_h
    local tile = self.tiles[p]
    if tile then
        -- Tiles may be a pixel or two narrower than requested to keep proportions.
        self:blitTile(bb, tile, x + round((w - tile.w) / 2), y + round((h - tile.h) / 2))
    end
    local border = is_center and self.line + 1 or self.line
    if x + w > 0 and x < self.W then
        bb:paintBorder(x, y, w, h, border, Blitbuffer.COLOR_BLACK)
    end
end

-- Painting -------------------------------------------------------------------------

function PageFlip:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

function PageFlip:paintTo(bb, x, y)
    local ok, err = pcall(self.paintFlip, self, bb, x, y)
    if not ok then
        logger.err("VoyagePageFlip: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function PageFlip:icon(name, size, cx, cy, bb)
    local icon = self.plugin:icon(name, size)
    icon:paintTo(bb, cx - round(size / 2), cy - round(size / 2))
    icon:free()
end

function PageFlip:pageLabel(p)
    return string.format(_("Page %d"), p)
end

function PageFlip:paintFlip(bb, x, y)
    local P, W = self.P, self.W
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, W, self.H, Blitbuffer.COLOR_WHITE)

    -- Status line: time left, chevron centre, wireless and battery right.
    local clock = self:text(datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")), self.face_status)
    clock:paintTo(bb, x + round(30 * P), y + round(78 * P) - round(clock:getSize().h / 2))
    local chevron = self.plugin:icon("chevron-down", round(130 * P))
    chevron:paintTo(bb, x + round((W - 130 * P) / 2), y + round(48 * P) - round(65 * P))
    chevron:free()
    local right = self.plugin:paintBattery(bb, x + W - round(30 * P), y + round(57 * P), round(26 * P), self.face_status)
    if not self.plugin:isWirelessOn() then
        local s = round(40 * P)
        self:icon("airplane", s, right - round(28 * P) - round(s / 2), y + round(57 * P), bb)
    end

    -- Toolbar: ← Library, then Aa, contents, page flip, bookmark, search, ⋮
    self:icon("back", round(46 * P), x + round(58 * P), y + round(190 * P), bb)
    local lib = self:text(_("Library"), self.face_library)
    lib:paintTo(bb, x + round(110 * P), y + round(190 * P) - round(lib:getSize().h / 2))
    local bookmarked = self.ui.bookmark and self.ui.bookmark:isPageBookmarked()
    for __, t in ipairs(self.tools) do
        if t.id == "aa" then
            local aa = self:text("Aa", self.face_aa)
            aa:paintTo(bb, x + t.cx - round(aa:getSize().w / 2), y + self.tool_cy - round(aa:getSize().h / 2))
        else
            local name = t.id == "bookmark" and (bookmarked and "bookmark-filled" or "bookmark") or t.id
            self:icon(name, round(46 * P), x + t.cx, y + self.tool_cy, bb)
        end
    end
    bb:paintRect(x, y + round(245 * P), W, self.line, Blitbuffer.COLOR_LIGHT_GRAY)

    -- Title
    local title = self.ui.doc_props and self.ui.doc_props.display_title or ""
    local title_w = self:text(title, self.face_title, W - round(80 * P))
    title_w:paintTo(bb, x + round(40 * P), y + round(315 * P) - round(title_w:getSize().h / 2))
    bb:paintRect(x, y + round(365 * P), W, self.thick, BLACK)

    -- Carousel: neighbours peek in from both sides.
    local cy = y + self.thumb_y
    self:paintPage(bb, self.page, x + self.center_x, cy, true)
    if self.page > 1 then
        self:paintPage(bb, self.page - 1, x + self.center_x - self.gap - self.thumb_w, cy)
    end
    if self.page < self.pages then
        self:paintPage(bb, self.page + 1, x + self.center_x + self.thumb_w + self.gap, cy)
    end

    -- "Back to page N" when you've moved away from where you were.
    if self.page ~= self.orig then
        local b = self.back_btn
        local label = self:text(string.format(_("Back to page %d"), self.orig), self.face_button)
        b.w = math.max(round(292 * P), label:getSize().w + round(60 * P))
        bb:paintRect(x + b.x, y + b.y, b.w, b.h, Blitbuffer.COLOR_WHITE)
        bb:paintBorder(x + b.x, y + b.y, b.w, b.h, self.line, BLACK)
        label:paintTo(bb, x + b.x + round((b.w - label:getSize().w) / 2), y + b.y + round((b.h - label:getSize().h) / 2))
    end

    -- Bottom: chapter with jumps, then grid and scrubber.
    self:paintBottom(bb, x, y)
end

function PageFlip:knobX(p)
    local frac = (p - 1) / math.max(self.pages - 1, 1)
    return round(self.track_x0 + frac * (self.track_x1 - self.track_x0))
end

function PageFlip:paintBottom(bb, x, y)
    local P, W = self.P, self.W
    local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local area = self.bottom_area
    bb:paintRect(x + area.x, y + area.y, area.w, area.h, WHITE)
    bb:paintRect(x, y + round(1485 * P) + self.extra, W, self.thick, BLACK)

    local chapter = self.ui.toc:getTocTitleByPage(self.page) or ""
    local chapter_w = self:text(chapter, self.face_chapter, W - round(420 * P))
    chapter_w:paintTo(bb, x + round((W - chapter_w:getSize().w) / 2), y + self.chapter_cy - round(chapter_w:getSize().h / 2))
    self:icon("chapter-prev", round(44 * P), x + round(92 * P), y + round(1535 * P) + self.extra, bb)
    self:icon("chapter-next", round(44 * P), x + W - round(90 * P), y + round(1535 * P) + self.extra, bb)
    self:icon("grid-small", round(44 * P), x + round(92 * P), y + self.track_cy, bb)

    -- Track: thick up to the knob, thin after; a dot marks where you were.
    local ty = y + self.track_cy
    local kx = x + self:knobX(self.page)
    bb:paintRect(x + self.track_x0, ty - round(1.5 * P), self.track_x1 - self.track_x0, math.max(2, round(3 * P)), BLACK)
    bb:paintRect(x + self.track_x0, ty - round(5 * P), kx - x - self.track_x0, round(10 * P), BLACK)
    if self.page ~= self.orig then
        bb:paintCircle(x + self:knobX(self.orig), ty, round(18 * P), BLACK)
    end
    bb:paintCircle(kx, ty, self.knob_r, WHITE)
    bb:paintCircle(kx, ty, self.knob_r, BLACK, math.max(2, round(3 * P)))
    local label = self:text(self:pageLabel(self.page), self.face_label)
    label:paintTo(bb, kx - round(label:getSize().w / 2), y + round(1595 * P) + self.extra - round(label:getSize().h / 2))
end

-- Navigation -----------------------------------------------------------------------

function PageFlip:refresh(region, mode)
    UIManager:setDirty(self, function() return mode or "ui", region or self.dimen end)
end

function PageFlip:preview(p, scrubbing)
    p = math.min(math.max(p, 1), self.pages)
    if p == self.page then return end
    self.page = p
    if scrubbing then
        self:refresh(self.bottom_area, "fast")
    else
        self:requestThumbnails()
        self:refresh(nil, "partial")
    end
end

function PageFlip:goTo(p)
    self:onClose()
    if p ~= self.orig then
        self.ui.link:addCurrentLocationToStack() -- so the toolbar's Back can return here
        self.ui:handleEvent(Event:new("GotoPage", p))
    end
end

function PageFlip:pageAtX(px)
    local frac = (px - self.track_x0) / math.max(self.track_x1 - self.track_x0, 1)
    return 1 + round(math.min(math.max(frac, 0), 1) * (self.pages - 1))
end

function PageFlip:tool(id)
    local ui = self.ui
    if id == "pageflip" then
        return self:onClose()
    elseif id == "kebab" then
        local hit
        for __, t in ipairs(self.tools) do if t.id == "kebab" then hit = t.hit end end
        UIManager:show(Dropdown:new{ anchor = hit, items = self.plugin:readingMenuItems(function() self:onClose() end) })
        return
    elseif id == "bookmark" then
        ui.bookmark:onToggleBookmark()
        return self:refresh(Geom:new{ x = 0, y = 0, w = self.W, h = round(250 * self.P) })
    end
    self:onClose()
    if id == "aa" then
        self.plugin:showTextSettings()
    elseif id == "contents" then
        self.plugin:showGoTo()
    elseif id == "search" then
        ui.search:onShowFulltextSearchInput()
    end
end

function PageFlip:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.chevron_hit) then return self:onClose() end
    if inside(pos, self.library_hit) then
        self:onClose()
        self.ui:onHome()
        return true
    end
    for __, t in ipairs(self.tools) do
        if inside(pos, t.hit) then self:tool(t.id) return true end
    end
    if self.page ~= self.orig and inside(pos, self.back_btn) then
        self:preview(self.orig)
        return true
    end
    if inside(pos, self.carousel) then
        if pos.x < self.center_x then
            self:preview(self.page - 1)
        elseif pos.x > self.center_x + self.thumb_w then
            self:preview(self.page + 1)
        else
            self:goTo(self.page)
        end
        return true
    end
    if inside(pos, self.prev_hit) then
        local p = self.ui.toc:getPreviousChapter(self.page)
        if p then self:preview(p) end
    elseif inside(pos, self.next_hit) then
        local p = self.ui.toc:getNextChapter(self.page)
        if p then self:preview(p) end
    elseif inside(pos, self.grid_hit) then
        self:onClose()
        self.ui:handleEvent(Event:new("ShowPageBrowser"))
    elseif inside(pos, self.track_hit) then
        self:preview(self:pageAtX(pos.x))
    end
    return true
end

function PageFlip:onPan(__, ges)
    if self.scrubbing or inside(ges.pos, self.track_hit) then
        self.scrubbing = true
        self:preview(self:pageAtX(ges.pos.x), true)
    end
    return true
end

function PageFlip:onPanRelease()
    if self.scrubbing then
        self.scrubbing = false
        self:requestThumbnails()
        self:refresh(nil, "partial")
    end
    return true
end

function PageFlip:onSwipe(__, ges)
    if inside(ges.pos, self.carousel) and (ges.direction == "west" or ges.direction == "east") then
        self:preview(self.page + (ges.direction == "west" and 1 or -1))
    elseif ges.direction == "south" and ges.pos.y < self.carousel.y then
        self:onClose()
    end
    return true
end

function PageFlip:onNextPage() self:preview(self.page + 1) return true end
function PageFlip:onPrevPage() self:preview(self.page - 1) return true end

function PageFlip:onShow()
    self:refresh(nil, "ui")
    return true
end

function PageFlip:onClose()
    UIManager:close(self)
    return true
end

function PageFlip:onCloseWidget()
    self.closed = true
    if self.ui.thumbnail then self.ui.thumbnail:cancelPageThumbnailRequests(self.batch) end
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.tiles = {} -- owned by the thumbnail cache
    self.plugin.pageflip = nil
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return PageFlip
