--[[--
Voyage quick panel: a Kindle-style quick settings panel opened by swiping down
from the top edge (tapping the top still opens KOReader's full menus).
Also owns Auto Brightness, driven by the Voyage's ambient light sensor.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local IconWidget = require("ui/widget/iconwidget")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local NetworkMgr = require("ui/network/manager")
local Library = require("library")
local QuickPanel = require("quickpanel")
local Toolbar = require("toolbar")
local AaPanel = require("aapanel")
local Dialog = require("dialog")
local PageFlip = require("pageflip")
local GoTo = require("goto")
local Lookup = require("lookup")
local Font = require("ui/font")
local FontChooser = require("ui/widget/fontchooser")
local TextWidget = require("ui/widget/textwidget")
local datetime = require("datetime")
local Screen = Device.screen

local AUTO_INTERVAL_S = 3

local VoyagePanel = WidgetContainer:extend{
    name = "voyagepanel",
    is_doc_only = false,
}

-- Swipe down from the top edge opens the panel instead of KOReader's menus.
local function hookSwipe(MenuClass)
    if MenuClass._voyage_swipe_hooked then return end
    MenuClass._voyage_swipe_hooked = true
    local orig = MenuClass.onSwipeShowMenu
    function MenuClass:onSwipeShowMenu(ges)
        local plugin = self.ui and self.ui.voyagepanel
        if plugin and ges.direction == "south" then
            -- Open only once the swipe is finished: opening mid-pan would let the rest of the
            -- finger's movement land on the panel's brightness slider.
            if ges.ges == "swipe" then
                plugin:showPanel()
            end
            self.ui:handleEvent(Event:new("HandledAsSwipe")) -- cancel any pan scroll made
            return true
        end
        return orig(self, ges)
    end
end
hookSwipe(require("apps/reader/modules/readermenu"))
hookSwipe(require("apps/filemanager/filemanagermenu"))

-- Swiping up from the bottom while reading opens the Kindle-style page flip instead of
-- KOReader's settings bar. Like the quick panel, it opens once the swipe is finished.
do
    local ReaderConfig = require("apps/reader/modules/readerconfig")
    if not ReaderConfig._voyage_swipe_hooked then
        ReaderConfig._voyage_swipe_hooked = true
        local orig = ReaderConfig.onSwipeShowConfigMenu
        function ReaderConfig:onSwipeShowConfigMenu(ges)
            local plugin = self.ui and self.ui.voyagepanel
            if plugin and ges.direction == "north" then
                if ges.ges == "swipe" then plugin:showPageFlip() end
                return true
            end
            return orig(self, ges)
        end
    end
end

-- Kindle-style word lookup: dictionary results show as a card plus a selection bar, and a
-- new multi-word selection shows the bar instead of KOReader's highlight dialog. Wikipedia
-- lookups and taps on existing highlights keep KOReader's own windows.
do
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    if not ReaderDictionary._voyage_hooked then
        ReaderDictionary._voyage_hooked = true
        local orig_showDict = ReaderDictionary.showDict
        function ReaderDictionary:showDict(word, results, boxes, link, dict_close_callback)
            local plugin = self.ui and self.ui.voyagepanel
            if not (plugin and self.ui.document and not self.is_wiki and results and results[1]
                    and G_reader_settings:nilOrTrue("voyage_kindle_lookup")) then
                return orig_showDict(self, word, results, boxes, link, dict_close_callback)
            end
            self:dismissLookupInfo()
            local highlight = self.highlight
            plugin:showLookup{
                highlight = highlight,
                word = word,
                results = results,
                boxes = boxes,
                on_close = dict_close_callback,
                full_lookup = function()
                    orig_showDict(self, word, results, boxes, link, dict_close_callback)
                end,
                more_menu = highlight and function()
                    -- Straight to KOReader's full highlight dialog (bypassing our bar hook).
                    highlight._voyage_full_menu = true
                    highlight:onShowHighlightMenu()
                    highlight._voyage_full_menu = nil
                end,
            }
        end
    end

    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    if not ReaderHighlight._voyage_hooked then
        ReaderHighlight._voyage_hooked = true
        local orig_menu = ReaderHighlight.onShowHighlightMenu
        function ReaderHighlight:onShowHighlightMenu(index)
            local plugin = self.ui and self.ui.voyagepanel
            if index or self._voyage_full_menu or not (plugin and self.selected_text and self.hold_pos)
                    or not G_reader_settings:nilOrTrue("voyage_kindle_lookup") then
                return orig_menu(self, index)
            end
            local boxes = {}
            for i, sbox in ipairs(self.selected_text.sboxes or {}) do
                boxes[i] = self.view:pageToScreenTransform(self.hold_pos.page, sbox)
            end
            plugin:showLookup{
                highlight = self,
                word = self.selected_text.text,
                boxes = boxes,
                more_menu = function()
                    -- KOReader's full highlight dialog, for everything the bar doesn't cover.
                    self._voyage_full_menu = true
                    orig_menu(self)
                    self._voyage_full_menu = nil
                end,
            }
        end
    end
end

-- Tapping the top while reading opens the Kindle-style toolbar instead of KOReader's menus.
do
    local ReaderMenu = require("apps/reader/modules/readermenu")
    if not ReaderMenu._voyage_tap_hooked then
        ReaderMenu._voyage_tap_hooked = true
        local orig = ReaderMenu.onTapShowMenu
        function ReaderMenu:onTapShowMenu(ges)
            local plugin = self.ui and self.ui.voyagepanel
            if plugin and G_reader_settings:nilOrTrue("voyage_toolbar") then
                plugin:showToolbar()
                return true
            end
            return orig(self, ges)
        end
    end
end

-- Show Clock While Reading: the time centered in the top margin, like the Kindle.
do
    local ReaderView = require("apps/reader/modules/readerview")
    if not ReaderView._voyage_clock_hooked then
        ReaderView._voyage_clock_hooked = true
        local orig = ReaderView.paintTo
        function ReaderView:paintTo(bb, x, y)
            orig(self, bb, x, y)
            local plugin = self.ui and self.ui.voyagepanel
            if plugin and G_reader_settings:isTrue("voyage_show_clock") then
                local ok, err = pcall(plugin.paintClock, plugin, bb, x, y)
                if not ok then logger.err("VoyageClock: paint failed:", err) end
            end
        end
    end
end

-- USB: KOReader lives on the drive the Kindle lends to a computer, so it can't stay running
-- while mounted. When a computer is plugged in, offer to step aside; a small script brings
-- KOReader back once the drive is ejected (tools/usb-handoff.sh).
local USB_GADGET = "/sys/devices/platform/fsl-usb2-udc/gadget/connected"
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")

local function computerConnected()
    local f = io.open(USB_GADGET, "r")
    if not f then return false end
    local v = f:read("*l")
    f:close()
    return v == "1"
end

local function activePlugin()
    local ReaderUI = require("apps/reader/readerui")
    local FileManager = require("apps/filemanager/filemanager")
    local ui = ReaderUI.instance or FileManager.instance
    return ui and ui.voyagepanel
end

do
    if not UIManager._voyage_usb_hooked and Device:isKindle() then
        UIManager._voyage_usb_hooked = true
        local orig = UIManager.event_handlers.Charging
        if orig then
            UIManager.event_handlers.Charging = function(...)
                orig(...)
                -- A computer takes a moment to enumerate; a wall charger never does.
                local tries = 0
                local function check()
                    tries = tries + 1
                    if computerConnected() then
                        local plugin = activePlugin()
                        if plugin then plugin:offerUsbMode() end
                    elseif tries < 8 then
                        UIManager:scheduleIn(0.5, check)
                    end
                end
                UIManager:scheduleIn(0.5, check)
            end
        end
    end
end

-- Stock Kindle sleep screens: copy them where KOReader's random-image screensaver can use
-- them (once; tools/stock-screensavers.sh only copies files that are missing).
do
    local marker = "/mnt/us/screensavers/bg_ss00.png"
    local existing = io.open(marker, "r")
    if existing then
        existing:close()
    elseif Device:isKindle() and not UIManager._voyage_screensavers then
        UIManager._voyage_screensavers = true
        os.execute(string.format("sh '%s/tools/stock-screensavers.sh' >/dev/null 2>&1 &", PLUGIN_DIR))
    end
end

-- Ambient light, in lux, from the Kindle's power daemon. nil when unavailable.
local lipc_handle
local function readLux()
    if lipc_handle == nil then
        local ok, lipc = pcall(require, "liblipclua")
        lipc_handle = ok and lipc and lipc.init("com.github.koreader.voyagepanel") or false
    end
    if not lipc_handle then return nil end
    local ok, lux = pcall(lipc_handle.get_int_property, lipc_handle, "com.lab126.powerd", "alsLux")
    if ok and type(lux) == "number" then return lux end
end

-- Darker rooms get a dimmer light: 0 lux -> lowest step, ~10k lux (daylight) -> full.
local function luxToLevel(lux, lo, hi)
    local frac = math.min(math.max(math.log10(lux + 1) / 4, 0), 1)
    return lo + math.floor(frac * (hi - lo) + 0.5)
end

function VoyagePanel:init()
    self.auto_tick = function() self:autoTick() end
    self.auto = G_reader_settings:isTrue("voyage_auto_brightness") and self:hasLightSensor()
    if self.auto then
        UIManager:scheduleIn(1, self.auto_tick)
    end
    self.clock_tick = function() self:clockTick() end
    if self.ui.document then self:onClockSettingChanged() end
    -- The Kindle-style library replaces the file browser as home. Plugins are created
    -- before the file browser builds its file list, so check once it has.
    if G_reader_settings:nilOrTrue("voyage_library") then
        UIManager:nextTick(function()
            if self.ui.file_chooser then self:showLibrary() end
        end)
    end
end

function VoyagePanel:deviceName()
    return G_reader_settings:readSetting("voyage_device_name") or "Kindle Voyage"
end

local function wirelessHandle()
    local ok, lipc = pcall(require, "liblipclua")
    return ok and lipc and lipc.init("com.github.koreader.voyagepanel.wireless") or nil
end

-- The Kindle's master wireless switch, read directly so toggles show immediately
-- (the network interface lags behind it).
function VoyagePanel:isWirelessOn()
    local handle = wirelessHandle()
    if not handle then return NetworkMgr:isWifiOn() end
    local ok, value = pcall(handle.get_int_property, handle, "com.lab126.cmd", "wirelessEnable")
    handle:close()
    if ok and type(value) == "number" then return value == 1 end
    return NetworkMgr:isWifiOn()
end

-- Flip the wireless radio like the Kindle's airplane mode: no connection attempt, no
-- network list, no popups. The Kindle's own wifid rejoins saved networks by itself.
-- Returns false when lipc isn't available (non-Kindle), so callers can fall back.
function VoyagePanel:setWireless(on)
    local handle = wirelessHandle()
    if not handle then return false end
    if on then
        handle:set_int_property("com.lab126.cmd", "wirelessEnable", 1)
        handle:set_int_property("com.lab126.wifid", "enable", 1)
    else
        handle:set_int_property("com.lab126.wifid", "enable", 0)
        handle:set_int_property("com.lab126.cmd", "wirelessEnable", 0)
    end
    handle:close()
    return true
end

-- A drawn battery whose right edge (with nub) sits at `right`; returns its left x.
function VoyagePanel:paintBattery(bb, right, cy, h)
    local border = math.max(2, math.floor(h / 9 + 0.5))
    local w = math.floor(h * 2.1 + 0.5)
    local x = right - w - border
    local top = cy - math.floor(h / 2 + 0.5)
    bb:paintRect(x + w, top + math.floor(h * 0.3 + 0.5), border, math.floor(h * 0.4 + 0.5), Blitbuffer.COLOR_BLACK)
    bb:paintBorder(x, top, w, h, border, Blitbuffer.COLOR_BLACK)
    local capacity = math.min(math.max(Device:getPowerDevice():getCapacity(), 0), 100)
    local fill = math.floor((w - 4 * border) * capacity / 100 + 0.5)
    if fill > 0 then
        bb:paintRect(x + 2 * border, top + 2 * border, fill, h - 4 * border, Blitbuffer.COLOR_BLACK)
    end
    return x
end

function VoyagePanel:icon(name, size)
    return IconWidget:new{ file = self.path .. "/icons/" .. name .. ".svg", width = size, height = size }
end

function VoyagePanel:showToolbar()
    if self.toolbar then return end
    local ok, err = pcall(function()
        self.toolbar = Toolbar:new{ plugin = self, icon_dir = self.path .. "/icons" }
        UIManager:show(self.toolbar)
    end)
    if not ok then
        logger.err("VoyageToolbar: failed to open:", err)
        self.toolbar = nil
        UIManager:show(InfoMessage:new{ text = "Toolbar error:\n" .. tostring(err) })
    end
end

function VoyagePanel:showPageFlip()
    if self.pageflip or not self.ui.document then return end
    local ok, err = pcall(function()
        self.pageflip = PageFlip:new{ plugin = self }
        UIManager:show(self.pageflip)
    end)
    if not ok then
        logger.err("VoyagePageFlip: failed to open:", err)
        self.pageflip = nil
        UIManager:show(InfoMessage:new{ text = "Page flip error:\n" .. tostring(err) })
    end
end

function VoyagePanel:showLookup(args)
    if self.lookup then UIManager:close(self.lookup) end
    local ok, err = pcall(function()
        args.plugin = self
        self.lookup = Lookup:new(args)
        UIManager:show(self.lookup)
    end)
    if not ok then
        logger.err("VoyageLookup: failed to open:", err)
        self.lookup = nil
        UIManager:show(InfoMessage:new{ text = "Lookup error:\n" .. tostring(err) })
    end
end

-- Go To: Kindle-style chapter list.
function VoyagePanel:showGoTo()
    if self.goto_view or not self.ui.document then return end
    local ok, err = pcall(function()
        self.goto_view = GoTo:new{ plugin = self }
        UIManager:show(self.goto_view)
    end)
    if not ok then
        logger.err("VoyageGoTo: failed to open:", err)
        self.goto_view = nil
        UIManager:show(InfoMessage:new{ text = "Go To error:\n" .. tostring(err) })
    end
end

-- Aa: the Kindle-style Themes / Font / Layout / More panel.
function VoyagePanel:showTextSettings()
    if self.aapanel then return end
    local ok, err = pcall(function()
        self.aapanel = AaPanel:new{ plugin = self }
        UIManager:show(self.aapanel)
    end)
    if not ok then
        logger.err("VoyageAa: failed to open:", err)
        self.aapanel = nil
        UIManager:show(InfoMessage:new{ text = "Aa panel error:\n" .. tostring(err) })
    end
end

function VoyagePanel:offerUsbMode()
    if self.usb_dialog then return end
    self.usb_dialog = Dialog:new{
        title = _("Connect to Computer"),
        text = _("Use your Kindle as a USB drive? KOReader will close while it's connected and come back when you eject it."),
        buttons = {
            { text = _("Not Now"), callback = function() self.usb_dialog = nil end },
            { text = _("Connect"), bold = true, callback = function()
                self.usb_dialog = nil
                self:enterUsbMode()
            end },
        },
    }
    UIManager:show(self.usb_dialog)
end

function VoyagePanel:enterUsbMode()
    -- The script must run from outside /mnt/us, which vanishes while the drive is mounted.
    local src, dst = PLUGIN_DIR .. "/tools/usb-handoff.sh", "/tmp/voyage-usb-handoff.sh"
    if os.execute(string.format("cp '%s' %s", src, dst)) ~= 0 then
        UIManager:show(InfoMessage:new{ text = _("Couldn't start USB mode."), timeout = 3 })
        return
    end
    -- Detach so it outlives KOReader (fall back to plain sh if this busybox lacks setsid).
    os.execute(string.format("(command -v setsid >/dev/null && setsid sh %s || sh %s) </dev/null >/dev/null 2>&1 &", dst, dst))
    -- KOReader takes a few seconds to close and hand over; say what's happening meanwhile.
    UIManager:show(InfoMessage:new{ text = _("Switching to USB drive mode…"), dismissable = false })
    UIManager:forceRePaint()
    -- KOReader only exits on its own once no windows are left, and this message is one,
    -- so quit explicitly after the book/library has closed and saved.
    UIManager:nextTick(function()
        self.ui.menu:exitOrRestart(function() UIManager:quit() end)
    end)
end

function VoyagePanel:showLibrary()
    if self.library then return end
    local ok, err = pcall(function()
        self.library = Library:new{ plugin = self }
        UIManager:show(self.library)
    end)
    if not ok then
        logger.err("VoyageLibrary: failed to open:", err)
        self.library = nil
        UIManager:show(InfoMessage:new{ text = "Library error:\n" .. tostring(err) })
    end
end

function VoyagePanel:hasLightSensor()
    return Device:hasLightSensor() and readLux() ~= nil
end

function VoyagePanel:setAuto(enabled)
    self.auto = enabled
    G_reader_settings:saveSetting("voyage_auto_brightness", enabled)
    UIManager:unschedule(self.auto_tick)
    if enabled then self:autoTick() end
end

function VoyagePanel:autoTick()
    if not self.auto then return end
    local lux = readLux()
    local powerd = Device:getPowerDevice()
    if lux and powerd:isFrontlightOn() then
        local lo, hi = QuickPanel.frontlightRange()
        local target = luxToLevel(lux, lo, hi)
        local current = powerd:frontlightIntensity()
        -- Small hysteresis so the light doesn't hunt between two steps.
        if math.abs(target - current) >= 2 or ((target == lo or target == hi) and target ~= current) then
            powerd:setIntensity(target)
            powerd:updateResumeFrontlightState()
            if self.panel then self.panel:refreshBrightness() end
        end
    end
    UIManager:scheduleIn(AUTO_INTERVAL_S, self.auto_tick)
end

-- Kindle-style refresh: flash-free (REAGL) page turns with no forced flash every N pages
-- (full_refresh_count = 0), and one clean full refresh when a new chapter starts.
function VoyagePanel:onPageUpdate(pageno)
    if pageno and self.ui.toc and G_reader_settings:nilOrTrue("voyage_chapter_flash")
            and self.ui.toc:isChapterStart(pageno) then
        UIManager:setDirty(nil, "full")
    end
end

function VoyagePanel:onSuspend()
    UIManager:unschedule(self.auto_tick)
    UIManager:unschedule(self.clock_tick)
end

function VoyagePanel:onResume()
    if self.auto then UIManager:scheduleIn(1, self.auto_tick) end
    if self.ui.document then self:onClockSettingChanged() end
end

function VoyagePanel:paintClock(bb, x, y)
    local file = "/usr/java/lib/fonts/Amazon-Ember-Bold.ttf"
    local f = FontChooser.isFontRegistered(file) and Font:getFace(file, 14) or Font:getFace("ffont", 14)
    local w = TextWidget:new{ text = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")), face = f }
    local size = w:getSize()
    local margin = Screen:scaleBySize(self.ui.document.configurable.t_page_margin or 30)
    local cx = math.floor((Screen:getWidth() - size.w) / 2)
    local cy = math.max(0, math.floor((margin - size.h) / 2))
    w:paintTo(bb, x + cx, y + cy)
    w:free()
    self.clock_rect = { x = cx, y = cy, w = size.w, h = size.h }
end

-- Repaint the clock at each minute boundary while it's shown.
function VoyagePanel:clockTick()
    if not (self.ui.document and G_reader_settings:isTrue("voyage_show_clock")) then return end
    local Geom = require("ui/geometry")
    local r = self.clock_rect
    local region = r and Geom:new{ x = r.x - r.w, y = r.y, w = r.w * 3, h = r.h } or nil
    UIManager:setDirty(self.ui, function() return "ui", region end)
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), self.clock_tick)
end

function VoyagePanel:onClockSettingChanged()
    UIManager:unschedule(self.clock_tick)
    if G_reader_settings:isTrue("voyage_show_clock") then
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), self.clock_tick)
    end
    if self.ui.document then UIManager:setDirty(self.ui, "ui") end
