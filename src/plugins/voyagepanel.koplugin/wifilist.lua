--[[--
Kindle-style Wi-Fi Networks screen (Settings > Wi-Fi, and wherever KOReader would show its
network picker): the network you're connected to first, with a check, then the others by
signal strength, each with drawn signal bars and its state (Saved, Secured, Open). Scans when
opened; Rescan in the header. Tap to connect (asking for the password when needed); long-press
a saved network to change its password or forget it. With wireless off, tap to turn it on.
Connecting itself is KOReader's (NetworkMgr). On a Kindle, joining happens in the background,
so the screen waits for the Kindle to report the new network.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dialog = require("dialog")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local Prompt = require("prompt")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")

local function round(v) return math.floor(v + 0.5) end

local function inside(pos, r)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function busy(text)
    local info = InfoMessage:new{ text = text }
    UIManager:show(info)
    UIManager:forceRePaint()
    return info
end

local WifiList = InputContainer:extend{
    plugin = nil,
    scan = false,       -- scan on opening (else network_list comes from KOReader)
    network_list = nil,
    connect_callback = nil,
    disconnect_callback = nil,
    covers_fullscreen = true,
}

function WifiList:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    local u = self.W / 1072
    self.u = u
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        if Device.input.group.PgFwd then self.key_events.NextPage = { { Device.input.group.PgFwd } } end
        if Device.input.group.PgBack then self.key_events.PrevPage = { { Device.input.group.PgBack } } end
        if Device.input.group.Back then self.key_events.Close = { { Device.input.group.Back } } end
    end
    self.pad = round(53 * u)
    self.line = math.max(1, round(2 * u))
    self.header_h = round(110 * u)
    self.row_h = round(124 * u)
    self.footer_h = round(80 * u)
    self.per_page = math.max(1, math.floor((self.H - self.header_h - self.footer_h) / self.row_h))
    self:setNetworks(self.network_list or {})
    if self.scan then self.message = _("Scanning for networks…") end
    self.face_header = Fonts.face("ui_bold", 21)
    self.face_name = Fonts.face("ui", 19)
    self.face_name_on = Fonts.face("ui_bold", 19)
    self.face_state = Fonts.face("ui", 14)
    self.face_action = Fonts.face("ui", 18)
    self.widgets = {}

    -- Already connected (KOReader missed it): finish up, as its own picker does.
    if self.connect_callback then
        UIManager:nextTick(function()
            local connected = self:connected()
            if connected then
                self:obtainIP()
                if G_reader_settings:nilOrTrue("auto_dismiss_wifi_scan") then UIManager:close(self) end
                UIManager:show(InfoMessage:new{ text = string.format(_("Connected to %s"), connected.display_ssid), timeout = 3 })
                self.connect_callback()
            end
        end)
    end
end

-- Connected network first, then by signal strength.
function WifiList:setNetworks(list)
    self.networks = list
    for __, n in ipairs(list) do
        n.flags = n.flags or ""
        n.display_ssid = n.ssid and util.fixUtf8(n.ssid, "�") or _("Hidden network")
    end
    table.sort(list, function(a, b)
        if (a.connected and true or false) ~= (b.connected and true or false) then return a.connected and true or false end
        return (a.signal_quality or 0) > (b.signal_quality or 0)
    end)
    self.pages = math.max(1, math.ceil(#list / self.per_page))
    self.page = 1
end

function WifiList:wirelessOn()
    if self.plugin then return self.plugin:isWirelessOn() end
    return NetworkMgr:isWifiOn()
end

function WifiList:doScan()
    if self.closed then return end
    if not self:wirelessOn() then
        self:setNetworks({})
        self.wireless_off = true
        self.message = _("Wireless is off. Tap here to turn it on.")
        return self:refresh()
    end
    self.wireless_off = nil
    self.message = _("Scanning for networks…")
    self:refresh()
    UIManager:forceRePaint()
    local list, err = NetworkMgr:getNetworkList()
    if list and #list == 0 then list, err = NetworkMgr:getNetworkList() end
    if self.closed then return end
    list = list or {}
    -- The Kindle may report the current network without listing it.
    local current = NetworkMgr.getCurrentNetwork and NetworkMgr:getCurrentNetwork()
    if current and current.ssid then
        local listed
        for __, n in ipairs(list) do
            if n.ssid == current.ssid then n.connected = true listed = true end
        end
        if not listed then table.insert(list, { ssid = current.ssid, connected = true, signal_quality = 0, flags = "" }) end
    end
    self:setNetworks(list)
    self.message = (#list == 0) and (err or _("No networks found.")) or nil
    self:refresh()
end

function WifiList:onShow()
    self:refresh()
    if self.scan then UIManager:nextTick(function() self:doScan() end) end
    return true
end

function WifiList:connected()
    for __, n in ipairs(self.networks) do
        if n.connected then return n end
    end
end

function WifiList:obtainIP()
    local info = busy(_("Obtaining IP address…"))
    NetworkMgr:obtainIP()
    UIManager:close(info)
end

function WifiList:keep(w)
    table.insert(self.widgets, w)
    return w
end

function WifiList:paintTo(bb, x, y)
    local ok, err = pcall(self.paintList, self, bb, x, y)
    if not ok then
        logger.err("VoyageWifi: paint failed:", err)
        UIManager:nextTick(function() self:onClose() end)
    end
end

function WifiList:stateText(n)
    if n.connected then return _("Connected") end
    if n.flags:find("WEP") then return _("Not supported (WEP)") end
    if n.password then return _("Saved") end
    if n.flags:find("WPA") then return _("Secured") end
    return _("Open")
end

-- Four bars, filled by signal strength.
function WifiList:paintSignal(bb, right, cy, quality)
    local u = self.u
    local bar_w, gap, max_h = round(9 * u), round(5 * u), round(34 * u)
    local filled = quality > 80 and 4 or quality > 55 and 3 or quality > 30 and 2 or quality > 5 and 1 or 0
    local x0 = right - 4 * bar_w - 3 * gap
    for i = 1, 4 do
        local h = round(max_h * i / 4)
        local bx, by = x0 + (i - 1) * (bar_w + gap), cy + round(max_h / 2) - h
        if i <= filled then
            bb:paintRect(bx, by, bar_w, h, Blitbuffer.COLOR_BLACK)
        else
            bb:paintBorder(bx, by, bar_w, h, self.line, Blitbuffer.COLOR_GRAY)
        end
    end
end

function WifiList:paintList(bb, x, y)
    for __, w in ipairs(self.widgets) do w:free() end
    self.widgets = {}
    local u, W, pad = self.u, self.W, self.pad
    bb:paintRect(x, y, W, self.H, Blitbuffer.COLOR_WHITE)
    local title = self:keep(TextWidget:new{ text = "‹  " .. _("Wi-Fi Networks"), face = self.face_header })
    title:paintTo(bb, x + pad, y + round((self.header_h - title:getSize().h) / 2))
    if self.scan and not self.wireless_off then
        local rescan = self:keep(TextWidget:new{ text = _("Rescan"), face = self.face_action })
        rescan:paintTo(bb, x + W - pad - rescan:getSize().w, y + round((self.header_h - rescan:getSize().h) / 2))
    end
    bb:paintRect(x, y + self.header_h - self.line, W, self.line, Blitbuffer.COLOR_BLACK)

    if #self.networks == 0 then
        local none = self:keep(TextWidget:new{ text = self.message or _("No networks found."), face = self.face_name,
            max_width = W - 2 * pad })
        none:paintTo(bb, x + pad, y + self.header_h + round(50 * u))
    end
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.networks, first + self.per_page - 1) do
        local n = self.networks[i]
        local ry = y + self.header_h + (i - first) * self.row_h
        local name = self:keep(TextWidget:new{ text = n.display_ssid, face = n.connected and self.face_name_on or self.face_name,
            max_width = W - 2 * pad - round(120 * u) })
        local state = self:keep(TextWidget:new{ text = self:stateText(n), face = self.face_state })
        local th = name:getSize().h + round(4 * u) + state:getSize().h
        local ty = ry + round((self.row_h - th) / 2)
        name:paintTo(bb, x + pad, ty)
        state:paintTo(bb, x + pad, ty + name:getSize().h + round(4 * u))
        local bars_right = x + W - pad
        self:paintSignal(bb, bars_right, ry + round(self.row_h / 2), n.signal_quality or 0)
        if n.connected then
            local s = round(40 * u)
            local check = IconWidget:new{ file = PLUGIN_DIR .. "/icons/check.svg", width = s, height = s }
            check:paintTo(bb, bars_right - round(58 * u) - round(20 * u) - s, ry + round((self.row_h - s) / 2))
            check:free()
        end
        bb:paintRect(x + pad, ry + self.row_h - self.line, W - 2 * pad, self.line, Blitbuffer.COLOR_LIGHT_GRAY)
    end
    if self.pages > 1 then
        local pg = self:keep(TextWidget:new{ text = string.format(_("Page %d of %d"), self.page, self.pages), face = self.face_state })
        pg:paintTo(bb, x + W - pad - pg:getSize().w, y + self.H - round((self.footer_h + pg:getSize().h) / 2))
    end
end

function WifiList:refresh(mode)
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function WifiList:networkAt(pos)
    if pos.y < self.header_h then return end
    local row = math.floor((pos.y - self.header_h) / self.row_h)
    if row >= self.per_page then return end
    return self.networks[(self.page - 1) * self.per_page + row + 1]
end

-- Connecting --------------------------------------------------------------------------

function WifiList:connect(n)
    local current = self:connected()
    if current and current ~= n and not Device:isKindle() then self:disconnect(current, true) end
    local info = busy(string.format(_("Connecting to %s…"), n.display_ssid))
    local success, err = NetworkMgr:authenticateNetwork(n)
    if not success then
        UIManager:close(info)
        self:refresh()
        UIManager:show(InfoMessage:new{ text = err or _("Couldn't connect."), timeout = 3 })
    elseif Device:isKindle() then
        -- The Kindle joins in the background: wait until it reports the network.
        self:waitForConnection(n, info, 0)
    else
        UIManager:close(info)
        self:obtainIP()
        self:markConnected(n)
    end
end

function WifiList:waitForConnection(n, info, tries)
    if self.closed then return UIManager:close(info) end
    local current = NetworkMgr:getCurrentNetwork()
    if current and current.ssid == n.ssid then
        UIManager:close(info)
        return self:markConnected(n)
    end
    if tries >= 20 then
        UIManager:close(info)
        return UIManager:show(InfoMessage:new{ text = string.format(_("Couldn't connect to %s."), n.display_ssid), timeout = 3 })
    end
    UIManager:scheduleIn(1, function() self:waitForConnection(n, info, tries + 1) end)
end

function WifiList:markConnected(n)
    for __, other in ipairs(self.networks) do other.connected = (other == n) or nil end
    self:setNetworks(self.networks)
    if self.connect_callback then
        self.connect_callback()
        UIManager:close(self)
    else
        self:refresh()
    end
    UIManager:show(InfoMessage:new{ text = string.format(_("Connected to %s"), n.display_ssid), timeout = 3 })
end

function WifiList:disconnect(n, quiet)
    local info = not quiet and busy(_("Disconnecting…"))
    NetworkMgr:disconnectNetwork(n)
    NetworkMgr:releaseIP()
    if info then UIManager:close(info) end
    n.connected = nil
    if self.disconnect_callback then self.disconnect_callback() end
    self:refresh()
end

function WifiList:askPassword(n)
    local wpa = n.flags:find("WPA") ~= nil
    UIManager:show(Prompt:new{
        title = n.display_ssid,
        text = n.password or "",
        hint = wpa and _("Password") or _("Password (leave empty for open networks)"),
        text_type = "password",
        ok_text = _("Connect"),
        on_ok = function(password, prompt)
            if password == "" and wpa then
                prompt:setMessage(_("Enter the network's password."))
                return false
            end
            if password ~= n.password then
                n.password = password
                n.psk = nil
                NetworkMgr:saveNetwork(n)
            end
            UIManager:nextTick(function() self:connect(n) end)
        end,
    })
end

function WifiList:onTap(__, ges)
    local pos = ges.pos
    if pos.y < self.header_h then
        if pos.x < self.W * 0.6 then return self:onClose() end
        if self.scan and not self.wireless_off then self:doScan() end
        return true
    end
    if self.wireless_off then
        if self.plugin then
            self.plugin:setWireless(true)
            self.message = _("Turning on wireless…")
            self:refresh()
            UIManager:scheduleIn(5, function() self:doScan() end)
        end
        return true
    end
    local n = self:networkAt(pos)
    if not n then return true end
    if n.flags:find("WEP") then
        UIManager:show(InfoMessage:new{ text = _("Networks with WEP encryption are not supported.") })
    elseif n.connected and Device:isKindle() then
        -- The Kindle has no "disconnect": it stays on its network until wireless is turned off.
        UIManager:show(Dialog:new{
            title = string.format(_("Connected to %s"), n.display_ssid),
            text = _("To disconnect, turn off Wireless."),
            buttons = { { text = _("OK"), bold = true } },
        })
    elseif n.connected then
        UIManager:show(Dialog:new{
            title = string.format(_("Disconnect from %s?"), n.display_ssid),
            text = _("Wireless stays on."),
            buttons = { { text = _("Cancel") }, { text = _("Disconnect"), bold = true, callback = function() self:disconnect(n) end } },
        })
    elseif n.password or not n.flags:find("WPA") then
        self:connect(n)
    else
        self:askPassword(n)
    end
    return true
end

function WifiList:onHold(__, ges)
    local n = self:networkAt(ges.pos)
    if not (n and n.password) then return true end
    UIManager:show(Dialog:new{
        title = n.display_ssid,
        text = _("Change the saved password, or forget this network."),
        buttons = {
            { text = _("Cancel") },
            { text = _("Forget"), callback = function()
                NetworkMgr:deleteNetwork(n)
                n.password = nil
                self:refresh()
            end },
            { text = _("Password"), bold = true, callback = function() self:askPassword(n) end },
        },
    })
    return true
end

function WifiList:goToPage(p)
    p = math.max(1, math.min(self.pages, p))
    if p ~= self.page then
        self.page = p
        self:refresh("partial")
    end
    return true
end

function WifiList:onNextPage() return self:goToPage(self.page + 1) end
function WifiList:onPrevPage() return self:goToPage(self.page - 1) end

function WifiList:onSwipe(__, ges)
    if ges.direction == "west" or ges.direction == "north" then return self:onNextPage() end
    if ges.direction == "east" or ges.direction == "south" then return self:onPrevPage() end
    return true
end

function WifiList:onClose()
    UIManager:close(self)
    return true
end

function WifiList:onCloseWidget()
    self.closed = true
    for __, w in ipairs(self.widgets) do w:free() end
    self.widgets = {}
    -- As KOReader's picker: without a connectivity check ticking, this connection attempt is over.
    if not NetworkMgr.pending_connectivity_check then
        NetworkMgr.pending_connection = false
    end
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return WifiList
