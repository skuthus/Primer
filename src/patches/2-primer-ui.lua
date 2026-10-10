-- Primer's interface font everywhere KOReader still draws its own UI (menus, title bars,
-- dialogs, notifications, dictionary and book map windows, the keyboard): Amazon Ember on
-- Kindles, else Inter bundled with Primer (koreader/fonts/primer). Noto stays as the fallback
-- for glyphs these fonts lack. Book text and monospace fields are untouched.
-- Also: rounded keys on the on-screen keyboard, like the Kindle's; square window corners and
-- left-aligned full-screen titles with a rule under them, like Primer's own screens.

-- Rounded keys (white on the keyboard's light grey), like the Kindle's keyboard.
local VirtualKeyboard = require("ui/widget/virtualkeyboard")
local Screen = require("device").screen
local orig_addKeys = VirtualKeyboard.addKeys
function VirtualKeyboard:addKeys(...)
    local r = orig_addKeys(self, ...)
    local radius = Screen:scaleBySize(6)
    for __, row in ipairs(self.layout or {}) do
        for __, key in ipairs(row) do
            if type(key) == "table" and key[1] and key[1].radius ~= nil then key[1].radius = radius end
        end
    end
    return r
end

-- Square corners on KOReader's windows (dictionary, dialogs), like Primer's cards.
require("ui/size").radius.window = 0

-- Full-screen title bars (book map, page browser, lists): title on the left over a rule.
local TitleBar = require("ui/widget/titlebar")
local orig_titlebar_init = TitleBar.init
function TitleBar:init()
    if self.fullscreen then
        self.align = "left"
        self.with_bottom_line = true
    end
    return orig_titlebar_init(self)
end

-- Fonts ------------------------------------------------------------------------------

local Font = require("ui/font")
local lfs = require("libs/libkoreader-lfs")

local function pick(kindle, bundled)
    if lfs.attributes("/usr/java/lib/fonts/" .. kindle, "mode") == "file" then
        return "/usr/java/lib/fonts/" .. kindle
    end
    if lfs.attributes("./fonts/primer/" .. bundled, "mode") == "file" then
        return "primer/" .. bundled
    end
end

local REGULAR = pick("Amazon-Ember-Regular.ttf", "Inter-Regular.ttf")
local BOLD = pick("Amazon-Ember-Bold.ttf", "Inter-Bold.ttf")
local ITALIC = pick("Amazon-Ember-RegularItalic.ttf", "Inter-Italic.ttf")
if not (REGULAR and BOLD) then return end -- (keep this section last)

local swap = {
    ["NotoSans-Regular.ttf"] = REGULAR,
    ["NotoSans-Bold.ttf"] = BOLD,
    ["NotoSans-Italic.ttf"] = ITALIC,
    -- The keyboard's key labels ("infont"); input fields keep their monospace "smallinfont".
    ["DroidSansMono.ttf"] = false,
}
for name, file in pairs(Font.fontmap) do
    if swap[file] then Font.fontmap[name] = swap[file] end
end
Font.fontmap.infont = REGULAR
Font.bold_font_variant[REGULAR] = BOLD
Font.regular_font_variant[BOLD] = REGULAR

-- Widgets that resolved their face when first loaded: point them at the new fonts.
for __, path in ipairs({
    "ui/widget/notification", "ui/widget/buttondialog", "ui/widget/confirmbox",
    "ui/widget/multiconfirmbox", "ui/widget/inputdialog", "ui/widget/inputtext",
    "ui/widget/checkbutton", "ui/widget/checkmark", "ui/widget/radiomark",
    "ui/widget/radiobuttontable", "ui/widget/sortwidget", "ui/widget/titlebar",
    "ui/widget/datetimewidget", "ui/widget/doublespinwidget", "ui/widget/numberpickerwidget",
    "ui/widget/trapwidget", "ui/widget/touchmenu", "ui/widget/virtualkeyboard",
}) do
    local ok, M = pcall(require, path)
    if ok and type(M) == "table" then
        for field, f in pairs(M) do
            if type(f) == "table" and f.realname and f.orig_size then
                local file = f.orig_font == "infont" and REGULAR or swap[f.realname]
                if file then M[field] = Font:getFace(file, f.orig_size) or f end
            end
        end
    end
end
