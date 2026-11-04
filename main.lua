--[[--
Book Drop: an asynchronous drop box for books.

Drop EPUBs (or any book KOReader opens) into a WebDAV folder from a phone or
a computer; the reader fetches them on its own the next time it is online,
saves them locally, and deletes them from the drop folder.

Files:
  bookdrop_logic.lua  pure logic (specced): parsing, names, validation, plan
  bookdrop_sync.lua   WebDAV client + the check (no UI)
  main.lua            settings, menu, triggers, feedback
--]]

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

-- The sync engine loads the first time a check runs, not when KOReader
-- starts: KOReader loads every plugin at startup and keeps it all session.
-- KOReader has put package.path back by then, so our directory is added
-- again while the module loads.
local function lazyrequire(name)
    local saved = package.path
    package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. saved
    local ok, mod = pcall(lrequire, name)
    package.path = saved
    if not package.path:find(_dir .. "common/?.lua", 1, true) then
        package.path = package.path .. ";" .. _dir .. "common/?.lua"
    end
    if not ok then error(mod, 0) end
    return mod
end

local BD              = require("ui/bidi")
local ConfirmBox      = require("ui/widget/confirmbox")
local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local T               = require("ffi/util").template

-- lrequire, not require: package.loaded["i18n"] is a single slot shared by
-- every plugin on the device and the first one loaded wins it. This plugin
-- is standalone (no common/), so it keeps its own module and table.
local i18n = lrequire("i18n")
local _    = i18n
i18n.extend(lrequire("i18n_fr"))

local L    = lrequire("bookdrop_logic")

local KOOFR_URL = "https://app.koofr.net/dav/Koofr/"
local BIG_FILE  = 1024 * 1024 -- show a progress message from this size on

---------------------------------------------------------------------------
-- Shared state (one per KOReader session, not per plugin instance: the
-- FileManager and every ReaderUI each build their own instance)
---------------------------------------------------------------------------

local settings_path = DataStorage:getSettingsDir() .. "/bookdrop.lua"
local settings
local in_flight = false
local sync_engine

local function S()
    if not settings then settings = LuaSettings:open(settings_path) end
    return settings
end

local function engine()
    if not sync_engine then
        sync_engine = lazyrequire("bookdrop_sync").new{
            http       = require("socket.http"),
            ltn12      = require("ltn12"),
            mime       = require("mime"),
            lfs        = require("libs/libkoreader-lfs"),
            socketutil = require("socketutil"),
            logger     = logger,
            logic      = L,
        }
    end
    return sync_engine
end

local function homeDir()
    local ok, fmu = pcall(require, "apps/filemanager/filemanagerutil")
    if ok and fmu and fmu.getHomeFolder then return fmu.getHomeFolder() end
    return G_reader_settings:readSetting("home_dir") or require("device").home_dir or "."
end

local function defaultDest()
    return (homeDir():gsub("/+$", "")) .. "/Bookdrop"
end

local function config()
    local s = S()
    return {
        server   = s:readSetting("server") or "",
        username = s:readSetting("username") or "",
        password = s:readSetting("password") or "",
        folder   = s:readSetting("folder") or L.DEFAULT_FOLDER,
        dest_dir = s:readSetting("dest_dir") or defaultDest(),
        types    = s:readSetting("types") or L.DEFAULT_TYPES,
        auto     = s:readSetting("auto") ~= false,
    }
end

local function isConfigured()
    return L.validServerUrl(S():readSetting("server"))
end

local function loadState()
    local s = S()
    return { fetched = s:readSetting("fetched") or {}, rejected = s:readSetting("rejected") or {} }
end

local function saveState(state)
    local s = S()
    s:saveSetting("fetched", state.fetched or {})
    s:saveSetting("rejected", state.rejected or {})
    s:flush()
end

local function isReading()
    local RUI = package.loaded["apps/reader/readerui"]
    return RUI ~= nil and RUI.instance ~= nil
end

local function fileManager()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance
end

---------------------------------------------------------------------------
-- Texts
---------------------------------------------------------------------------

