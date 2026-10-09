-- Kindle-style message boxes: Amazon Ember, no info icon, short messages centered,
-- and no "Opening file" box at all.
-- Warning/error icons and boxes that bring their own face or image are left alone.

local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")

local EMBER = "/usr/java/lib/fonts/Amazon-Ember-Regular.ttf"
local has_ember = lfs.attributes(EMBER, "mode") == "file"

-- KOReader's "Opening file '…'" box: the Kindle shows nothing while a book opens.
local _ = require("gettext")
local OPENING_PREFIX = _("Opening file '%1'."):match("^(.-)%%1")

local orig_init = InfoMessage.init
function InfoMessage:init()
    if OPENING_PREFIX and type(self.text) == "string" and self.text:sub(1, #OPENING_PREFIX) == OPENING_PREFIX then
        self.invisible = true
    end
    if self.icon == "notice-info" and not self.image then
        self.show_icon = false
    end
    if has_ember and not self.face and not self.monospace_font then
        self.face = Font:getFace(EMBER, 20)
    end
    if self.alignment == "left" and type(self.text) == "string" and #self.text < 120 then
        self.alignment = "center"
    end
    return orig_init(self)
end