end

function VoyagePanel:onCloseWidget()
    UIManager:unschedule(self.auto_tick)
    UIManager:unschedule(self.clock_tick)
    if self.panel then UIManager:close(self.panel) end
    if self.library then UIManager:close(self.library) end
    if self.toolbar then UIManager:close(self.toolbar) end
    if self.aapanel then UIManager:close(self.aapanel) end
    if self.pageflip then UIManager:close(self.pageflip) end
    if self.goto_view then UIManager:close(self.goto_view) end
    if self.lookup then UIManager:close(self.lookup) end
end

function VoyagePanel:showPanel()
    if self.panel then return end
    local ok, err = pcall(function()
        self.panel = QuickPanel:new{
            plugin = self,
            icon_dir = self.path .. "/icons",
        }
        UIManager:show(self.panel)
    end)
    if not ok then
        logger.err("VoyagePanel: failed to open:", err)
        self.panel = nil
        UIManager:show(InfoMessage:new{ text = "Quick panel error:\n" .. tostring(err) })
    end
end

function VoyagePanel:sync()
    local kosync = self.ui.kosync
    local configured = kosync and kosync.settings and kosync.settings.userkey
    if configured and self.ui.document then
        self.ui:handleEvent(Event:new("KOSyncPushProgress"))
        UIManager:scheduleIn(1, function() self.ui:handleEvent(Event:new("KOSyncPullProgress")) end)
    elseif configured then
        UIManager:show(InfoMessage:new{ text = _("Open a book to sync its reading position."), timeout = 3 })
    else
        UIManager:show(InfoMessage:new{
            text = _("Progress sync isn't set up yet.\n\nSet it up in All Settings → Tools → Progress sync."),
            timeout = 5,
        })
    end
end

function VoyagePanel:openAllSettings()
    if self.ui.document and G_reader_settings:nilOrTrue("show_bottom_menu") then
        self.ui:handleEvent(Event:new("ShowConfigMenu"))
    end
    self.ui.menu:onShowMenu()
end

return VoyagePanel
