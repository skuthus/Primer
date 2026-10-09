-- Kindle-style footer items: "Page 9" and "45%", without totals, icons or prefixes.
-- Layout (page left, filler, percentage right; Bookerly; no progress bar) lives in
-- the footer settings, see src/defaults/footer.lua.

local ReaderFooter = require("apps/reader/modules/readerfooter")
local Screen = require("device").screen
local generators = ReaderFooter.textGeneratorMap

-- Line the footer up with the text, like the Kindle: use the book's side margins
-- instead of KOReader's fixed ~10px. PDFs keep the stock margin.
local function alignToText(footer, h_margins)
    if footer.ui.paging or not h_margins then return end
    footer.horizontal_margin = Screen:scaleBySize(math.floor((h_margins[1] + h_margins[2]) / 2))
    footer:updateFooterContainer()
    footer:resetLayout(true)
end

local orig_onReaderReady = ReaderFooter.onReaderReady
function ReaderFooter:onReaderReady(...)
    alignToText(self, self.ui.document.configurable.h_page_margins)
    return orig_onReaderReady(self, ...)
end

local orig_onSetPageHorizMargins = ReaderFooter.onSetPageHorizMargins
function ReaderFooter:onSetPageHorizMargins(h_margins)
    alignToText(self, h_margins)
    orig_onSetPageHorizMargins(self, h_margins)
    self:refreshFooter(true)
end

-- "1 min", "15 mins", "1 hr 5 mins"
local function minutesText(minutes)
    if minutes < 60 then
        return minutes == 1 and "1 min" or ("%d mins"):format(minutes)
    end
    local h, m = math.floor(minutes / 60), minutes % 60
    local hours = h == 1 and "1 hr" or ("%d hrs"):format(h)
    if m == 0 then return hours end
    return hours .. " " .. (m == 1 and "1 min" or ("%d mins"):format(m))
end

-- Left item follows Aa > More > Reading Progress: page, time left in chapter/book, or nothing.
generators.page_progress = function(footer)
    local mode = G_reader_settings:readSetting("voyage_reading_progress") or "page"
    if mode == "none" then return "" end
    if mode == "chapter" or mode == "book" then
        local stats = footer.ui.statistics
        if stats and stats.settings and stats.settings.is_enabled and stats.avg_time and stats.avg_time == stats.avg_time then
            local left = mode == "chapter" and footer.ui.toc:getChapterPagesLeft(footer.pageno, true)
                or footer.ui.document:getTotalPagesLeft(footer.pageno)
            local minutes = math.max(1, math.ceil(left * stats.avg_time / 60))
            return minutesText(minutes) .. (mode == "chapter" and " left in chapter" or " left in book")
        end
        -- No reading-speed data yet: fall back to the page number.
    end
    -- Prefer the publisher's print page numbers when the book has them and they're enabled.
    if footer.ui.pagemap and footer.ui.pagemap:wantsPageLabels() then
        return "Page " .. footer.ui.pagemap:getCurrentPageLabel(true)
    end
    return ("Page %d"):format(footer.pageno)
end

generators.percentage = function(footer)
    -- Round down like the Kindle, so 100% only shows on the last page.
    return ("%d%%"):format(math.floor(footer.percent_finished * 100))
end
