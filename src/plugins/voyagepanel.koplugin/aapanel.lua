--[[--
Kindle-style Aa panel: a bottom sheet with Themes / Font / Layout / More tabs, laid out
from screenshots of the Voyage's own. Changes apply to the open book immediately and
become the default for every book, like the Kindle.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Dialog = require("dialog")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local Prompt = require("prompt")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen


local TABS = { "themes", "font", "layout", "more" }
local TAB_LABELS = { themes = _("Themes"), font = _("Font"), layout = _("Layout"), more = _("More") }
local TAB_X = { 57, 258, 406, 592 } -- label positions on the Voyage's 1072px screen

-- Kindle's 5 bold steps and 14 size steps, mapped to KOReader values. Size 4 is KOReader's
-- 22 (the default); from there each step is about 15% larger, so each one is a visible change.
local WEIGHTS = { 0, 0.5, 1, 1.5, 3 }
local SIZES = { 14, 16, 19, 22, 25, 29, 33, 38, 44, 51, 59, 68, 78, 90 }
-- Size and Bold changes wait this long after the last tap, since each one re-lays out the book.
local APPLY_DELAY_S = 1
local MARGINS = { { h = 15, t = 15 }, { h = 30, t = 30 }, { h = 50, t = 40 } }
local SPACINGS = { 100, 115, 135 }

local PRESETS = {
    { name = _("Compact"), icon = "compact", size = 19, spacing = 100, h = 15, t = 15 },
    { name = _("Standard"), icon = "standard", size = 22, spacing = 115, h = 30, t = 30 },
    { name = _("Large"), icon = "large", size = 28, spacing = 125, h = 30, t = 30 },
}

local PROGRESS = {
    { id = "page", label = _("Page in book") },
    { id = "chapter", label = _("Time left in chapter") },
    { id = "book", label = _("Time left in book") },
    { id = "none", label = _("None") },
}

-- Non-Latin and UI-only system fonts the Kindle doesn't offer for reading.
local HIDDEN_FONTS = { "CJK", "KR", "Arabic", "Naskh", "Devanagari", "Bengali", "Gujarati", "Kannada",
    "Malayalam", "Tamil", "Telugu", "STHeiti", "STSong", "STKai", "MYingHei", "SongT", "TBGothic",
    "TBMincho", "HYGothic", "HYMyeongJo", "Diwan", "Sakkal", "Symbol", "Blackbox", "MTChinese", "Display" }
local FONT_NAMES = {
    ["PMN Caecilia LT"] = "Caecilia",
    ["Helvetica Neue LT 65 Kindle Medium"] = "Helvetica",
    ["Futura Medium"] = "Futura",
}

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function nearest(list, value, key)
    local best, best_d = 1, math.huge
    for i, v in ipairs(list) do
        local d = math.abs((key and v[key] or v) - value)
        if d < best_d then best, best_d = i, d end
    end
    return best
end

local AaPanel = InputContainer:extend{
    plugin = nil,
}

-- Like ReaderFont:onSetFontSize, minus its "Font size set to: 22" note: Primer speaks in steps.
local function setFontSize(ui, size)
    ui.document.configurable.font_size = size
    ui.document:setFontSize(Screen:scaleBySize(size))
    ui:handleEvent(Event:new("UpdatePos"))
    G_reader_settings:saveSetting("copt_font_size", size)
end

-- Move the open book's font size by `delta` of the panel's steps (used by pinch and spread).
function AaPanel.stepFontSize(ui, delta)
    local conf = ui.document.configurable
    local i = math.max(1, math.min(#SIZES, nearest(SIZES, conf.font_size or 22) + delta))
    if SIZES[i] ~= conf.font_size then setFontSize(ui, SIZES[i]) end
    Notification:notify(string.format(_("Size %d"), i))
end

function AaPanel:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.u = self.W / 1072
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.tab = G_reader_settings:readSetting("voyage_aa_tab") or "themes"
    self.cache = {}
    self.hits = {}

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

    self.face_tab = Fonts.face("ui", 18)
    self.face_tab_on = Fonts.face("ui_bold", 18)
    self.face_text = Fonts.face("ui", 18)
    self.face_bold = Fonts.face("ui_bold", 18)
    self.face_small = Fonts.face("ui", 14)
    self.face_italic = Fonts.face("ui_italic", 17)
    self.face_value = Fonts.face("ui", 15)
    self.face_sign = Fonts.face("ui", 26)

    local u = self.u
    -- The sheet is as tall as its contents (laid out for the Voyage, where it starts 40% down):
    -- the same on the Voyage, shorter on taller screens such as the reMarkable's.
    self.top_y = math.max(round(self.H * 0.4), self.H - round(869 * u))
    self.tab_h = round(108 * u)
    self.content_y = self.top_y + self.tab_h
    self.sheet = Geom:new{ x = 0, y = self.top_y, w = self.W, h = self.H - self.top_y }
    self.thick = math.max(2, round(3 * u))
    self.line = math.max(1, round(2 * u))
end

-- Current settings, read from the open book.
function AaPanel:current()
    local conf = self.ui.document.configurable
    local h = conf.h_page_margins and conf.h_page_margins[1] or 30
    return {
        font = self.ui.font.font_face,
        size = conf.font_size or 22,
        weight = conf.font_base_weight or 0,
        spacing = conf.line_spacing or 115,
        h = h,
        t = conf.t_page_margin or 30,
    }
end

-- Current settings with any queued Size / Bold change on top, for drawing.
function AaPanel:shown()
    local cur = self:current()
    for k, v in pairs(self.pending or {}) do cur[k] = v end
    return cur
end

function AaPanel:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

function AaPanel:hit(rect, fn)
    table.insert(self.hits, { rect = rect, fn = fn })
end

function AaPanel:paintTo(bb, x, y)
    self.hits = {}
    local ok, err = pcall(self.paintPanel, self, bb, x, y)
    if not ok then
        logger.err("VoyageAa: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function AaPanel:paintPanel(bb, x, y)
    local W, u = self.W, self.u
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y + self.top_y, W, self.H - self.top_y, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x, y + self.top_y, W, self.thick, BLACK)

    if self.subview then
        self:paintSubview(bb, x, y)
        return
    end

    -- Tabs
    for i, id in ipairs(TABS) do
        local active = id == self.tab
        local label = self:text(TAB_LABELS[id], active and self.face_tab_on or self.face_tab)
        local lx = x + round(TAB_X[i] * u)
        label:paintTo(bb, lx, y + self.top_y + round(54 * u) - round(label:getSize().h / 2))
        local pad = round(16 * u)
        if active then
            bb:paintRect(lx - pad, y + self.content_y - round(10 * u), label:getSize().w + 2 * pad, round(10 * u), BLACK)
        end
        self:hit(Geom:new{ x = lx - pad, y = self.top_y, w = label:getSize().w + 2 * pad, h = self.tab_h }, function()
            self.tab = id
            G_reader_settings:saveSetting("voyage_aa_tab", id)
            self:refresh()
        end)
    end
    bb:paintRect(x, y + self.content_y, W, self.line, BLACK)

    if self.tab == "themes" then self:paintThemes(bb, x, y)
    elseif self.tab == "font" then self:paintFont(bb, x, y)
    elseif self.tab == "layout" then self:paintLayout(bb, x, y)
    else self:paintMore(bb, x, y) end
end

-- Icons ----------------------------------------------------------------------------

-- Small page icon: a rounded box with lines. `lines` = { {x0, x1, thickness}, ... } in box fractions.
function AaPanel:pageIcon(bb, bx, by, bw, bh, border, lines, gap)
    bb:paintBorder(bx, by, bw, bh, border, Blitbuffer.COLOR_BLACK, round(10 * self.u))
    local n = #lines
    local total = 0
    for __, l in ipairs(lines) do total = total + l[3] end
    total = total + gap * (n - 1)
    local ly = by + round((bh - total) / 2)
    for __, l in ipairs(lines) do
        local lx0 = bx + round(bw * l[1])
        bb:paintRect(lx0, ly, bx + round(bw * l[2]) - lx0, l[3], Blitbuffer.COLOR_BLACK)
        ly = ly + l[3] + gap
    end
end

local function evenLines(n, x0, x1, t)
    local lines = {}
    for i = 1, n do lines[i] = { x0, x1, t } end
    return lines
end

-- Themes ---------------------------------------------------------------------------

function AaPanel:themes()
    local list = {}
    for __, t in ipairs(G_reader_settings:readSetting("voyage_themes") or {}) do
        table.insert(list, { name = t.name, icon = "custom", saved = t })
    end
    for __, p in ipairs(PRESETS) do table.insert(list, { name = p.name, icon = p.icon, preset = p }) end
    return list
end

local function matches(theme, cur)
    local t = theme.saved or theme.preset
    return t.size == cur.size and t.spacing == cur.spacing and t.h == cur.h and t.t == cur.t
        and (not t.font or t.font == cur.font) and (t.weight == nil or t.weight == cur.weight)
end

function AaPanel:paintThemeIcon(bb, bx, by, s, icon)
    local u = self.u
    if icon == "compact" then
        self:pageIcon(bb, bx, by, s, s, self.thick, evenLines(8, 0.2, 0.8, math.max(1, round(2 * u))), round(4 * u))
    elseif icon == "standard" then
        self:pageIcon(bb, bx, by, s, s, self.thick, evenLines(5, 0.2, 0.8, math.max(1, round(2 * u))), round(7 * u))
    elseif icon == "large" then
        self:pageIcon(bb, bx, by, s, s, self.thick, evenLines(3, 0.2, 0.8, round(5 * u)), round(9 * u))
    else
        bb:paintBorder(bx, by, s, s, self.thick, Blitbuffer.COLOR_BLACK, round(10 * u))
        local a = self:text("A", Fonts.face("ui", 22))
        a:paintTo(bb, bx + round((s - a:getSize().w) / 2), by + round((s - a:getSize().h) / 2))
    end
end

function AaPanel:paintThemes(bb, x, y)
    local u, cy0 = self.u, y + self.content_y
    local cur = self:shown()
    local items = self:themes()
    local selected
    for i, t in ipairs(items) do
        if matches(t, cur) then selected = i break end
    end
    if not selected then
        table.insert(items, 1, { name = _("Custom"), icon = "custom", custom = true })
        selected = 1
    end

    local s = round(76 * u)
    for i, t in ipairs(items) do
        if i > 6 then break end
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local bx = x + round((82 + col * 470) * u)
        local by = cy0 + round((72 + row * 158) * u)
        self:paintThemeIcon(bb, bx, by, s, t.icon)
        local is_sel = i == selected
        local name = self:text(t.name, is_sel and self.face_bold or self.face_text, round(330 * u))
        local tx = bx + s + round(24 * u)
        if is_sel then
            -- Check mark over the icon's top-left corner, "Current Theme" under the name.
            local check = self.plugin:icon("check", round(46 * u))
            check:paintTo(bb, bx - round(18 * u), by - round(22 * u))
            check:free()
            local sub = self:text(_("Current Theme"), self.face_italic)
            local total = name:getSize().h + sub:getSize().h
            name:paintTo(bb, tx, by + round((s - total) / 2))
            sub:paintTo(bb, tx, by + round((s - total) / 2) + name:getSize().h)
        else
            name:paintTo(bb, tx, by + round((s - name:getSize().h) / 2))
        end
        if not t.custom then
            self:hit(Geom:new{ x = bx - round(30 * u), y = by - round(30 * u), w = round(470 * u), h = s + round(60 * u) },
                function() self:applyTheme(t.saved or t.preset) end)
        end
    end

    -- Save Current Settings
    local btn = Geom:new{ x = round(53 * u), y = self.content_y + round(517 * u), w = round(964 * u), h = round(92 * u) }
    bb:paintBorder(x + btn.x, y + btn.y, btn.w, btn.h, self.line, Blitbuffer.COLOR_BLACK)
    local save = self:text(_("Save Current Settings"), self.face_text)
    save:paintTo(bb, x + btn.x + round((btn.w - save:getSize().w) / 2), y + btn.y + round((btn.h - save:getSize().h) / 2))
    self:hit(btn, function() self:saveTheme() end)

    -- Manage Themes
    local my = self.content_y + round(645 * u)
    bb:paintRect(x + round(53 * u), y + my, round(964 * u), self.thick, Blitbuffer.COLOR_BLACK)
    self:chevronRow(bb, x, y, my + self.thick, round(112 * u), _("Manage Themes"), nil, function() self:manageThemes() end)
end

function AaPanel:chevronRow(bb, x, y, ry, rh, label, value, fn)
    local u = self.u
    local l = self:text(label, self.face_text)
    l:paintTo(bb, x + round(53 * u), y + ry + round((rh - l:getSize().h) / 2))
    local chev = self:text("›", self.face_sign)
    local cx = x + self.W - round(80 * u)
    chev:paintTo(bb, cx, y + ry + round((rh - chev:getSize().h) / 2))
    if value then
        local v = self:text(value, self.face_text)
        v:paintTo(bb, cx - round(24 * u) - v:getSize().w, y + ry + round((rh - v:getSize().h) / 2))
    end
    self:hit(Geom:new{ x = 0, y = ry, w = self.W, h = rh }, fn)
end

function AaPanel:saveTheme()
    UIManager:show(Prompt:new{
        title = _("Save Current Settings"),
        hint = _("Theme name"),
        ok_text = _("Save"),
        on_ok = function(name)
            if not name:match("%S") then return false end
            local cur = self:shown()
            cur.name = name
            local themes = G_reader_settings:readSetting("voyage_themes") or {}
            table.insert(themes, cur)
            G_reader_settings:saveSetting("voyage_themes", themes)
            self:refresh()
        end,
    })
end

function AaPanel:manageThemes()
    self:openSubview("themes")
end

function AaPanel:deleteTheme(i)
    local themes = G_reader_settings:readSetting("voyage_themes") or {}
    if not themes[i] then return end
    UIManager:show(Dialog:new{
        title = string.format(_("Delete “%s”?"), themes[i].name),
        text = _("Your current settings won't change."),
        buttons = {
            { text = _("Cancel") },
            { text = _("Delete"), bold = true, callback = function()
                table.remove(themes, i)
                G_reader_settings:saveSetting("voyage_themes", themes)
                self:refresh()
            end },
        },
    })
end

-- Font -----------------------------------------------------------------------------

function AaPanel:fontList()
    local cre = require("document/credocument"):engineInit()
    local list = {}
    for __, name in ipairs(cre.getFontFaces()) do
        local file, index = cre.getFontFaceFilenameAndFaceIndex(name)
        -- On a Kindle, offer its own fonts and sideloaded ones (like the Kindle does); elsewhere,
        -- whatever KOReader has, minus KOReader's UI/symbol fonts.
        local hidden
        if Device:isKindle() then
            -- (Primer's bundled fonts count too: KOReader may resolve Literata/Bitter to those copies.)
            hidden = not file or not (file:find("^/usr/java/lib/fonts/") or file:find("^/mnt/us/fonts/")
                or file:find("fonts/primer/", 1, true))
        else
            hidden = not file or file:find("nerdfonts", 1, true) ~= nil
        end
        for __, pat in ipairs(HIDDEN_FONTS) do
            if name:find(pat, 1, true) then hidden = true end
        end
        if not hidden then
            table.insert(list, { name = name, label = FONT_NAMES[name] or name, file = file, index = index })
        end
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    return list
end

function AaPanel:fontFace(name, size)
    local cre = require("document/credocument"):engineInit()
    local file = cre.getFontFaceFilenameAndFaceIndex(name)
    if file then
        local ok, f = pcall(Font.getFace, Font, file, size)
        if ok and f then return f end
    end
    return self.face_text
end

function AaPanel:paintSteps(bb, x, y, cy, n, level, seg_w, gap, on_step)
    local u = self.u
    local x0 = round(413 * u)
    local h = round(14 * u)
    for i = 1, n do
        local sx = x0 + (i - 1) * (seg_w + gap)
        if i <= level then
            bb:paintRect(x + sx, y + cy - round(h / 2), seg_w, h, Blitbuffer.COLOR_BLACK)
        else
            bb:paintBorder(x + sx, y + cy - round(h / 2), seg_w, h, self.line, Blitbuffer.COLOR_BLACK)
        end
        if i == level then
            local v = self:text(tostring(level), self.face_value)
            v:paintTo(bb, x + sx + round((seg_w - v:getSize().w) / 2), y + cy - round(h / 2) - round(6 * u) - v:getSize().h)
        end
        self:hit(Geom:new{ x = sx - round(gap / 2), y = cy - round(40 * u), w = seg_w + gap, h = round(80 * u) },
            function() on_step(i) end)
    end
    local minus = self:text("—", self.face_text)
    minus:paintTo(bb, x + round(338 * u), y + cy - round(minus:getSize().h / 2))
    local plus = self:text("+", self.face_sign)
    plus:paintTo(bb, x + round(945 * u), y + cy - round(plus:getSize().h / 2))
    self:hit(Geom:new{ x = round(300 * u), y = cy - round(50 * u), w = round(100 * u), h = round(100 * u) },
        function() on_step(math.max(1, level - 1)) end)
    self:hit(Geom:new{ x = round(920 * u), y = cy - round(50 * u), w = round(152 * u), h = round(100 * u) },
        function() on_step(math.min(n, level + 1)) end)
end

function AaPanel:paintFont(bb, x, y)
    local u, cy0 = self.u, self.content_y
    local cur = self:shown()
    local divider = function(dy) bb:paintRect(x + round(62 * u), y + dy, round(946 * u), self.line, Blitbuffer.COLOR_BLACK) end

    -- Font Family
    local row_h = round(168 * u)
    local label = self:text(_("Font Family"), self.face_text)
    label:paintTo(bb, x + round(62 * u), y + cy0 + round((row_h - label:getSize().h) / 2))
    local fname = FONT_NAMES[cur.font] or cur.font or ""
    local chev = self:text("›", self.face_sign)
    local right = x + self.W - round(90 * u)
    chev:paintTo(bb, right, y + cy0 + round((row_h - chev:getSize().h) / 2))
    local name_w = self:text("— " .. fname, self:fontFace(cur.font, 18))
    local nx = right - round(28 * u) - name_w:getSize().w
    name_w:paintTo(bb, nx, y + cy0 + round((row_h - name_w:getSize().h) / 2))
    local aa = self:text("Aa", self:fontFace(cur.font, 40))
    aa:paintTo(bb, nx - round(12 * u) - aa:getSize().w, y + cy0 + round((row_h - aa:getSize().h) / 2))
    self:hit(Geom:new{ x = 0, y = cy0, w = self.W, h = row_h }, function() self:openSubview("fonts") end)
    divider(cy0 + row_h)

    -- Bold
    local bold_cy = cy0 + round(252 * u)
    local b = self:text(_("Bold"), self.face_text)
    b:paintTo(bb, x + round(62 * u), y + bold_cy - round(b:getSize().h / 2))
    self:paintSteps(bb, x, y, bold_cy, #WEIGHTS, nearest(WEIGHTS, cur.weight), round(90 * u), round(10 * u),
        function(i) self:queue{ weight = WEIGHTS[i] } end)
    divider(cy0 + round(336 * u))

    -- Size
    local size_cy = cy0 + round(420 * u)
    local s = self:text(_("Size"), self.face_text)
    s:paintTo(bb, x + round(62 * u), y + size_cy - round(s:getSize().h / 2))
    self:paintSteps(bb, x, y, size_cy, #SIZES, nearest(SIZES, cur.size), round(26 * u), round(10 * u),
        function(i) self:queue{ size = SIZES[i] } end)
end

-- Layout ---------------------------------------------------------------------------

function AaPanel:isLeftAligned()
    local st = self.ui.styletweak
    return st and st:isTweakEnabled("text_align_most_left") or false
end

function AaPanel:paintLayout(bb, x, y)
    local u, cy0 = self.u, self.content_y
    local cur = self:shown()
    local thin, thickb = self.line, round(5 * u)
    local L = math.max(1, round(2 * u))
    local function label(str, lx, ly)
        local w = self:text(str, self.face_text)
        w:paintTo(bb, x + round(lx * u), y + cy0 + round(ly * u) - round(w:getSize().h / 2))
    end
    local function option(rect, selected, lines, gap, fn)
        self:pageIcon(bb, x + rect.x, y + rect.y, rect.w, rect.h, selected and thickb or thin, lines, gap)
        self:hit(Geom:new{ x = rect.x - round(10 * u), y = rect.y - round(10 * u), w = rect.w + round(20 * u), h = rect.h + round(20 * u) }, fn)
    end
    local box = function(lx, ly, w, h) return Geom:new{ x = round(lx * u), y = cy0 + round(ly * u), w = round(w * u), h = round(h * u) } end

    -- Orientation
    label(_("Orientation"), 57, 67)
    local landscape = Screen:getRotationMode() % 2 == 1
    option(box(57, 127, 86, 116), not landscape, evenLines(6, 0.22, 0.78, L), round(10 * u), function() self:setLandscape(false) end)
    option(box(172, 127, 117, 86), landscape, evenLines(5, 0.15, 0.85, L), round(7 * u), function() self:setLandscape(true) end)

    -- Margins
    label(_("Margins"), 478, 67)
    local m = nearest(MARGINS, cur.h, "h")
    local insets = { 0.08, 0.15, 0.25 }
    for i, inset in ipairs(insets) do
        option(box(478 + (i - 1) * 168, 127, 138, 77), m == i, evenLines(6, inset, 1 - inset, L), round(4 * u),
            function() self:apply{ h = MARGINS[i].h, t = MARGINS[i].t } end)
    end

    -- Alignment
    label(_("Alignment"), 57, 333)
    local left = self:isLeftAligned()
    option(box(57, 393, 138, 77), not left, evenLines(4, 0.15, 0.85, L), round(7 * u), function() self:setLeftAligned(false) end)
    option(box(225, 393, 138, 77), left, { { 0.15, 0.85, L }, { 0.15, 0.7, L }, { 0.15, 0.8, L }, { 0.15, 0.62, L } },
        round(7 * u), function() self:setLeftAligned(true) end)

    -- Spacing
    label(_("Spacing"), 478, 333)
    local sp = nearest(SPACINGS, cur.spacing)
    local gaps = { 6, 10, 15 }
    for i, g in ipairs(gaps) do
        option(box(478 + (i - 1) * 168, 393, 138, 77), sp == i, evenLines(4 - (i == 3 and 1 or 0), 0.15, 0.85, L), round(g * u),
            function() self:apply{ spacing = SPACINGS[i] } end)
    end
end

-- More -----------------------------------------------------------------------------

function AaPanel:paintToggle(bb, tx, ty, on)
    local u = self.u
    local w, h = round(104 * u), round(56 * u)
    local r = round(h / 2)
    local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    if on then
        bb:paintRoundedRect(tx, ty, w, h, BLACK, r)
        bb:paintCircle(tx + w - r, ty + r, r - round(5 * u), WHITE)
    else
        bb:paintBorder(tx, ty, w, h, self.line, BLACK, r)
        bb:paintCircle(tx + r, ty + r, r, BLACK, self.thick)
    end
end

function AaPanel:paintMore(bb, x, y)
    local u, cy0 = self.u, self.content_y
    local divider = function(dy) bb:paintRect(x + round(62 * u), y + dy, round(884 * u), self.line, Blitbuffer.COLOR_BLACK) end
    local progress = G_reader_settings:readSetting("voyage_reading_progress") or "page"
    local progress_label = PROGRESS[1].label
    for __, p in ipairs(PROGRESS) do if p.id == progress then progress_label = p.label end end

    local row = round(192 * u)
    self:chevronRow(bb, x, y, cy0, row, _("Reading Progress"), progress_label, function() self:openSubview("progress") end)
    divider(cy0 + row)

    local function toggleRow(ry, title, subtitle, on, fn)
        local t = self:text(title, self.face_text)
        local total = t:getSize().h
        local sub
        if subtitle then
            sub = TextWidget:new{ text = subtitle, face = self.face_small, max_width = round(700 * u) }
            total = total + sub:getSize().h
        end
        local ty = y + ry + round((row - total) / 2)
        t:paintTo(bb, x + round(62 * u), ty)
        if sub then
            sub:paintTo(bb, x + round(62 * u), ty + t:getSize().h)
            sub:free()
        end
        self:paintToggle(bb, x + round(840 * u), y + ry + round((row - 56 * u) / 2), on)
        self:hit(Geom:new{ x = 0, y = ry, w = self.W, h = row }, fn)
    end

    toggleRow(cy0 + row + self.line, _("Show Clock While Reading"), nil, G_reader_settings:isTrue("voyage_show_clock"), function()
        G_reader_settings:flipNilOrFalse("voyage_show_clock")
        self.plugin:onClockSettingChanged()
        self:refresh()
    end)
    divider(cy0 + 2 * row + self.line)

    local menu_on = G_reader_settings:readSetting("default_highlight_action", "ask") == "ask"
    toggleRow(cy0 + 2 * row + 2 * self.line, _("Highlight Menu"), _("Show the highlight menu when you select text."), menu_on, function()
        G_reader_settings:saveSetting("default_highlight_action", menu_on and "highlight" or "ask")
        self:refresh()
    end)
end

-- Subviews (font list, reading progress choices, saved themes) ---------------------

function AaPanel:openSubview(kind)
    self.subview = kind
    self.sub_page = 1
    if kind == "fonts" then self.sub_items = self:fontList() end
    self:refresh()
end

function AaPanel:paintSubview(bb, x, y)
    local u = self.u
    local row_h = round(104 * u)
    local head_y = self.top_y + self.thick
    local title = self.subview == "fonts" and _("Font Family") or self.subview == "themes" and _("Manage Themes")
        or _("Reading Progress")
    local back = self:text("‹  " .. title, self.face_bold)
    back:paintTo(bb, x + round(53 * u), y + head_y + round((self.tab_h - back:getSize().h) / 2))
    self:hit(Geom:new{ x = 0, y = self.top_y, w = round(self.W * 0.7), h = self.tab_h }, function()
        self.subview = nil
        self:refresh()
    end)
    bb:paintRect(x, y + self.content_y, self.W, self.line, Blitbuffer.COLOR_BLACK)

    local items, selected
    if self.subview == "fonts" then
        items = self.sub_items
        selected = self.ui.font.font_face
    elseif self.subview == "themes" then
        items = {}
        for i, t in ipairs(G_reader_settings:readSetting("voyage_themes") or {}) do
            items[i] = { id = i, label = t.name }
        end
        if #items == 0 then
            local none = self:text(_("No saved themes yet. Use Save Current Settings."), self.face_italic, round(self.W * 0.85))
            none:paintTo(bb, x + round(62 * u), y + self.content_y + round(60 * u))
        end
    else
        items = PROGRESS
        selected = G_reader_settings:readSetting("voyage_reading_progress") or "page"
    end
    local per_page = math.max(1, math.floor((self.H - self.content_y - round(20 * u)) / row_h))
    local pages = math.max(1, math.ceil(#items / per_page))
    self.sub_page = math.min(self.sub_page, pages)
    self.sub_pages = pages
    if pages > 1 then
        local pg = self:text(string.format("%d / %d", self.sub_page, pages), self.face_small)
        pg:paintTo(bb, x + self.W - round(53 * u) - pg:getSize().w, y + head_y + round((self.tab_h - pg:getSize().h) / 2))
    end

    local first = (self.sub_page - 1) * per_page + 1
    for i = first, math.min(#items, first + per_page - 1) do
        local item = items[i]
        local ry = self.content_y + self.line + (i - first) * row_h
        local is_sel = (item.name or item.id) == selected
        local f = self.subview == "fonts" and self:fontFace(item.name, 20) or self.face_text
        local t = self:text(item.label, f, round(self.W * 0.7))
        t:paintTo(bb, x + round(62 * u), y + ry + round((row_h - t:getSize().h) / 2))
        if self.subview == "themes" then
            local del = self:text(_("Delete"), self.face_text)
            del:paintTo(bb, x + self.W - round(62 * u) - del:getSize().w, y + ry + round((row_h - del:getSize().h) / 2))
        elseif is_sel then
            local check = self.plugin:icon("check", round(44 * u))
            check:paintTo(bb, x + self.W - round(110 * u), y + ry + round((row_h - 44 * u) / 2))
            check:free()
        end
        bb:paintRect(x + round(62 * u), y + ry + row_h - self.line, round(946 * u), self.line, Blitbuffer.COLOR_LIGHT_GRAY)
        self:hit(Geom:new{ x = 0, y = ry, w = self.W, h = row_h }, function()
            if self.subview == "themes" then
                return self:deleteTheme(item.id)
            elseif self.subview == "fonts" then
                self:apply{ font = item.name }
            else
                G_reader_settings:saveSetting("voyage_reading_progress", item.id)
                self.ui:handleEvent(Event:new("UpdateFooter", true, true))
            end
            self.subview = nil
            self:refresh()
        end)
    end
end

-- Applying settings ----------------------------------------------------------------

-- Size and Bold: show the new step at once, apply once the taps stop.
function AaPanel:queue(s)
    self.pending = self.pending or {}
    for k, v in pairs(s) do self.pending[k] = v end
    self:refresh()
    self.commit_task = self.commit_task or function() self:apply{} end
    UIManager:unschedule(self.commit_task)
    UIManager:scheduleIn(APPLY_DELAY_S, self.commit_task)
end

-- Apply to the open book (with anything queued) and save as the default for all books.
function AaPanel:apply(s)
    if self.pending then
        UIManager:unschedule(self.commit_task)
        local merged = self.pending
        self.pending = nil
        for k, v in pairs(s) do merged[k] = v end
        s = merged
    end
    local ui, conf = self.ui, self.ui.document.configurable
    if s.font and s.font ~= ui.font.font_face then
        ui.font:onSetFont(s.font)
        G_reader_settings:saveSetting("cre_font", s.font)
    end
    if s.size and s.size ~= conf.font_size then
        setFontSize(ui, s.size)
    end
    if s.weight and s.weight ~= conf.font_base_weight then
        ui.font:onSetFontBaseWeight(s.weight)
        G_reader_settings:saveSetting("copt_font_base_weight", s.weight)
    end
    if s.spacing and s.spacing ~= conf.line_spacing then
        ui.font:onSetLineSpace(s.spacing)
        G_reader_settings:saveSetting("copt_line_spacing", s.spacing)
    end
    local h = conf.h_page_margins and conf.h_page_margins[1]
    if (s.h and s.h ~= h) or (s.t and s.t ~= conf.t_page_margin) then
        local nh, nt = s.h or h, s.t or conf.t_page_margin
        conf.h_page_margins = { nh, nh }
        conf.t_page_margin = nt
        ui.typeset.unscaled_margins[2] = nt
        -- Horizontal margins via their own event so the footer re-aligns to the text.
        ui:handleEvent(Event:new("SetPageHorizMargins", { nh, nh }))
        G_reader_settings:saveSetting("copt_h_page_margins", { nh, nh })
        G_reader_settings:saveSetting("copt_t_page_margin", nt)
    end
    if not self.closed then self:refresh() end
end

function AaPanel:applyTheme(t)
    self:apply{ font = t.font, size = t.size, weight = t.weight, spacing = t.spacing, h = t.h, t = t.t }
end

function AaPanel:setLeftAligned(left)
    local st = self.ui.styletweak
    if not st then return end
    for id, on in pairs({ text_align_most_left = left, text_align_most_justify = not left }) do
        st.global_tweaks[id] = on or nil
        st.doc_tweaks[id] = nil
    end
    G_reader_settings:saveSetting("style_tweaks", st.global_tweaks)
    st:updateCssText(true)
    self:refresh()
end

function AaPanel:setLandscape(landscape)
    local mode = landscape and Screen.DEVICE_ROTATED_CLOCKWISE or Screen.DEVICE_ROTATED_UPRIGHT
    if mode == Screen:getRotationMode() then return end
    -- The panel is laid out for the current orientation, so close it first.
    self:onClose()
    UIManager:nextTick(function() self.ui:handleEvent(Event:new("SetRotationMode", mode)) end)
end

-- Gestures -------------------------------------------------------------------------

function AaPanel:refresh()
    UIManager:setDirty(self, function() return "ui", self.sheet end)
end

function AaPanel:onTap(__, ges)
    if not inside(ges.pos, self.sheet) then
        return self:onClose()
    end
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if inside(ges.pos, h.rect) then
            h.fn()
            return true
        end
    end
    return true
end

function AaPanel:onSwipe(__, ges)
    if self.subview and self.sub_pages and self.sub_pages > 1 and inside(ges.pos, self.sheet) then
        if ges.direction == "north" or ges.direction == "west" then
            self.sub_page = math.min(self.sub_page + 1, self.sub_pages)
        elseif ges.direction == "south" or ges.direction == "east" then
            self.sub_page = math.max(self.sub_page - 1, 1)
        end
        self:refresh()
        return true
    end
    if ges.direction == "south" then
        return self:onClose()
    end
    return true
end

function AaPanel:onShow()
    self:refresh()
    return true
end

function AaPanel:onClose()
    UIManager:close(self)
    return true
end

function AaPanel:onCloseWidget()
    self.closed = true
    if self.pending then self:apply{} end
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.plugin.aapanel = nil
    UIManager:setDirty(nil, function() return "ui", self.sheet end)
end

return AaPanel
