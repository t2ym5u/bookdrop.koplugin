-- bookdrop_logic.lua -- pure decision logic for Book Drop.
--
-- No KOReader dependency (only the Lua standard library), so every function
-- here is specced with busted in test_bookdrop_logic_spec.lua. Must stay
-- LuaJIT / Lua 5.1 compatible: no integer division, no goto, no utf8 lib.

local L = {}

L.DEFAULT_FOLDER = "Bookdrop"
L.DEFAULT_TYPES  = { "epub", "pdf", "cbz", "fb2", "mobi", "azw", "djvu", "txt", "html", "docx" }
L.AUTO_INTERVAL  = 300   -- seconds between two automatic checks
L.SETTLE_SECONDS = 30    -- a file modified more recently than this may still be uploading

-- Containers that must be a complete ZIP archive to be readable.
local ZIP_TYPES = {
    epub = true, epub3 = true, kepub = true, cbz = true, docx = true, docm = true,
    odt = true, htmlz = true, fb3 = true, pptx = true, xlsx = true, zip = true,
}

---------------------------------------------------------------------------
-- Strings and URLs
---------------------------------------------------------------------------

function L.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "user:password" for Basic auth. Both are trimmed: a space typed (unseen) at
-- either end of a masked password field turns a good password into a 401.
function L.credentials(username, password)
    return L.trim(username or "") .. ":" .. L.trim(password or "")
end

