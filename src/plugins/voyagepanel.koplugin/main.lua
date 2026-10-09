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
            plugin:showPanel()
            self.ui:handleEvent(Event:new("HandledAsSwipe")) -- cancel any pan scroll made
            return true
        end
        return orig(self, ges)
    end
end
hookSwipe(require("apps/reader/modules/readermenu"))
hookSwipe(require("apps/filemanager/filemanagermenu"))

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

-- Aa. TODO: replace with the Kindle-style Font / Page / Progress panel.
function VoyagePanel:showTextSettings()
    self.ui:handleEvent(Event:new("ShowConfigMenu"))
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

function VoyagePanel:onSuspend()
    UIManager:unschedule(self.auto_tick)
end

function VoyagePanel:onResume()
    if self.auto then UIManager:scheduleIn(1, self.auto_tick) end
end

function VoyagePanel:onCloseWidget()
    UIManager:unschedule(self.auto_tick)
    if self.panel then UIManager:close(self.panel) end
    if self.library then UIManager:close(self.library) end
    if self.toolbar then UIManager:close(self.toolbar) end
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
