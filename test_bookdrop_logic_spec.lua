-- busted specs for bookdrop_logic.lua (pure, no KOReader).
local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local L = dofile(dir .. "bookdrop_logic.lua")

local function tmpfile(content)
    local p = os.tmpname()
    local f = assert(io.open(p, "wb"))
    f:write(content)
    f:close()
    return p
end

-- A minimal, complete ZIP: one stored empty file "a".
local function tinyZip(comment)
    comment = comment or ""
    local lfh = "PK\3\4" .. string.rep("\0", 22) .. "\1\0\0\0" .. "a"
    local cd  = "PK\1\2" .. string.rep("\0", 24) .. "\1\0" .. string.rep("\0", 12) .. "\0\0\0\0" .. "a"
    local eocd = "PK\5\6" .. string.rep("\0", 4) .. "\1\0\1\0"
        .. string.char(#cd, 0, 0, 0) .. string.char(#lfh, 0, 0, 0)
        .. string.char(#comment % 256, math.floor(#comment / 256)) .. comment
    return lfh .. cd .. eocd
end

describe("urls", function()
    it("decodes UTF-8 percent escapes and keeps '+'", function()
        assert.equal("Le Petit Prince é+.epub", L.urlDecode("Le%20Petit%20Prince%20%C3%A9+.epub"))
    end)
    it("encodes a segment, keeping unreserved characters", function()
        assert.equal("Le%20Petit%20Prince%20%C3%A9%2B%23%3F.epub", L.encodeSegment("Le Petit Prince é+#?.epub"))
        assert.equal("a-b_c.d~e", L.encodeSegment("a-b_c.d~e"))
    end)
    it("round-trips any name through encode/decode", function()
        local n = "Ça & ça / 100% (2).epub"
        assert.equal(n, L.urlDecode(L.encodeSegment(n)))
    end)
    it("builds folder URLs with exactly one slash between parts", function()
        assert.equal("https://app.koofr.net/dav/Koofr/Bookdrop/", L.folderUrl("https://app.koofr.net/dav/Koofr/", "Bookdrop"))
        assert.equal("https://h/dav/Bookdrop/", L.folderUrl("  https://h/dav  ", "/Bookdrop/"))
        assert.equal("https://h/dav/My%20Books/Drop/", L.folderUrl("https://h/dav//", "My Books/Drop"))
        assert.equal("https://h/dav/", L.folderUrl("https://h/dav", ""))
        assert.equal("https://h/x/", L.folderUrl("https://h/", "../x"))
    end)
    it("validates server URLs", function()
        assert.is_true(L.validServerUrl("https://app.koofr.net/dav/Koofr/"))
        assert.is_true(L.validServerUrl("HTTP://192.168.1.2:8080"))
        assert.is_false(L.validServerUrl("app.koofr.net"))
        assert.is_false(L.validServerUrl(nil))
        assert.is_false(L.validServerUrl("https://"))
    end)
    it("extracts the path of a URL", function()
        assert.equal("/a/b/", L.urlPath("https://h:8080/a/b/"))
        assert.equal("/", L.urlPath("https://h"))
        assert.equal("/a", L.urlPath("/a"))
    end)
end)

describe("credentials", function()
    it("trims spaces around the username and password, not inside", function()
        assert.equal("me@mail.fr:ab cd", L.credentials(" me@mail.fr ", " ab cd \n"))
    end)
    it("keeps '%' and accents as they are", function()
        assert.equal("u:p%41é", L.credentials("u", "p%41é"))
    end)
    it("accepts a missing password", function()
        assert.equal("u:", L.credentials("u", nil))
    end)
end)

describe("errors", function()
    it("reports 429 as a temporary block", function()
        assert.equal("rate_limited", L.classifyError(429))
    end)
    it("pauses automatic checks only after a refused login or a block", function()
        assert.is_true(L.pausesAutoCheck(L.classifyError(401)))
        assert.is_true(L.pausesAutoCheck(L.classifyError(429)))
        assert.is_false(L.pausesAutoCheck(L.classifyError(503)))
        assert.is_false(L.pausesAutoCheck(L.classifyError(nil, "timeout")))
        assert.is_false(L.pausesAutoCheck(nil))
    end)
end)

describe("parsePropfind", function()
    local xml = [[<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/dav/Koofr/Bookdrop/</d:href><d:propstat><d:prop>
   <d:resourcetype><d:collection/></d:resourcetype></d:prop>
   <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/dav/Koofr/Bookdrop/Le%20Petit%20Prince%20%C3%A9.epub</d:href><d:propstat><d:prop>
   <d:resourcetype/><d:getcontentlength>1234</d:getcontentlength>
   <d:getetag>"abc"</d:getetag>
   <d:getlastmodified>Fri, 30 Oct 2026 10:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
 <d:response><d:href>https://app.koofr.net/dav/Koofr/Bookdrop/Sub/</d:href><d:propstat><d:prop>
   <d:resourcetype><d:collection /></d:resourcetype></d:prop></d:propstat></d:response>
 <d:response><d:href>/dav/Koofr/Bookdrop/Tom%20&amp;%20Jerry.pdf</d:href><d:propstat><d:prop>
   <d:resourcetype></d:resourcetype><d:getcontentlength>7</d:getcontentlength></d:prop></d:propstat></d:response>
</d:multistatus>]]

    it("reads files, folders, sizes, etags and dates", function()
        local e = L.parsePropfind(xml, "https://app.koofr.net/dav/Koofr/Bookdrop/")
        assert.equal(4, #e)
        assert.is_true(e[1].is_self)
        assert.is_true(e[1].is_dir)
        assert.equal("Le Petit Prince é.epub", e[2].name)
        assert.is_false(e[2].is_dir)
        assert.is_false(e[2].is_self)
        assert.equal(1234, e[2].size)
        assert.equal('"abc"', e[2].etag)
        assert.equal("Fri, 30 Oct 2026 10:00:00 GMT", e[2].lastmod)
        assert.is_true(e[3].is_dir)
        assert.is_false(e[3].is_self)
        assert.equal("Sub", e[3].name)
        assert.equal("Tom & Jerry.pdf", e[4].name)
        assert.equal(7, e[4].size)
    end)

    it("handles upper-case and missing namespace prefixes", function()
        local up = [[<D:multistatus xmlns:D="DAV:"><D:response><D:href>/x/a.epub</D:href>
            <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>5</D:getcontentlength></D:prop></D:propstat></D:response></D:multistatus>]]
        local e = L.parsePropfind(up, "http://h/x/")
        assert.equal(1, #e)
        assert.equal("a.epub", e[1].name)
        assert.equal(5, e[1].size)
        local none = [[<multistatus xmlns="DAV:"><response><href>/x/</href><propstat><prop>
            <resourcetype><collection/></resourcetype></prop></propstat></response>
            <response><href>/x/b%20c.fb2</href><propstat><prop><resourcetype/>
            <getcontentlength>9</getcontentlength></prop></propstat></response></multistatus>]]
        e = L.parsePropfind(none, "http://h/x/")
        assert.equal(2, #e)
        assert.is_true(e[1].is_self)
        assert.equal("b c.fb2", e[2].name)
    end)

    it("decodes numeric character references in hrefs", function()
        local x = [[<d:multistatus xmlns:d="DAV:"><d:response><d:href>/x/caf&#233;%20&#x4E2D;.epub</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response></d:multistatus>]]
        local e = L.parsePropfind(x, "/x/")
        assert.equal("café 中.epub", e[1].name)
        assert.is_nil(e[1].size)
    end)

    it("returns nothing for garbage", function()
        assert.same({}, L.parsePropfind(nil))
        assert.same({}, L.parsePropfind("<html>Login</html>"))
    end)
end)

describe("parseHttpDate", function()
    it("parses RFC 1123 dates as UTC", function()
        assert.equal(784111777, L.parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"))
        assert.equal(0, L.parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"))
        assert.equal(951782400, L.parseHttpDate("Tue, 29 Feb 2000 00:00:00 GMT"))
    end)
    it("rejects junk", function()
        assert.is_nil(L.parseHttpDate("yesterday"))
        assert.is_nil(L.parseHttpDate(nil))
    end)
end)

describe("sanitizeName", function()
    it("keeps ordinary UTF-8 names", function()
        assert.equal("Le Petit Prince é.epub", L.sanitizeName("Le Petit Prince é.epub"))
    end)
    it("strips separators, traversal and control characters", function()
        assert.equal("_etc_passwd", L.sanitizeName("/etc/passwd"))
        assert.equal("a_b.epub", L.sanitizeName("a\\b.epub"))
        assert.equal("_._x.epub", L.sanitizeName("../../x.epub"))
        assert.equal("x.epub", L.sanitizeName("..x.epub"))
        assert.equal("ab.epub", L.sanitizeName("a\0b\10.epub"))
        assert.is_nil(L.sanitizeName(".."))
        assert.is_nil(L.sanitizeName("..."))
        assert.is_nil(L.sanitizeName("  "))
        assert.is_nil(L.sanitizeName(nil))
    end)
    it("never returns a name containing a separator or '..'", function()
        for _, n in ipairs({ "../a", "a/../b", "..\\..\\c", "a..b", "/", "\\..", "x/.." }) do
            local s = L.sanitizeName(n)
            if s then
                assert.is_nil(s:find("[/\\]"))
                assert.is_nil(s:find("..", 1, true))
                assert.is_not.equal(".", s:sub(1, 1))
            end
        end
    end)
    it("replaces characters FAT32 refuses", function()
        assert.equal("Q_ A_B _c_.pdf", L.sanitizeName('Q? A:B "c".pdf'))
    end)
    it("drops trailing dots and spaces", function()
        assert.equal("name", L.sanitizeName("name. . "))
    end)
    it("shortens long names on a UTF-8 boundary and keeps the extension", function()
        local s = L.sanitizeName(string.rep("é", 200) .. ".epub")
        assert.is_true(#s <= 240)
        assert.equal(".epub", s:sub(-5))
        local stem = s:sub(1, -6)
        assert.equal(0, #stem % 2)
    end)
end)

describe("uniqueName", function()
    it("adds (2), (3)… before the extension", function()
        local taken = { ["a.epub"] = true, ["a (2).epub"] = true }
        local ex = function(n) return taken[n] end
        assert.equal("b.epub", L.uniqueName("b.epub", ex))
        assert.equal("a (3).epub", L.uniqueName("a.epub", ex))
        taken["README"] = true
        assert.equal("README (2)", L.uniqueName("README", ex))
    end)
end)

describe("file types", function()
    it("parses a free-form list", function()
        assert.same({ "epub", "pdf", "cbz" }, L.parseTypes(" EPUB, .pdf;cbz epub "))
        assert.same({}, L.parseTypes(""))
    end)
    it("filters by the last extension, case-insensitively", function()
        local t = L.DEFAULT_TYPES
        assert.is_true(L.typeAllowed("A.EPUB", t))
        assert.is_true(L.typeAllowed("x.tar.pdf", t))
        assert.is_false(L.typeAllowed("photo.jpg", t))
        assert.is_false(L.typeAllowed("noext", t))
        assert.is_false(L.typeAllowed("x.epub.part", t))
    end)
    it("only defaults to types KOReader opens", function()
        for _, t in ipairs(L.DEFAULT_TYPES) do assert.is_not.equal("azw3", t) end
    end)
end)

describe("content validation", function()
    it("accepts a complete ZIP, with or without comment", function()
        local z = tinyZip()
        assert.is_true(L.zipBytesValid(z:sub(1, 8), z))
        local zc = tinyZip("hello")
        assert.is_true(L.zipBytesValid(zc:sub(1, 8), zc))
    end)
    it("rejects truncated or foreign data", function()
        local z = tinyZip()
        assert.is_false(L.zipBytesValid(z:sub(1, 8), z:sub(1, #z - 5)))
        assert.is_false(L.zipBytesValid("<html>", z))
        assert.is_false(L.zipBytesValid(nil, nil))
    end)
    it("validates files on disk by type", function()
        local z = tmpfile(tinyZip())
        assert.is_true(L.validateFile(z, "a.epub"))
        local half = tmpfile(tinyZip():sub(1, 40))
        local ok, why = L.validateFile(half, "a.cbz")
        assert.is_false(ok)
        assert.equal("zip", why)
        local pdf = tmpfile("%PDF-1.4\n...\n%%EOF\n")
        assert.is_true(L.validateFile(pdf, "x.pdf"))
        local badpdf = tmpfile("%PDF-1.4\n... truncated")
        ok, why = L.validateFile(badpdf, "x.PDF")
        assert.is_false(ok)
        assert.equal("pdf", why)
        assert.is_true(L.validateFile(badpdf, "x.txt")) -- no check for plain text
        for _, p in ipairs({ z, half, pdf, badpdf }) do os.remove(p) end
    end)
end)

describe("plan", function()
    local types = L.DEFAULT_TYPES
    local function f(name, size, etag, lastmod)
        return { name = name, size = size, etag = etag, lastmod = lastmod, is_dir = false }
    end

    it("sorts entries into download / skipped counts", function()
        local p = L.plan({
            { name = "Bookdrop", is_dir = true, is_self = true },
            { name = "Sub", is_dir = true },
            f("b.epub", 10), f("a.pdf", 5), f("pic.jpg", 3), f("empty.epub", 0),
        }, {}, { types = types })
        assert.equal(2, #p.download)
        assert.equal("a.pdf", p.download[1].name)
        assert.equal(1, p.skipped_dirs)
        assert.equal(1, p.skipped_type)
        assert.equal(1, p.skipped_empty)
    end)

    it("does not download again what is only waiting for its DELETE", function()
        local state = { fetched = { ["a.epub"] = { size = 10, etag = '"1"' } } }
        local p = L.plan({ f("a.epub", 10, '"1"') }, state, { types = types })
        assert.equal(0, #p.download)
        assert.equal(1, #p.retry_delete)
    end)

    it("treats a changed file under a fetched name as a new drop", function()
        local state = { fetched = { ["a.epub"] = { size = 10, etag = '"1"' } } }
        local p = L.plan({ f("a.epub", 12, '"2"') }, state, { types = types })
        assert.equal(1, #p.download)
        assert.same({ "a.epub" }, p.drop_fetched)
    end)

    it("forgets records whose remote file is gone", function()
        local state = { fetched = { ["gone.epub"] = { size = 1 } }, rejected = { ["old.pdf"] = { size = 2 } } }
        local p = L.plan({}, state, { types = types })
        assert.same({ "gone.epub" }, p.drop_fetched)
        assert.same({ "old.pdf" }, p.drop_rejected)
    end)

    it("skips rejected files until they change", function()
        local state = { rejected = { ["bad.epub"] = { size = 10, lastmod = "x" } } }
        local p = L.plan({ f("bad.epub", 10, nil, "x") }, state, { types = types })
        assert.equal(0, #p.download)
        assert.equal(1, p.rejected)
        p = L.plan({ f("bad.epub", 11, nil, "y") }, state, { types = types })
        assert.equal(1, #p.download)
    end)

    it("waits for files modified in the last seconds (upload in progress)", function()
        local now = L.parseHttpDate("Fri, 30 Oct 2026 10:00:20 GMT")
        local p = L.plan({
            f("fresh.epub", 10, nil, "Fri, 30 Oct 2026 10:00:00 GMT"),
            f("old.epub", 10, nil, "Fri, 30 Oct 2026 09:00:00 GMT"),
        }, {}, { types = types, server_now = now })
        assert.equal(1, p.waiting)
        assert.equal(1, #p.download)
        assert.equal("old.epub", p.download[1].name)
    end)

    it("compares versions by etag first, then size and date", function()
        assert.is_true(L.sameVersion({ etag = "a", size = 1 }, { etag = "a", size = 2 }))
        assert.is_false(L.sameVersion({ etag = "a" }, { etag = "b" }))
        assert.is_true(L.sameVersion({ size = 3 }, { size = 3 }))
        assert.is_false(L.sameVersion({ size = 3, lastmod = "x" }, { size = 3, lastmod = "y" }))
        assert.is_false(L.sameVersion(nil, { size = 3 }))
    end)
end)

describe("shouldAutoCheck", function()
    local base = { enabled = true, configured = true, now = 1000 }
    local function with(t)
        local o = {}
        for k, v in pairs(base) do o[k] = v end
        for k, v in pairs(t) do o[k] = v end
        return o
    end
    it("runs when everything allows it", function()
        assert.is_true(L.shouldAutoCheck(with{}))
        assert.is_true(L.shouldAutoCheck(with{ last_auto = 1000 - 301 }))
    end)
    it("explains why it does not run", function()
        local function why(t) return select(2, L.shouldAutoCheck(with(t))) end
        assert.equal("disabled", why{ enabled = false })
        assert.equal("unconfigured", why{ configured = false })
        assert.equal("paused", why{ paused = true })
        assert.equal("busy", why{ in_flight = true })
        assert.equal("reading", why{ reading = true })
        assert.equal("throttled", why{ last_auto = 900 })
    end)
    it("is not fooled by a clock that went backwards", function()
        assert.is_true(L.shouldAutoCheck(with{ last_auto = 5000 }))
    end)
end)

describe("misc", function()
    it("scales the download timeout with size, within bounds", function()
        assert.equal(60, L.downloadTimeout(nil))
        assert.equal(60, L.downloadTimeout(1000))
        assert.equal(500, L.downloadTimeout(10000000))
        assert.equal(1800, L.downloadTimeout(1e12))
    end)
    it("classifies errors", function()
        assert.equal("auth", L.classifyError(401))
        assert.equal("folder_missing", L.classifyError(404, nil, "folder"))
        assert.equal("not_found", L.classifyError(404))
        assert.equal("not_webdav", L.classifyError(405))
        assert.equal("server", L.classifyError(503))
        assert.equal("http", L.classifyError(418))
        assert.equal("timeout", L.classifyError(nil, "timeout"))
        assert.equal("dns", L.classifyError("host not found"))
        assert.equal("refused", L.classifyError(nil, "connection refused"))
        assert.equal("network", L.classifyError(nil, "closed"))
    end)
end)

describe("translations", function()
    -- Every _() string literal in main.lua must have fr/es/de.
    local function literals(src)
        local out = {}
        for q, body in src:gmatch('_%(%s*(["\'])(.-[^\\])%1%s*%)') do
            out[#out + 1] = assert((loadstring or load)("return " .. q .. body .. q))()
        end
        for body in src:gmatch("_%(%[%[(.-)%]%]%)") do
            out[#out + 1] = body:gsub("^\n", "")
        end
        return out
    end
    it("covers every string of main.lua", function()
        local fh = assert(io.open(dir .. "main.lua", "rb"))
        local src = fh:read("*a")
        fh:close()
        local fr = dofile(dir .. "i18n_fr.lua")
        local strings = literals(src)
        assert.is_true(#strings > 50)
        local missing = {}
        for _, s in ipairs(strings) do
            local e = fr[s]
            if not (e and e.fr and e.es and e.de) then missing[#missing + 1] = s end
        end
        assert.same({}, missing)
    end)
end)
