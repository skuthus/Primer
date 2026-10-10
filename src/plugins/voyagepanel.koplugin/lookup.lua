--[[--
Kindle-style word lookup. Long-pressing a word shows a dictionary card on the opposite
half of the screen (bold headword, italic part of speech, numbered senses, "Dictionary"
header, dictionary name at the bottom) plus a selection bar next to the word:
Highlight | Note | Copy | Search | ⋮. A multi-word selection shows just the bar.
Tapping anywhere else dismisses both and clears the selection.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FontChooser = require("ui/widget/fontchooser")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local EMBER = "/usr/java/lib/fonts/Amazon-Ember-Regular.ttf"
local EMBER_BOLD = "/usr/java/lib/fonts/Amazon-Ember-Bold.ttf"
local SERIF = "/usr/java/lib/fonts/Bookerly-Regular.ttf"
local SERIF_BOLD = "/usr/java/lib/fonts/Bookerly-Bold.ttf"
local SERIF_ITALIC = "/usr/java/lib/fonts/Bookerly-Italic.ttf"

local function face(file, size)
    if FontChooser.isFontRegistered(file) then return Font:getFace(file, size) end
    return Font:getFace("cfont", size)
end

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
local function plain(html)
    local s = html:gsub("<[^>]*>", ""):gsub("&(#?%w+);", function(e)
        if e:sub(1, 1) == "#" then
            local hex = e:sub(2, 2):lower() == "x"
            local n = hex and tonumber(e:sub(3), 16) or tonumber(e:sub(2))
            return n and util.unicodeCodepointToUtf8(n) or ""
        end
        return ENTITIES[e] or ("&" .. e .. ";")
    end)
    return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Turn a dictionary entry into blocks: { kind = "pos"|"sense"|"text", text, number, depth }.
-- Handles the simple markup these dictionaries use (<i>, <b>, <br>, <ol>/<ul>/<li>); plain text
-- entries come through as paragraphs.
local function parseDefinition(definition, is_html)
    local blocks = {}
    if not is_html then
        for para in (definition .. "\n"):gmatch("(.-)\n") do
            if para:match("%S") then table.insert(blocks, { kind = "text", text = para }) end
        end
        return blocks
    end
    local counters, depth = {}, 0
    local pending = ""
    local function flush()
        local t = plain(pending)
        if t ~= "" then table.insert(blocks, { kind = "text", text = t }) end
        pending = ""
    end
    local pos = 1
    while pos <= #definition do
        local s, e, tag = definition:find("<(/?%w+)[^>]*>", pos)
        if not s then
            pending = pending .. definition:sub(pos)
            break
        end
        pending = pending .. definition:sub(pos, s - 1)
        tag = tag:lower()
        if tag == "ol" or tag == "ul" then
            flush()
            depth = depth + 1
            counters[depth] = tag == "ol" and 0 or false
        elseif tag == "/ol" or tag == "/ul" then
            flush()
            depth = math.max(0, depth - 1)
        elseif tag == "li" then
            flush()
            local li_end = definition:find("<[/]?[ou]l[^>]*>", e + 1) or (#definition + 1)
            local close = definition:find("</li>", e + 1, true)
            local stop = close and close < li_end and close or li_end
            local n
            if counters[depth] then
                counters[depth] = counters[depth] + 1
                n = counters[depth]
            end
            local t = plain(definition:sub(e + 1, stop - 1))
            if t ~= "" then table.insert(blocks, { kind = "sense", text = t, number = n, depth = depth }) end
            e = (close and close < li_end) and (close + 4) or (li_end - 1)
        elseif tag == "i" and #plain(pending) == 0 then
            -- An italic run on its own line is a part of speech ("adj", "noun").
            local close = definition:find("</i>", e + 1, true)
            if close then
                local t = plain(definition:sub(e + 1, close - 1))
                local after = definition:sub(close + 4, close + 8):lower()
                if t ~= "" and (after:find("^<br") or after:find("^<ol") or after:find("^<ul") or after == "") then
                    table.insert(blocks, { kind = "pos", text = t })
                    e = close + 3
                else
                    pending = pending .. definition:sub(e + 1, close - 1)
                    e = close + 3
                end
            end
        elseif tag == "br" or tag == "p" or tag == "/p" or tag == "div" or tag == "/div" then
            flush()
        end
        pos = e + 1
    end
    flush()
    return blocks
end

-- KOReader highlight-dialog entries the ⋮ menu leaves out: unused here, or already on the bar.
local HIDDEN_MENU_ITEMS = {
    ["01_select"] = true, ["02_highlight"] = true, ["03_copy"] = true, ["04_add_note"] = true,
    ["05_wikipedia"] = true, ["06_dictionary"] = true, ["07_translate"] = true,
    ["09_view_html"] = true, ["12_generate_qr_code"] = true, ["12_search"] = true,
}

-- "English-English Wiktionary dictionary (en-en)" -> "Wiktionary"
local function shortDictName(name)
    if not name or name == "" then return _("Dictionary") end
    if name:find("Wiktionary") then return "Wiktionary" end
    return (name:gsub("%s*%b()", ""):gsub("[Dd]ictionary", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local Lookup = InputContainer:extend{
    plugin = nil,
    highlight = nil,    -- ReaderHighlight
    word = nil,
    results = nil,      -- dictionary results, nil for a multi-word selection (bar only)
    boxes = nil,        -- screen boxes of the selection
    full_lookup = nil,  -- function: open KOReader's full lookup window
}

function Lookup:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.u = self.W / 1072
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.cache = {}
    self.result_idx = 1
    self.page = 1

    local screen = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        local close = {}
        for __, group in ipairs({ "Back", "PgFwd", "PgBack" }) do
            if Device.input.group[group] then table.insert(close, { Device.input.group[group] }) end
        end
        self.key_events.Close = close
    end

    self.face_header = face(EMBER_BOLD, 17)
    self.face_footer = face(EMBER_BOLD, 13)
    self.face_head = face(SERIF_BOLD, 19)
    self.face_pos = face(SERIF_ITALIC, 17)
    self.face_body = face(SERIF, 17)
    self.face_button = face(EMBER_BOLD, 18)

    self:layout()
    if self.results then self:buildCard() end
end

function Lookup:selectionBox()
    local boxes = self.boxes
    if not boxes or not boxes[1] then return nil end
    return Geom.boundingBox(boxes)
end

function Lookup:layout()
    local u, W, H = self.u, self.W, self.H
    local sel = self:selectionBox()
    local sel_cy = sel and (sel.y + sel.h / 2) or H / 2

    -- Card on the half away from the word.
    if self.results then
        local margin = round(W * 0.06)
        local card_h = round(H * 0.4)
        local y = sel_cy > H / 2 and round(H * 0.035) or (H - card_h - round(H * 0.045))
        self.card = Geom:new{ x = margin, y = y, w = W - 2 * margin, h = card_h }
    end

    -- Selection bar right under the word, or above it if there's no room
    -- (only when the lookup came from a text selection).
    if not self.highlight then return end
    self.bar_h = round(80 * u)
    local labels = { _("Highlight"), _("Note"), _("Copy") }
    self.bar_items = {}
    local x = 0
    for i, label in ipairs(labels) do
        local w = self:text(label, self.face_button):getSize().w + round(56 * u)
        self.bar_items[i] = { id = ({ "highlight", "note", "copy" })[i], label = label, x = x, w = w }
        x = x + w
    end
    -- ⋮ only when there's something beyond the bar (Follow Link, Hyphenate, plugin extras).
    self.menu_items = self:extraMenuItems()
    for __, icon in ipairs(#self.menu_items > 0 and { "search", "kebab" } or { "search" }) do
        local w = round(100 * u)
        table.insert(self.bar_items, { id = icon, icon = icon, x = x, w = w })
        x = x + w
    end
    local bar_w = x
    local gap = round(16 * u)
    local bx = sel and (sel.x + sel.w / 2 - bar_w / 2) or (W - bar_w) / 2
    bx = round(math.min(math.max(bx, round(20 * u)), W - bar_w - round(20 * u)))
    local by
    if sel then
        by = sel.y + sel.h + gap
        local clash = self.card and by + self.bar_h > self.card.y and by < self.card.y + self.card.h
        if by + self.bar_h > H - round(20 * u) or clash then
            by = sel.y - gap - self.bar_h
        end
    else
        by = round(H * 0.6)
    end
    self.bar = Geom:new{ x = bx, y = round(by), w = bar_w, h = self.bar_h }
end

-- KOReader's highlight-dialog buttons that apply to this selection, minus the hidden ones.
function Lookup:extraMenuItems()
    local hl, items = self.highlight, {}
    if not (hl and hl._highlight_buttons and hl.selected_text) then return items end
    for id, make in ffiUtil.orderedPairs(hl._highlight_buttons) do
        if not HIDDEN_MENU_ITEMS[id] then
            local ok, button = pcall(make, hl)
            if ok and button and button.text and button.callback
                    and (not button.show_in_highlight_dialog_func or button.show_in_highlight_dialog_func()) then
                table.insert(items, { text = button.text, callback = button.callback })
            end
        end
    end
    return items
end

-- Dropdown under (or over) the ⋮ button, styled like the bar.
function Lookup:layoutMenu()
    local u, b = self.u, self.bar
    local row_h = round(84 * u)
    local w = round(360 * u)
    for __, item in ipairs(self.menu_items) do
        w = math.max(w, self:text(item.text, self.face_button):getSize().w + round(80 * u))
    end
    local h = row_h * #self.menu_items
    local kebab = self.bar_items[#self.bar_items]
    local x = math.min(b.x + kebab.x + kebab.w - w, self.W - w - round(20 * u))
    x = math.max(x, round(20 * u))
    local y = b.y + b.h - math.max(1, round(2 * u))
    if y + h > self.H - round(20 * u) then y = b.y - h + math.max(1, round(2 * u)) end
    self.menu = Geom:new{ x = round(x), y = round(y), w = w, h = h }
    self.menu_row_h = row_h
end

function Lookup:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

-- Parse the current result into blocks. Widgets are laid out lazily, a page at a time:
-- entries like "run" have 100+ senses and laying them all out up front is slow on e-ink.
function Lookup:buildCard()
    local u, card = self.u, self.card
    self:freeBlocks()
    local result = self.results[self.result_idx] or {}
    self.pad = round(34 * u)
    self.header_h = round(66 * u)
    self.footer_h = round(56 * u)
    self.body_top = card.y + self.header_h + round(18 * u)
    self.body_h = card.h - self.header_h - self.footer_h - round(30 * u)
    self.text_w = card.w - 2 * self.pad - round(24 * u) -- room for the scrollbar

    local blocks = { { kind = "head", text = result.word or self.word or "" } }
    for __, b in ipairs(parseDefinition(result.definition or "", result.is_html)) do table.insert(blocks, b) end
    self.blocks = blocks
    self.page_starts = { 1 }
    self.page = 1
end

function Lookup:layoutBlock(b)
    if b.widget then return b end
    local u = self.u
    local indent, f, prefix = 0, self.face_body, nil
    if b.kind == "head" then f = self.face_head
    elseif b.kind == "pos" then f, indent = self.face_pos, round(20 * u)
    elseif b.kind == "sense" then
        indent = round((20 + 24 * (b.depth or 1)) * u)
        prefix = b.number and (b.number .. ".") or "•"
    end
    b.indent = indent
    if prefix then
        b.prefix = self:text(prefix, self.face_body)
        b.prefix_w = round(36 * u)
    end
    b.widget = TextBoxWidget:new{ text = b.text, face = f, width = self.text_w - indent - (b.prefix_w or 0) }
    b.h = b.widget:getSize().h + round((b.kind == "head" and 8 or 4) * u)
    return b
end

-- Last block index that fits on the page starting at `first`.
function Lookup:pageEnd(first)
    local used, last = 0, first
    for i = first, #self.blocks do
        local h = self:layoutBlock(self.blocks[i]).h
        if used > 0 and used + h > self.body_h then break end
        used, last = used + h, i
    end
    return last
end

function Lookup:hasNextPage()
    return self:pageEnd(self.page_starts[self.page]) < #self.blocks
end

function Lookup:nextPage()
    if not self:hasNextPage() then return false end
    local next_start = self:pageEnd(self.page_starts[self.page]) + 1
    self.page = self.page + 1
    self.page_starts[self.page] = next_start
    return true
end

function Lookup:prevPage()
    if self.page <= 1 then return false end
    self.page = self.page - 1
    return true
end

function Lookup:freeBlocks()
    for __, b in ipairs(self.blocks or {}) do
        if b.widget then b.widget:free() b.widget = nil end
    end
end

function Lookup:paintTo(bb, x, y)
    local ok, err = pcall(self.paintLookup, self, bb, x, y)
    if not ok then
        logger.err("VoyageLookup: paint failed:", err)
        UIManager:nextTick(function() self:dismiss() end)
    end
end

function Lookup:paintLookup(bb, x, y)
    local u = self.u
    local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local border = math.max(2, round(3 * u))
    local line = math.max(1, round(2 * u))

    if self.card then
        local c = self.card
        bb:paintRect(x + c.x, y + c.y, c.w, c.h, WHITE)
        bb:paintBorder(x + c.x, y + c.y, c.w, c.h, border, BLACK)
        -- Header
        local multi = #self.results > 1
        local header = self:text(multi and (_("Dictionary") .. "  ▾") or _("Dictionary"), self.face_header)
        header:paintTo(bb, x + c.x + round(18 * u), y + c.y + round((self.header_h - header:getSize().h) / 2))
        bb:paintRect(x + c.x + round(18 * u), y + c.y + self.header_h, c.w - round(36 * u), line, Blitbuffer.COLOR_GRAY)
        if multi then
            -- Dots: one per result, filled for the one shown.
            local r, spacing = round(7 * u), round(26 * u)
            local dx = x + c.x + c.w / 2 - (#self.results - 1) * spacing / 2
            for i = 1, #self.results do
                bb:paintCircle(round(dx + (i - 1) * spacing), y + c.y - round(18 * u), r,
                    i == self.result_idx and BLACK or Blitbuffer.COLOR_GRAY)
            end
        end
        -- Body (current page)
        local first = self.page_starts[self.page]
        local last = self:pageEnd(first)
        local by = y + self.body_top
        for i = first, last do
            local b = self.blocks[i]
            local bx = x + c.x + self.pad + b.indent
            if b.prefix then
                b.prefix:paintTo(bb, bx, by)
                bx = bx + b.prefix_w
            end
            b.widget:paintTo(bb, bx, by)
            by = by + b.h
        end
        -- Scrollbar when the entry runs over several pages (position by block).
        if first > 1 or last < #self.blocks then
            local sx = x + c.x + c.w - round(26 * u)
            local track_h = self.body_h
            local n = #self.blocks
            bb:paintRect(sx, y + self.body_top, line, track_h, Blitbuffer.COLOR_GRAY)
            local thumb_h = math.max(round(30 * u), round(track_h * (last - first + 1) / n))
            local ty = y + self.body_top + math.min(round(track_h * (first - 1) / n), track_h - thumb_h)
            bb:paintRect(sx - line, ty, line * 3, thumb_h, BLACK)
        end
        -- Footer: dictionary name ▸ (opens KOReader's full lookup)
        local result = self.results[self.result_idx] or {}
        local footer = self:text(shortDictName(result.dict) .. "  ▸", self.face_footer)
        self.footer_hit = Geom:new{ x = c.x + c.w / 2, y = c.y + c.h - self.footer_h, w = c.w / 2, h = self.footer_h }
        footer:paintTo(bb, x + c.x + c.w - round(24 * u) - footer:getSize().w,
            y + c.y + c.h - self.footer_h + round((self.footer_h - footer:getSize().h) / 2))
    end

    -- Selection bar
    local b = self.bar
    if not b then return end
    bb:paintRect(x + b.x, y + b.y, b.w, b.h, WHITE)
    bb:paintBorder(x + b.x, y + b.y, b.w, b.h, line, BLACK)
    for i, item in ipairs(self.bar_items) do
        local ix = x + b.x + item.x
        if i > 1 then bb:paintRect(ix, y + b.y, line, b.h, BLACK) end
        if item.icon then
            local s = round(40 * u)
            local icon = self.plugin:icon(item.icon, s)
            icon:paintTo(bb, ix + round((item.w - s) / 2), y + b.y + round((b.h - s) / 2))
            icon:free()
        else
            local t = self:text(item.label, self.face_button)
            t:paintTo(bb, ix + round((item.w - t:getSize().w) / 2), y + b.y + round((b.h - t:getSize().h) / 2))
        end
        if self.pressed == i then
            bb:invertRect(ix + line, y + b.y + line, item.w - line, b.h - 2 * line)
        end
    end

    -- ⋮ dropdown
    local m = self.menu
    if m then
        bb:paintRect(x + m.x, y + m.y, m.w, m.h, WHITE)
        bb:paintBorder(x + m.x, y + m.y, m.w, m.h, line, BLACK)
        for i, item in ipairs(self.menu_items) do
            local ry = y + m.y + (i - 1) * self.menu_row_h
            if i > 1 then bb:paintRect(x + m.x, ry, m.w, line, BLACK) end
            local t = self:text(item.text, self.face_button)
            t:paintTo(bb, x + m.x + round(40 * u), ry + round((self.menu_row_h - t:getSize().h) / 2))
            if self.menu_pressed == i then
                bb:invertRect(x + m.x + line, ry + line, m.w - 2 * line, self.menu_row_h - line)
            end
        end
    end
end

function Lookup:refresh(region, mode)
    UIManager:setDirty(self, function() return mode or "ui", region end)
end

function Lookup:refreshAll()
    if self.card then self:refresh(self.card) end
    if self.bar then self:refresh(self.bar) end
end

function Lookup:barAction(id)
    local hl = self.highlight
    if id == "highlight" then
        self:dismiss(true)
        hl:saveHighlight()
        hl:clear()
    elseif id == "note" then
        self:dismiss(true)
        hl:addNote()
    elseif id == "copy" then
        local text = hl.selected_text and hl.selected_text.text or self.word or ""
        Device.input.setClipboardText(util.cleanupSelectedText(text))
        self:dismiss()
        UIManager:show(InfoMessage:new{ text = _("Copied"), timeout = 1 })
    elseif id == "search" then
        self:dismiss(true)
        hl:onHighlightSearch()
    elseif id == "kebab" then
        -- Toggle the dropdown in place.
        self.pressed = nil
        if self.menu then
            local old = self.menu
            self.menu = nil
            UIManager:setDirty(nil, function() return "ui", old end)
            self:refresh(self.bar)
        else
            self:layoutMenu()
            self:refresh(self.bar)
            self:refresh(self.menu)
        end
    end
end

function Lookup:onTap(__, ges)
    local pos = ges.pos
    if self.menu and inside(pos, self.menu) then
        local i = math.floor((pos.y - self.menu.y) / self.menu_row_h) + 1
        local item = self.menu_items[i]
        if item then
            self.menu_pressed = i
            self:refresh(self.menu, "fast")
            UIManager:forceRePaint()
            UIManager:scheduleIn(0.12, function()
                self:dismiss(true)
                item.callback()
            end)
        end
        return true
    end
    if self.bar and inside(pos, self.bar) then
        for i, item in ipairs(self.bar_items) do
            local r = Geom:new{ x = self.bar.x + item.x, y = self.bar.y, w = item.w, h = self.bar.h }
            if inside(pos, r) then
                self.pressed = i
                self:refresh(r, "fast")
                UIManager:forceRePaint()
                UIManager:scheduleIn(0.12, function() self:barAction(item.id) end)
                return true
            end
        end
        return true
    end
    if self.card and inside(pos, self.card) then
        if self.footer_hit and inside(pos, self.footer_hit) and self.full_lookup then
            self:dismiss(true)
            self.full_lookup()
        elseif self:nextPage() then
            self:refresh(self.card)
        end
        return true
    end
    self:dismiss()
    return true
end

function Lookup:onSwipe(__, ges)
    if not (self.card and inside(ges.pos, self.card)) then
        self:dismiss()
        return true
    end
    local d, changed = ges.direction, false
    if d == "north" then
        changed = self:nextPage()
    elseif d == "south" then
        changed = self:prevPage()
    elseif (d == "west" or d == "east") and #self.results > 1 then
        local n = #self.results
        self.result_idx = (self.result_idx + (d == "west" and 1 or -1) - 1) % n + 1
        self:buildCard()
        changed = true
    end
    if changed then self:refresh(self.card) end
    return true
end

-- Close; keep the selection when an action takes over from here.
function Lookup:dismiss(keep_selection)
    self.keep_selection = keep_selection
    UIManager:close(self)
end

function Lookup:onClose()
    self:dismiss()
    return true
end

function Lookup:onShow()
    self:refreshAll()
    return true
end

function Lookup:onCloseWidget()
    self:freeBlocks()
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.plugin.lookup = nil
    if self.card then UIManager:setDirty(nil, function() return "ui", self.card end) end
    if self.bar then UIManager:setDirty(nil, function() return "ui", self.bar end) end
    if self.menu then UIManager:setDirty(nil, function() return "ui", self.menu end) end
    if self.on_close then self.on_close() end
    if not self.keep_selection and self.highlight then
        self.highlight:clear()
    end
end

return Lookup