local function errorText(key, code, detail)
    local texts = {
        auth = _("Wrong username or password.\n\nFor Koofr, use an app password (Koofr → Preferences → Password), not your account password."),
        forbidden = _("Access denied by the server."),
        folder_missing = _("The drop folder could not be found or created. Check the folder name."),
        not_found = _("Not found on the server. Check the server address."),
        not_webdav = _("This address does not look like a WebDAV server. Check the server address."),
        server_full = _("The server is out of space."),
        server = _("Server error. Try again later."),
        timeout = _("The server did not answer in time."),
        dns = _("Server not found. Check the address and your network connection."),
        refused = _("Connection refused. Check the server address."),
        tls = _("Secure connection failed (certificate or TLS error)."),
        unconfigured = _("Set up the server first."),
    }
    if texts[key] then return texts[key] end
    if key == "http" then return T(_("Unexpected server response (HTTP %1)."), tostring(code)) end
    if key == "dest" then return T(_("Cannot create the download folder:\n%1"), tostring(detail)) end
    return T(_("Network error: %1"), tostring(detail or code or key))
end

local function reasonText(key)
    local texts = {
        incomplete = _("download incomplete"),
        io         = _("could not write the file"),
        name       = _("unusable file name"),
        internal   = _("internal error"),
    }
    return texts[key] or errorText(key)
end

local function newBooksText(n)
    if n == 1 then return _("1 new book in Book Drop") end
    return T(_("%1 new books in Book Drop"), n)
end

-- Full report of a check, for a manual check or the "Last check" entry.
local function summaryText(r)
    if not r.ok then return errorText(r.error, r.code, r.detail) end
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    if r.created then
        add(T(_("The folder %1 was created on the server."), config().folder))
    end
    local n = #r.downloaded
    if n > 0 then
        add(n == 1 and _("1 new book:") or T(_("%1 new books:"), n))
        for i, d in ipairs(r.downloaded) do
            if i > 8 then add("…"); break end
            add("• " .. BD.filename(d.path:match("[^/]+$") or d.name))
        end
    else
        add(_("No new books."))
    end
    if #r.failed > 0 then
        add("")
        add(_("Not downloaded (left in the drop box, retried next time):"))
        for i, f in ipairs(r.failed) do
            if i > 5 then add("…"); break end
            add("• " .. BD.filename(f.name) .. " — " .. reasonText(f.reason))
        end
    end
    local counts = {
        { r.rejected,      _("Not a valid book (damaged or incomplete), left in the drop box: %1") },
        { r.waiting,       _("Still uploading, fetched next time: %1") },
        { r.delete_failed, _("Could not be removed from the drop box (retried next time): %1") },
        { r.skipped_type,  _("Other file types ignored: %1") },
        { r.skipped_dirs,  _("Subfolders ignored: %1") },
        { r.skipped_empty, _("Empty files ignored: %1") },
    }
    local first = true
    for _i, c in ipairs(counts) do
        if (c[1] or 0) > 0 then
            if first then add(""); first = false end
            add(T(c[2], c[1]))
        end
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Plugin
---------------------------------------------------------------------------

local BookDrop = WidgetContainer:extend{
    name        = "bookdrop",
    is_doc_only = false,
}

function BookDrop:init()
    -- Read by KOReader's plugin list for "Delete plugin settings".
    self.settings_file = settings_path
    self.ui.menu:registerToMainMenu(self)
    -- Startup / back to the file browser: check shortly after, never during
    -- init (no delay to startup) and never while a book is open.
    if not self.ui.document then
        self._startup_check = function()
            self._startup_check = nil
            self:autoCheck("startup")
        end
        UIManager:scheduleIn(5, self._startup_check)
    end
end

function BookDrop:onCloseWidget()
    if self._startup_check then
        UIManager:unschedule(self._startup_check)
        self._startup_check = nil
    end
end

-- Broadcast by NetworkMgr when Wi-Fi comes up (and at launch when it
-- already was). Not consumed: other plugins need it too.
function BookDrop:onNetworkConnected()
    if self.ui.document then return end -- deferred: see README
    UIManager:scheduleIn(3, function() self:autoCheck("network") end)
end

function BookDrop:autoCheck(trigger)
    local cfg = config()
    local ok, why = L.shouldAutoCheck{
        enabled    = cfg.auto,
        configured = isConfigured(),
        in_flight  = in_flight,
        reading    = isReading(),
        now        = os.time(),
        last_auto  = S():readSetting("last_auto"),
    }
    if not ok then
        logger.dbg("bookdrop: auto check skipped:", trigger, why)
        return
    end
    -- Only when already connected: never turn Wi-Fi on or prompt for it.
    local nok, NetworkMgr = pcall(require, "ui/network/manager")
    if not nok or not NetworkMgr or not NetworkMgr:isConnected() then
        logger.dbg("bookdrop: auto check skipped: offline")
        return
    end
    S():saveSetting("last_auto", os.time())
    logger.info("bookdrop: automatic check (" .. trigger .. ")")
    self:runCheck(false)
