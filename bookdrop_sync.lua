-- bookdrop_sync.lua -- the WebDAV client and the check itself.
--
-- No UI here and no KOReader module required directly: the network and
-- filesystem libraries are passed in (deps), so the very same code runs
-- inside KOReader and in the end-to-end test driver.
--
--   local Sync = lrequire("bookdrop_sync")
--   local s = Sync.new{ http = require("socket.http"), ltn12 = ..., mime = ...,
--                       lfs = ..., socketutil = ... (optional), logger = ... }
--   local result = s:check(cfg, state, progress_cb)

local L -- bookdrop_logic, injected by new()

local Sync = {}
Sync.__index = Sync

local function noop() end

function Sync.new(deps)
    local o = setmetatable({}, Sync)
    o.http       = assert(deps.http, "http")
    o.ltn12      = assert(deps.ltn12, "ltn12")
    o.mime       = assert(deps.mime, "mime")
    o.lfs        = assert(deps.lfs, "lfs")
    o.socketutil = deps.socketutil
    o.logger     = deps.logger or { info = noop, warn = noop, err = noop, dbg = noop }
    L            = assert(deps.logic, "logic")
    o.L          = L
    return o
end

---------------------------------------------------------------------------
-- HTTP
---------------------------------------------------------------------------

function Sync:setTimeout(block, total)
    if self.socketutil then self.socketutil:set_timeout(block, total) end
end

function Sync:resetTimeout()
    if self.socketutil then self.socketutil:reset_timeout() end
end

