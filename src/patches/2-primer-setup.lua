-- Primer's first-run setup, so a fresh install is ready without touching KOReader's menus.
-- Runs before KOReader decides what to open, once per SETUP_VERSION:
--   * Primer's look and behaviour (refresh, footer, sleep screens, start with the last book),
--     on a new install only: someone updating Primer keeps the choices they've made,
--   * reading defaults (font, size, margins…) only where there is no value yet,
--   * gestures: KOReader's frontlight / brightness / page-flipping gestures off,
--   * KOReader's quickstart guide skipped (Primer opens on its library instead).
-- The values live in plugins/voyagepanel.koplugin/defaults/.

local SETUP_VERSION = 2 -- 2: sleep after 10 minutes, like a Kindle

if (G_reader_settings:readSetting("primer_setup_version") or 0) >= SETUP_VERSION then return end

local DataStorage = require("datastorage")
local Device = require("device")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local DEFAULTS = "plugins/voyagepanel.koplugin/defaults/"

local function readDefaults(name)
    local ok, t = pcall(dofile, DEFAULTS .. name .. ".lua")
    if ok and type(t) == "table" then return t end
    logger.warn("Primer setup: couldn't read defaults", name, t)
end

local function exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local kindle_fonts = Device:isKindle() and exists("/usr/java/lib/fonts/Amazon-Ember-Regular.ttf")

-- Primer has run here before (from before this setup existed) if any of its settings are there.
local existing_primer = false
for key in pairs(G_reader_settings.data) do
    if type(key) == "string" and (key:find("^voyage_") or key:find("^primer_")) then
        existing_primer = true
        break
    end
end

local device = readDefaults("device")

-- Defaults that never override a choice (new installs and updates).
for k, v in pairs(device and device.unset or {}) do
    if not G_reader_settings:has(k) then G_reader_settings:saveSetting(k, v) end
end

-- Look and behaviour (new installs only).
if device and not existing_primer then
    for k, v in pairs(device.all or {}) do G_reader_settings:saveSetting(k, v) end
    if Device:isKindle() then
        for k, v in pairs(device.kindle or {}) do G_reader_settings:saveSetting(k, v) end
    end
end

local footer = not existing_primer and readDefaults("footer")
if footer then
    if not kindle_fonts then footer.text_font_face = "primer/Inter-Regular.ttf" end
    local current = G_reader_settings:readSetting("footer") or {}
    for k, v in pairs(footer) do current[k] = v end
    G_reader_settings:saveSetting("footer", current)
end

-- Reading defaults: never over the reader's own.
local reading = readDefaults("reading")
if reading then
    if not (kindle_fonts and exists("/usr/java/lib/fonts/Bookerly-Regular.ttf")) then reading.cre_font = "Literata" end
    for k, v in pairs(reading) do
        if not G_reader_settings:has(k) then G_reader_settings:saveSetting(k, v) end
    end
end

-- Gestures: start from KOReader's defaults when there is no gestures file yet.
local gestures = readDefaults("gestures")
if gestures then
    local file = LuaSettings:open(DataStorage:getSettingsDir() .. "/gestures.lua")
    if not next(file.data) then
        local defaults = LuaSettings:open("plugins/gestures.koplugin/defaults.lua")
        file.data = require("util").tableDeepCopy(defaults.data)
    end
    for __, mode in ipairs({ "gesture_fm", "gesture_reader" }) do
        local t = file.data[mode] or {}
        for name, action in pairs(gestures) do t[name] = action end
        file.data[mode] = t
    end
    file:flush()
end

-- Skip KOReader's quickstart guide.
local ok, QuickStart = pcall(require, "ui/quickstart")
if ok and QuickStart.quickstart_force_show_version
        and (G_reader_settings:readSetting("quickstart_shown_version") or 0) < QuickStart.quickstart_force_show_version then
    G_reader_settings:saveSetting("quickstart_shown_version", QuickStart.quickstart_force_show_version)
end

G_reader_settings:saveSetting("primer_setup_version", SETUP_VERSION)
G_reader_settings:flush()
logger.info("Primer setup: applied version", SETUP_VERSION, existing_primer and "(update: kept look settings)" or "(new install)")
