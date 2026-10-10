--[[--
Kindle-style reading toolbar, shown when tapping the top of the page while reading.
Top: status line (title, airplane, battery, time), home / back / settings, Search, ⋮ (a
dropdown: Notebook, Reading Statistics),
then Aa, Go To and the bookmark ribbon. Bottom: chapter, page and time left, and
Book map / Page browser. The page stays visible in between; tapping it closes.
Proportions follow a screenshot of the Voyage's own toolbar.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dropdown = require("dropdown")
local Event = require("ui/event")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
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

local Toolbar = InputContainer:extend{
    plugin = nil,
    icon_dir = nil,
}

function Toolbar:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.cache = {}

    local screen = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        local close = {}
        for __, group in ipairs({ "Back", "PgFwd", "PgBack" }) do
            if Device.input.group[group] then table.insert(close, { Device.input.group[group] }) end
        end
        self.key_events = self.key_events or {}
        self.key_events.Close = close
    end

    self.face_status = Fonts.face("ui", 16)
    self.face_label = Fonts.face("ui", 13)
    self.face_search = Fonts.face("ui", 18)
    self.face_aa = Fonts.face("ui", 30)
    self.face_goto = Fonts.face("ui", 18)
    self.face_chapter = Fonts.face("ui", 18)
    self.face_info = Fonts.face("ui", 15)

    self:layout()
end

function Toolbar:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

function Toolbar:icon(name, size)
    return IconWidget:new{ file = self.icon_dir .. "/" .. name .. ".svg", width = size, height = size }
end

function Toolbar:layout()
    local W, H = self.W, self.H
    local u = W / 1072 -- the screenshot was taken at the Voyage's 1072px width
    self.u = u
    self.line = math.max(1, round(2 * u))
    self.pad = round(47 * u)

    -- Top block
    self.status_h = round(57 * u)
    self.row1_y, self.row1_h = self.status_h, round(105 * u)
    self.row2_y, self.row2_h = self.row1_y + self.row1_h, round(110 * u)
    self.top = Geom:new{ x = 0, y = 0, w = W, h = self.row2_y + self.row2_h + self.line }

    -- Row 1: three tool buttons share the left section, then Search, then ⋮.
    self.search_x0, self.search_x1 = round(694 * u), round(960 * u)
    self.tool_icon = round(44 * u)
    self.tools = {}
    for i, id in ipairs({ "home", "back", "settings" }) do
        local col_w = self.search_x0 / 3
        self.tools[i] = { id = id, cx = round(col_w * (i - 0.5)),
            hit = Geom:new{ x = round(col_w * (i - 1)), y = self.row1_y, w = round(col_w), h = self.row1_h } }
    end
    self.search_hit = Geom:new{ x = self.search_x0, y = self.row1_y, w = self.search_x1 - self.search_x0, h = self.row1_h }
    self.kebab_hit = Geom:new{ x = self.search_x1, y = self.row1_y, w = W - self.search_x1, h = self.row1_h }

    -- Row 2: Aa on the left, Go To and the bookmark ribbon on the right.
    self.aa_hit = Geom:new{ x = 0, y = self.row2_y, w = round(W * 0.3), h = self.row2_h }
    self.ribbon = round(48 * u)
    self.ribbon_x = round(946 * u)
    self.bookmark_hit = Geom:new{ x = round(905 * u), y = self.row2_y, w = W - round(905 * u), h = self.row2_h }
    self.goto_hit = Geom:new{ x = round(760 * u), y = self.row2_y, w = round(145 * u), h = self.row2_h }

    -- Bottom block
    self.bottom_h = round(276 * u)
    self.bottom = Geom:new{ x = 0, y = H - self.bottom_h, w = W, h = self.bottom_h }
    self.seg_w, self.seg_h = round(135 * u), round(53 * u)
    self.seg_y = self.bottom.y + round(193 * u)
    self.seg_x = round(W / 2) - self.seg_w
    self.bookmap_hit = Geom:new{ x = self.seg_x - round(20 * u), y = self.seg_y - round(15 * u), w = self.seg_w + round(20 * u), h = self.seg_h + round(30 * u) }
    self.browser_hit = Geom:new{ x = self.seg_x + self.seg_w, y = self.seg_y - round(15 * u), w = self.seg_w + round(20 * u), h = self.seg_h + round(30 * u) }
end

-- Page, chapter and progress, as the footer sees them.
function Toolbar:progress()
    local footer = self.ui.view and self.ui.view.footer
    local pageno = footer and footer.pageno or self.ui:getCurrentPage()
    local pages = footer and footer.pages or self.ui.document:getPageCount()
    local percent = footer and footer.percent_finished or (pageno / math.max(pages, 1))
    local page_text
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        page_text = string.format(_("Page %s of %s"), self.ui.pagemap:getCurrentPageLabel(true), self.ui.pagemap:getLastPageLabel(true))
    else
        page_text = string.format(_("Page %d of %d"), pageno, pages)
    end
    local parts = { page_text }
    local stats = self.ui.statistics
    if stats and stats.settings and stats.settings.is_enabled and stats.avg_time and stats.avg_time == stats.avg_time then
        local left = self.ui.toc:getChapterPagesLeft(pageno, true) or self.ui.document:getTotalPagesLeft(pageno)
        if left then
            local minutes = math.max(1, math.ceil(left * stats.avg_time / 60))
            table.insert(parts, string.format(_("%s left in chapter"), self.plugin.minutesText(minutes)))
        end
    end
    table.insert(parts, string.format("%d%%", math.floor(percent * 100)))
    return self.ui.toc:getTocTitleByPage(pageno) or "", table.concat(parts, " | ")
end

function Toolbar:paintTo(bb, x, y)
    local ok, err = pcall(self.paintToolbar, self, bb, x, y)
    if not ok then
        logger.err("VoyageToolbar: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function Toolbar:paintLine(bb, x, y, w)
    bb:paintRect(x, y, w, self.line, Blitbuffer.COLOR_GRAY)
end

function Toolbar:paintToolbar(bb, x, y)
    local W, u, pad = self.W, self.u, self.pad
    local WHITE = Blitbuffer.COLOR_WHITE
    bb:paintRect(x, y, W, self.top.h, WHITE)
    bb:paintRect(x, y + self.bottom.y, W, self.bottom_h, WHITE)

    -- Status line: time left, title centred, airplane and battery right (like the other menus).
    local cy = y + round(self.status_h / 2)
    local clock = self:text(datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")), self.face_status)
    clock:paintTo(bb, x + pad, cy - round(clock:getSize().h / 2))
    local left = x + pad + clock:getSize().w + round(28 * u)
    local right = self.plugin:paintBattery(bb, x + W - pad, cy, round(20 * u))
    local powerd = Device:getPowerDevice()
    local pct = self:text(string.format("%d%%", powerd:getCapacity()), self.face_status)
    right = right - round(6 * u) - pct:getSize().w
    pct:paintTo(bb, right, cy - round(pct:getSize().h / 2))
    if not self.plugin:isWirelessOn() then
        local plane = self.plugin:icon("airplane", round(36 * u))
        right = right - round(24 * u) - round(36 * u)
        plane:paintTo(bb, right, cy - round(18 * u))
        plane:free()
    end
    local title = self.ui.doc_props and self.ui.doc_props.display_title or ""
    -- Centred on the screen, but kept clear of the clock and the status icons.
    local room = 2 * math.min(x + W / 2 - left, right - (x + W / 2)) - round(20 * u)
    local title_w = self:text(title, self.face_status, math.max(room, round(100 * u)))
    title_w:paintTo(bb, x + round((W - title_w:getSize().w) / 2), cy - round(title_w:getSize().h / 2))
    self:paintLine(bb, x, y + self.row1_y - self.line, W)

    -- Row 1
    for __, t in ipairs(self.tools) do
        local icon = self:icon(t.id == "settings" and "gear" or t.id, self.tool_icon)
        icon:paintTo(bb, x + t.cx - round(self.tool_icon / 2), y + self.row1_y + round(18 * u))
        icon:free()
        local label = self:text(t.id == "home" and _("home") or t.id == "back" and _("back") or _("settings"), self.face_label)
        label:paintTo(bb, x + t.cx - round(label:getSize().w / 2), y + self.row1_y + round(66 * u))
    end
    bb:paintRect(x + self.search_x0, y + self.row1_y, self.line, self.row1_h, Blitbuffer.COLOR_GRAY)
    bb:paintRect(x + self.search_x1, y + self.row1_y, self.line, self.row1_h, Blitbuffer.COLOR_GRAY)
    local mag = self:icon("search", round(52 * u))
    local row1_cy = y + self.row1_y + round(self.row1_h / 2)
    mag:paintTo(bb, x + self.search_x0 + round(26 * u), row1_cy - round(26 * u))
    mag:free()
    local placeholder = TextWidget:new{ text = _("Search"), face = self.face_search, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    placeholder:paintTo(bb, x + self.search_x0 + round(106 * u), row1_cy - round(placeholder:getSize().h / 2))
    placeholder:free()
    local kebab = self:icon("kebab", round(40 * u))
    kebab:paintTo(bb, x + round((self.search_x1 + W) / 2) - round(20 * u), row1_cy - round(20 * u))
    kebab:free()
    self:paintLine(bb, x, y + self.row2_y - self.line, W)

    -- Row 2
    local row2_cy = y + self.row2_y + round(self.row2_h / 2)
    local aa = self:text("Aa", self.face_aa)
    aa:paintTo(bb, x + round(52 * u), row2_cy - round(aa:getSize().h / 2))
    local goto_w = self:text(_("Go To"), self.face_goto)
    goto_w:paintTo(bb, x + round(802 * u), row2_cy - round(goto_w:getSize().h / 2))
    local bookmarked = self.ui.bookmark and self.ui.bookmark:isPageBookmarked()
    local ribbon = self:icon(bookmarked and "bookmark-filled" or "bookmark", self.ribbon)
    ribbon:paintTo(bb, x + self.ribbon_x, row2_cy - round(self.ribbon / 2))
    ribbon:free()
    self:paintLine(bb, x, y + self.top.h - self.line, W)

    -- Bottom block
    local by = y + self.bottom.y
    self:paintLine(bb, x, by, W)
    local chapter, info = self:progress()
    local chapter_w = self:text(chapter, self.face_chapter, W - 2 * pad)
    chapter_w:paintTo(bb, x + round((W - chapter_w:getSize().w) / 2), by + round(66 * u) - round(chapter_w:getSize().h / 2))
    local info_w = self:text(info, self.face_info, W - 2 * pad)
    info_w:paintTo(bb, x + round((W - info_w:getSize().w) / 2), by + round(123 * u) - round(info_w:getSize().h / 2))
    local border = math.max(2, round(3 * u))
    for i, name in ipairs({ "bookmap", "grid" }) do
        local sx = x + self.seg_x + (i - 1) * self.seg_w
        bb:paintBorder(sx, y + self.seg_y, self.seg_w + (i == 1 and border or 0), self.seg_h, border, Blitbuffer.COLOR_BLACK)
        local s = round(34 * u)
        local glyph = self:icon(name, s)
        glyph:paintTo(bb, sx + round((self.seg_w - s) / 2), y + self.seg_y + round((self.seg_h - s) / 2))
        glyph:free()
    end
end

function Toolbar:refresh()
    UIManager:setDirty(self, function() return "ui", self.top end)
    UIManager:setDirty(self, function() return "ui", self.bottom end)
end

function Toolbar:act(id)
    local ui = self.ui
    if id == "home" then
        self:onClose()
        ui:onHome()
    elseif id == "back" then
        self:onClose()
        if ui.link and ui.link.location_stack and #ui.link.location_stack > 0 then
            ui.link:onGoBackLink()
        else
            ui:onHome()
        end
    elseif id == "settings" then
        self:onClose()
        self.plugin:openAllSettings()
    elseif id == "search" then
        self:onClose()
        ui.search:onShowFulltextSearchInput()
    elseif id == "kebab" then
        UIManager:show(Dropdown:new{ anchor = self.kebab_hit, items = self.plugin:readingMenuItems(function() self:onClose() end) })
    elseif id == "aa" then
        self:onClose()
        self.plugin:showTextSettings()
    elseif id == "goto" then
        self:onClose()
        self.plugin:showGoTo()
    elseif id == "bookmark" then
        ui.bookmark:onToggleBookmark()
        self:refresh()
    elseif id == "bookmap" then
        self:onClose()
        ui:handleEvent(Event:new("ShowBookMap"))
    elseif id == "browser" then
        self:onClose()
        ui:handleEvent(Event:new("ShowPageBrowser"))
    end
end

function Toolbar:onTap(__, ges)
    local pos = ges.pos
    if not (inside(pos, self.top) or inside(pos, self.bottom)) then
        return self:onClose()
    end
    for __, t in ipairs(self.tools) do
        if inside(pos, t.hit) then self:act(t.id); return true end
    end
    local targets = {
        { self.search_hit, "search" }, { self.kebab_hit, "kebab" }, { self.aa_hit, "aa" },
        { self.goto_hit, "goto" }, { self.bookmark_hit, "bookmark" },
        { self.bookmap_hit, "bookmap" }, { self.browser_hit, "browser" },
    }
    for __, target in ipairs(targets) do
        if inside(pos, target[1]) then self:act(target[2]); return true end
    end
    return true
end

function Toolbar:onSwipe(__, ges)
    if ges.direction == "north" or ges.direction == "south" then
        return self:onClose()
    end
    return true
end

function Toolbar:onShow()
    self:refresh()
    return true
end

function Toolbar:onClose()
    UIManager:close(self)
    return true
end

function Toolbar:onCloseWidget()
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.plugin.toolbar = nil
    UIManager:setDirty(nil, function() return "ui", self.top end)
    UIManager:setDirty(nil, function() return "ui", self.bottom end)
end

return Toolbar
