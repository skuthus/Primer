--[[--
Library trash. Removing a book moves it (with its reading progress, highlights and notes)
into a hidden ".primer-trash" folder in the home folder, from where it can be restored to
its original place or deleted for good. The original paths live in the "voyage_trash" setting.
--]]

local BookList = require("ui/widget/booklist")
local DocSettings = require("docsettings")
local ReadCollection = require("readcollection")
local ReadHistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Trash = {}

local function home()
    return G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()
end

local function index()
    return G_reader_settings:readSetting("voyage_trash") or {}
end

local function saveIndex(idx)
    G_reader_settings:saveSetting("voyage_trash", idx)
end

function Trash.dir()
    return home() .. "/.primer-trash"
end

-- Move a file and its book data, the way KOReader's file manager does.
local function moveBook(from, to)
    if not os.rename(from, to) then return false end
    DocSettings.updateLocation(from, to)
    ReadHistory:updateItem(from, to)
    ReadCollection:updateItem(from, to)
    BookList.resetBookInfoCache(from)
    BookList.resetBookInfoCache(to)
    return true
end

-- A free path: "name.epub", else "name (2).epub", …
local function freePath(path)
    if not lfs.attributes(path, "mode") then return path end
    local base, ext = path:match("^(.*)(%.[^./]+)$")
    base, ext = base or path, ext or ""
    for i = 2, 99 do
        local candidate = string.format("%s (%d)%s", base, i, ext)
        if not lfs.attributes(candidate, "mode") then return candidate end
    end
end

function Trash.move(file)
    local dir = Trash.dir()
    util.makePath(dir)
    local dest = freePath(dir .. "/" .. file:match("([^/]+)$"))
    if not (dest and moveBook(file, dest)) then return false end
    local idx = index()
    idx[dest:match("([^/]+)$")] = { orig = file, time = os.time() }
    saveIndex(idx)
    return true
end

function Trash.restore(trashed)
    local idx = index()
    local name = trashed:match("([^/]+)$")
    local entry = idx[name]
    local target = freePath(entry and entry.orig or (home() .. "/" .. name))
    if not target then return false end
    util.makePath(target:match("^(.*)/[^/]+$"))
    if not moveBook(trashed, target) then return false end
    idx[name] = nil
    saveIndex(idx)
    return target
end

function Trash.purge(trashed)
    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager:deleteFile(trashed, true) then return false end
    local idx = index()
    idx[trashed:match("([^/]+)$")] = nil
    saveIndex(idx)
    return true
end

-- Trashed books, newest first: { file, name, orig, time, size }.
function Trash.list()
    local dir, idx, items = Trash.dir(), index(), {}
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok then return items end
    for name in iter, state do
        local path = dir .. "/" .. name
        if name:sub(1, 1) ~= "." and not name:match("%.sdr$") and lfs.attributes(path, "mode") == "file" then
            local entry = idx[name] or {}
            table.insert(items, { file = path, name = name, orig = entry.orig, time = entry.time or 0,
                size = lfs.attributes(path, "size") or 0 })
        end
    end
    table.sort(items, function(a, b) return a.time > b.time end)
    return items
end

function Trash.empty()
    for __, item in ipairs(Trash.list()) do Trash.purge(item.file) end
end

return Trash
