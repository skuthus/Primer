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
local NotePopup = require("notes")
local Notebook = require("notebook")
local Stats = require("stats")
local EndCard = require("endcard")
local WifiList = require("wifilist")
local BookMap = require("bookmap")
local PageGrid = require("pagegrid")
local SearchBar = require("searchbar")
local SearchResults = require("searchresults")
local SettingsView = require("settings")
local Fonts = require("fonts")
local lfs = require("libs/libkoreader-lfs")
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
    -- Tapping the bottom of the page turns it, like the Kindle, instead of opening
    -- KOReader's settings bar (returning nothing lets the tap reach the page-turn zones).
    if not ReaderConfig._voyage_tap_hooked then
        ReaderConfig._voyage_tap_hooked = true
        local orig = ReaderConfig.onTapShowConfigMenu
        function ReaderConfig:onTapShowConfigMenu(...)
            if self.ui and self.ui.voyagepanel then return end
            return orig(self, ...)
        end
    end
end

-- No re-layout icons in the top-left corner after a font or layout change (the Kindle shows
-- none). KOReader still re-lays out the current chapter first and the rest in the background.
do
    local ReaderFlipping = require("apps/reader/modules/readerflipping")
    if not ReaderFlipping._voyage_hooked then
        ReaderFlipping._voyage_hooked = true
        local orig = ReaderFlipping.getRollingRenderingStateIconWidget
        function ReaderFlipping:getRollingRenderingStateIconWidget(...)
            if self.ui and self.ui.voyagepanel then return nil end
            return orig(self, ...)
        end
    end
end

