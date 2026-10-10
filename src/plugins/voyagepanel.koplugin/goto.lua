--[[--
Kindle-style Go To: the book's chapters with page numbers, the current chapter marked,
tap one to go there. "Page…" (top right) jumps to a page number; the Notes tab opens your
highlights and bookmarks. Swipe or use the page buttons to move through long contents.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Prompt = require("prompt")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen


local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local GoTo = InputContainer:extend{
    plugin = nil,
    covers_fullscreen = true,
}

function GoTo:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.u = self.W / 1072
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
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
        if Device.input.group.Back then self.key_events.Close = { { Device.input.group.Back } } end
    end

    self.face_header = Fonts.face("ui_bold", 21)
    self.face_action = Fonts.face("ui", 18)
    self.face_tab = Fonts.face("ui", 18)
    self.face_tab_on = Fonts.face("ui_bold", 18)
    self.face_row = Fonts.face("ui", 18)
    self.face_row_on = Fonts.face("ui_bold", 18)
    self.face_page = Fonts.face("ui", 16)
    self.face_small = Fonts.face("ui", 14)

    -- Contents
    self.ui.toc:fillToc()
    self.items = {}
    local min_depth = math.huge
    for __, item in ipairs(self.ui.toc.toc or {}) do
        if item.page then
            table.insert(self.items, item)
            min_depth = math.min(min_depth, item.depth or 1)
        end
    end
    self.min_depth = min_depth == math.huge and 1 or min_depth
    local cur_page = self.ui:getCurrentPage()
    self.current = self.ui.toc:getTocIndexByPage(cur_page)

    self:layout()
    -- Open on the page of the list that holds the current chapter.
    self.page = self.current and math.ceil(self.current / self.per_page) or 1
end

function GoTo:layout()
    local u = self.u
    self.pad = round(53 * u)
    self.line = math.max(1, round(2 * u))
    self.thick = math.max(2, round(3 * u))
    self.header_h = round(110 * u)
    self.tabs_y, self.tab_h = self.header_h, round(100 * u)
    self.list_y = self.tabs_y + self.tab_h + self.line
    self.row_h = round(96 * u)
    self.footer_h = round(80 * u)
    self.per_page = math.max(1, math.floor((self.H - self.list_y - self.footer_h) / self.row_h))
    self.pages = math.max(1, math.ceil(#self.items / self.per_page))

    self.back_hit = Geom:new{ x = 0, y = 0, w = round(self.W * 0.55), h = self.header_h }
    self.page_hit = Geom:new{ x = round(self.W * 0.6), y = 0, w = round(self.W * 0.4), h = self.header_h }
    self.contents_tab = Geom:new{ x = 0, y = self.tabs_y, w = round(300 * u), h = self.tab_h }
    self.notes_tab = Geom:new{ x = round(300 * u), y = self.tabs_y, w = round(260 * u), h = self.tab_h }
end

function GoTo:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

function GoTo:paintTo(bb, x, y)
    local ok, err = pcall(self.paintGoTo, self, bb, x, y)
    if not ok then
        logger.err("VoyageGoTo: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function GoTo:pageLabel(item)
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() and self.ui.pagemap.getXPointerPageLabel and item.xpointer then
        return self.ui.pagemap:getXPointerPageLabel(item.xpointer, true) or tostring(item.page)
    end
    return tostring(item.page)
end

function GoTo:paintGoTo(bb, x, y)
    local u, W, pad = self.u, self.W, self.pad
    local BLACK = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, W, self.H, Blitbuffer.COLOR_WHITE)

    -- Header: "‹  Go To" closes; "Page…" on the right.
    local title = self:text("‹  " .. _("Go To"), self.face_header)
    title:paintTo(bb, x + pad, y + round((self.header_h - title:getSize().h) / 2))
    local page_btn = self:text(_("Page…"), self.face_action)
    page_btn:paintTo(bb, x + W - pad - page_btn:getSize().w, y + round((self.header_h - page_btn:getSize().h) / 2))
    bb:paintRect(x, y + self.header_h - self.line, W, self.line, Blitbuffer.COLOR_LIGHT_GRAY)

    -- Tabs: Contents (this view) and Notes.
    local tab_pad = round(16 * u)
    local contents = self:text(_("Contents"), self.face_tab_on)
    local cx = x + pad
    contents:paintTo(bb, cx, y + self.tabs_y + round((self.tab_h - contents:getSize().h) / 2))
    bb:paintRect(cx - tab_pad, y + self.list_y - self.line - round(10 * u), contents:getSize().w + 2 * tab_pad, round(10 * u), BLACK)
    local notes = self:text(_("Notes"), self.face_tab)
    notes:paintTo(bb, x + round(345 * u), y + self.tabs_y + round((self.tab_h - notes:getSize().h) / 2))
    bb:paintRect(x, y + self.list_y - self.line, W, self.line, BLACK)

    -- Chapters
    if #self.items == 0 then
        local none = self:text(_("This book has no table of contents."), self.face_row)
        none:paintTo(bb, x + round((W - none:getSize().w) / 2), y + self.list_y + self.row_h)
    end
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.items, first + self.per_page - 1) do
        local item = self.items[i]
        local ry = y + self.list_y + (i - first) * self.row_h
        local is_current = i == self.current
        local indent = round(((item.depth or 1) - self.min_depth) * 40 * u)
        local num = self:text(self:pageLabel(item), self.face_page)
        local num_x = x + W - pad - num:getSize().w
        local label = self:text(self.ui.toc:cleanUpTocTitle(item.title or "", true),
            is_current and self.face_row_on or self.face_row, num_x - (x + pad + indent) - round(30 * u))
        label:paintTo(bb, x + pad + indent, ry + round((self.row_h - label:getSize().h) / 2))
        num:paintTo(bb, num_x, ry + round((self.row_h - num:getSize().h) / 2))
        if is_current then
            -- A bar in the left margin marks where you are.
            bb:paintRect(x + round(pad / 2) - round(4 * u), ry + round(self.row_h * 0.25), round(8 * u), round(self.row_h * 0.5), BLACK)
        end
        bb:paintRect(x + pad, ry + self.row_h - self.line, W - 2 * pad, self.line, Blitbuffer.COLOR_LIGHT_GRAY)
    end

    if self.pages > 1 then
        local pg = self:text(string.format(_("Page %d of %d"), self.page, self.pages), self.face_small)
        pg:paintTo(bb, x + round((W - pg:getSize().w) / 2), y + self.H - self.footer_h + round((self.footer_h - pg:getSize().h) / 2))
    end
end

function GoTo:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function GoTo:goToPage(p)
    p = math.min(math.max(p, 1), self.pages)
    if p ~= self.page then
        self.page = p
        self:refresh("partial")
    end
    return true
end

function GoTo:onNextPage() return self:goToPage(self.page + 1) end
function GoTo:onPrevPage() return self:goToPage(self.page - 1) end

-- Page number entry. Books with publisher page labels keep KOReader's dialog, which knows them.
function GoTo:askPage()
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        self:onClose()
        return self.ui.gotopage:onShowGotoDialog()
    end
    local pages = self.ui.document:getPageCount()
    UIManager:show(Prompt:new{
        title = _("Go to Page"),
        description = string.format(_("You are on page %d of %d."), self.ui:getCurrentPage(), pages),
        hint = string.format(_("Page (1–%d)"), pages),
        input_type = "number",
        ok_text = _("Go"),
        on_ok = function(text, prompt)
            local p = tonumber(text)
            if not p or p < 1 or p > pages or p % 1 ~= 0 then
                prompt:setMessage(string.format(_("Enter a page from 1 to %d."), pages))
                return false
            end
            self:onClose()
            self.ui.link:addCurrentLocationToStack()
            self.ui:handleEvent(Event:new("GotoPage", p))
        end,
    })
end

function GoTo:onTap(__, ges)
    local pos = ges.pos
    if inside(pos, self.back_hit) then return self:onClose() end
    if inside(pos, self.page_hit) then
        self:askPage()
        return true
    end
    if inside(pos, self.notes_tab) then
        self:onClose()
        self.plugin:showNotebook()
        return true
    end
    if pos.y >= self.list_y then
        local row = math.floor((pos.y - self.list_y) / self.row_h)
        local i = (self.page - 1) * self.per_page + row + 1
        local item = row < self.per_page and self.items[i]
        if item then
            self:onClose()
            self.ui.link:addCurrentLocationToStack()
            self.ui:handleEvent(Event:new("GotoPage", item.page))
        end
    end
    return true
end

function GoTo:onSwipe(__, ges)
    if ges.direction == "west" or ges.direction == "north" then
        return self:onNextPage()
    elseif ges.direction == "east" or ges.direction == "south" then
        return self:onPrevPage()
    end
    return true
end

function GoTo:onShow()
    self:refresh("ui")
    return true
end

function GoTo:onClose()
    UIManager:close(self)
    return true
end

function GoTo:onCloseWidget()
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.plugin.goto_view = nil
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return GoTo
