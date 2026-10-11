--[[--
Kindle 2-style library: every book in one flat list (folders are ignored), title on
the left in Caecilia with length/progress dots underneath, author on the right,
"read" in the margin for finished books. Replaces KOReader's file browser as home.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookCard = require("bookcard")
local SearchBar = require("searchbar")
local Trash = require("trash")
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
local datetime = require("datetime")
local time = require("ui/time")
local _ = require("gettext")
local Screen = Device.screen


local NEW_DAYS = 3 -- unopened books added within this many days get a "NEW" badge

local FILTERS = { "all", "reading", "unread", "finished", "trash" }
local FILTER_LABELS = { all = _("All Items"), reading = _("Reading"), unread = _("Unread"), finished = _("Finished"), trash = _("Trash") }

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
            local function str(v) return type(v) == "string" and v or nil end
            by_path[device_root .. "/" .. book.lpath] = {
                title = str(book.title),
                author = authors,
                author_sort = str(book.author_sort),
                series = str(book.series),
                series_index = type(book.series_index) == "number" and book.series_index or nil,
                comments = str(book.comments),
            }
        end
    end
    return by_path
end

-- Kindle housekeeping files that aren't books: clippings, crash reports, Amazon dictionaries,
-- the firmware's version.txt, jailbreak markers and scriptlets. Images (sleep screens, cover
-- thumbnails) open in KOReader but don't belong in a library either.
local IMAGE_EXTENSIONS = { gif = true, jpg = true, jpeg = true, png = true, webp = true, svg = true, bmp = true }
local function isClutter(name)
    local ext = name:match("%.([^.]+)$")
    return name == "My Clippings.txt"
        or name == "version.txt"
        or name == "JAILBROKEN.txt"
        or (ext ~= nil and (IMAGE_EXTENSIONS[ext:lower()] or ext:lower() == "sh"))
        or name:find("_crash_", 1, true) ~= nil
        or (name:find("Dictionary", 1, true) ~= nil and name:match("_B0%w+%.azw$") ~= nil)
end

-- Folders that never hold books: the Kindle's own (system, screensavers, fonts, audio) and
-- KOReader's, in case the home folder is the device root rather than documents.
local SKIP_DIRS = {
    system = true, screensavers = true, fonts = true, koreader = true, extensions = true,
    kmc = true, libkh = true, audible = true, voice = true, ["cycle-dir"] = true,
    ["amazon-cover-bug"] = true,
}

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
    self.filter = G_reader_settings:readSetting("voyage_library_filter") or "all"
    self.query = nil
    self.page = 1
    self.cache = {}

    local screen = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = screen } },
        Hold = { GestureRange:new{ ges = "hold", range = screen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input.group.PgFwd then self.key_events.NextPage = { { Device.input.group.PgFwd } } end
        if Device.input.group.PgBack then self.key_events.PrevPage = { { Device.input.group.PgBack } } end
    end

    self.face_header = Fonts.face("ui_bold", 20)
    self.face_status = Fonts.face("ui", 12)
    self.face_sub = Fonts.face("ui_bold", 14)
    self.face_title = Fonts.face("slab", 19)
    self.face_author = Fonts.face("slab", 15)
    self.face_tag = Fonts.face("ui", 12)
    self.face_badge = Fonts.face("ui_bold", 10)
    self.face_footer = Fonts.face("ui", 14)
    self.face_search = Fonts.face("ui", 17)
    self.face_menu = Fonts.face("ui", 17)

    self:scan()
    self:layout()
end

function Library:scan()
    local start = time.now()
    local home = G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()
    -- KOReader's default home on a Kindle is the whole user partition; books live in documents.
    if Device:isKindle() and not G_reader_settings:has("home_dir") and lfs.attributes(home .. "/documents", "mode") == "directory" then
        home = home .. "/documents"
    end
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
                    if not SKIP_DIRS[name] then walk(path) end
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
                        series = meta and meta.series,
                        series_index = meta and meta.series_index,
                        comments = meta and meta.comments,
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
    self.all_books = books
    self:sortBooks()
    self:applyView()
    logger.info("VoyageLibrary: scanned", #books, "books in", time.to_ms(time.since(start)), "ms")
end

function Library:sortBooks()
    local sort = self.sort
    table.sort(self.all_books, function(a, b)
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

-- "reading" / "unread" / "finished", cached per book (reset when it changes).
function Library:statusOf(book)
    if not book.status then
        if not BookList.hasBookBeenOpened(book.file) then
            book.status = "unread"
        else
            local info = BookList.getBookInfo(book.file)
            book.status = info.status == "complete" and "finished" or "reading"
        end
    end
    return book.status
end

-- The visible list: all books, narrowed by the status filter and the search, in sort order.
function Library:applyView()
    local query = self.query and self.query:lower()
    local books = {}
    if self.filter == "trash" then
        for __, item in ipairs(Trash.list()) do
            local title, author = fromFilename(item.name)
            local keep = not query or title:lower():find(query, 1, true) or author:lower():find(query, 1, true)
            if keep then
                table.insert(books, { file = item.file, title = title, author = author, size = item.size,
                    added = 0, opened = 0, trashed = item })
            end
        end
        self.books = books
        self.page = 1
        return
    end
    for __, book in ipairs(self.all_books) do
        local keep = self.filter == "all" or self:statusOf(book) == self.filter
        if keep and query then
            keep = book.title:lower():find(query, 1, true) or book.author:lower():find(query, 1, true)
                or (book.series and book.series:lower():find(query, 1, true))
        end
        if keep then table.insert(books, book) end
    end
    self.books = books
    self.page = 1
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
    -- Sizes follow the shorter side (S), so landscape keeps portrait proportions; the bands,
    -- stripes and rules still span the full width.
    local S = math.min(W, H)
    self.short = S
    local pad = round(S * 0.045)
    self.pad = pad

    -- Striped bands: a shaded header, the books (shaded every other row) and the footer at the
    -- bottom. The book rows share the space between the slim subheader and the footer exactly
    -- (as many as fit at about a header's height), so there's no gap anywhere.
    local band = round(S * 0.098)
    self.bar = Geom:new{ x = 0, y = 0, w = W, h = band }
    self.bar_icon = round(S * 0.058) -- header icons keep the size they had in the old, slimmer bar
    local sub_h = self:text("Ag", self.face_sub):getSize().h
    self.sub_y = band + round(S * 0.022)
    self.list_y = self.sub_y + sub_h + round(S * 0.025)
    local space = H - band - self.list_y
    self.per_page = math.max(1, math.floor(space / band + 0.5))
    self.row_h = math.floor(space / self.per_page)
    self.footer_top = self.list_y + self.per_page * self.row_h
    self.footer_h = H - self.footer_top
    self.rule = math.max(2, round(S * 0.0028))
    -- The footer continues the stripes: shaded when the last book row is white.
    self.footer_shaded = self.per_page % 2 == 0
    local sort_w = self:text(SORT_LABELS[self.sort], self.face_sub):getSize().w
    self.sort_hit = Geom:new{ x = W - pad - sort_w - round(S * 0.05), y = self.sub_y - round(S * 0.02),
        w = sort_w + round(S * 0.05) + pad, h = sub_h + round(S * 0.04) }
    self.filter_hit = Geom:new{ x = 0, y = self.sub_y - round(S * 0.02), w = self.sort_hit.x, h = sub_h + round(S * 0.04) }
    self.footer_icon = round(S * 0.064 * 0.55)
    self.search_hit = Geom:new{ x = 0, y = self.footer_top, w = round(W * 0.6), h = self.footer_h }
    self.pages = math.max(1, math.ceil(#self.books / self.per_page))
    self.page = math.min(self.page, self.pages)

    -- Titles line up with "Showing All…".
    self.title_x = pad
    local text_w = W - self.title_x - pad
    self.title_max = round(text_w * 0.64)
    self.author_max = round(text_w * 0.32)
    self.dot = math.max(3, round(S * 0.0035))
    self.dot_gap = self.dot * 2
end

function Library:paintTo(bb, x, y)
    local ok, err = pcall(self.paintLibrary, self, bb, x, y)
    if not ok then
        logger.err("VoyageLibrary: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end


function Library:paintHeader(bb, x, y)
    local W, bar = self.width, self.bar
    bb:paintRect(x + bar.x, y + bar.y, bar.w, bar.h, Blitbuffer.COLOR_GRAY_D)
    -- A firm rule closes the header off from the list (the footer gets the same one).
    bb:paintRect(x + bar.x, y + bar.y + bar.h - self.rule, bar.w, self.rule, Blitbuffer.COLOR_BLACK)
    local cy = y + bar.y + round(bar.h / 2)
    local now = os.time()
    local stamp = datetime.secondsToHour(now, G_reader_settings:isTrue("twelve_hour_clock"))
        .. "  •  " .. os.date("%d %b %Y", now):gsub("^0", "")
    local clock = TextWidget:new{ text = stamp, face = self.face_header }
    clock:paintTo(bb, x + self.pad, cy - round(clock:getSize().h / 2))
    clock:free()
    local right = self.plugin:paintBattery(bb, x + W - self.pad, cy, round(self.bar_icon * 0.36), self.face_footer)
    if self.plugin:isWirelessOn() then
        local s = round(self.bar_icon * 0.55)
        local wifi = self.plugin:icon("s-wifi", s, true)
        wifi:paintTo(bb, right - round(self.short * 0.02) - s, cy - round(s / 2))
        wifi:free()
    end
end

-- Keep the header clock current while the library is up (refreshes just the bar).
function Library:clockTick()
    UIManager:setDirty(self, function() return "ui", self.bar end)
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), self.clock_tick)
end

function Library:paintLibrary(bb, x, y)
    local W, pad = self.width, self.pad
    bb:paintRect(x, y, W, self.height, Blitbuffer.COLOR_WHITE)

    -- Header bar: time and date left; Wi-Fi (only when on) and battery right.
    self:paintHeader(bb, x, y)

    -- Subheader: what's showing (tap for the filter), sort on the right.
    local count = #self.books
    local showing
    if self.query then
        showing = count == 1 and string.format(_("1 Result for “%s”"), self.query) or string.format(_("%d Results for “%s”"), count, self.query)
    elseif self.filter == "trash" then
        showing = count == 1 and _("1 Book in Trash") or string.format(_("%d Books in Trash"), count)
    elseif self.filter == "all" then
        showing = count == 1 and _("Showing 1 Item") or string.format(_("Showing All %d Items"), count)
    else
        showing = string.format(_("Showing %d %s"), count, FILTER_LABELS[self.filter])
    end
    local showing_w = self:text(showing .. "  ▾", self.face_sub, round(W * 0.55))
    showing_w:paintTo(bb, x + pad, y + self.sub_y)
    local sort = self:text(SORT_LABELS[self.sort], self.face_sub)
    sort:paintTo(bb, x + W - pad - sort:getSize().w, y + self.sub_y)

    -- Rows
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(first + self.per_page - 1, count) do
        self:paintRow(bb, x, y + self.list_y + (i - first) * self.row_h, self.books[i], i == self.pressed, (i - first) % 2 == 0)
    end

    -- Footer: a row-height band (shaded when the stripes call for it), Search on the left,
    -- page position on the right.
    if self.footer_shaded then
        bb:paintRect(x, y + self.footer_top, W, self.footer_h, Blitbuffer.COLOR_GRAY_D)
    end
    bb:paintRect(x, y + self.footer_top, W, self.rule, Blitbuffer.COLOR_BLACK)
    local fy = y + self.footer_top + round(self.footer_h / 2)
    local is = self.footer_icon
    local label
    if self.filter == "trash" and not self.query then
        label = count > 0 and _("Empty Trash") or nil
    else
        local icon = self.plugin:icon(self.query and "close" or "search", is, true)
        icon:paintTo(bb, x + pad, fy - round(is / 2))
        icon:free()
        label = self.query and string.format(_("Clear “%s”"), self.query) or _("Search")
    end
    if label then
        local lx = x + pad + ((self.filter == "trash" and not self.query) and 0 or (is + round(self.short * 0.015)))
        local search = self:text(label, self.face_search, round(W * 0.45))
        search:paintTo(bb, lx, fy - round(search:getSize().h / 2))
    end
    local footer = self:text(string.format(_("Page %d of %d"), self.page, self.pages), self.face_footer)
    footer:paintTo(bb, x + W - pad - footer:getSize().w, y + self.footer_top + round((self.footer_h - footer:getSize().h) / 2))
    if count == 0 then
        local msg = (self.query or self.filter ~= "all") and _("No matching books.")
            or (_("No books found in ") .. (G_reader_settings:readSetting("home_dir") or "documents"))
        local empty = self:text(msg, self.face_author)
        empty:paintTo(bb, x + round((W - empty:getSize().w) / 2), y + self.list_y + self.row_h)
    end
    self:paintFilterMenu(bb, x, y)
end

-- Status filter dropdown under "Showing …".
function Library:paintFilterMenu(bb, x, y)
    if not self.menu_open then return end
    local S, pad = self.short, self.pad
    local row_h = round(S * 0.085)
    local w = round(S * 0.5)
    local line = math.max(1, round(S * 0.002))
    self.menu = Geom:new{ x = pad - round(S * 0.015), y = self.sub_y + round(S * 0.05), w = w, h = row_h * #FILTERS }
    local m = self.menu
    bb:paintRect(x + m.x, y + m.y, m.w, m.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x + m.x, y + m.y, m.w, m.h, line, Blitbuffer.COLOR_BLACK)
    for i, id in ipairs(FILTERS) do
        local ry = y + m.y + (i - 1) * row_h
        if i > 1 then bb:paintRect(x + m.x, ry, m.w, line, Blitbuffer.COLOR_LIGHT_GRAY) end
        local t = self:text(FILTER_LABELS[id], self.face_menu)
        t:paintTo(bb, x + m.x + round(S * 0.04), ry + round((row_h - t:getSize().h) / 2))
        if id == self.filter then
            local cs = round(row_h * 0.45)
            local check = self.plugin:icon("check", cs)
            check:paintTo(bb, x + m.x + m.w - round(S * 0.03) - cs, ry + round((row_h - cs) / 2))
            check:free()
        end
    end
    self.menu_row_h = row_h
end

function Library:paintRow(bb, x, row_y, book, pressed, striped)
    local W, S, pad = self.width, self.short, self.pad
    -- Every other row is lightly shaded, like Finder's lists, so rows are easy to follow.
    if striped then bb:paintRect(x, row_y, W, self.row_h, Blitbuffer.COLOR_GRAY_D) end
    local info = BookList.getBookInfo(book.file)
    local finished = info.been_opened and info.status == "complete"
    local percent = finished and 1 or (info.percent_finished or 0)

    -- NEW badge sits right after the title (for unopened books added in the last few days).
    local is_new = not book.trashed and not info.been_opened and os.time() - book.added < NEW_DAYS * 86400
    local badge, badge_w, badge_h
    if is_new then
        badge = TextWidget:new{ text = _("NEW"), face = self.face_badge, fgcolor = Blitbuffer.COLOR_WHITE }
        badge_h = badge:getSize().h
        badge_w = badge:getSize().w + round(S * 0.014)
    end
    local title = self:text(book.title, self.face_title, self.title_max - (badge and badge_w + round(S * 0.015) or 0))
    local author = self:text(book.author, self.face_author, self.author_max)
    local th = title:getSize().h
    local title_y = row_y + round(self.row_h * 0.12)
    title:paintTo(bb, x + self.title_x, title_y)
    if badge then
        local bx = x + self.title_x + title:getSize().w + round(S * 0.015)
        local by = title_y + round((th - badge_h) / 2)
        bb:paintRoundedRect(bx, by, badge_w, badge_h, Blitbuffer.COLOR_BLACK, round(badge_h * 0.3))
        badge:paintTo(bb, bx + round((badge_w - badge:getSize().w) / 2), by)
        badge:free()
    end
    local ah = author:getSize().h
    author:paintTo(bb, x + W - pad - author:getSize().w, title_y + th - ah)

    -- Trashed books: when they were removed, instead of progress.
    if book.trashed then
        local days = math.floor((os.time() - (book.trashed.time or 0)) / 86400)
        local when = (book.trashed.time or 0) <= 0 and _("Removed")
            or days <= 0 and _("Removed today") or days == 1 and _("Removed yesterday")
            or string.format(_("Removed %d days ago"), days)
        local t = self:text(when, self.face_tag)
        t:paintTo(bb, x + self.title_x, title_y + th)
        if pressed then bb:invertRect(x, row_y, W, self.row_h) end
        return
    end

    -- Dots: count follows the book's size, filled dots show how far you've read.
    local max_dots = math.floor(self.title_max / (self.dot + self.dot_gap))
    local total = math.min(math.max(round(math.sqrt(book.size / 1024) * 0.8), 3), max_dots)
    local filled = round(total * percent)
    -- Centred between the bottom of the title and the bottom of the row.
    local dot_y = round((title_y + th + row_y + self.row_h) / 2 - self.dot / 2)
    for d = 0, total - 1 do
        local dx = x + self.title_x + d * (self.dot + self.dot_gap)
        if d < filled then
            bb:paintRect(dx, dot_y - 1, self.dot + 2, self.dot + 2, Blitbuffer.COLOR_BLACK)
        else
            bb:paintRect(dx + 1, dot_y, self.dot, self.dot, Blitbuffer.COLOR_DARK_GRAY)
        end
    end

    -- Progress after the dots: "read" when finished, "23%" while reading, otherwise nothing.
    local label
    if finished then
        label = _("read")
    elseif info.been_opened and percent > 0 then
        label = string.format("%d%%", math.max(1, math.floor(percent * 100)))
    end
    if label then
        local t = self:text(label, self.face_tag)
        local lx = x + self.title_x + total * (self.dot + self.dot_gap) + round(S * 0.008)
        t:paintTo(bb, lx, dot_y + round(self.dot / 2) - round(t:getSize().h / 2))
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
    -- Filter dropdown open: pick an entry, or close it.
    if self.menu_open then
        if self.menu and inside(pos, self.menu) then
            local id = FILTERS[math.floor((pos.y - self.menu.y) / self.menu_row_h) + 1]
            if id and id ~= self.filter then
                self.filter = id
                G_reader_settings:saveSetting("voyage_library_filter", id)
                self:applyView()
                self:layout()
            end
        end
        self.menu_open = false
        self:refresh("partial")
        return true
    end
    if inside(pos, self.sort_hit) then
        local next_sort = SORTS[1]
        for i, s in ipairs(SORTS) do
            if s == self.sort then next_sort = SORTS[i % #SORTS + 1] end
        end
        self.sort = next_sort
        G_reader_settings:saveSetting("voyage_library_sort", next_sort)
        self:sortBooks()
        self:applyView()
        self:clearCache()
        self:layout()
        self:refresh("partial")
    elseif inside(pos, self.filter_hit) then
        self.menu_open = true
        self:refresh("ui")
    elseif inside(pos, self.search_hit) then
        if self.query then
            self:setQuery(nil)
        elseif self.filter == "trash" then
            if #self.books > 0 then self:confirmEmptyTrash() end
        else
            self:showSearch()
        end
    elseif pos.y < self.sub_y then
        self.plugin:openAllSettings()
    else
        local index = self:rowAt(pos)
        if index and self.books[index].trashed then
            self:onHold(nil, ges)
        elseif index then
            self:openBook(index)
        end
    end
    return true
end

function Library:setQuery(text)
    text = text and text:gsub("^%s+", ""):gsub("%s+$", "")
    self.query = (text and text ~= "") and text or nil
    self:applyView()
    self:layout()
    self:refresh("partial")
end

-- Kindle-style search bar over the library; the list filters as you type.
function Library:showSearch()
    UIManager:show(SearchBar:new{
        plugin = self.plugin,
        text = self.query or "",
        on_change = function(text) self:setQuery(text) end,
        on_done = function(text) self:setQuery(text) end,
        on_cancel = function() self:setQuery(nil) end,
    })
end

function Library:confirmEmptyTrash()
    local Dialog = require("dialog")
    UIManager:show(Dialog:new{
        title = _("Empty Trash?"),
        text = string.format(_("%d books and their reading progress, highlights and notes will be deleted for good."), #self.books),
        buttons = {
            { text = _("Cancel") },
            { text = _("Empty Trash"), bold = true, callback = function()
                Trash.empty()
                self:applyView()
                self:layout()
                self:refresh("partial")
            end },
        },
    })
end
-- Long-press a book: the info card (cover, details, Open / Mark as Read / Remove).
function Library:onHold(__, ges)
    local index = self:rowAt(ges.pos)
    local book = index and self.books[index]
    if not book then return true end
    UIManager:show(BookCard:new{
        plugin = self.plugin,
        book = book,
        on_open = function() self:openBook(index) end,
        on_changed = function()
            book.status = nil
            self:applyView()
            self:layout()
            self:refresh("partial")
        end,
        on_removed = function() -- moved to / restored from / deleted from the trash
            self:scan()
            self:layout()
            self:refresh("partial")
        end,
    })
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
    self.clock_tick = self.clock_tick or function() self:clockTick() end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), self.clock_tick)
    return true
end

function Library:onSuspend()
    if self.clock_tick then UIManager:unschedule(self.clock_tick) end
end

function Library:onResume()
    if self.clock_tick then
        UIManager:unschedule(self.clock_tick)
        self:clockTick()
    end
end

function Library:onCloseWidget()
    if self.clock_tick then UIManager:unschedule(self.clock_tick) end
    self:clearCache()
    self.plugin.library = nil
end

return Library