end

function BookDrop:checkNow()
    if not isConfigured() then
        UIManager:show(InfoMessage:new{ text = errorText("unconfigured") })
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function() self:runCheck(true) end)
end

-- The check itself. Synchronous (LuaSocket blocks), shielded by pcall.
function BookDrop:runCheck(manual)
    if in_flight then
        if manual then
            UIManager:show(InfoMessage:new{ text = _("A check is already running."), timeout = 2 })
        end
        return
    end
    in_flight = true
    local cfg = config()
    local state = loadState()
    local msg
    local function showMsg(text)
        if msg then UIManager:close(msg) end
        msg = InfoMessage:new{ text = text, dismissable = false }
        UIManager:show(msg)
        UIManager:forceRePaint()
    end
    if manual then showMsg(_("Checking Book Drop…")) end
    local progress = function(i, n, e)
        -- Small books arrive without any popup during automatic checks.
        if manual or (e.size or 0) >= BIG_FILE then
            showMsg(T(_("Book Drop: downloading %1/%2\n%3"), i, n, BD.filename(e.name)))
        end
    end
    local ok, res = pcall(engine().check, engine(), cfg, state, progress)
    if msg then UIManager:close(msg) end
    in_flight = false
    if not ok then
        logger.err("bookdrop: check crashed:", res)
        res = { ok = false, error = "network", detail = tostring(res), downloaded = {}, failed = {} }
    else
        saveState(state)
    end
    local s = S()
    s:saveSetting("last_check", os.time())
    s:saveSetting("last_result", {
        ok = res.ok, error = res.error, code = res.code,
        detail = res.detail and tostring(res.detail):sub(1, 200),
        downloaded = #(res.downloaded or {}), failed = #(res.failed or {}),
        delete_failed = res.delete_failed, rejected = res.rejected,
    })
    s:flush()
    self:report(res, manual, cfg)
end

function BookDrop:refreshBrowser(dest)
    local fm = fileManager()
    if not fm or not fm.file_chooser then return end
    local shown = (fm.file_chooser.path or ""):gsub("/+$", "")
    if shown == dest:gsub("/+$", "") then
        fm.file_chooser:refreshPath()
    end
end

function BookDrop:openFolder()
    local dest = config().dest_dir
    if require("libs/libkoreader-lfs").attributes(dest, "mode") ~= "directory" then
        UIManager:show(InfoMessage:new{
            text = T(_("The folder does not exist yet:\n%1"), BD.dirpath(dest)) })
        return
    end
    local fm = fileManager()
    if fm then
        fm.file_chooser:changeToPath(dest)
    elseif self.ui.document then
        local ui = self.ui
        ui:onClose()
        ui:showFileManager(dest .. "/")
    end
end

function BookDrop:report(res, manual, cfg)
    local n = #(res.downloaded or {})
    if n > 0 then self:refreshBrowser(cfg.dest_dir) end
    if manual then
        if n > 0 then
            UIManager:show(ConfirmBox:new{
                text        = summaryText(res),
                icon        = "notice-info",
                ok_text     = _("Open folder"),
                cancel_text = _("Close"),
                ok_callback = function() self:openFolder() end,
            })
        else
            UIManager:show(InfoMessage:new{ text = summaryText(res) })
        end
        return
    end
    -- Automatic check: a toast, never a dialog. Errors stay silent (logged,
    -- and shown under "Last check" in the menu).
    local Notification = require("ui/widget/notification")
    if n > 0 then
        UIManager:show(Notification:new{ text = newBooksText(n), timeout = 4 })
    elseif res.ok and #(res.failed or {}) > 0 then
        UIManager:show(Notification:new{
            text = _("Book Drop: some files could not be downloaded"), timeout = 4 })
    end
    if not res.ok then
        logger.warn("bookdrop: automatic check failed:", res.error, res.code, res.detail)
    end
end

---------------------------------------------------------------------------
-- Settings dialogs
---------------------------------------------------------------------------

