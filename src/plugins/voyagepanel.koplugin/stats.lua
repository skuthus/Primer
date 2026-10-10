--[[--
Reading Statistics for the open book, opened from the toolbar's ⋮ menu: a card with the
book, a progress bar and a grid of figures (time left, time spent, days reading, average
per day, pages read, highlights and notes, started, finish estimate). Times come from
KOReader's statistics plugin; without it the time figures show a dash.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local DASH = "—"

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- "Oct 3", or "Oct 3, 2025" outside this year.
local function shortDate(ts)
    local fmt = os.date("%Y", ts) == os.date("%Y") and "%b %d" or "%b %d, %Y"
    return (os.date(fmt, ts):gsub(" 0", " "))
end

local Stats = InputContainer:extend{
    plugin = nil,
    modal = true,
}

function Stats:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.u = self.W / 1072
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then
        local close = {}
        for __, group in ipairs({ "Back", "PgFwd", "PgBack" }) do
            if Device.input.group[group] then table.insert(close, { Device.input.group[group] }) end
        end
        self.key_events = self.key_events or {}
        self.key_events.Close = close
    end
    self.widgets = {}
    self:layout(self:gather())
end

function Stats:add(w)
    table.insert(self.widgets, w)
    return w
end

-- Figures for the open book.
function Stats:gather()
    local ui = self.ui
    local footer = ui.view and ui.view.footer
    local page = footer and footer.pageno or ui:getCurrentPage()
    local pages = math.max(1, footer and footer.pages or ui.document:getPageCount())
    local d = {
        page = page, pages = pages,
        percent = footer and footer.percent_finished or (page / pages),
        highlights = 0, notes = 0,
    }
    for __, a in ipairs(ui.annotation and ui.annotation.annotations or {}) do
        if a.drawer then d.highlights = d.highlights + 1 end
        if a.note and a.note:match("%S") then d.notes = d.notes + 1 end
    end
    local summary = ui.doc_settings and ui.doc_settings:readSetting("summary")
    d.finished = summary and summary.status == "complete"

    local stats = ui.statistics
    local id = stats and stats.id_curr_book
    if not (id and stats:isEnabled()) then return d end
    local ok, err = pcall(function()
        stats:insertDB() -- count the current session too
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local days = conn:rowexec(string.format([[
            SELECT count(*) FROM (SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS day
            FROM page_stat WHERE id_book = %d GROUP BY day);]], id))
        local read_pages, first = conn:rowexec(string.format(
            "SELECT count(DISTINCT page), min(start_time) FROM page_stat WHERE id_book = %d;", id))
        conn:close()
        d.days = tonumber(days) or 0
        d.read_pages = tonumber(read_pages) or 0
        d.first = tonumber(first)
        -- Time spent per page is capped (as KOReader's own estimates are), so idle pages don't count.
        local __, read_time = stats:getPageTimeTotalStats(id)
        d.read_time = tonumber(read_time) or 0
        local avg = stats.avg_time
        if avg and avg == avg and avg > 0 then
            d.time_left = math.max(0, pages - page) * avg
        end
        if d.days > 0 then d.per_day = d.read_time / d.days end
    end)
    if not ok then logger.warn("VoyageStats: no statistics:", err) end
    return d
end

function Stats:duration(seconds)
    if not seconds then return DASH end
    if seconds > 0 and seconds < 60 then return _("Under 1 min") end
    return self.plugin.minutesText(math.floor(seconds / 60))
end

function Stats:layout(d)
    local u = self.u
    self.pad = round(44 * u)
    self.line = math.max(1, round(2 * u))
    self.border = math.max(2, round(3 * u))
    local w = round(self.W * 0.9)
    local c = Geom:new{ x = round((self.W - w) / 2), y = 0, w = w, h = 0 }
    self.card = c
    local inner = w - 2 * self.pad
    local function text(str, role, size, max_w, color)
        return self:add(TextWidget:new{ text = str, face = Fonts.face(role, size), max_width = max_w or inner, fgcolor = color })
    end

    self.header_h = round(104 * u)
    self.heading = text(_("Reading Statistics"), "ui_bold", 20)
    self.close_s = round(36 * u)
    self.close_hit = Geom:new{ x = c.x + w - round(130 * u), y = 0, w = round(130 * u), h = self.header_h }

    local props = self.ui.doc_props or {}
    self.title = text(props.display_title or "", "serif_bold", 21)
    self.author = props.authors and props.authors ~= "" and text(props.authors:gsub("\n", ", "), "ui", 16) or nil

    self.bar_h = round(18 * u)
    local pct = d.finished and 100 or math.floor(d.percent * 100)
    self.fill = d.finished and 1 or math.max(0, math.min(1, d.percent))
    self.page_w = text(string.format(_("Page %d of %d"), d.page, d.pages), "ui", 15)
    self.pct_w = text(string.format(_("%d%% read"), pct), "ui_bold", 15)

    local time_left = d.finished and _("Finished") or self:duration(d.time_left)
    local finish = DASH
    if d.finished then
        finish = _("Finished")
    elseif d.time_left and d.per_day and d.per_day > 0 then
        local days = math.ceil(d.time_left / d.per_day)
        finish = days <= 1 and _("Tomorrow") or shortDate(os.time() + days * 86400)
    end
    local tiles = {
        { time_left, _("Time left in book") },
        { self:duration(d.read_time), _("Time spent reading") },
        { d.days and tostring(d.days) or DASH, d.days == 1 and _("Day reading") or _("Days reading") },
        { self:duration(d.per_day), _("Average per day") },
        { d.read_pages and tostring(d.read_pages) or DASH, _("Pages read") },
        { string.format("%d · %d", d.highlights, d.notes), _("Highlights · Notes") },
        { d.first and shortDate(d.first) or DASH, _("Started") },
        { finish, _("Estimated finish") },
    }
    local col_w = round((inner - self.pad) / 2)
    self.tiles = {}
    for i, t in ipairs(tiles) do
        self.tiles[i] = { value = text(t[1], "ui_bold", 24, col_w), label = text(t[2], "ui", 15, col_w) }
    end
    self.col_w = col_w
    self.tile_h = self.tiles[1].value:getSize().h + round(6 * u) + self.tiles[1].label:getSize().h + round(40 * u)

    -- Height: header, book, progress, grid.
    local h = self.header_h + self.pad
    h = h + self.title:getSize().h + (self.author and round(6 * u) + self.author:getSize().h or 0)
    h = h + round(34 * u) + self.bar_h + round(14 * u) + self.page_w:getSize().h
    h = h + round(36 * u) + self.line + round(36 * u)
    h = h + self.tile_h * math.ceil(#self.tiles / 2) - round(40 * u) + self.pad
    c.h = h
    c.y = round((self.H - h) / 2)
    self.close_hit.y = c.y
end

function Stats:paintTo(bb, x, y)
    local ok, err = pcall(self.paintCard, self, bb, x, y)
    if not ok then
        logger.err("VoyageStats: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

function Stats:paintCard(bb, x, y)
    local u, c, pad = self.u, self.card, self.pad
    local BLACK = Blitbuffer.COLOR_BLACK
    local cx, cy = x + c.x, y + c.y
    bb:paintRect(cx, cy, c.w, c.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(cx, cy, c.w, c.h, self.border, BLACK)

    -- Header: Reading Statistics            ✕
    local hs = self.heading:getSize()
    self.heading:paintTo(bb, cx + pad, cy + round((self.header_h - hs.h) / 2))
    local close = self.plugin:icon("close", self.close_s)
    close:paintTo(bb, cx + c.w - pad - self.close_s, cy + round((self.header_h - self.close_s) / 2))
    close:free()
    bb:paintRect(cx, cy + self.header_h, c.w, self.line, BLACK)

    -- Book
    local ty = cy + self.header_h + pad
    self.title:paintTo(bb, cx + pad, ty)
    ty = ty + self.title:getSize().h
    if self.author then
        ty = ty + round(6 * u)
        self.author:paintTo(bb, cx + pad, ty)
        ty = ty + self.author:getSize().h
    end

    -- Progress bar, with the page on the left and the percentage on the right.
    ty = ty + round(34 * u)
    local bw = c.w - 2 * pad
    bb:paintBorder(cx + pad, ty, bw, self.bar_h, self.line, BLACK)
    local fw = round(bw * self.fill)
    if fw > 0 then bb:paintRect(cx + pad, ty, fw, self.bar_h, BLACK) end
    ty = ty + self.bar_h + round(14 * u)
    self.page_w:paintTo(bb, cx + pad, ty)
    self.pct_w:paintTo(bb, cx + c.w - pad - self.pct_w:getSize().w, ty)
    ty = ty + self.page_w:getSize().h + round(36 * u)
    bb:paintRect(cx + pad, ty, bw, self.line, Blitbuffer.COLOR_LIGHT_GRAY)
    ty = ty + self.line + round(36 * u)

    -- Figures, two to a row.
    for i, t in ipairs(self.tiles) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local tx = cx + pad + col * (self.col_w + pad)
        local ry = ty + row * self.tile_h
        t.value:paintTo(bb, tx, ry)
        t.label:paintTo(bb, tx, ry + t.value:getSize().h + round(6 * u))
    end
end

function Stats:onTap(__, ges)
    if not inside(ges.pos, self.card) or inside(ges.pos, self.close_hit) then
        return self:onClose()
    end
    return true
end

function Stats:onShow()
    UIManager:setDirty(self, function() return "ui", self.card end)
    return true
end

function Stats:onClose()
    UIManager:close(self)
    return true
end

function Stats:onCloseWidget()
    for __, w in ipairs(self.widgets) do w:free() end
    self.widgets = {}
    self.plugin.stats = nil
    UIManager:setDirty(nil, function() return "ui", self.card end)
end

return Stats