-- One request. Returns code (number) or nil, response headers, error string.
-- Basic auth is sent as our own header: LuaSocket's user/password fields
-- url-unescape the password, which mangles any password containing "%".
function Sync:request(cfg, method, url, opts)
    opts = opts or {}
    local headers = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    if cfg.username and cfg.username ~= "" then
        headers["Authorization"] = "Basic "
            .. self.mime.b64(L.credentials(cfg.username, cfg.password))
    end
    local source
    if opts.body then
        headers["Content-Type"] = headers["Content-Type"] or "application/xml; charset=utf-8"
        headers["Content-Length"] = tostring(#opts.body)
        source = self.ltn12.source.string(opts.body)
    end
    local sink_tbl = {}
    self:setTimeout(opts.block or 15, opts.total or 30)
    local ok, r1, r2, r3 = pcall(self.http.request, {
        url     = url,
        method  = method,
        headers = headers,
        source  = source,
        sink    = opts.sink or self.ltn12.sink.table(sink_tbl),
        redirect = (method == "GET") and nil or false,
    })
    self:resetTimeout()
    if not ok then return nil, nil, tostring(r1) end
    -- table form: http.request returns 1, code, headers, status -- or nil, err
    if r1 == nil then return nil, nil, tostring(r2) end
    if type(r2) ~= "number" then return nil, nil, tostring(r2) end
    return r2, r3 or {}, nil, table.concat(sink_tbl)
end

function Sync:propfind(cfg, url, depth)
    local code, headers, err, body = self:request(cfg, "PROPFIND", url, {
        headers = { Depth = tostring(depth or 1) },
        body    = L.PROPFIND_BODY,
    })
    return code, body, headers, err
end

function Sync:delete(cfg, url)
    local code, _, err = self:request(cfg, "DELETE", url)
    return code, err
end

function Sync:mkcol(cfg, url)
    local code, _, err = self:request(cfg, "MKCOL", url)
    return code, err
end

-- Creates every missing segment of cfg.folder. Returns true or false, code, err.
function Sync:ensureFolder(cfg)
    local base = L.trim(cfg.server or ""):gsub("/+$", "")
    local url = base
    local code, err
    for seg in (cfg.folder or ""):gmatch("[^/\\]+") do
        if seg ~= "." and seg ~= ".." then
            url = url .. "/" .. L.encodeSegment(seg)
            code, err = self:mkcol(cfg, url .. "/")
            -- 405: already exists; 301: some servers redirect to the slash form
            if code ~= 201 and code ~= 405 and code ~= 301 then
                return false, code, err
            end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Filesystem helpers
---------------------------------------------------------------------------

function Sync:exists(path)
    return self.lfs.attributes(path, "mode") ~= nil
end

function Sync:mkdirp(dir)
    if self.lfs.attributes(dir, "mode") == "directory" then return true end
    local acc = dir:sub(1, 1) == "/" and "" or "."
    for seg in dir:gmatch("[^/]+") do
        acc = acc .. "/" .. seg
        if self.lfs.attributes(acc, "mode") == nil then
            local ok, err = self.lfs.mkdir(acc)
            if not ok and self.lfs.attributes(acc, "mode") ~= "directory" then
                return false, err
            end
        end
    end
    return self.lfs.attributes(dir, "mode") == "directory"
end

---------------------------------------------------------------------------
-- Listing
---------------------------------------------------------------------------

-- Lists the drop folder, creating it when missing.
-- Returns { ok, entries, server_now, created, error, code, detail }
function Sync:list(cfg)
    local folder_url = L.folderUrl(cfg.server, cfg.folder)
    local code, body, headers, err = self:propfind(cfg, folder_url, 1)
    if code == 404 then
        local ok, c2, e2 = self:ensureFolder(cfg)
        if not ok then
            return { ok = false, error = L.classifyError(c2, e2, "folder"), code = c2, detail = e2 }
        end
        return { ok = true, entries = {}, created = true, folder_url = folder_url }
    end
    if code ~= 207 and code ~= 200 then
        return { ok = false, error = L.classifyError(code, err, "folder"), code = code, detail = err }
    end
    return {
        ok = true,
        folder_url = folder_url,
        entries = L.parsePropfind(body, folder_url),
        server_now = L.parseHttpDate(headers and (headers.date or headers.Date)),
    }
end

---------------------------------------------------------------------------
-- Download one file
---------------------------------------------------------------------------

-- Returns status, info:
--   "ok", final_path
--   "rejected", reason          (complete download, not a valid book)
--   "failed", reason, network   (nothing kept; network=true aborts the run)
function Sync:downloadOne(cfg, folder_url, entry, dest)
    local name = L.sanitizeName(entry.name)
    if not name then return "failed", "name" end
    local part = dest .. "/" .. name .. ".part"
    os.remove(part)
    local f, ferr = io.open(part, "wb")
    if not f then
        self.logger.warn("bookdrop: cannot write", part, ferr)
        return "failed", "io"
    end
    local bytes, write_err, closed = 0, nil, false
    local function sink(chunk, src_err)
        if chunk == nil then
            if not closed then f:close(); closed = true end
            if src_err then write_err = write_err or src_err end
            return 1
        end
        if chunk ~= "" then
            local ok, e = f:write(chunk)
            if not ok then write_err = e or "write"; return nil, write_err end
            bytes = bytes + #chunk
        end
        return 1
    end
    local code, headers, err = self:request(cfg, "GET", L.fileUrl(folder_url, entry.name), {
        sink  = sink,
        block = 30,
        total = L.downloadTimeout(entry.size),
    })
    if not closed then pcall(f.close, f); closed = true end

    local function fail(reason, network)
        os.remove(part)
        return "failed", reason, network
    end
    if code ~= 200 then
        if type(code) ~= "number" and bytes > 0 then
            -- the server hung up mid-file: this file failed, the network didn't
            self.logger.warn("bookdrop: transfer interrupted", entry.name, bytes, err)
            return fail("incomplete")
        end
        return fail(L.classifyError(code, err), type(code) ~= "number")
    end
    if write_err then
        self.logger.warn("bookdrop: download error", entry.name, write_err)
        return fail("incomplete")
    end
    local expected = tonumber(headers and (headers["content-length"] or headers["Content-Length"]))
    if (entry.size and bytes ~= entry.size) or (expected and bytes ~= expected) then
        self.logger.warn("bookdrop: size mismatch", entry.name, bytes, entry.size, expected)
        return fail("incomplete")
    end
    local real = self.lfs.attributes(part, "size")
    if real ~= bytes then
        return fail("incomplete")
    end
    local valid, why = L.validateFile(part, name)
    if not valid then
        os.remove(part)
        return "rejected", why
    end
    local exists = function(n) return self:exists(dest .. "/" .. n) end
    local final = dest .. "/" .. L.uniqueName(name, exists)
    local ok, rerr = os.rename(part, final)
    if not ok or self.lfs.attributes(final, "size") ~= bytes then
        self.logger.warn("bookdrop: rename failed", part, final, rerr)
        return fail("io")
    end
    return "ok", final
end

---------------------------------------------------------------------------
-- The check
---------------------------------------------------------------------------

local function isGone(code) return code == 200 or code == 204 or code == 404 end

-- cfg   = { server, username, password, folder, dest_dir, types }
-- state = { fetched = {}, rejected = {} }, updated in place (caller saves)
-- progress(i, n, entry) is called before each download.
-- Returns a result table (see README "How a check works").
function Sync:check(cfg, state, progress)
    state.fetched  = state.fetched or {}
    state.rejected = state.rejected or {}
    local r = {
        ok = true, downloaded = {}, failed = {},
        rejected = 0, skipped_type = 0, skipped_dirs = 0, skipped_empty = 0,
        waiting = 0, delete_failed = 0, deleted_retry = 0,
    }
    local listing = self:list(cfg)
    if not listing.ok then
        r.ok, r.error, r.code, r.detail = false, listing.error, listing.code, listing.detail
        return r
    end
    r.created = listing.created
    local folder_url = listing.folder_url

    local p = L.plan(listing.entries, state, {
        types = cfg.types, server_now = listing.server_now,
    })
    for _, n in ipairs(p.drop_fetched) do state.fetched[n] = nil end
    for _, n in ipairs(p.drop_rejected) do state.rejected[n] = nil end
    r.skipped_type, r.skipped_dirs, r.skipped_empty = p.skipped_type, p.skipped_dirs, p.skipped_empty
    r.waiting, r.rejected = p.waiting, p.rejected

    -- Deletes still owed from earlier checks: the book is already here.
    for _, e in ipairs(p.retry_delete) do
        local code = self:delete(cfg, L.fileUrl(folder_url, e.name))
        if isGone(code) then
            state.fetched[e.name] = nil
            r.deleted_retry = r.deleted_retry + 1
        else
            r.delete_failed = r.delete_failed + 1
        end
    end

    if #p.download == 0 then return r end

    local ok_dir, derr = self:mkdirp(cfg.dest_dir)
    if not ok_dir then
        r.ok, r.error, r.detail = false, "dest", derr
        return r
    end

    for i, e in ipairs(p.download) do
        if progress then pcall(progress, i, #p.download, e) end
        local pok, status, info, network = pcall(self.downloadOne, self, cfg, folder_url, e, cfg.dest_dir)
        if not pok then
            self.logger.err("bookdrop: download crashed", e.name, status)
            local name = L.sanitizeName(e.name)
            if name then os.remove(cfg.dest_dir .. "/" .. name .. ".part") end
            status, info = "failed", "internal"
        end
        if status == "ok" then
            r.downloaded[#r.downloaded + 1] = { name = e.name, path = info }
            -- Only now, with the book safely in place, empty the drop box.
            local code = self:delete(cfg, L.fileUrl(folder_url, e.name))
            if not isGone(code) then
                self.logger.warn("bookdrop: DELETE failed", e.name, code)
                state.fetched[e.name] = L.record(e, { path = info, time = os.time() })
                r.delete_failed = r.delete_failed + 1
            end
        elseif status == "rejected" then
            state.rejected[e.name] = L.record(e, { reason = info })
            r.rejected = r.rejected + 1
        else
            r.failed[#r.failed + 1] = { name = e.name, reason = info }
            if network then
                -- the connection is gone: don't time out once per file
                for j = i + 1, #p.download do
                    r.failed[#r.failed + 1] = { name = p.download[j].name, reason = info }
                end
                break
            end
        end
    end
    return r
end

-- "Test connection": lists the folder (creating it if needed) and counts
-- what a check would download.
function Sync:test(cfg, state)
    local listing = self:list(cfg)
    if not listing.ok then return listing end
    local p = L.plan(listing.entries, state or {}, { types = cfg.types })
    listing.pending = #p.download
    listing.other = p.skipped_type
    return listing
end

return Sync
