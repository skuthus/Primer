--[[--
Book info card, shown by long-pressing a book in the library: cover, title, author, series,
reading status, format and size, with Open / Mark as Read / Remove (to the trash). For a
trashed book: Restore / Delete Forever. Sized to its contents; the cover loads just after
the card appears, so it opens instantly.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local Device = require("device")
local DocSettings = require("docsettings")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Trash = require("trash")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- "3 days ago", "yesterday", "today"
local function ago(ts)
    if not ts or ts <= 0 then return nil end
    local days = math.floor((os.time() - ts) / 86400)
    if days <= 0 then return _("today") end
    if days == 1 then return _("yesterday") end
    if days < 30 then return string.format(_("%d days ago"), days) end
    return (os.date("%d %b %Y", ts):gsub("^0", ""))
end

local BookCard = InputContainer:extend{
    plugin = nil,
    book = nil,         -- library entry: file, title, author, series, series_index, size, opened, trashed
    on_open = nil,
    on_changed = nil,   -- reading status changed
    on_removed = nil,   -- moved to / restored from / deleted from the trash
    modal = true,
}

function BookCard:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    -- Sizes scale from the shorter side, so landscape keeps portrait proportions.
    self.u = math.min(self.W, self.H) / 1072
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        local close = {}
        for __, group in ipairs({ "Back", "PgFwd", "PgBack" }) do
            if Device.input.group[group] then table.insert(close, { Device.input.group[group] }) end
        end
        self.key_events.Close = close
    end
    self.widgets = {}

    local u = self.u
    self.pad = round(44 * u)
    self.line = math.max(1, round(2 * u))
    self.border = math.max(2, round(3 * u))
    local w = round(math.min(self.W, self.H) * 0.9) -- portrait width, also in landscape
    self.card = Geom:new{ x = round((self.W - w) / 2), y = 0, w = w, h = 0 }
    self.cover_w = round(w * 0.26)
    self.cover_h = round(self.cover_w * 1.5)
    self.button_h = round(104 * u)
    self.info = not self.book.trashed and BookList.getBookInfo(self.book.file) or {}
    self:layoutText()
    UIManager:nextTick(function() self:loadCover() end)
end

function BookCard:add(w)
    table.insert(self.widgets, w)
    return w
end

-- Status line, and whether the book is finished.
function BookCard:status()
    local book, info = self.book, self.info
    if book.trashed then
        local from = book.trashed.orig and book.trashed.orig:match("^(.*)/[^/]+$")
        from = from and from:match("([^/]+)$")
        return from and string.format(_("In Trash · from %s"), from) or _("In Trash"), false
    end
    if info.been_opened and info.status == "complete" then return _("Finished"), true end
    if info.been_opened then
        local pct = math.max(1, math.floor((info.percent_finished or 0) * 100))
        local last = ago(book.opened)
        return last and string.format(_("%d%% read · Last read %s"), pct, last) or string.format(_("%d%% read"), pct), false
    end
    return _("Not started"), false
end

-- Text column beside the cover; the card's height follows whichever is taller.
function BookCard:layoutText()
    for __, w in ipairs(self.widgets) do w:free() end
    self.widgets = {}
    local u, c = self.u, self.card
    local col_x = self.pad + self.cover_w + round(36 * u)
    local col_w = c.w - col_x - self.pad
    local book = self.book
    self.lines = {}
    local function line(text, role, size, gap)
        if not text or text == "" then return end
        table.insert(self.lines, { widget = self:add(TextBoxWidget:new{ text = text, face = Fonts.face(role, size), width = col_w }), gap = gap or 0 })
    end
    line(book.title, "serif_bold", 21)
    line(book.author, "ui", 17, round(8 * u))
    if book.series and book.series ~= "" then
        local idx = tonumber(book.series_index)
        local num = idx and ((idx % 1 == 0) and string.format("%d", idx) or tostring(idx))
        line(num and string.format("%s #%s", book.series, num) or book.series, "ui_italic", 16, round(6 * u))
    end
    local status, finished = self:status()
    line(status, "ui_bold", 15, round(22 * u))
    local ext = (book.file:match("%.([^.]+)$") or ""):upper()
    line(string.format("%s · %.1f MB", ext, (book.size or 0) / 1048576), "ui", 15, round(6 * u))
    self.col_x = col_x

    local text_h = 0
    for __, l in ipairs(self.lines) do text_h = text_h + l.gap + l.widget:getSize().h end
    c.h = self.pad + math.max(self.cover_h, text_h) + self.pad + self.button_h
    c.y = round((self.H - c.h) / 2)

    if book.trashed then
        self.buttons = { { id = "restore", text = _("Restore") }, { id = "purge", text = _("Delete Forever"), bold = true } }
    else
        self.buttons = {
            { id = "open", text = _("Open") },
            { id = "toggle", text = finished and _("Mark as Unread") or _("Mark as Read") },
            { id = "remove", text = _("Remove") },
        }
    end
    for __, b in ipairs(self.buttons) do
        b.widget = self:add(TextWidget:new{ text = b.text, face = Fonts.face(b.bold and "ui_bold" or "ui", 18) })
    end
end

function BookCard:loadCover()
    if self.closed then return end
    local BookInfo = require("apps/filemanager/filemanagerbookinfo")
    local ok, bb = pcall(BookInfo.getCoverImage, BookInfo, nil, self.book.file)
    if ok and bb and not self.closed then
        local scale = math.min(self.cover_w / bb:getWidth(), self.cover_h / bb:getHeight())
        local w, h = math.max(1, round(bb:getWidth() * scale)), math.max(1, round(bb:getHeight() * scale))
        self.cover = RenderImage:scaleBlitBuffer(bb, w, h, true)
        self:refresh()
    elseif ok and bb then
        bb:free()
    end
end

function BookCard:paintTo(bb, x, y)
    local ok, err = pcall(self.paintCard, self, bb, x, y)
    if not ok then
        logger.err("VoyageBookCard: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

function BookCard:paintCard(bb, x, y)
    local c = self.card
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x + c.x, y + c.y, c.w, c.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x + c.x, y + c.y, c.w, c.h, self.border, BLACK)

    -- Cover, or a frame while it loads / when there is none.
    local cx, cy = x + c.x + self.pad, y + c.y + self.pad
    if self.cover then
        local cw, ch = self.cover:getWidth(), self.cover:getHeight()
        local ox = cx + round((self.cover_w - cw) / 2)
        bb:blitFrom(self.cover, ox, cy, 0, 0, cw, ch)
        bb:paintBorder(ox, cy, cw, ch, self.line, Blitbuffer.COLOR_GRAY)
    else
        bb:paintBorder(cx, cy, self.cover_w, self.cover_h, self.line, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    local ty = y + c.y + self.pad
    for __, l in ipairs(self.lines) do
        ty = ty + l.gap
        l.widget:paintTo(bb, x + c.x + self.col_x, ty)
        ty = ty + l.widget:getSize().h
    end

    -- Buttons
    local by = y + c.y + c.h - self.button_h
    bb:paintRect(x + c.x, by, c.w, self.line, BLACK)
    local col = c.w / #self.buttons
    for i, b in ipairs(self.buttons) do
        local bx = x + c.x + round(col * (i - 1))
        if i > 1 then bb:paintRect(bx, by, self.line, self.button_h, BLACK) end
        local s = b.widget:getSize()
        b.widget:paintTo(bb, bx + round((col - s.w) / 2), by + round((self.button_h - s.h) / 2))
        b.rect = Geom:new{ x = bx - x, y = by - y, w = round(col), h = self.button_h }
        if self.pressed == i then
            bb:invertRect(bx + self.line, by + self.line, round(col) - self.line, self.button_h - self.border)
        end
    end
end

function BookCard:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.card end)
end

function BookCard:setFinished(finished)
    local file = self.book.file
    local doc_settings = DocSettings:open(file)
    local summary = doc_settings:readSetting("summary") or {}
    summary.status = finished and "complete" or "reading"
    require("apps/filemanager/filemanagerutil").saveSummary(doc_settings, summary)
    BookList.setBookInfoCacheProperty(file, "status", summary.status)
end

function BookCard:act(id)
    if id == "open" then
        self:onClose()
        if self.on_open then self.on_open() end
    elseif id == "toggle" then
        local __, finished = self:status()
        self:setFinished(not finished)
        self.info = BookList.getBookInfo(self.book.file)
        local c = self.card
        local old = Geom:new{ x = c.x, y = c.y, w = c.w, h = c.h }
        self:layoutText()
        UIManager:setDirty(nil, function() return "ui", old end)
        self:refresh()
        if self.on_changed then self.on_changed() end
    elseif id == "remove" then
        -- Reversible, so no confirmation: it can be restored from Trash.
        if Trash.move(self.book.file) then
            self:onClose()
            if self.on_removed then self.on_removed() end
            UIManager:show(InfoMessage:new{ text = _("Moved to Trash"), timeout = 2 })
        end
    elseif id == "restore" then
        if Trash.restore(self.book.file) then
            self:onClose()
            if self.on_removed then self.on_removed() end
            UIManager:show(InfoMessage:new{ text = _("Restored"), timeout = 2 })
        end
    elseif id == "purge" then
        local Dialog = require("dialog")
        UIManager:show(Dialog:new{
            title = _("Delete forever?"),
            text = string.format(_("“%s” and its reading progress, highlights and notes will be deleted for good."), self.book.title),
            buttons = {
                { text = _("Cancel") },
                { text = _("Delete"), bold = true, callback = function()
                    if Trash.purge(self.book.file) then
                        self:onClose()
                        if self.on_removed then self.on_removed() end
                    end
                end },
            },
        })
    end
end

function BookCard:onTap(__, ges)
    if not inside(ges.pos, self.card) then return self:onClose() end
    for i, b in ipairs(self.buttons or {}) do
        if b.rect and inside(ges.pos, b.rect) then
            self.pressed = i
            UIManager:setDirty(self, function() return "fast", b.rect end)
            UIManager:forceRePaint()
            UIManager:scheduleIn(0.12, function()
                self.pressed = nil
                self:act(b.id)
            end)
            return true
        end
    end
    return true
end

function BookCard:onShow()
    self:refresh()
    return true
end

function BookCard:onClose()
    UIManager:close(self)
    return true
end

function BookCard:onCloseWidget()
    self.closed = true
    for __, w in ipairs(self.widgets) do w:free() end
    self.widgets = {}
    if self.cover then self.cover:free() self.cover = nil end
    UIManager:setDirty(nil, function() return "ui", self.card end)
end

return BookCard
