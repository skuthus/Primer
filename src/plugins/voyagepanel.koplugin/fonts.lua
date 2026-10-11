--[[--
Font roles for Primer's interface. On Kindles the built-in Amazon fonts are used; elsewhere
the open fonts Primer bundles (installed to koreader/fonts/primer/); failing both, KOReader's
own default. Amazon's fonts are proprietary and are never bundled.

    Fonts.face("ui_bold", 18)    Fonts.path("ui")  -- path KOReader's font settings understand
--]]

local Device = require("device")
local Font = require("ui/font")
local lfs = require("libs/libkoreader-lfs")

local KINDLE = "/usr/java/lib/fonts/"
local BUNDLED = "./fonts/primer/"

local ROLES = {
    ui           = { "Amazon-Ember-Regular.ttf", "Inter-Regular.ttf", "ffont" },
    ui_bold      = { "Amazon-Ember-Bold.ttf", "Inter-Bold.ttf", "ffont" },
    ui_italic    = { "Amazon-Ember-RegularItalic.ttf", "Inter-Italic.ttf", "ffont" },
    serif        = { "Bookerly-Regular.ttf", "Literata-Regular.ttf", "cfont" },
    serif_bold   = { "Bookerly-Bold.ttf", "Literata-Bold.ttf", "cfont" },
    serif_italic = { "Bookerly-Italic.ttf", "Literata-Italic.ttf", "cfont" },
    slab         = { "Caecilia_LT_65_Medium.ttf", "Bitter-Medium.ttf", "cfont" },
}

local resolved = {}

local function exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local Fonts = {}

-- Book text sizes were tuned on the Voyage (6"). On the 7" Paperwhite (2024) the same sizes read
-- a little big (user, 2026-10-11), so its whole size ladder runs 10% smaller: Size 4 is 20
-- there instead of 22. Other models keep the Voyage's sizes.
local BOOK_SCALE = {
    KindlePaperWhite6 = 0.9,
}

-- A Voyage-tuned book font size as this device should use it.
function Fonts.bookSize(size)
    local scale = BOOK_SCALE[Device.model] or 1
    return math.floor(size * scale + 0.5)
end

-- File for a role (Kindle font, else bundled), or nil if only KOReader's default is left.
function Fonts.path(role)
    if resolved[role] == nil then
        local r = ROLES[role] or ROLES.ui
        if exists(KINDLE .. r[1]) then
            resolved[role] = KINDLE .. r[1]
        elseif exists(BUNDLED .. r[2]) then
            resolved[role] = BUNDLED .. r[2]
        else
            resolved[role] = false
        end
    end
    return resolved[role] or nil
end

function Fonts.face(role, size)
    local path = Fonts.path(role)
    if path then
        -- Font:getFace takes paths relative to KOReader's fonts dir, or absolute ones.
        local name = path:sub(1, #"./fonts/") == "./fonts/" and path:sub(#"./fonts/" + 1) or path
        local ok, f = pcall(Font.getFace, Font, name, size)
        if ok and f then return f end
    end
    return Font:getFace((ROLES[role] or ROLES.ui)[3], size)
end

return Fonts