function BookDrop:editServer(touchmenu)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local cfg = config()
    local dialog
    dialog = MultiInputDialog:new{
        title  = _("Book Drop server"),
        fields = {
            { description = _("WebDAV address"), text = cfg.server,
              hint = "https://app.koofr.net/dav/Koofr/" },
            { description = _("Username"), text = cfg.username, hint = _("e.g. your Koofr e-mail") },
            { description = _("Password"), text = cfg.password, text_type = "password",
              hint = _("app password") },
            { description = _("Drop folder on the server"), text = cfg.folder, hint = L.DEFAULT_FOLDER },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = "Koofr", callback = function()
                dialog.input_fields[1]:setText(KOOFR_URL)
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local f = dialog:getFields()
                local server = L.trim(f[1] or "")
                if server ~= "" and not L.validServerUrl(server) then
                    UIManager:show(InfoMessage:new{
                        text = _("The address must start with https:// (or http://).") })
                    return
                end
                local folder = L.trim(f[4] or ""):gsub("^/+", ""):gsub("/+$", "")
                local s = S()
                s:saveSetting("server", server)
                s:saveSetting("username", L.trim(f[2] or ""))
                s:saveSetting("password", f[3] or "")
                s:saveSetting("folder", folder ~= "" and folder or L.DEFAULT_FOLDER)
                s:flush()
                UIManager:close(dialog)
                if touchmenu then touchmenu:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Read-only: lists the WebDAV accounts of KOReader's Cloud storage.
function BookDrop:importFromCloudStorage(touchmenu)
    local ok, cs = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/cloudstorage.lua"):readSetting("cs_servers")
    end)
    local servers = {}
    for _i, srv in ipairs(ok and cs or {}) do
        if srv.type == "webdav" and srv.address then servers[#servers + 1] = srv end
    end
    if #servers == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No WebDAV account found in Cloud storage.") })
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _i, srv in ipairs(servers) do
        buttons[#buttons + 1] = {{
            text = (srv.name or srv.address),
            callback = function()
                UIManager:close(dialog)
                local s = S()
                s:saveSetting("server", srv.address)
                s:saveSetting("username", srv.username or "")
                s:saveSetting("password", srv.password or "")
                s:flush()
                if touchmenu then touchmenu:updateItems() end
                UIManager:show(InfoMessage:new{
                    text = T(_("Imported %1.\nThe drop folder is still %2."),
                        srv.name or srv.address, config().folder) })
            end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title   = _("Import a WebDAV account from Cloud storage"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function BookDrop:testConnection()
    if not isConfigured() then
        UIManager:show(InfoMessage:new{ text = errorText("unconfigured") })
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local msg = InfoMessage:new{ text = _("Connecting…"), dismissable = false }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local cfg = config()
        local ok, r = pcall(engine().test, engine(), cfg, loadState())
        UIManager:close(msg)
        if not ok then
            logger.err("bookdrop: test crashed:", r)
            r = { ok = false, error = "network", detail = tostring(r) }
        end
        local text
        if r.ok then
            text = _("Connection OK.")
            if r.created then
                text = text .. "\n" .. T(_("The folder %1 was created on the server."), cfg.folder)
            end
            text = text .. "\n" .. T(_("Books waiting in the drop box: %1"), r.pending or 0)
            if (r.other or 0) > 0 then
                text = text .. "\n" .. T(_("Other file types ignored: %1"), r.other)
            end
        else
            text = errorText(r.error, r.code, r.detail)
        end
        UIManager:show(InfoMessage:new{
            text = text, icon = r.ok and "notice-info" or "notice-warning" })
    end)
end

function BookDrop:chooseDest(touchmenu)
    local fmu = require("apps/filemanager/filemanagerutil")
    local cur = S():readSetting("dest_dir")
    fmu.showChooseDialog(_("Download folder:"), function(path)
        if path == defaultDest() then path = nil end
        S():saveSetting("dest_dir", path)
        S():flush()
        if touchmenu then touchmenu:updateItems() end
    end, cur or defaultDest(), defaultDest())
end

function BookDrop:editTypes(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title       = _("File types to fetch"),
        description = _("Extensions separated by commas."),
        input       = L.typesToString(config().types),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Default"), callback = function()
                dialog:setInputText(L.typesToString(L.DEFAULT_TYPES))
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local types = L.parseTypes(dialog:getInputText())
                if #types == 0 then types = L.DEFAULT_TYPES end
                S():saveSetting("types", types)
                S():flush()
                UIManager:close(dialog)
                if touchmenu then touchmenu:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function lastCheckText()
    local t = S():readSetting("last_check")
    if not t then return _("Last check: never") end
    local r = S():readSetting("last_result") or {}
    local what
    if not r.ok then
        what = _("error")
    elseif (r.downloaded or 0) > 0 then
        what = T(_("%1 downloaded"), r.downloaded)
    else
        what = _("nothing new")
    end
    return T(_("Last check: %1 (%2)"), os.date("%d/%m %H:%M", t), what)
end

local function lastCheckDetails()
    local r = S():readSetting("last_result")
    if not r then return _("No check yet.") end
    if not r.ok then return errorText(r.error, r.code, r.detail) end
    local lines = { T(_("Books downloaded: %1"), r.downloaded or 0) }
    if (r.failed or 0) > 0 then
        lines[#lines + 1] = T(_("Not downloaded (left in the drop box, retried next time): %1"), r.failed)
    end
    if (r.rejected or 0) > 0 then
        lines[#lines + 1] = T(_("Not a valid book (damaged or incomplete), left in the drop box: %1"), r.rejected)
    end
    local pending = 0
    for _k in pairs(S():readSetting("fetched") or {}) do pending = pending + 1 end
    if pending > 0 then
        lines[#lines + 1] = T(_("Could not be removed from the drop box (retried next time): %1"), pending)
    end
    return table.concat(lines, "\n")
end

function BookDrop:showHelp()
    UIManager:show(InfoMessage:new{
        text = _([[Book Drop fetches books you drop into a folder on a WebDAV server, then removes them from that folder.

Free setup with Koofr:
1. Create a free account at koofr.eu.
2. In the Koofr web app: Preferences → Password → generate an app password.
3. Here: Server → tap "Koofr", enter your Koofr e-mail and the app password.
4. Test connection: the folder "Bookdrop" is created for you.
5. From your phone or computer, put books into Koofr → Bookdrop.

Nextcloud: https://your.server/remote.php/dav/files/USERNAME/ with an app password.

Books are fetched when the reader is online and the file browser is shown, at most every 5 minutes.]]),
    })
end

function BookDrop:addToMainMenu(menu_items)
    menu_items.bookdrop = {
        text         = _("Book Drop"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Check now"),
                enabled_func = isConfigured,
                callback = function() self:checkNow() end,
            },
            {
                text = _("Open download folder"),
                callback = function() self:openFolder() end,
            },
            {
                text = _("Check automatically"),
                checked_func = function() return config().auto end,
                callback = function()
                    S():saveSetting("auto", not config().auto)
                    S():flush()
                end,
                help_text = _("When the reader is online and the file browser is shown: at startup and whenever Wi-Fi connects, at most every 5 minutes. Never turns Wi-Fi on by itself."),
            },
            {
                text_func = lastCheckText,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{ text = lastCheckDetails() })
                end,
                separator = true,
            },
            {
                text_func = function()
                    local s = S():readSetting("server")
                    return T(_("Server: %1"), (s and s ~= "") and s:gsub("^https?://", "") or _("not set"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu) self:editServer(touchmenu) end,
            },
            {
                text = _("Import from Cloud storage"),
                keep_menu_open = true,
                callback = function(touchmenu) self:importFromCloudStorage(touchmenu) end,
            },
            {
                text = _("Test connection"),
                enabled_func = isConfigured,
                keep_menu_open = true,
                callback = function() self:testConnection() end,
            },
            {
                text_func = function()
                    return T(_("Local folder: %1"), BD.dirpath(config().dest_dir))
                end,
                keep_menu_open = true,
                callback = function(touchmenu) self:chooseDest(touchmenu) end,
            },
            {
                text_func = function()
                    return T(_("File types: %1"), L.typesToString(config().types))
                end,
                keep_menu_open = true,
                callback = function(touchmenu) self:editTypes(touchmenu) end,
                separator = true,
            },
            {
                text = _("Help"),
                keep_menu_open = true,
                callback = function() self:showHelp() end,
            },
        },
    }
end

-- Exposed for the headless test driver.
BookDrop._summaryText = summaryText

return BookDrop
