--[[--
Kindle-style Settings: a status line, "Settings" with ⋮ (KOReader's full menu) and ✕, then
category rows (icon, bold title, optional subtitle, ›) leading to pages of toggles, choices
and actions. Only the settings that matter on Primer; KOReader's own menu stays behind ⋮.
Layout follows a screenshot of a Kindle's Settings (1072px wide).

Row kinds:  page (opens rows)  toggle (switch)  choice (opens a pick-one list)  action  info
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
local datetime = require("datetime")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen


local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function choiceLabel(row)
    local current = row.get()
    for __, c in ipairs(row.choices) do
        if c[2] == current then return c[1] end
    end
    return row.fallback or ""
end

local Settings = InputContainer:extend{
    plugin = nil,
    covers_fullscreen = true,
}

-- Pages ------------------------------------------------------------------------------

function Settings:pages()
    local plugin, ui = self.plugin, self.ui
    local reading = ui.document ~= nil
    local function setting(key, default)
        return function() return G_reader_settings:readSetting(key, default) end,
            function(v) G_reader_settings:saveSetting(key, v) end
    end

    local P = {}

    P.wifi = { title = _("Wi-Fi"), rows = function() return {
        { kind = "toggle", title = _("Wireless"), subtitle = _("Turn all wireless off or on, like airplane mode"),
            get = function() return plugin:isWirelessOn() end,
            set = function(on) plugin:setWireless(on) end },
        { kind = "action", title = _("Wi-Fi networks"), subtitle = plugin:wifiSummary(),
            run = function() plugin:showWifiNetworks() end },
    } end }

    local sleep_get, sleep_set = setting("auto_suspend_timeout_seconds", 600)
    P.device = { title = _("Device options"), rows = function() return {
        { kind = "info", title = _("Battery"),
            subtitle = string.format("%d%%%s", Device:getPowerDevice():getCapacity(),
                Device:getPowerDevice():isCharging() and (" · " .. _("charging")) or "") },
        { kind = "toggle", title = _("Battery percentage"), subtitle = _("Show the percentage next to the battery icon"),
            get = function() return plugin:showBatteryPercent() end,
            set = function(on) G_reader_settings:saveSetting("voyage_battery_percent", on) end },
        { kind = "choice", title = _("Sleep after"), choices = {
                { _("5 minutes"), 300 }, { _("10 minutes"), 600 }, { _("15 minutes"), 900 },
                { _("30 minutes"), 1800 }, { _("1 hour"), 3600 } },
            get = sleep_get,
            set = function(v)
                sleep_set(v)
                local autosuspend = ui.autosuspend
                if autosuspend then
                    autosuspend.auto_suspend_timeout_seconds = v
                    autosuspend:_unschedule()
                    autosuspend:_start()
                end
            end },
        (function()
            local get, set = setting("start_with", "filemanager")
            return { kind = "choice", title = _("When Primer starts"),
                choices = { { _("Open the last book"), "last" }, { _("Show the library"), "filemanager" } },
                get = get, set = set }
        end)(),
        { kind = "toggle", title = _("24-hour clock"),
            subtitle = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")),
            get = function() return not G_reader_settings:isTrue("twelve_hour_clock") end,
            set = function(on)
                G_reader_settings:saveSetting("twelve_hour_clock", not on)
                plugin:onClockSettingChanged()
            end },
        plugin:canAutostart() and { kind = "toggle", title = _("Start Primer at boot"),
            subtitle = _("Instead of the Kindle's home screen when it turns on"),
            get = function() return plugin:isAutostartOn() end,
            set = function(on) plugin:setAutostart(on) end } or false,
        Device:isKindle() and { kind = "toggle", title = _("Ask to connect to a computer"), subtitle = _("When a USB cable to a computer is plugged in"),
            get = function() return G_reader_settings:nilOrTrue("voyage_usb_prompt") end,
            set = function(on) G_reader_settings:saveSetting("voyage_usb_prompt", on) end } or false,
        Device:hasKeys() and { kind = "toggle", title = _("Swap page-turn buttons"),
            get = function() return G_reader_settings:isTrue("input_invert_page_turn_keys") end,
            set = function() UIManager:broadcastEvent(Event:new("SwapPageTurnButtons")) end } or false,
        { kind = "action", title = _("Restart Primer"), run = function()
            self:onClose()
            UIManager:restartKOReader()
        end },
    } end }

    P.screen = { title = _("Screen and brightness"), rows = function() return {
        { kind = "action", title = _("Brightness"), subtitle = _("Open the quick settings panel"),
            run = function()
                self:onClose()
                plugin:showPanel()
            end },
        { kind = "toggle", title = _("Auto brightness"), enabled = plugin:hasLightSensor(),
            get = function() return plugin.auto end, set = function(on) plugin:setAuto(on) end },
        plugin:canAutoRotate() and { kind = "toggle", title = _("Turn for landscape"),
            subtitle = _("Turn the device sideways for two pages side by side"),
            get = function() return plugin:autoRotateOn() end,
            set = function(on) plugin:setAutoRotate(on) end } or false,
        { kind = "toggle", title = _("Dark mode"),
            get = function() return G_reader_settings:isTrue("night_mode") end,
            set = function()
                UIManager:broadcastEvent(Event:new("ToggleNightMode"))
                self:refresh("full")
            end },
        (Device.canDoSwipeAnimation and Device:canDoSwipeAnimation()) and { kind = "toggle", title = _("Page turn animation"),
            subtitle = _("The new page sweeps across the screen, like the Kindle's"),
            get = function() return G_reader_settings:isTrue("swipe_animations") end,
            set = function(on) G_reader_settings:saveSetting("swipe_animations", on) end } or false,
        { kind = "choice", title = _("Full page refresh"), choices = {
                { _("Never"), 0 }, { _("Every 20 pages"), 20 }, { _("Every 40 pages"), 40 } },
            get = function() return G_reader_settings:readSetting("full_refresh_count", 0) end,
            set = function(v) UIManager:setRefreshRate(v, v) end },
        { kind = "toggle", title = _("Refresh at each new chapter"),
            get = function() return G_reader_settings:nilOrTrue("voyage_chapter_flash") end,
            set = function(on) G_reader_settings:saveSetting("voyage_chapter_flash", on) end },
        -- Sleep screen: an image collection (the Kindle's own, or one of Primer's), the book's
        -- cover, or none. A collection is KOReader's random image from that collection's folder.
        (function()
            local collections = plugin:sleepCollections()
            local choices = {}
            for __, c in ipairs(collections) do table.insert(choices, { c.label, c.id }) end
            table.insert(choices, { _("Book cover"), "cover" })
            table.insert(choices, { _("None"), "disable" })
            return { kind = "choice", title = _("Sleep screen"), choices = choices,
                get = function()
                    local kind = G_reader_settings:readSetting("screensaver_type", "random_image")
                    if kind ~= "random_image" then return kind end
                    local dir = G_reader_settings:readSetting("screensaver_dir")
                    for __, c in ipairs(collections) do
                        if c.dir == dir then return c.id end
                    end
                    return collections[1] and collections[1].id or "cover"
                end,
                set = function(v)
                    for __, c in ipairs(collections) do
                        if c.id == v then
                            G_reader_settings:saveSetting("screensaver_type", "random_image")
                            G_reader_settings:saveSetting("screensaver_dir", c.dir)
                            return
                        end
                    end
                    G_reader_settings:saveSetting("screensaver_type", v)
                end }
        end)(),
    } end }

    P.reading = { title = _("Reading"), rows = function() return {
        { kind = "action", title = _("Font and layout"), subtitle = reading and _("Themes, font, size, margins") or _("Open a book first"),
            enabled = reading, run = function()
                self:onClose()
                plugin:showTextSettings()
            end },
        (function()
            local get, set = setting("voyage_reading_progress", "page")
            return { kind = "choice", title = _("Reading progress"),
                choices = { { _("Page in book"), "page" }, { _("Time left in chapter"), "chapter" },
                    { _("Time left in book"), "book" }, { _("None"), "none" } },
                get = get,
                set = function(v)
                    set(v)
                    if reading then ui:handleEvent(Event:new("UpdateFooter", true, true)) end
                end }
        end)(),
        { kind = "toggle", title = _("Show clock while reading"),
            get = function() return G_reader_settings:isTrue("voyage_show_clock") end,
            set = function()
                G_reader_settings:flipNilOrFalse("voyage_show_clock")
                plugin:onClockSettingChanged()
            end },
        { kind = "toggle", title = _("Highlight menu"), subtitle = _("Show the menu when you select text"),
            get = function() return G_reader_settings:readSetting("default_highlight_action", "ask") == "ask" end,
            set = function(on) G_reader_settings:saveSetting("default_highlight_action", on and "ask" or "highlight") end },
    } end }

    P.library = { title = _("Home and Library"), rows = function() return {
        { kind = "toggle", title = _("Kindle-style library"), subtitle = _("Instead of the plain file browser"),
            get = function() return G_reader_settings:nilOrTrue("voyage_library") end,
            set = function(on) G_reader_settings:saveSetting("voyage_library", on) end },
        (function()
            local get, set = setting("voyage_library_sort", "recent")
            return { kind = "choice", title = _("Sort library by"),
                choices = { { _("Most recent first"), "recent" }, { _("Title"), "title" },
                    { _("Author"), "author" }, { _("Newest added"), "added" } },
                get = get, set = set }
        end)(),
    } end }

    P.advanced = { title = _("Advanced"), rows = function()
        local ssh = ui.SSH
        return {
            { kind = "action", title = _("Full settings menu"), subtitle = _("Every option of KOReader, which Primer is built on"),
                run = function()
                    self:onClose()
                    if reading and G_reader_settings:nilOrTrue("show_bottom_menu") then
                        ui:handleEvent(Event:new("ShowConfigMenu"))
                    end
                    ui.menu:onShowMenu()
                end },
            { kind = "toggle", title = _("SSH server"), enabled = ssh ~= nil,
                subtitle = _("For installing Primer updates over Wi-Fi"),
                get = function() return ssh and ssh:isRunning() end,
                set = function(on)
                    if on then ssh:start() else ssh:stop() end
                end },
        }
    end }

    P.about = { title = _("About"), rows = function()
        local ok, version = pcall(function() return require("version"):getCurrentRevision() end)
        return {
            { kind = "info", title = "Primer", subtitle = _("A modern UI frontend for KOReader") },
            { kind = "info", title = _("Built on KOReader"), subtitle = ok and version or "?" },
            { kind = "info", title = _("Device"), subtitle = Device.model or "Kindle" },
        }
    end }

    P.root = { title = _("Settings"), root = true, rows = function() return {
        { kind = "action", icon = "s-person", title = plugin:deviceName(),
            subtitle = Device:isKindle() and _("Rename your Kindle") or _("Rename this device"),
            run = function() self:rename() end },
        { kind = "page", icon = "s-wifi", title = _("Wi-Fi"), page = P.wifi },
        { kind = "page", icon = "s-device", title = _("Device options"), page = P.device },
        { kind = "page", icon = "s-sun", title = _("Screen and brightness"), page = P.screen },
        { kind = "page", icon = "s-reading", title = _("Reading"), page = P.reading },
        { kind = "page", icon = "s-book", title = _("Home and Library"), page = P.library },
        { kind = "page", icon = "s-advanced", title = _("Advanced"), page = P.advanced },
        { kind = "page", icon = "s-help", title = _("About"), page = P.about },
        { kind = "action", icon = "s-exit", title = _("Exit"), subtitle = _("Return to the Kindle home screen"),
            run = function() self:confirmExit() end },
    } end }
    return P
end

-- Widget -----------------------------------------------------------------------------

function Settings:init()
    self.ui = self.plugin.ui
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    -- Sizes scale from the shorter side, so landscape keeps portrait proportions; design x
    -- positions right of centre shift by rx so they stay anchored to the right edge (rx is 0
    -- in portrait).
    self.u = math.min(self.W, self.H) / 1072
    self.rx = self.W - round(1072 * self.u)
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
        if Device.input.group.Back then self.key_events.Back = { { Device.input.group.Back } } end
    end

    self.face_status = Fonts.face("ui", 16)
    self.face_header = Fonts.face("ui_bold", 22)
    self.face_title = Fonts.face("ui_bold", 20)
    self.face_title_light = Fonts.face("ui", 20)
    self.face_sub = Fonts.face("ui", 17)
    self.face_sign = Fonts.face("ui", 28)

    local u = self.u
    self.status_h = round(100 * u)
    self.header_y, self.header_h = self.status_h, round(112 * u)
    self.list_y = self.header_y + self.header_h + round(2 * u)
    self.row_h, self.row_h_sub = round(116 * u), round(145 * u)
    self.line = math.max(1, round(2 * u))

    self.P = self:pages()
    self.stack = { { page = self.P.root, first = 1 } }
end

function Settings:current()
    return self.stack[#self.stack]
end

-- Rows for the current page; a choice page lists its options.
function Settings:rows()
    local cur = self:current()
    if cur.choice then
        local row, rows = cur.choice, {}
        for __, c in ipairs(row.choices) do
            table.insert(rows, { kind = "option", title = c[1], value = c[2], selected = row.get() == c[2] })
        end
        return rows
    end
    -- Rows that don't apply on this device are `false` in the page definition.
    local rows = {}
    for __, row in ipairs(cur.page.rows()) do
        if row then table.insert(rows, row) end
    end
    return rows
end

function Settings:text(str, f, max_width)
    local key = table.concat({ str, tostring(f), tostring(max_width) }, "\0")
    local w = self.cache[key]
    if not w then
        w = TextWidget:new{ text = str, face = f, max_width = max_width }
        self.cache[key] = w
    end
    return w
end

function Settings:paintTo(bb, x, y)
    local ok, err = pcall(self.paintSettings, self, bb, x, y)
    if not ok then
        logger.err("VoyageSettings: paint failed:", err)
        UIManager:nextTick(function() UIManager:close(self) end)
    end
end

function Settings:paintToggle(bb, tx, ty, on)
    local u = self.u
    local w, h = round(104 * u), round(56 * u)
    local r = round(h / 2)
    if on then
        bb:paintRoundedRect(tx, ty, w, h, Blitbuffer.COLOR_BLACK, r)
        bb:paintCircle(tx + w - r, ty + r, r - round(5 * u), Blitbuffer.COLOR_WHITE)
    else
        bb:paintBorder(tx, ty, w, h, self.line, Blitbuffer.COLOR_BLACK, r)
        bb:paintCircle(tx + r, ty + r, r, Blitbuffer.COLOR_BLACK, math.max(2, round(3 * u)))
    end
end

function Settings:paintSettings(bb, x, y)
    local u, W, rx = self.u, self.W, self.rx
    local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    bb:paintRect(x, y, W, self.H, WHITE)
    local cur = self:current()

    -- Status line: time, chevron (closes), wireless and battery.
    local cy = y + round(50 * u)
    local clock = self:text(datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")), self.face_status)
    clock:paintTo(bb, x + round(30 * u), cy - round(clock:getSize().h / 2))
    local chevron = self.plugin:icon("chevron-down", round(126 * u))
    chevron:paintTo(bb, x + round((W - 126 * u) / 2), cy - round(63 * u) - round(14 * u))
    chevron:free()
    local right = self.plugin:paintBattery(bb, x + W - round(30 * u), cy, round(24 * u), self.face_status)
    if self.plugin:isWirelessOn() then
        local s = round(40 * u)
        local wifi = self.plugin:icon("s-wifi", s)
        wifi:paintTo(bb, right - round(26 * u) - s, cy - round(s / 2))
        wifi:free()
    end

    -- Header: title (or ‹ title on sub-pages), ⋮ and ✕.
    local hy = y + self.header_y
    local title = cur.choice and cur.choice.title or cur.page.title
    local head = self:text(cur.page.root and not cur.choice and title or ("‹  " .. title), self.face_header, round(W * 0.7))
    head:paintTo(bb, x + round(64 * u), hy + round((self.header_h - head:getSize().h) / 2))
    local s = round(44 * u)
    local kebab = self.plugin:icon("kebab", s)
    kebab:paintTo(bb, x + rx + round(914 * u) - round(s / 2), hy + round((self.header_h - s) / 2))
    kebab:free()
    local close = self.plugin:icon("close", s)
    close:paintTo(bb, x + rx + round(1015 * u) - round(s / 2), hy + round((self.header_h - s) / 2))
    close:free()
    bb:paintRect(x, y + self.list_y - round(3 * u), W, round(3 * u), Blitbuffer.COLOR_LIGHT_GRAY)

    -- Rows
    local rows = self:rows()
    self.row_hits = {}
    local ry = self.list_y
    local i = cur.first
    while rows[i] do
        local row = rows[i]
        local subtitle = row.subtitle
        if row.kind == "choice" then subtitle = choiceLabel(row) end
        local h = subtitle and self.row_h_sub or self.row_h
        if ry + h > self.H then break end
        local enabled = row.enabled ~= false
        local tx = x + (row.icon and round(137 * u) or round(64 * u))
        if row.icon then
            local is = round(44 * u)
            local icon = self.plugin:icon(row.icon, is)
            icon:paintTo(bb, x + round(86 * u) - round(is / 2), y + ry + round((h - is) / 2))
            icon:free()
        end
        local right_w = (row.kind == "toggle") and round(170 * u) or round(120 * u)
        local tw = self:text(row.title, (row.kind == "option" and not row.selected) and self.face_title_light or self.face_title,
            W - (tx - x) - right_w)
        local sw = subtitle and self:text(subtitle, self.face_sub, W - (tx - x) - right_w)
        local total = tw:getSize().h + (sw and sw:getSize().h + round(4 * u) or 0)
        local ty = y + ry + round((h - total) / 2)
        tw:paintTo(bb, tx, ty)
        if sw then sw:paintTo(bb, tx, ty + tw:getSize().h + round(4 * u)) end

        if row.kind == "page" or row.kind == "choice" or row.kind == "action" then
            local chev = self:text("›", self.face_sign)
            chev:paintTo(bb, x + rx + round(985 * u) - round(chev:getSize().w / 2), y + ry + round((h - chev:getSize().h) / 2))
        elseif row.kind == "toggle" then
            self:paintToggle(bb, x + W - round(64 * u) - round(104 * u), y + ry + round((h - 56 * u) / 2), row.get() and true or false)
        elseif row.kind == "option" and row.selected then
            local cs = round(44 * u)
            local check = self.plugin:icon("check", cs)
            check:paintTo(bb, x + rx + round(985 * u) - round(cs / 2), y + ry + round((h - cs) / 2))
            check:free()
        end
        if not enabled then
            -- Greyed out: wash the row with light grey dither.
            bb:lightenRect(x, y + ry, W, h, 0.6)
        end
        table.insert(self.row_hits, { row = row, rect = Geom:new{ x = 0, y = ry, w = W, h = h } })
        ry = ry + h
        bb:paintRect(x + round(32 * u), y + ry - self.line, W - round(64 * u), self.line, Blitbuffer.COLOR_LIGHT_GRAY)
        i = i + 1
    end
    self.last_shown = i - 1
    self.total_rows = #rows
end

-- Navigation -------------------------------------------------------------------------

function Settings:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function Settings:push(entry)
    entry.first = 1
    table.insert(self.stack, entry)
    self:refresh("partial")
end

function Settings:onBack()
    if #self.stack > 1 then
        table.remove(self.stack)
        self:refresh("partial")
        return true
    end
    return self:onClose()
end

function Settings:onNextPage()
    if self.last_shown and self.last_shown < self.total_rows then
        self:current().first = self.last_shown + 1
        self:refresh("partial")
    end
    return true
end

function Settings:onPrevPage()
    local cur = self:current()
    if cur.first > 1 then
        cur.first = math.max(1, cur.first - 6)
        self:refresh("partial")
    end
    return true
end

function Settings:rename()
    UIManager:show(Prompt:new{
        title = _("Rename your Kindle"),
        text = self.plugin:deviceName(),
        ok_text = _("Save"),
        on_ok = function(name)
            if not name:match("%S") then return false end
            G_reader_settings:saveSetting("voyage_device_name", name)
            self:refresh()
        end,
    })
end

-- Exit Primer to the Kindle's own interface, after a Kindle-style confirmation.
function Settings:confirmExit()
    local Dialog = require("dialog")
    UIManager:show(Dialog:new{
        title = _("Exit Primer?"),
        text = _("Your place is saved. Your Kindle will return to its home screen."),
        buttons = {
            { text = _("Cancel") },
            { text = _("Exit"), bold = true, callback = function()
                self:onClose()
                -- Quit explicitly once the book/library has closed and saved.
                self.ui.menu:exitOrRestart(function() UIManager:quit() end)
            end },
        },
    })
end

function Settings:onTap(__, ges)
    local pos, u, rx = ges.pos, self.u, self.rx
    -- Status chevron or ✕ close; ⋮ opens KOReader's full menu; ‹ title goes back.
    if pos.y < self.status_h and math.abs(pos.x - self.W / 2) < self.W * 0.15 then return self:onClose() end
    if pos.y >= self.header_y and pos.y < self.header_y + self.header_h then
        if pos.x > rx + round(965 * u) then return self:onClose() end
        if pos.x > rx + round(860 * u) then
            self:onClose()
            self.ui.menu:onShowMenu()
            return true
        end
        if #self.stack > 1 and pos.x < self.W * 0.6 then return self:onBack() end
        return true
    end
    for __, hit in ipairs(self.row_hits or {}) do
        if inside(pos, hit.rect) then
            local row = hit.row
            if row.enabled == false or row.kind == "info" then return true end
            if row.kind == "page" then
                self:push{ page = row.page }
            elseif row.kind == "choice" then
                self:push{ page = self:current().page, choice = row }
            elseif row.kind == "option" then
                self:current().choice.set(row.value)
                self:onBack()
            elseif row.kind == "toggle" then
                row.set(not row.get())
                self:refresh("fast")
            elseif row.kind == "action" then
                row.run()
            end
            return true
        end
    end
    return true
end

function Settings:onSwipe(__, ges)
    if ges.direction == "west" or ges.direction == "north" then return self:onNextPage() end
    if ges.direction == "east" then return self:onBack() end
    if ges.direction == "south" then
        if ges.pos.y < self.list_y then return self:onClose() end
        return self:onPrevPage()
    end
    return true
end

function Settings:onShow()
    self:refresh("ui")
    return true
end

function Settings:onClose()
    UIManager:close(self)
    return true
end

function Settings:onCloseWidget()
    for __, w in pairs(self.cache) do w:free() end
    self.cache = {}
    self.plugin.settings_view = nil
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return Settings
