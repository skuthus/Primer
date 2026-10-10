--[[--
Kindle 2-style library: every book in one flat list (folders are ignored), title on
the left in Caecilia with length/progress dots underneath, author on the right,
"read" in the margin for finished books. Replaces KOReader's file browser as home.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookList = require("ui/widget/booklist")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ReadHistory = require("readhistory")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local Screen = Device.screen


local SORTS = { "recent", "title", "author", "added" }
local SORT_LABELS = {
    recent = _("By Most Recent First"),
    title = _("By Title"),
    author = _("By Author"),
    added = _("By Newest Added"),
}

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- Sort keys ignore case and a leading article, like the Kindle.
local function titleKey(title)
    return title:lower():gsub("^the ", ""):gsub("^an? ", "")
end

-- "Stephen King" -> "king, stephen"
local function authorKey(author)
    if author:find(",") then return author:lower() end
    local first, last = author:match("^(.-)%s*(%S+)$")
    return ((last or author) .. ", " .. (first or "")):lower()
end

-- Calibre's metadata.calibre, keyed by absolute path. Empty when absent.
local function loadCalibre(device_root)
    local ok, rapidjson = pcall(require, "rapidjson")
    if not ok then return {} end
    local path = device_root .. "/metadata.calibre"
    if lfs.attributes(path, "mode") ~= "file" then return {} end
    local ok_load, books = pcall(rapidjson.load_calibre, path)
    if not ok_load or type(books) ~= "table" then return {} end
    local by_path = {}
    for __, book in ipairs(books) do
        if type(book.lpath) == "string" then
            local authors = type(book.authors) == "table" and table.concat(book.authors, " & ") or nil
            by_path[device_root .. "/" .. book.lpath] = {
                title = type(book.title) == "string" and book.title or nil,
                author = authors,
                author_sort = type(book.author_sort) == "string" and book.author_sort or nil,
            }
        end
    end
    return by_path
end

-- Kindle housekeeping files that aren't books: clippings, crash reports, Amazon dictionaries.
local function isClutter(name)
    return name == "My Clippings.txt"
        or name:find("_crash_", 1, true) ~= nil
        or (name:find("Dictionary", 1, true) ~= nil and name:match("_B0%w+%.azw$") ~= nil)
end

-- Calibre-style file names: "Title_ Subtitle - Author.epub"
local function fromFilename(name)
    local base = name:gsub("%.[^.]+$", ""):gsub("_ ", ": ")
    local title, author = base:match("^(.*) %- (.-)$") -- greedy title: split on the last " - "
    return title or base, author or ""
end

local Library = InputContainer:extend{
    plugin = nil,
    covers_fullscreen = true,
}

function Library:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.sort = G_reader_settings:readSetting("voyage_library_sort") or "recent"
    self.page = 1
    self.cache = {}

    local screen = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input.group.PgFwd then self.key_events.NextPage = { { Device.input.group.PgFwd } } end
        if Device.input.group.PgBack then self.key_events.PrevPage = { { Device.input.group.PgBack } } end
    end

    self.face_header = Fonts.face("ui_bold", 15)
    self.face_status = Fonts.face("ui", 12)
    self.face_sub = Fonts.face("ui_bold", 14)
    self.face_title = Fonts.face("slab", 19)
    self.face_author = Fonts.face("slab", 15)
    self.face_tag = Fonts.face("ui", 11)

    self:scan()
    self:layout()
end

function Library:scan()
    local start = time.now()
    local home = G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()
    local calibre = loadCalibre(home:match("^(.*)/[^/]+$") or home)

    local opened = {}
    for __, item in ipairs(ReadHistory.hist) do
        if item.file and not opened[item.file] then opened[item.file] = item.time end
    end

    local books = {}
    local function walk(dir)
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, state do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    walk(path)
                elseif attr and attr.mode == "file" and not isClutter(name) and DocumentRegistry:hasProvider(path) then
                    local meta = calibre[path]
                    local title, author = fromFilename(name)
                    if meta then
                        title = meta.title or title
                        author = meta.author or author
                    end
                    table.insert(books, {
                        file = path,
                        title = title,
                        author = author,
                        title_key = titleKey(title),
                        author_key = meta and meta.author_sort and meta.author_sort:lower() or authorKey(author),
                        size = attr.size or 0,
                        added = attr.modification or 0,
                        opened = opened[path] or 0,
                    })
                end
            end
        end
    end
    walk(home)
    self.books = books
    self:sortBooks()
    logger.info("VoyageLibrary: scanned", #books, "books in", time.to_ms(time.since(start)), "ms")
end

function Library:sortBooks()
    local sort = self.sort
    table.sort(self.books, function(a, b)
        if sort == "title" then
            if a.title_key ~= b.title_key then return a.title_key < b.title_key end
        elseif sort == "author" then
            if a.author_key ~= b.author_key then return a.author_key < b.author_key end
            if a.title_key ~= b.title_key then return a.title_key < b.title_key end
        elseif sort == "added" then
            if a.added ~= b.added then return a.added > b.added end
        else -- recent: last opened or added, whichever is later
            local ra, rb = math.max(a.opened, a.added), math.max(b.opened, b.added)
            if ra ~= rb then return ra > rb end
        end
        return a.file < b.file
    end)
end

-- TextWidgets cached by (text, face, max width); freed on close.
function Library:text(str, f, max_width, bold)
    local key = table.concat({ str, tostring(f), tostring(max_width), tostring(bold) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width, bold = bold }
        self.cache[key] = w
    end
    return w
end

function Library:clearCache()
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
end

function Library:layout()
    local W, H = self.width, self.height
    local pad = round(W * 0.045)
    self.pad = pad

    -- Header bar
    self.bar = Geom:new{ x = round(W * 0.02), y = round(W * 0.02), w = W - round(W * 0.04), h = round(W * 0.058) }
    -- Subheader: item count and sort
    self.sub_y = self.bar.y + self.bar.h + round(W * 0.022)
    local sub_h = self:text("Ag", self.face_sub):getSize().h
    local sort_w = self:text(SORT_LABELS[self.sort], self.face_sub):getSize().w
    self.sort_hit = Geom:new{ x = W - pad - sort_w - round(W * 0.05), y = self.sub_y - round(W * 0.02),
        w = sort_w + round(W * 0.05) + pad, h = sub_h + round(W * 0.04) }

    -- Rows fill the space between subheader and footer.
    self.footer_y = H - round(W * 0.075)
    self.list_y = self.sub_y + sub_h + round(W * 0.03)
    self.row_h = round(W * 0.098)
    self.per_page = math.max(1, math.floor((self.footer_y - round(W * 0.02) - self.list_y) / self.row_h))
    self.pages = math.max(1, math.ceil(#self.books / self.per_page))
    self.page = math.min(self.page, self.pages)

    -- Titles line up with "Showing All…"; the "read" tag hangs in the margin, like the Kindle 2.
    self.title_x = pad
    local text_w = W - self.title_x - pad
    self.title_max = round(text_w * 0.64)
    self.author_max = round(text_w * 0.32)
    self.dot = math.max(3, round(W * 0.0035))
    self.dot_gap = self.dot * 2
end

function Library:paintTo(bb, x, y)
    local ok, err = pcall(self.paintLibrary, self, bb, x, y)
    if not ok then
        logger.err("VoyageLibrary: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function Library:paintBattery(bb, right, cy)
    local powerd = Device:getPowerDevice()
    local h = round(self.bar.h * 0.36)
    local w = round(h * 2.1)
    local border = math.max(2, round(self.width * 0.002))
    local x = right - w - border
    local top = cy - round(h / 2)
    bb:paintRect(x + w, top + round(h * 0.3), border, round(h * 0.4), Blitbuffer.COLOR_BLACK)
    bb:paintBorder(x, top, w, h, border, Blitbuffer.COLOR_BLACK)
    local inner = w - 4 * border
    local fill = round(inner * math.min(math.max(powerd:getCapacity(), 0), 100) / 100)
    if fill > 0 then
        bb:paintRect(x + 2 * border, top + 2 * border, fill, h - 4 * border, Blitbuffer.COLOR_BLACK)
    end
    return x
end

function Library:paintLibrary(bb, x, y)
    local W, pad = self.width, self.pad
    bb:paintRect(x, y, W, self.height, Blitbuffer.COLOR_WHITE)

    -- Header bar: name left; wireless state and battery right.
    local bar = self.bar
    bb:paintRoundedRect(x + bar.x, y + bar.y, bar.w, bar.h, Blitbuffer.COLOR_LIGHT_GRAY, round(bar.h * 0.25))
    local name = self:text(self.plugin:deviceName(), self.face_header)
    local cy = y + bar.y + round(bar.h / 2)
    name:paintTo(bb, x + bar.x + round(W * 0.025), cy - round(name:getSize().h / 2))
    local batt_x = self:paintBattery(bb, x + bar.x + bar.w - round(W * 0.025), cy)
    local wireless = self:text(self.plugin:isWirelessOn() and _("Wi-Fi") or _("OFF"), self.face_status)
    wireless:paintTo(bb, batt_x - round(W * 0.02) - wireless:getSize().w, cy - round(wireless:getSize().h / 2))

    -- Subheader
    local count = #self.books
    local showing = self:text(count == 1 and _("Showing 1 Item") or string.format(_("Showing All %d Items"), count), self.face_sub)
    showing:paintTo(bb, x + pad, y + self.sub_y)
    local sort = self:text(SORT_LABELS[self.sort], self.face_sub)
    sort:paintTo(bb, x + W - pad - sort:getSize().w, y + self.sub_y)

    -- Rows
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(first + self.per_page - 1, count) do
        self:paintRow(bb, x, y + self.list_y + (i - first) * self.row_h, self.books[i], i == self.pressed)
    end

    -- Footer
    local footer = self:text(string.format(_("Page %d of %d"), self.page, self.pages), self.face_sub)
    footer:paintTo(bb, x + pad, y + self.footer_y)
    bb:paintRect(x, y + self.footer_y - round(W * 0.018), W, math.max(1, round(W * 0.0015)), Blitbuffer.COLOR_LIGHT_GRAY)
    if count == 0 then
        local empty = self:text(_("No books found in ") .. (G_reader_settings:readSetting("home_dir") or "documents"), self.face_author)
        empty:paintTo(bb, x + round((W - empty:getSize().w) / 2), y + self.list_y + self.row_h)
    end
end

function Library:paintRow(bb, x, row_y, book, pressed)
    local W, pad = self.width, self.pad
    local info = BookList.getBookInfo(book.file)
    local finished = info.been_opened and info.status == "complete"
    local percent = finished and 1 or (info.percent_finished or 0)

    local title = self:text(book.title, self.face_title, self.title_max)
    local author = self:text(book.author, self.face_author, self.author_max)
    local th = title:getSize().h
    local title_y = row_y + round(self.row_h * 0.12)
    title:paintTo(bb, x + self.title_x, title_y)
    local ah = author:getSize().h
    author:paintTo(bb, x + W - pad - author:getSize().w, title_y + th - ah)

    if finished then
        local tag = self:text(_("read"), self.face_tag)
        local tag_x = math.max(round(W * 0.005), pad - round(W * 0.008) - tag:getSize().w)
        tag:paintTo(bb, x + tag_x, title_y + round((th - tag:getSize().h) / 2))
    end

    -- Dots: count follows the book's size, filled dots show how far you've read.
    local max_dots = math.floor(self.title_max / (self.dot + self.dot_gap))
    local total = math.min(math.max(round(math.sqrt(book.size / 1024) * 0.8), 3), max_dots)
    local filled = round(total * percent)
    local dot_y = title_y + th + round(self.dot * 0.5)
    for d = 0, total - 1 do
        local dx = x + self.title_x + d * (self.dot + self.dot_gap)
        if d < filled then
            bb:paintRect(dx, dot_y - 1, self.dot + 2, self.dot + 2, Blitbuffer.COLOR_BLACK)
        else
            bb:paintRect(dx + 1, dot_y, self.dot, self.dot, Blitbuffer.COLOR_DARK_GRAY)
        end
    end

    if pressed then
        bb:invertRect(x, row_y, W, self.row_h)
    end
end

function Library:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function Library:goToPage(page)
    page = math.min(math.max(page, 1), self.pages)
    if page ~= self.page then
        self.page = page
        self:refresh("partial")
    end
    return true
end

function Library:onNextPage() return self:goToPage(self.page + 1) end
function Library:onPrevPage() return self:goToPage(self.page - 1) end

function Library:rowAt(pos)
    if pos.y < self.list_y then return end
    local index = math.floor((pos.y - self.list_y) / self.row_h)
    if index >= self.per_page then return end
    local book_index = (self.page - 1) * self.per_page + index + 1
    if book_index <= #self.books then return book_index end
end

function Library:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.sort_hit) then
        local next_sort = SORTS[1]
        for i, s in ipairs(SORTS) do
            if s == self.sort then next_sort = SORTS[i % #SORTS + 1] end
        end
        self.sort = next_sort
        G_reader_settings:saveSetting("voyage_library_sort", next_sort)
        self:sortBooks()
        self.page = 1
        self:clearCache()
        self:layout()
        self:refresh("partial")
    elseif pos.y < self.sub_y then
        self.plugin:openAllSettings()
    else
        local index = self:rowAt(pos)
        if index then self:openBook(index) end
    end
    return true
end

function Library:openBook(index)
    -- Like the Kindle: the tapped row stays inverted until the book appears,
    -- with no "Opening file" box (seamless open).
    self.pressed = index
    self:refresh("fast")
    UIManager:scheduleIn(0.1, function()
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(self.books[index].file, nil, true)
    end)
end

function Library:onSwipe(__, ges)
    if ges.direction == "west" then
        return self:onNextPage()
    elseif ges.direction == "east" then
        return self:onPrevPage()
    elseif ges.direction == "south" and ges.pos.y < self.height / 8 then
        self.plugin:showPanel()
    end
    return true
end

-- Rebuild after the quick panel or settings change something we show (night mode, wireless).
function Library:onNetworkConnected() self:refresh() end
function Library:onNetworkDisconnected() self:refresh() end

function Library:onShowingReader()
    UIManager:close(self)
end

function Library:onShow()
    self:refresh("full")
    return true
end

function Library:onCloseWidget()
    self:clearCache()
    self.plugin.library = nil
end

return Library