-- Percent-decoding for URL *paths*: "+" is a literal plus here, not a space.
function L.urlDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Percent-encode one path segment (RFC 3986 unreserved characters kept).
function L.encodeSegment(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Encode a relative path ("Books/Drop box") segment by segment, dropping
-- empty segments, "." and "..".
function L.encodePath(path)
    local out = {}
    for seg in (path or ""):gmatch("[^/\\]+") do
        if seg ~= "." and seg ~= ".." then out[#out + 1] = L.encodeSegment(seg) end
    end
    return table.concat(out, "/")
end

-- XML character references and the five predefined entities.
local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

function L.xmlUnescape(s)
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    return (s:gsub("&amp;", "&"))
end

-- "https://host/a/b/" -> "/a/b/" ; "/a/b" -> "/a/b"
function L.urlPath(url)
    local p = url:match("^%a[%w+.-]*://[^/]*(/.*)$")
    if p then return p end
    if url:match("^%a[%w+.-]*://[^/]*$") then return "/" end
    return url
end

-- The folder URL every request is built from, always with a trailing slash.
function L.folderUrl(server, folder)
    local base = L.trim(server or ""):gsub("/+$", "")
    local enc = L.encodePath(folder)
    if enc == "" then return base .. "/" end
    return base .. "/" .. enc .. "/"
end

function L.fileUrl(folder_url, name)
    return folder_url .. L.encodeSegment(name)
end

-- Is this a plausible http(s) server address?
function L.validServerUrl(s)
    s = L.trim(s or "")
    return s:match("^[Hh][Tt][Tt][Pp][Ss]?://[^/%s]+") ~= nil
end

---------------------------------------------------------------------------
-- PROPFIND
---------------------------------------------------------------------------

L.PROPFIND_BODY = '<?xml version="1.0" encoding="utf-8"?>'
    .. '<d:propfind xmlns:d="DAV:"><d:prop>'
    .. '<d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/>'
    .. '</d:prop></d:propfind>'

-- Last non-empty segment of an href, percent-decoded.
function L.hrefName(href)
    local path = L.urlPath(href)
    local last
    for seg in path:gmatch("[^/]+") do last = seg end
    return last and L.urlDecode(last) or nil
end

local function normPath(p)
    return L.urlDecode(L.urlPath(p)):gsub("/+$", "")
end

-- Parses a Depth: 1 multistatus. `folder_url` identifies the folder's own
-- entry. Returns a list of
--   { href, name, is_dir, is_self, size (number|nil), etag, lastmod }
-- Namespace prefixes vary between servers (d:, D:, lp1:, or none at all),
-- so they are stripped from tag names before matching.
function L.parsePropfind(xml, folder_url)
    local entries = {}
    if type(xml) ~= "string" then return entries end
    xml = xml:gsub("<(/?)[%w_%-%.]+:", "<%1")
    local self_path = folder_url and normPath(folder_url)
    for body in xml:gmatch("<response[%s>].-</response>") do
        local href = body:match("<href[^>]*>%s*(.-)%s*</href>")
        if href and href ~= "" then
            href = L.xmlUnescape(href)
            local rtype = body:match("<resourcetype[^>]*/>") and ""
                or body:match("<resourcetype[^>]*>(.-)</resourcetype>") or ""
            local size = body:match("<getcontentlength[^>]*>%s*(%d+)%s*</getcontentlength>")
            local etag = body:match("<getetag[^>]*>%s*(.-)%s*</getetag>")
            local lastmod = body:match("<getlastmodified[^>]*>%s*(.-)%s*</getlastmodified>")
            local e = {
                href    = href,
                name    = L.hrefName(href),
                is_dir  = rtype:find("<collection") ~= nil,
                size    = size and tonumber(size) or nil,
                etag    = (etag and etag ~= "") and L.xmlUnescape(etag) or nil,
                lastmod = (lastmod and lastmod ~= "") and lastmod or nil,
            }
            e.is_self = self_path ~= nil and normPath(href) == self_path
            entries[#entries + 1] = e
        end
    end
    return entries
end

---------------------------------------------------------------------------
-- HTTP dates
---------------------------------------------------------------------------

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
                 Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

-- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- RFC 1123 date ("Sun, 06 Nov 1994 08:49:37 GMT") -> UTC epoch, or nil.
function L.parseHttpDate(s)
    if type(s) ~= "string" then return nil end
    local d, mon, y, hh, mm, ss = s:match("(%d%d?)[ %-](%a%a%a)[ %-](%d%d%d%d) (%d%d):(%d%d):(%d%d)")
    local m = mon and MONTHS[mon]
    if not m then return nil end
    return daysFromCivil(tonumber(y), m, tonumber(d)) * 86400
        + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
end

---------------------------------------------------------------------------
-- Local file names
---------------------------------------------------------------------------

-- Cut a string to at most `max` bytes without splitting a UTF-8 sequence.
local function utf8Cut(s, max)
    if #s <= max then return s end
    local i = max
    -- step back over continuation bytes so s:sub(1, i) ends on a boundary
    while i > 0 and s:byte(i + 1) and s:byte(i + 1) >= 0x80 and s:byte(i + 1) < 0xC0 do
        i = i - 1
    end
    return s:sub(1, i)
end

-- Turn a remote name into a safe local file name, or nil if nothing usable
-- is left. Strips path separators, "..", control characters and the
-- characters FAT32 (Kobo/Kindle storage) refuses.
function L.sanitizeName(name)
    if type(name) ~= "string" then return nil end
    local s = name:gsub("[%z\1-\31\127]", "")
    s = s:gsub("[/\\]", "_")
    s = s:gsub('[:%*%?"<>|]', "_")
    s = s:gsub("%.%.+", ".")
    s = L.trim(s)
    s = s:gsub("^%.+", "")          -- no hidden files, no "." / ".."
    s = s:gsub("[%s%.]+$", "")      -- Windows/FAT drop trailing dots and spaces
    if s == "" then return nil end
    if #s > 240 then
        local stem, ext = s:match("^(.*)(%.[^%.]+)$")
        if stem and #ext <= 16 then
            s = utf8Cut(stem, 240 - #ext) .. ext
        else
            s = utf8Cut(s, 240)
        end
    end
    return s
end

-- Lower-cased extension; ".fb2.zip" style double suffixes are not needed
-- for the type filter, which is about the last suffix.
function L.extension(name)
    local ext = type(name) == "string" and name:match("%.([^%./\\]+)$")
    return ext and ext:lower() or nil
end

-- "Name.epub" -> "Name (2).epub" -> "Name (3).epub"... `exists(name)` says
-- whether a candidate is taken. Never returns a taken name.
function L.uniqueName(name, exists)
    if not exists(name) then return name end
    local stem, ext = name:match("^(.+)(%.[^%.]+)$")
    if not stem then stem, ext = name, "" end
    local n = 2
    while true do
        local cand = stem .. " (" .. n .. ")" .. ext
        if not exists(cand) then return cand end
        n = n + 1
    end
end

---------------------------------------------------------------------------
-- File types
---------------------------------------------------------------------------

-- "epub, .PDF  cbz" -> { "epub", "pdf", "cbz" } (deduplicated, in order)
function L.parseTypes(s)
    local out, seen = {}, {}
    for raw in (s or ""):gmatch("[^%s,;]+") do
        local t = raw:gsub("^%.+", ""):lower()
        if t ~= "" and not seen[t] then
            seen[t] = true
            out[#out + 1] = t
        end
    end
    return out
end

function L.typesToString(types)
    return table.concat(types or {}, ", ")
end

function L.typeAllowed(name, types)
    local ext = L.extension(name)
    if not ext then return false end
    for _, t in ipairs(types or {}) do
        if t == ext then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Content validation
---------------------------------------------------------------------------

function L.needsZipCheck(name)
    return ZIP_TYPES[L.extension(name) or ""] == true
end

-- A ZIP is complete when it starts with a local file header and its
-- end-of-central-directory record ("PK\5\6", at most 65535 + 22 bytes from
-- the end) is present. `head` is the first bytes, `tail` the last <= 65557.
function L.zipBytesValid(head, tail)
    if type(head) ~= "string" or head:sub(1, 4) ~= "PK\3\4" then return false end
    if type(tail) ~= "string" then return false end
    local pos = 1
    while true do
        local i = tail:find("PK\5\6", pos, true)
        if not i then return false end
        -- the record is 22 bytes + comment; the comment must fit in the file
        if #tail - i + 1 >= 22 then
            local lo, hi = tail:byte(i + 20, i + 21)
            if lo and (#tail - i + 1) >= 22 + lo + hi * 256 then return true end
        end
        pos = i + 1
    end
end

function L.needsPdfCheck(name)
    return L.extension(name) == "pdf"
end

-- A complete PDF starts with "%PDF-" and has an "%%EOF" marker near its end.
function L.pdfBytesValid(head, tail)
    if type(head) ~= "string" or head:sub(1, 5) ~= "%PDF-" then return false end
    return type(tail) == "string" and tail:find("%%EOF", 1, true) ~= nil
end

-- Reads `path` and validates it according to the name's type.
-- Returns true, or false + reason ("zip" / "pdf" / "io").
function L.validateFile(path, name)
    local zip, pdf = L.needsZipCheck(name), L.needsPdfCheck(name)
    if not zip and not pdf then return true end
    local f = io.open(path, "rb")
    if not f then return false, "io" end
    local head = f:read(8) or ""
    local size = f:seek("end")
    local tail_len = zip and 65557 or 4096
    f:seek("set", math.max(0, size - tail_len))
    local tail = f:read(tail_len) or ""
    f:close()
    if zip then
        if L.zipBytesValid(head, tail) then return true end
        return false, "zip"
    end
    if L.pdfBytesValid(head, tail) then return true end
    return false, "pdf"
end

---------------------------------------------------------------------------
-- Bookkeeping of remote files already handled
---------------------------------------------------------------------------

-- A record { size, etag, lastmod } still describes `entry` when the
-- strongest validator both sides have agrees.
function L.sameVersion(rec, entry)
    if not rec or not entry then return false end
    if rec.etag and entry.etag then return rec.etag == entry.etag end
    if rec.size ~= entry.size then return false end
    if rec.lastmod and entry.lastmod then return rec.lastmod == entry.lastmod end
    return true
end

function L.record(entry, extra)
    local r = { size = entry.size, etag = entry.etag, lastmod = entry.lastmod }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

-- Decides what a check does with a listing.
--   state.fetched[name]  : downloaded, remote DELETE still owed
--   state.rejected[name] : downloaded complete but not a valid book; skipped
--                          until the remote file changes
--   opts = { types, server_now (epoch|nil), settle (seconds) }
-- Returns a plan:
--   download, retry_delete : lists of entries
--   skipped_type, skipped_dirs, skipped_empty, waiting, rejected : counts
--   drop_fetched, drop_rejected : names whose records are obsolete
function L.plan(entries, state, opts)
    state = state or {}
    opts = opts or {}
    local fetched, rejected = state.fetched or {}, state.rejected or {}
    local settle = opts.settle or L.SETTLE_SECONDS
    local p = {
        download = {}, retry_delete = {},
        skipped_type = 0, skipped_dirs = 0, skipped_empty = 0, waiting = 0, rejected = 0,
        drop_fetched = {}, drop_rejected = {},
    }
    local present = {}
    for _, e in ipairs(entries or {}) do
        if e.is_self then -- luacheck: ignore 542
            -- the drop folder itself
        elseif e.is_dir then
            p.skipped_dirs = p.skipped_dirs + 1
        elseif not e.name then -- luacheck: ignore 542
            -- unusable href
        else
            present[e.name] = true
            if fetched[e.name] and L.sameVersion(fetched[e.name], e) then
                p.retry_delete[#p.retry_delete + 1] = e
            elseif rejected[e.name] and L.sameVersion(rejected[e.name], e) then
                p.rejected = p.rejected + 1
            else
                -- a changed file under a known name is a new drop
                if fetched[e.name] then p.drop_fetched[#p.drop_fetched + 1] = e.name end
                if rejected[e.name] then p.drop_rejected[#p.drop_rejected + 1] = e.name end
                if not L.typeAllowed(e.name, opts.types) then
                    p.skipped_type = p.skipped_type + 1
                elseif e.size == 0 then
                    p.skipped_empty = p.skipped_empty + 1
                else
                    local mod = L.parseHttpDate(e.lastmod)
                    if opts.server_now and mod and opts.server_now - mod < settle then
                        p.waiting = p.waiting + 1
                    else
                        p.download[#p.download + 1] = e
                    end
                end
            end
        end
    end
    -- records whose remote file is gone (deleted by hand, or by us at last)
    for name in pairs(fetched) do
        if not present[name] then p.drop_fetched[#p.drop_fetched + 1] = name end
    end
    for name in pairs(rejected) do
        if not present[name] then p.drop_rejected[#p.drop_rejected + 1] = name end
    end
    table.sort(p.download, function(a, b) return a.name < b.name end)
    return p
end

---------------------------------------------------------------------------
-- Scheduling
---------------------------------------------------------------------------

-- Should an *automatic* check start now?
-- s = { enabled, configured, paused, in_flight, reading, now, last_auto, interval }
-- Returns ok, reason ("disabled", "unconfigured", "paused", "busy", "reading",
-- "throttled").
function L.shouldAutoCheck(s)
    if not s.enabled then return false, "disabled" end
    if not s.configured then return false, "unconfigured" end
    if s.paused then return false, "paused" end
    if s.in_flight then return false, "busy" end
    if s.reading then return false, "reading" end
    local interval = s.interval or L.AUTO_INTERVAL
    if s.last_auto and s.now and s.now - s.last_auto < interval and s.now >= s.last_auto then
        return false, "throttled"
    end
    return true
end

-- Errors after which automatic checks stop until the settings change or a
-- manual check succeeds: retrying them only adds failed logins, and servers
-- such as Koofr answer those with a temporary block (429).
function L.pausesAutoCheck(error_key)
    return error_key == "auth" or error_key == "rate_limited"
end

-- Total timeout for downloading `size` bytes: generous, assumes >= 20 KB/s.
function L.downloadTimeout(size)
    local t = math.floor((size or 0) / 20000)
    if t < 60 then t = 60 end
    if t > 1800 then t = 1800 end
    return t
end

---------------------------------------------------------------------------
-- Errors
---------------------------------------------------------------------------

-- Maps a failed request to a message key (translated by the caller).
--   code: HTTP status number, or nil with `err` a LuaSocket error string
function L.classifyError(code, err, what)
    if type(code) ~= "number" then
        err = tostring(err or code or "")
        if err:find("timeout") then return "timeout" end
        if err:find("host not found") or err:find("nodename") or err:find("resolve") then
            return "dns"
        end
        if err:find("refused") then return "refused" end
        if err:find("certificate") or err:find("ssl") or err:find("handshake") then return "tls" end
        return "network"
    end
    if code == 401 then return "auth" end
    if code == 403 then return "forbidden" end
    if code == 429 then return "rate_limited" end
    if code == 404 then return what == "folder" and "folder_missing" or "not_found" end
    if code == 405 or code == 501 then return "not_webdav" end
    if code == 507 then return "server_full" end
    if code >= 500 then return "server" end
    return "http"
end

return L