-- In-book search: Primer's search bar, results list and result-to-result bar instead of
-- KOReader's search dialog, results menu and navigation popup. The search itself is KOReader's.
do
    local ReaderSearch = require("apps/reader/modules/readersearch")
    if not ReaderSearch._voyage_hooked then
        ReaderSearch._voyage_hooked = true
        local orig_input = ReaderSearch.onShowFulltextSearchInput
        function ReaderSearch:onShowFulltextSearchInput(search_string)
            local plugin = self.ui and self.ui.voyagepanel
            if not plugin then return orig_input(self, search_string) end
            plugin:showBookSearch(search_string)
            return true
        end
        local orig_results = ReaderSearch.onShowFindAllResults
        function ReaderSearch:onShowFindAllResults(not_cached)
            local plugin = self.ui and self.ui.voyagepanel
            if not plugin then return orig_results(self, not_cached) end
            if not self.last_search_hash or (not not_cached and self.findall_results == nil) then
                plugin:showBookSearch()
                return true
            end
            plugin:showSearchResults(self.findall_results_item_index)
            self:showErrorNotification(#self.findall_results)
            return true
        end
    end
end

-- Footnote popups, Kindle-style: a "Footnote" heading over the note (still rendered by
-- KOReader, in the book's font) and a "Go to Footnote" button under it.
do
    local FootnoteWidget = require("ui/widget/footnotewidget")
    if not FootnoteWidget._voyage_hooked then
        FootnoteWidget._voyage_hooked = true
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local LeftContainer = require("ui/widget/container/leftcontainer")
        local LineWidget = require("ui/widget/linewidget")
        local VerticalGroup = require("ui/widget/verticalgroup")

        local function dress(self)
            local W, H = Screen:getWidth(), Screen:getHeight()
            local u = math.min(W, H) / 1072 -- the shorter side, so landscape isn't oversized
            local pad = math.floor(53 * u + 0.5)
            local thick = math.max(2, math.floor(3 * u + 0.5))
            local thin = math.max(1, math.floor(2 * u + 0.5))
            local header_h, footer_h = math.floor(88 * u + 0.5), math.floor(104 * u + 0.5)
            local note = self.container[1]
            -- KOReader's own top border becomes a light rule under the heading.
            local group = note.ignore and note[1] or note
            if group[1] and getmetatable(group[1]) == LineWidget then
                group[1].background = Blitbuffer.COLOR_LIGHT_GRAY
                group[1].dimen.h = thin
            end
            self.container[1] = VerticalGroup:new{
                LineWidget:new{ dimen = Geom:new{ w = W, h = thick } },
                LeftContainer:new{
                    dimen = Geom:new{ w = W, h = header_h },
                    HorizontalGroup:new{
                        HorizontalSpan:new{ width = pad },
                        TextWidget:new{ text = _("Footnote"), face = Fonts.face("ui_bold", 18) },
                    },
                },
                note,
                LineWidget:new{ dimen = Geom:new{ w = W, h = thin }, background = Blitbuffer.COLOR_LIGHT_GRAY },
                CenterContainer:new{
                    dimen = Geom:new{ w = W, h = footer_h },
                    TextWidget:new{ text = _("Go to Footnote"), face = Fonts.face("ui", 18) },
                },
            }
            self.height = self.height + thick + header_h + thin + footer_h
            self._voyage_follow = Geom:new{ x = 0, y = H - footer_h, w = W, h = footer_h }
        end

        local orig_init = FootnoteWidget.init
        function FootnoteWidget:init()
            orig_init(self)
            local ok, err = pcall(dress, self)
            if not ok then logger.warn("VoyageFootnote: kept KOReader's popup:", err) end
        end

        local orig_tap = FootnoteWidget.onTapClose
        function FootnoteWidget:onTapClose(arg, ges)
            if self._voyage_follow and ges and ges.pos and ges.pos:intersectWith(self._voyage_follow) then
                return self:onFollow()
            end
            return orig_tap(self, arg, ges)
        end
    end
end

-- End of book: Primer's card (book marked as finished) instead of KOReader's "What would you
-- like to do?" popup. Other end-of-book actions chosen in KOReader's menu are left alone.
do
    local ReaderStatus = require("apps/reader/modules/readerstatus")
    if not ReaderStatus._voyage_hooked then
        ReaderStatus._voyage_hooked = true
        local orig = ReaderStatus.onEndOfBook
        function ReaderStatus:onEndOfBook()
            local plugin = self.ui and self.ui.voyagepanel
            local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
            local quickstart = G_reader_settings:readSetting("lastfile") == require("ui/quickstart").quickstart_filename
            if not plugin or action ~= "pop-up" or quickstart then return orig(self) end
            plugin:showEndCard()
            return true
        end
    end
end

-- Wi-Fi: Primer's network list wherever KOReader would show its network picker.
do
    local NetworkSetting = require("ui/widget/networksetting")
    if not NetworkSetting._voyage_hooked then
        NetworkSetting._voyage_hooked = true
        function NetworkSetting.new(__, o)
            return WifiList:new(o)
        end
    end
end

-- Book map and page browser: Primer's book map and Kindle-style page grid, from the toolbar,
-- the page flip, or any gesture set to them.
do
    local ReaderThumbnail = require("apps/reader/modules/readerthumbnail")
    if not ReaderThumbnail._voyage_hooked then
        ReaderThumbnail._voyage_hooked = true
        local orig_map, orig_browser = ReaderThumbnail.onShowBookMap, ReaderThumbnail.onShowPageBrowser
        function ReaderThumbnail:onShowBookMap(...)
            local plugin = self.ui and self.ui.voyagepanel
            if not plugin then return orig_map(self, ...) end
            plugin:showBookMap()
            return true
        end
        function ReaderThumbnail:onShowPageBrowser(...)
            local plugin = self.ui and self.ui.voyagepanel
            if not plugin then return orig_browser(self, ...) end
            plugin:showPageGrid()
            return true
        end
    end
end

-- Refresh the screen on demand, anywhere in Primer: a two-finger tap (fingers close together;
-- KOReader's wide corner-to-corner tap stays a screenshot).
do
    if not UIManager._voyage_refresh_hooked then
        UIManager._voyage_refresh_hooked = true
        local orig = UIManager.handleInputEvent
        function UIManager:handleInputEvent(input_event)
            local arg = type(input_event) == "table" and input_event.handler == "onGesture"
                and input_event.args and input_event.args[1]
            if arg and arg.ges == "two_finger_tap"
                    and (arg.span or 0) < math.min(Screen:getWidth(), Screen:getHeight()) * 0.5 then
                UIManager:setDirty(nil, "full")
                return
            end
            return orig(self, input_event)
        end
    end
end

-- reMarkable: AppLoad lets the system and KOReader both see each touch, so the system's own
-- swipe down from the top-right corner (brightness) also reached KOReader, where its opening
-- press could open an image on the page. Presses, drags and swipes that start in that corner
-- are left to the system; quick taps there still work (e.g. the bookmark corner).
do
    if not UIManager._voyage_remarkable_corner_hooked and Device:isRemarkable() then
        UIManager._voyage_remarkable_corner_hooked = true
        local STARTS = { hold = true, pan = true, swipe = true, multiswipe = true }
        local ENDS = { hold_release = true, pan_release = true, swipe = true, multiswipe = true }
        local FOLLOWS = { hold_pan = true, hold_release = true, pan = true, pan_release = true }
        local in_corner_gesture = false
        -- The device's physical top-right corner, wherever the current rotation puts it on screen.
        local function inCorner(p)
            if not p then return false end
            local W, H = Screen:getWidth(), Screen:getHeight()
            local mode = Screen:getRotationMode()
            if mode == Screen.DEVICE_ROTATED_CLOCKWISE then
                return p.x >= W * 0.88 and p.y >= H * 0.75
            elseif mode == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then
                return p.x <= W * 0.12 and p.y <= H * 0.25
            elseif mode == Screen.DEVICE_ROTATED_UPSIDE_DOWN then
                return p.x <= W * 0.25 and p.y >= H * 0.88
            end
            return p.x >= W * 0.75 and p.y <= H * 0.12
        end
        local orig = UIManager.handleInputEvent
        function UIManager:handleInputEvent(input_event)
            local ges = type(input_event) == "table" and input_event.handler == "onGesture"
                and input_event.args and input_event.args[1]
            if ges and ges.ges then
                if in_corner_gesture and (FOLLOWS[ges.ges] or ENDS[ges.ges]) then
                    if ENDS[ges.ges] then in_corner_gesture = false end
                    return
                end
                if STARTS[ges.ges] and inCorner(ges.start_pos or ges.pos) then
                    in_corner_gesture = not ENDS[ges.ges]
                    return
                end
            end
            return orig(self, input_event)
        end
    end
end

-- reMarkable: books don't keep their own layout. KOReader saves every layout setting into a book
-- whenever it closes, so books opened before (or before a defaults change) kept stale values.
-- In Primer the Aa panel saves to the defaults for all books, like a Kindle, so as a book's
-- settings load, its layout values are dropped and it follows the defaults. Reading position,
-- highlights, notes and orientation are kept.
do
    local DocSettings = require("docsettings")
    if not DocSettings._voyage_layout_hooked and Device:isRemarkable() then
        DocSettings._voyage_layout_hooked = true
        local KEEP = { copt_rotation_mode = true, copt_visible_pages = true }
        local DROP = { font_face = true, font_family_fonts = true, hyphenation = true, style_tweaks = true }
        local orig_open = DocSettings.open
        function DocSettings:open(doc_path)
            local settings = orig_open(self, doc_path)
            local data = settings and settings.data
            if type(data) == "table" then
                for key in pairs(data) do
                    if type(key) == "string" and ((key:find("^copt_") and not KEEP[key]) or key:find("^hyph_") or DROP[key]) then
                        data[key] = nil
                    end
                end
            end
            return settings
        end
    end
end

-- Pinch and spread step through the Aa panel's font sizes instead of by pinch distance.
do
    local ReaderFont = require("apps/reader/modules/readerfont")
    if not ReaderFont._voyage_hooked then
        ReaderFont._voyage_hooked = true
        local orig_inc, orig_dec = ReaderFont.onIncreaseFontSize, ReaderFont.onDecreaseFontSize
        local function step(self, ges, dir)
            -- A long pinch moves up to three steps.
            local span = math.min(Screen:getWidth(), Screen:getHeight())
            local n = math.min(3, 1 + math.floor((ges.distance or 0) / (span * 0.5)))
            AaPanel.stepFontSize(self.ui, dir * n)
            return true
        end
        function ReaderFont:onIncreaseFontSize(ges)
            if type(ges) ~= "table" or not self.ui.voyagepanel then return orig_inc(self, ges) end
            return step(self, ges, 1)
        end
        function ReaderFont:onDecreaseFontSize(ges)
            if type(ges) ~= "table" or not self.ui.voyagepanel then return orig_dec(self, ges) end
            return step(self, ges, -1)
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
            }
        end
    end

    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    if not ReaderHighlight._voyage_hooked then
        ReaderHighlight._voyage_hooked = true
        local orig_menu = ReaderHighlight.onShowHighlightMenu
        function ReaderHighlight:onShowHighlightMenu(index)
            local plugin = self.ui and self.ui.voyagepanel
            if index or not (plugin and self.selected_text and self.hold_pos)
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
            }
        end

        -- Tapping an existing highlight: the same bar (Delete | Note | Copy | Search), with the
        -- note in a card when there is one, instead of KOReader's note viewer / edit dialog.
        local orig_note_or_dialog = ReaderHighlight.showHighlightNoteOrDialog
        function ReaderHighlight:showHighlightNoteOrDialog(index)
            local plugin = self.ui and self.ui.voyagepanel
            local anno = self.ui.annotation.annotations[index]
            if not (plugin and anno and G_reader_settings:nilOrTrue("voyage_kindle_lookup")) then
                return orig_note_or_dialog(self, index)
            end
            local boxes = self:getHighlightVisibleBoxes(index) or {}
            if self.ui.paging then
                local page = anno.pos0.page
                for i, box in ipairs(boxes) do boxes[i] = self.view:pageToScreenTransform(page, box) end
            end
            if anno.note and anno.note:match("%S") then
                plugin:showNote{ highlight = self, index = index, boxes = boxes }
            else
                plugin:showLookup{ highlight = self, annotation_index = index, boxes = boxes }
            end
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
local USB_GADGET = "/sys/devices/platform/fsl-usb2-udc/gadget/connected" -- i.MX Kindles (USB drive)
local POWER_SUPPLIES = "/sys/class/power_supply"
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")

local function readLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

local function dirNames(dir)
    local names = {}
    local ok, iter, state = pcall(lfs.dir, dir)
    if ok then
        for name in iter, state do
            if name:sub(1, 1) ~= "." then table.insert(names, name) end
        end
    end
    return names
end

-- Is the cable going to a computer rather than a wall charger? i.MX Kindles say so through the
-- USB gadget; MediaTek ones (Paperwhite 5 and 6, Scribe, Colorsoft) through the charger driver,
-- which reports a computer's port as SDP or CDP and a charger as DCP. Failing both, a gadget a
-- host has configured can only mean a computer.
local function computerConnected()
    local gadget = readLine(USB_GADGET)
    if gadget then return gadget == "1" end
    for __, name in ipairs(dirNames(POWER_SUPPLIES)) do
        local dir = POWER_SUPPLIES .. "/" .. name
        local usb_type = readLine(dir .. "/usb_type") -- "SDP [CDP] DCP …" on newer kernels
        local kind = usb_type and usb_type:match("%[(%w+)%]") or readLine(dir .. "/type")
        if kind == "USB_SDP" or kind == "USB_CDP" or kind == "SDP" or kind == "CDP" then
            return readLine(dir .. "/online") ~= "0"
        end
    end
    for __, name in ipairs(dirNames("/sys/class/udc")) do
        if readLine("/sys/class/udc/" .. name .. "/state") == "configured" then return true end
    end
    return false
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

-- Sleep screen collections: the Kindle's own illustrations (Kindle only), then Primer's public
-- domain sets, installed to koreader/screensavers/primer/<id> (credits in CREDITS.md there).
local SLEEP_COLLECTIONS = {
    { id = "dore", label = _("Doré engravings") },
    { id = "tenniel", label = _("Tenniel's Alice") },
    { id = "hiroshige", label = _("Japanese woodblocks") },
    { id = "haeckel", label = _("Haeckel's nature forms") },
}

function VoyagePanel:sleepCollections()
    local list = {}
    if Device:isKindle() then
        table.insert(list, { id = "kindle", label = _("Kindle illustrations"), dir = "/mnt/us/screensavers" })
    end
    local base = require("datastorage"):getFullDataDir() .. "/screensavers/primer/"
    for __, c in ipairs(SLEEP_COLLECTIONS) do
        if lfs.attributes(base .. c.id, "mode") == "directory" then
            table.insert(list, { id = c.id, label = c.label, dir = base .. c.id })
        end
    end
    return list
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
    -- Off-Kindle, the footer's Amazon Ember setting points nowhere: use Primer's bundled UI font.
    local footer = G_reader_settings:readSetting("footer")
    local face = footer and footer.text_font_face
    if face and not (lfs.attributes(face, "mode") or lfs.attributes("./fonts/" .. face, "mode")) then
        footer.text_font_face = Fonts.path("ui")
    end
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
    self.rotate_tick = function() self:rotateTick() end
    if self.ui.document and self:canAutoRotate() and self:autoRotateOn() then
        UIManager:scheduleIn(1, self.rotate_tick)
    end
    if not G_reader_settings:isTrue("primer_welcomed") then
        UIManager:scheduleIn(1, function() self:showWelcome() end)
    end
end

-- Start at boot (Kindle): the upstart job installed by the KUAL extension's script.
local AUTOSTART_JOB = "/etc/upstart/koreader-autostart.conf"
local AUTOSTART_SCRIPT = "/mnt/us/extensions/primer/bin/autostart.sh"

function VoyagePanel:canAutostart()
    return Device:isKindle() and lfs.attributes(AUTOSTART_SCRIPT, "mode") == "file"
end

function VoyagePanel:isAutostartOn()
    return lfs.attributes(AUTOSTART_JOB, "mode") == "file"
end

function VoyagePanel:setAutostart(on)
    os.execute(string.format("/bin/sh %s %s quiet", AUTOSTART_SCRIPT, on and "enable" or "disable"))
    return self:isAutostartOn() == on
end

-- KOReader release Primer was built and tested against; older ones may lack what it hooks.
local TESTED_KOREADER = "v2026.07"

-- First run: a short welcome, offering to start Primer when the Kindle starts.
function VoyagePanel:showWelcome()
    if G_reader_settings:isTrue("primer_welcomed") or self.welcome_shown then return end
    self.welcome_shown = true
    local text = _("Swipe down from the top for quick settings. Tap the top of a page for the reading toolbar, and swipe up from the bottom to flip through the book.")
    local Version = require("version")
    local ok, current = pcall(Version.getNormalizedCurrentVersion, Version)
    if ok and current and current < Version:getNormalizedVersion(TESTED_KOREADER) then
        text = text .. "\n\n" .. string.format(_("Primer was made for KOReader %s or newer. Update KOReader if something doesn't look right."), TESTED_KOREADER:sub(2))
    end
    local function done() G_reader_settings:makeTrue("primer_welcomed") end
    local buttons
    if self:canAutostart() and not self:isAutostartOn() then
        text = text .. "\n\n" .. _("Start Primer whenever your Kindle turns on? You can change this in Settings.")
        buttons = {
            { text = _("Not Now"), callback = done },
            { text = _("Start at Boot"), bold = true, callback = function()
                done()
                if not self:setAutostart(true) then
                    UIManager:show(InfoMessage:new{ text = _("Couldn't set Primer to start at boot. Try KUAL > Primer."), timeout = 4 })
                end
            end },
        }
    else
        buttons = { { text = _("Get Started"), bold = true, callback = done } }
    end
    UIManager:show(Dialog:new{ title = _("Welcome to Primer"), text = text, buttons = buttons })
end

-- The name set in Settings, else the Kindle's own registered name, else the model.
function VoyagePanel:deviceName()
    local name = G_reader_settings:readSetting("voyage_device_name")
    if name then return name end
    if self.registered_name == nil then
        self.registered_name = false
        local f = Device:isKindle() and io.open("/var/local/java/prefs/reginfo", "r")
        if f then
            local info = f:read("*a") or ""
            f:close()
            local found = info:match('[Dd]evice[_ ]?[Nn]ame%s*[=:]%s*"([^"]+)"') or info:match("<deviceName>([^<]+)</deviceName>")
                or info:match("[Dd]evice[_ ]?[Nn]ame%s*[=:]%s*([^\r\n]+)")
            self.registered_name = found and found:match("^%s*(.-)%s*$") or false
            if self.registered_name == "" then self.registered_name = false end
        end
    end
    return self.registered_name or Device.model or "Primer"
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

-- Wireless on/off. On a Kindle, flip the radio like its airplane mode: no connection attempt,
-- network list or popups (its own wifid rejoins saved networks). Elsewhere, KOReader's Wi-Fi toggle.
function VoyagePanel:setWireless(on)
    local handle = wirelessHandle()
    if not handle then
        if on then NetworkMgr:toggleWifiOn() else NetworkMgr:toggleWifiOff() end
        return
    end
    if on then
        handle:set_int_property("com.lab126.cmd", "wirelessEnable", 1)
        handle:set_int_property("com.lab126.wifid", "enable", 1)
    else
        handle:set_int_property("com.lab126.wifid", "enable", 0)
        handle:set_int_property("com.lab126.cmd", "wirelessEnable", 0)
    end
    handle:close()
    if not on then UIManager:broadcastEvent(Event:new("NetworkDisconnected")) end
end

-- A drawn battery whose right edge (with nub) sits at `right`; returns its left x.
function VoyagePanel:showBatteryPercent()
    return G_reader_settings:nilOrTrue("voyage_battery_percent")
end

-- The battery, drawn the same everywhere: a rounded outline with a rounded fill inset by a small
-- gap, a rounded nub, and a lightning bolt while charging. Its right edge sits at `right`,
-- centred on `cy`. With `face`, the percentage goes to its left when Settings > Device options
-- > Battery percentage is on. Returns the leftmost x drawn.
function VoyagePanel:paintBattery(bb, right, cy, h, face)
    local BLACK = Blitbuffer.COLOR_BLACK
    local powerd = Device:getPowerDevice()
    local capacity = math.min(math.max(powerd:getCapacity(), 0), 100)
    local function r(v) return math.floor(v + 0.5) end
    local border = math.max(2, r(h / 10))
    local gap = math.max(1, r(h / 11))
    local w = r(h * 2.1)
    local nub_w, nub_h = math.max(2, r(h * 0.14)), r(h * 0.42)
    local x = right - nub_w - w
    local top = cy - r(h / 2)
    local radius = r(h * 0.32)
    bb:paintRoundedRect(x + w - 1, cy - r(nub_h / 2), nub_w + 1, nub_h, BLACK, r(nub_w * 0.6))
    bb:paintBorder(x, top, w, h, border, BLACK, radius)
    local inset = border + gap
    local inner_w, inner_h = w - 2 * inset, h - 2 * inset
    local fill = r(inner_w * capacity / 100)
    if fill > 0 then
        bb:paintRoundedRect(x + inset, top + inset, math.max(fill, math.min(inner_h, inner_w)), inner_h, BLACK,
            math.max(1, radius - inset))
    end
    if powerd:isCharging() then
        local s = r(h * 1.15)
        local bolt = self:icon("bolt", s, true)
        bolt:paintTo(bb, x + r((w - s) / 2), cy - r(s / 2))
        bolt:free()
    end
    local left = x
    if face and self:showBatteryPercent() then
        local pct = TextWidget:new{ text = string.format("%d%%", capacity), face = face }
        left = x - r(h * 0.35) - pct:getSize().w
        pct:paintTo(bb, left, cy - r(pct:getSize().h / 2))
        pct:free()
    end
    return left
end

-- `alpha`: keep the icon's transparency, for icons drawn on a shaded background.
function VoyagePanel:icon(name, size, alpha)
    return IconWidget:new{ file = self.path .. "/icons/" .. name .. ".svg", width = size, height = size, alpha = alpha }
end

-- "1 min", "15 mins", "1 hr 5 mins"
function VoyagePanel.minutesText(minutes)
    if minutes < 60 then
        return minutes == 1 and _("1 min") or string.format(_("%d mins"), minutes)
    end
    local h, m = math.floor(minutes / 60), minutes % 60
    local hours = h == 1 and _("1 hr") or string.format(_("%d hrs"), h)
    if m == 0 then return hours end
    return hours .. " " .. (m == 1 and _("1 min") or string.format(_("%d mins"), m))
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

function VoyagePanel:showNote(args)
    if self.note_popup then UIManager:close(self.note_popup) end
    local ok, err = pcall(function()
        args.plugin = self
        self.note_popup = NotePopup:new(args)
        UIManager:show(self.note_popup)
    end)
    if not ok then
        logger.err("VoyageNote: failed to open:", err)
        self.note_popup = nil
        UIManager:show(InfoMessage:new{ text = "Note error:\n" .. tostring(err) })
    end
end

-- Notebook: highlights, notes and bookmarks (optionally opening on one filter).
function VoyagePanel:showNotebook(filter)
    if self.notebook or not self.ui.document then return end
    local ok, err = pcall(function()
        self.notebook = Notebook:new{ plugin = self, filter = filter or "all" }
        UIManager:show(self.notebook)
    end)
    if not ok then
        logger.err("VoyageNotebook: failed to open:", err)
        self.notebook = nil
        UIManager:show(InfoMessage:new{ text = "Notebook error:\n" .. tostring(err) })
    end
end

-- Go To: Kindle-style chapter list.
-- The reading ⋮ menu (toolbar and page flip). `close_owner` closes the screen it came from.
function VoyagePanel:readingMenuItems(close_owner)
    return {
        { text = _("Notebook"), callback = function() close_owner() self:showNotebook() end },
        { text = _("Reading Statistics"), callback = function() close_owner() self:showStats() end },
    }
end

function VoyagePanel:showBookSearch(text)
    local search = self.ui.search
    if not (search and self.ui.document) then return end
    -- Offer the last search again only if it's a word or phrase, not a long passage searched
    -- from a selection.
    text = text or search.last_search_text or self.ui.doc_settings:readSetting("fulltext_search_last_search_text") or ""
    if #text > 40 or text:find("\n") then text = "" end
    UIManager:show(SearchBar:new{
        plugin = self,
        text = text,
        hint = _("Search this book"),
        on_done = function(query)
            if not query:match("%S") then return end
            query = require("ffi/utf8proc").normalize_NFC(query)
            self.ui.doc_settings:saveSetting("fulltext_search_last_search_text", query)
            search.last_search_text = query
            search.start_page = self.ui.paging and self.ui.view.state.page or self.ui.document:getXPointer()
            search.case_insensitive = true
            search.current_search_type = search.default_search_type
            search.findall_results_item_index = nil
            require("ui/trapper"):wrap(function() search:findAllText(query) end)
        end,
    })
end

function VoyagePanel:showSearchResults(index)
    UIManager:show(SearchResults.Results:new{ plugin = self, index = index })
end

-- Go to search result `i` (marked on the page), with the previous / next bar.
function VoyagePanel:gotoSearchResult(i)
    local ui = self.ui
    local item = ui.search.findall_results and ui.search.findall_results[i]
    if not item then return end
    ui.search.findall_results_item_index = i
    if ui.rolling then
        ui.link:addCurrentLocationToStack()
        ui.rolling:onGotoXPointer(item.start, item.start)
        ui.document:getTextFromXPointers(item.start, item["end"], true)
    else
        ui.highlight:clear()
        local page = item.start
        local boxes = {}
        for n, box in ipairs(item.boxes or {}) do
            boxes[n] = ui.document:nativeToPageRectTransform(page, box)
        end
        ui.link:onGotoLink({ page = page - 1 })
        ui.view.highlight.temp[page] = boxes
    end
    UIManager:show(SearchResults.Nav:new{ plugin = self, index = i })
end

function VoyagePanel:showEndCard()
    if self.endcard or not self.ui.document then return end
    local ok, err = pcall(function()
        self.endcard = EndCard:new{ plugin = self }
        UIManager:show(self.endcard)
    end)
    if not ok then
        logger.err("VoyageEndCard: failed to open:", err)
        self.endcard = nil
    end
end

function VoyagePanel:showWifiNetworks()
    UIManager:show(WifiList:new{ plugin = self, scan = true })
end

-- "Connected to Home", "Not connected", or "Wireless is off" (Settings > Wi-Fi).
function VoyagePanel:wifiSummary()
    if not self:isWirelessOn() then return _("Wireless is off") end
    local ok, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
    if ok and current and current.ssid then return string.format(_("Connected to %s"), current.ssid) end
    return _("Not connected · choose a network to join")
end

function VoyagePanel:showBookMap()
    if self.bookmap or not self.ui.document then return end
    local ok, err = pcall(function()
        self.bookmap = BookMap:new{ plugin = self }
        UIManager:show(self.bookmap)
    end)
    if not ok then
        logger.err("VoyageBookMap: failed to open:", err)
        self.bookmap = nil
    end
end

function VoyagePanel:showPageGrid()
    if self.pagegrid or not self.ui.document then return end
    local ok, err = pcall(function()
        self.pagegrid = PageGrid:new{ plugin = self }
        UIManager:show(self.pagegrid)
    end)
    if not ok then
        logger.err("VoyagePageGrid: failed to open:", err)
        self.pagegrid = nil
    end
end

function VoyagePanel:showStats()
    if self.stats or not self.ui.document then return end
    local ok, err = pcall(function()
        self.stats = Stats:new{ plugin = self }
        UIManager:show(self.stats)
    end)
    if not ok then
        logger.err("VoyageStats: failed to open:", err)
        self.stats = nil
        UIManager:show(InfoMessage:new{ text = "Reading statistics error:\n" .. tostring(err) })
    end
end

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
    if self.usb_dialog or not G_reader_settings:nilOrTrue("voyage_usb_prompt") then return end
    self.usb_dialog = Dialog:new{
        title = _("Connect to Computer"),
        text = _("Use your Kindle for file transfer? Primer closes while it's connected and comes back when you eject or unplug it."),
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
    -- Not every device (or KOReader version) has hasLightSensor.
    return Device.hasLightSensor ~= nil and Device:hasLightSensor() and readLux() ~= nil
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
    UIManager:unschedule(self.rotate_tick)
end

function VoyagePanel:onResume()
    if self.auto then UIManager:scheduleIn(1, self.auto_tick) end
    if self.ui.document then self:onClockSettingChanged() end
    if self.ui.document and self:canAutoRotate() and self:autoRotateOn() then UIManager:scheduleIn(1, self.rotate_tick) end
end

-- Auto-rotate (reMarkable): its accelerometer (lis2dw12) isn't used by KOReader, so Primer reads it
-- while a book is open. Turned sideways, the book goes to landscape with two pages side by side;
-- upright again, back to one page. A position has to hold for two readings (about 0.8 s), the
-- device lying flat changes nothing, and it waits while a Primer screen or menu is open.
local ROTATE_POLL_S = 0.4
local GRAVITY = 16384 -- raw reading for 1 g

local function findAccelerometer()
    for i = 0, 9 do
        local dir = "/sys/bus/iio/devices/iio:device" .. i
        local f = io.open(dir .. "/name", "r")
        if f then
            local name = f:read("*l")
            f:close()
            if name == "lis2dw12_accel" then return dir end
        end
    end
end

local function readNumber(path)
    local f = io.open(path, "r")
    if not f then return end
    local v = tonumber(f:read("*l"))
    f:close()
    return v
end

function VoyagePanel:canAutoRotate()
    if self.accelerometer == nil then
        self.accelerometer = Device:isRemarkable() and findAccelerometer() or false
    end
    return self.accelerometer ~= false
end

function VoyagePanel:autoRotateOn()
    return G_reader_settings:nilOrTrue("voyage_auto_rotate")
end

function VoyagePanel:setAutoRotate(on)
    G_reader_settings:saveSetting("voyage_auto_rotate", on)
    UIManager:unschedule(self.rotate_tick)
    if on and self.ui.document then UIManager:scheduleIn(ROTATE_POLL_S, self.rotate_tick) end
end

-- Which way the device is held, from gravity: nil when flat or in between.
function VoyagePanel:heldRotation()
    local x = readNumber(self.accelerometer .. "/in_accel_x_raw")
    local y = readNumber(self.accelerometer .. "/in_accel_y_raw")
    if not (x and y) then return end
    local ax, ay = math.abs(x), math.abs(y)
    if ax > 0.6 * GRAVITY and ax > 1.5 * ay then
        return x < 0 and Screen.DEVICE_ROTATED_CLOCKWISE or Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
    elseif ay > 0.6 * GRAVITY and ay > 1.5 * ax then
        return y < 0 and Screen.DEVICE_ROTATED_UPRIGHT or Screen.DEVICE_ROTATED_UPSIDE_DOWN
    end
end

function VoyagePanel:rotateTick()
    if not (self.ui.document and self:autoRotateOn()) then return end
    local held = self:heldRotation()
    if held ~= nil and held == self.rotate_candidate then
        self.rotate_count = (self.rotate_count or 0) + 1
    else
        self.rotate_candidate, self.rotate_count = held, 1
    end
    -- Only over the page itself: Primer's screens are laid out for the orientation they opened in.
    local on_page = UIManager:getTopmostVisibleWidget() == self.ui
    if held ~= nil and self.rotate_count >= 2 and on_page and held ~= Screen:getRotationMode() then
        local landscape = held == Screen.DEVICE_ROTATED_CLOCKWISE or held == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
        self.ui:handleEvent(Event:new("SetRotationMode", held))
        if self.ui.rolling then
            self.ui:handleEvent(Event:new("SetVisiblePages", landscape and 2 or 1))
        end
    end
    UIManager:scheduleIn(ROTATE_POLL_S, self.rotate_tick)
end

function VoyagePanel:paintClock(bb, x, y)
    local f = Fonts.face("ui_bold", 14)
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
    UIManager:unschedule(self.rotate_tick)
    if self.panel then UIManager:close(self.panel) end
    if self.library then UIManager:close(self.library) end
    if self.toolbar then UIManager:close(self.toolbar) end
    if self.aapanel then UIManager:close(self.aapanel) end
    if self.pageflip then UIManager:close(self.pageflip) end
    if self.goto_view then UIManager:close(self.goto_view) end
    if self.lookup then UIManager:close(self.lookup) end
    if self.note_popup then UIManager:close(self.note_popup) end
    if self.notebook then UIManager:close(self.notebook) end
    if self.settings_view then UIManager:close(self.settings_view) end
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

-- Kindle-style Settings (KOReader's full menu stays behind its ⋮).
function VoyagePanel:openAllSettings()
    if self.settings_view then return end
    local ok, err = pcall(function()
        self.settings_view = SettingsView:new{ plugin = self }
        UIManager:show(self.settings_view)
    end)
    if not ok then
        logger.err("VoyageSettings: failed to open:", err)
        self.settings_view = nil
        UIManager:show(InfoMessage:new{ text = "Settings error:\n" .. tostring(err) })
    end
end

return VoyagePanel
