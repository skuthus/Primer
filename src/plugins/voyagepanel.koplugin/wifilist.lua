--[[--
Kindle-style Wi-Fi network list, shown wherever KOReader would show its network picker:
networks by signal strength, each with drawn signal bars and its state (Connected, Saved,
Secured, Open). Tap to connect (asking for the password when needed) or to disconnect;
long-press a saved network to change its password or forget it. Connecting itself is
KOReader's (NetworkMgr), so it works the same on every device.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dialog = require("dialog")
local Fonts = require("fonts")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local Prompt = require("prompt")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

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
    self.networks = self.network_list or {}
    table.sort(self.networks, function(a, b) return (a.signal_quality or 0) > (b.signal_quality or 0) end)
    for __, n in ipairs(self.networks) do
        n.flags = n.flags or ""
        n.display_ssid = n.ssid and util.fixUtf8(n.ssid, "�") or _("Hidden network")
    end

    self.pad = round(53 * u)
    self.line = math.max(1, round(2 * u))
    self.header_h = round(110 * u)
    self.row_h = round(124 * u)
    self.footer_h = round(80 * u)
    self.per_page = math.max(1, math.floor((self.H - self.header_h - self.footer_h) / self.row_h))
    self.pages = math.max(1, math.ceil(#self.networks / self.per_page))
    self.page = 1
    self.face_header = Fonts.face("ui_bold", 21)
    self.face_name = Fonts.face("ui", 19)
    self.face_name_on = Fonts.face("ui_bold", 19)
    self.face_state = Fonts.face("ui", 14)
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
    bb:paintRect(x, y + self.header_h - self.line, W, self.line, Blitbuffer.COLOR_BLACK)

    if #self.networks == 0 then
        local none = self:keep(TextWidget:new{ text = _("No networks found."), face = self.face_name })
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
        self:paintSignal(bb, x + W - pad, ry + round(self.row_h / 2), n.signal_quality or 0)
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
    if current and current ~= n then self:disconnect(current, true) end
    local info = busy(string.format(_("Connecting to %s…"), n.display_ssid))
    local success, err = NetworkMgr:authenticateNetwork(n)
    UIManager:close(info)
    if success then
        self:obtainIP()
        n.connected = true
        if self.connect_callback then self.connect_callback() end
        UIManager:close(self)
        UIManager:show(InfoMessage:new{ text = string.format(_("Connected to %s"), n.display_ssid), timeout = 3 })
    else
        self:refresh()
        UIManager:show(InfoMessage:new{ text = err or _("Couldn't connect."), timeout = 3 })
    end
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
    if pos.y < self.header_h and pos.x < self.W * 0.7 then return self:onClose() end
    local n = self:networkAt(pos)
    if not n then return true end
    if n.flags:find("WEP") then
        UIManager:show(InfoMessage:new{ text = _("Networks with WEP encryption are not supported.") })
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
    for __, w in ipairs(self.widgets) do w:free() end
    self.widgets = {}
    -- As KOReader's picker: without a connectivity check ticking, this connection attempt is over.
    if not NetworkMgr.pending_connectivity_check then
        NetworkMgr.pending_connection = false
    end
    UIManager:setDirty(nil, function() return "flashui", self.dimen end)
end

return WifiList
