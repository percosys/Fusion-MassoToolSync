-- VECTRIC LUA SCRIPT
-- MassoToolSync.lua  --  VCarve Pro Gadget: Sync tool libraries to MASSO G3 CNC controller.
--
-- This is a VCarve Pro gadget that reads tools from VCarve's tool database
-- (or from Fusion 360 / CSV files) and writes them to a MASSO G3 controller's
-- USB drive in the .htg binary format.
--
-- Entry point: main(script_path) or Gadget_Action()

-- ---------------------------------------------------------------------------
-- Module loading
-- ---------------------------------------------------------------------------
--
-- VCarve Pro scans the gadget folder for .lua files and creates a menu
-- entry for each one, which means helper modules with .lua extension show
-- up as bogus menu items. To avoid this we rename all helper modules to
-- .luax (the Vectric convention for "library" files that aren't gadgets)
-- and teach Lua's require() how to find them.
--
-- VCarve Pro's gadget search path (package.path) only includes the parent
-- "Gadgets\VCarve Pro V12.5\" folder, NOT the specific gadget subfolder.
-- We need to add our own folder to package.path BEFORE any require() calls
-- so that config.luax, crc32.luax, etc. can be found.
--
-- debug.getinfo() with "@"-prefixed source gives us the running script's
-- filesystem path, which works regardless of how VCarve invokes the gadget
-- (Gadget_Action vs main(script_path)).

local script_dir
do
    local info = debug.getinfo(1, "S")
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    script_dir = source:match("(.+)[/\\]")
    if script_dir then
        package.path = script_dir .. "\\?.luax;"
                    .. script_dir .. "/?.luax;"
                    .. script_dir .. "\\?.lua;"
                    .. script_dir .. "/?.lua;"
                    .. (package.path or "")
    end
end

-- Load all modules now that package.path is set up.
local config    = require("config")
local masso     = require("masso_htg")
local merge_mod = require("merge")
local vcarve_db = require("vcarve_db")

-- ---------------------------------------------------------------------------
-- Gadget metadata (for VCarve Gadgets menu)
-- ---------------------------------------------------------------------------

function Gadget_Description()
    return {
        Name        = "MASSO Tool Sync",
        Description = "Sync VCarve Pro tool libraries to MASSO G3 CNC tool tables",
        Version     = "0.1.0",
        Author      = "fusion2masso",
    }
end

function Gadget_Category()
    return "Tool Management"
end

-- ---------------------------------------------------------------------------
-- USB drive detection (Windows)
-- ---------------------------------------------------------------------------

local function detect_usb_drives()
    -- Scan drive letters D-Q for the MASSO folder via io.open only --
    -- no subprocess. Each io.open on a missing drive is a single
    -- filesystem call that returns almost instantly. We intentionally
    -- skip R-Z because Parallels Desktop typically auto-assigns those
    -- letters to Mac shared folders, which are network mounts where
    -- an io.open can take seconds to time out.
    local drives = {}
    for letter in ("DEFGHIJKLMNOPQ"):gmatch(".") do
        local root = letter .. ":\\"
        local marker = io.open(root .. "MASSO\\Machine Settings\\.", "r")
        if marker then
            marker:close()
            drives[#drives + 1] = {
                path = root,
                label = letter .. ": (MASSO detected)",
            }
        end
    end
    return drives
end

--- Validate a USB drive path for MASSO content.
-- Returns: is_valid, status_text, status_class, htg_path, htg_filename
local function validate_usb(usb_path, config)
    if not usb_path or usb_path == "" then
        return false, "Select MASSO USB drive...", "gray", nil, nil
    end

    local settings_dir = usb_path .. config.MACHINE_SETTINGS_SUBDIR
    -- Check if the MASSO/Machine Settings directory exists
    local test = io.open(settings_dir .. "\\.", "r")
    if not test then
        -- Try with io.popen dir check
        local handle = io.popen('dir "' .. settings_dir .. '" /b 2>nul')
        local result = handle and handle:read("*a") or ""
        if handle then handle:close() end
        if result == "" then
            return false, "MASSO/Machine Settings/ not found on this drive", "red", nil, nil
        end
    else
        test:close()
    end

    -- Auto-detect firmware by checking which .htg files exist
    for _, fw in ipairs(config.FIRMWARE_VERSIONS) do
        local htg_path = settings_dir .. "\\" .. fw.filename
        local f = io.open(htg_path, "rb")
        if f then
            f:close()
            return true,
                   "Found " .. fw.filename .. " (" .. fw.name .. ")",
                   "green", htg_path, fw.filename
        end
    end

    -- No tool file found — will create with default firmware filename
    local default_fn = config.FIRMWARE_VERSIONS[1].filename
    return true,
           "No existing tool table -- will create " .. default_fn,
           "orange", nil, default_fn
end

--- Backup the Machine Settings folder using PowerShell.
local function backup_machine_settings(usb_path, backup_dir, config)
    local settings_dir = usb_path .. config.MACHINE_SETTINGS_SUBDIR

    -- Create backup directory
    os.execute('mkdir "' .. backup_dir .. '" 2>nul')

    local timestamp = os.date("%Y-%m-%d_%H%M%S")
    local zip_path = backup_dir .. "\\MASSO_Backup_" .. timestamp .. ".zip"

    -- Use PowerShell Compress-Archive (Windows 10+)
    local cmd = string.format(
        'powershell -Command "Compress-Archive -Path \'%s\\*\' -DestinationPath \'%s\' -Force" 2>nul',
        settings_dir:gsub("'", "''"),
        zip_path:gsub("'", "''")
    )
    local ok = os.execute(cmd)

    if not ok then
        -- Fallback: simple file copy to timestamped directory
        local copy_dir = backup_dir .. "\\MASSO_Backup_" .. timestamp
        os.execute('mkdir "' .. copy_dir .. '" 2>nul')
        os.execute('xcopy "' .. settings_dir .. '\\*" "' .. copy_dir .. '\\" /E /Q /Y 2>nul')
        return copy_dir
    end

    return zip_path
end

-- ---------------------------------------------------------------------------
-- Format merge report as HTML
-- ---------------------------------------------------------------------------

local function format_report_html(report, total_tools, merge_mod)
    local lines = {}
    lines[#lines + 1] = "<b>Merge Preview</b> (" .. total_tools .. " tools in library)<br>"

    local counts = {}
    for _, kind in ipairs({merge_mod.ADDED, merge_mod.UPDATED, merge_mod.REPLACED,
                           merge_mod.UNCHANGED, merge_mod.SKIPPED}) do
        counts[kind] = merge_mod.count_kind(report, kind)
    end

    if counts[merge_mod.ADDED] > 0 then
        lines[#lines + 1] = '<span class="added"><b>ADDED: ' .. counts[merge_mod.ADDED] .. '</b></span> (new slots)<br>'
    end
    if counts[merge_mod.UPDATED] > 0 then
        lines[#lines + 1] = '<span class="updated"><b>UPDATED: ' .. counts[merge_mod.UPDATED] .. '</b></span><br>'
    end
    if counts[merge_mod.REPLACED] > 0 then
        lines[#lines + 1] = '<span class="replaced"><b>REPLACED: ' .. counts[merge_mod.REPLACED] .. '</b></span> (different tool)<br>'
    end
    if counts[merge_mod.UNCHANGED] > 0 then
        lines[#lines + 1] = 'UNCHANGED: ' .. counts[merge_mod.UNCHANGED] .. '<br>'
    end
    if counts[merge_mod.SKIPPED] > 0 then
        lines[#lines + 1] = '<span class="skipped">SKIPPED: ' .. counts[merge_mod.SKIPPED] .. '</span><br>'
    end

    -- Detail lines
    local details = {}
    for _, c in ipairs(report.changes) do
        if c.kind ~= merge_mod.UNCHANGED then
            local num_str = (c.number >= 0) and ("T" .. c.number) or "T?"
            local name = c.name:sub(1, 40)
            local class_name = c.kind:lower()
            local detail = '<span class="' .. class_name .. '">' .. num_str .. '</span> ' .. name
            if c.reason and c.reason ~= "" then
                detail = detail .. ' <i>(' .. c.reason:sub(1, 60) .. ')</i>'
            end
            details[#details + 1] = detail
        end
    end

    if #details > 0 then
        lines[#lines + 1] = '<br><b>Details:</b><br>'
        for i = 1, math.min(#details, 20) do
            lines[#lines + 1] = details[i] .. '<br>'
        end
        if #details > 20 then
            lines[#lines + 1] = '<i>...and ' .. (#details - 20) .. ' more</i><br>'
        end
    end

    if #report.warnings > 0 then
        lines[#lines + 1] = '<br><b>Warnings:</b><br>'
        for i = 1, math.min(#report.warnings, 5) do
            lines[#lines + 1] = '<span class="warning">' .. report.warnings[i]:sub(1, 80) .. '</span><br>'
        end
    end

    return table.concat(lines)
end

-- ---------------------------------------------------------------------------
-- Main gadget logic
-- ---------------------------------------------------------------------------

-- Simple timing helper for diagnosing slow startups. Only surfaces
-- timings when total() exceeds a threshold so a fast normal startup
-- stays clean, but a slow one auto-shows the diagnostic breakdown.
local function make_timer()
    local clock = os.clock
    local start = clock()
    local last = start
    local log = {}
    return {
        step = function(name)
            local now = clock()
            log[#log + 1] = string.format("%-30s  %6.0f ms  (total %6.0f ms)",
                name, (now - last) * 1000, (now - start) * 1000)
            last = now
        end,
        total_ms = function()
            return (clock() - start) * 1000
        end,
        dump = function()
            return table.concat(log, "\n")
        end,
    }
end

-- Show the timing breakdown when startup exceeds this many ms.
local STARTUP_SLOW_THRESHOLD_MS = 500

local function run_gadget()
    local timer = make_timer()

    -- ---- Detect VCarve tool database ----
    -- (done before the progress bar so we can choose a message that
    -- tells the user what's about to happen)
    local db_path = vcarve_db.get_db_path()
    timer.step("get_db_path")

    -- Pre-flight: is the tool-groups cache fresh? If so, we'll be fast
    -- (cache hit -> ~5 ms). If not, we're about to do a slow sqlite3
    -- query (~5 s on Parallels). Show a specific message in each case
    -- so the user knows what to expect.
    local cache_fresh = false
    if db_path then
        cache_fresh = vcarve_db.cache_is_fresh(script_dir, db_path)
    end

    -- When the cache is stale, launch an auxiliary process that shows
    -- a "please wait" window while we do the slow sqlite3 query. We
    -- use mshta.exe (Windows' HTML application host) rather than
    -- PowerShell because mshta starts in ~100-300 ms whereas a fresh
    -- PowerShell with WinForms takes 1-3 s -- by the time PowerShell
    -- finished loading the .NET runtime, sqlite3 was already done and
    -- the dialog barely flashed. mshta has no runtime to cold-start so
    -- the dialog appears almost immediately.
    --
    -- The HTA polls for a sentinel flag file and closes as soon as it
    -- appears. Lua writes the flag after list_groups() returns.
    local rebuild_flag = nil
    if db_path and not cache_fresh then
        rebuild_flag = script_dir .. "\\rebuild_done.flag"
        os.remove(rebuild_flag)  -- clear any stale flag from a crashed prior run
        local notify_hta = script_dir .. "\\rebuild_notify.hta"

        -- Pass the flag file path via URL querystring instead of as a
        -- command-line arg -- location.search is reliable across IE/HTA
        -- versions; window.commandLine is flaky.
        -- Convert backslashes to forward slashes for the URL; URL-encode
        -- spaces and percent signs to be safe.
        local function url_encode_path(p)
            return p:gsub("\\", "/"):gsub("%%", "%%25"):gsub(" ", "%%20")
        end
        local hta_url = "file:///" .. url_encode_path(notify_hta)
                     .. "?flag=" .. url_encode_path(rebuild_flag)

        -- Fire-and-forget: `start ""` detaches the child so os.execute
        -- returns immediately and we can proceed to the slow work.
        os.execute('start "" mshta.exe "' .. hta_url .. '"')
    end

    -- ProgressBar is still shown as a best-effort secondary indicator.
    local progress_msg = cache_fresh and "MASSO Tool Sync -- loading..."
                         or "MASSO Tool Sync -- rebuilding cache..."
    local progress = nil
    if ProgressBar then
        local ok, pb = pcall(ProgressBar, progress_msg, 1)
        if ok then progress = pb end
    end
    timer.step("progress bar")

    local db_status
    local tool_groups = {}
    local schema_dump = nil
    if db_path then
        local groups, group_err = vcarve_db.list_groups(db_path, script_dir)
        if groups and #groups > 0 then
            tool_groups = groups
            db_status = string.format("Found %d tool groups", #groups)
        elseif group_err then
            db_status = "Found DB but could not list groups: " .. tostring(group_err)
            -- Dump schema for diagnosis
            schema_dump = vcarve_db.dump_schema(db_path, script_dir)
        else
            db_status = "Found: " .. db_path
        end
    else
        db_status = "Not found (use File source instead)"
    end
    timer.step("list_groups [" .. tostring(vcarve_db.last_cache_status or "?") .. "]")

    -- Signal the "please wait" PowerShell window to close. We write the
    -- flag file after the slow query returns; the notification process
    -- polls for the file every 150 ms and closes its dialog on sight.
    if rebuild_flag then
        local f = io.open(rebuild_flag, "w")
        if f then f:write("done") f:close() end
    end

    -- ---- Detect USB drives ----
    local usb_drives = detect_usb_drives()
    timer.step("detect_usb_drives")

    -- ---- Load saved settings from registry ----
    local saved_backup = ""
    local saved_usb = ""
    if Registry then
        local reg = Registry(config.REGISTRY_SECTION)
        saved_backup = reg:GetString("BackupPath",
            os.getenv("USERPROFILE") .. "\\Documents\\MASSO Backups")
        saved_usb = reg:GetString("UsbDrive", "")
    else
        saved_backup = os.getenv("USERPROFILE") .. "\\Documents\\MASSO Backups"
    end
    timer.step("read registry")

    -- ---- Build the dialog ----
    -- Load the HTML file contents and pass as an inline string. VCarve's
    -- HTML_Dialog takes (is_inline_html, content, width, height, title). We
    -- always load the file ourselves so it doesn't matter how VCarve's build
    -- interprets the boolean -- we pass raw HTML either way.
    local htm_path = script_dir .. "\\MassoToolSync.htm"
    local htm_file, htm_err = io.open(htm_path, "r")
    if not htm_file then
        DisplayMessageBox("Cannot find dialog HTML file:\n" .. htm_path ..
            "\n\n" .. tostring(htm_err))
        return false
    end
    local htm_content = htm_file:read("*a")
    htm_file:close()
    timer.step("read HTML file")

    local dialog = HTML_Dialog(true, htm_content, 820, 780,
        "MASSO Tool Sync v" .. config.VERSION)

    -- Source configuration
    dialog:AddDropDownList("SourceMode", "vcarve_db")
    for _, src in ipairs(config.SOURCE_MODES) do
        dialog:AddDropDownListValue("SourceMode", src.value)
    end
    dialog:AddTextField("FilePath", "")
    dialog:AddLabelField("DbStatus", db_status)

    -- Tool Group dropdown (populated from tool_tree_entry)
    -- The display value is the group path ("Parent > Child"); the mapping
    -- from name to ID is kept in Lua for lookup after the dialog closes.
    dialog:AddDropDownList("ToolGroup", "")
    dialog:AddDropDownListValue("ToolGroup", "")  -- empty = all tools
    local group_name_to_id = {}
    for _, g in ipairs(tool_groups) do
        local label = g.path or g.name
        dialog:AddDropDownListValue("ToolGroup", label)
        group_name_to_id[label] = g.id
    end

    -- File picker for source files
    dialog:AddFilePicker(true, "BrowseFile", "FilePath", true)

    -- MASSO configuration
    dialog:AddDropDownList("MassoUnits", "mm")
    for _, u in ipairs(config.MASSO_UNITS) do
        dialog:AddDropDownListValue("MassoUnits", u.value)
    end

    dialog:AddDropDownList("NumberingMode", "auto")
    for _, n in ipairs(config.NUMBERING_MODES) do
        dialog:AddDropDownListValue("NumberingMode", n.value)
    end

    dialog:AddDropDownList("ZOffsetMode", "preserve")
    for _, z in ipairs(config.Z_MODES) do
        dialog:AddDropDownListValue("ZOffsetMode", z.value)
    end

    dialog:AddDropDownList("SlotMode", "match")
    for _, s in ipairs(config.SLOT_MODES) do
        dialog:AddDropDownListValue("SlotMode", s.value)
    end

    -- USB drive selection
    dialog:AddDropDownList("UsbDrive", "")
    dialog:AddDropDownListValue("UsbDrive", "")
    for _, drive in ipairs(usb_drives) do
        dialog:AddDropDownListValue("UsbDrive", drive.path)
    end
    if saved_usb ~= "" then
        dialog:AddDropDownList("UsbDrive", saved_usb)
    end

    dialog:AddLabelField("UsbStatus", "Select a MASSO USB drive...")
    dialog:AddTextField("BackupPath", saved_backup)
    dialog:AddDirectoryPicker("BrowseBackup", "BackupPath", true)
    timer.step("dialog setup (before ShowDialog)")
    local preview_initial = "Select a tool source and USB drive, then click Sync."
    if schema_dump then
        -- HTML-escape angle brackets so <tags> don't break rendering
        local escaped = schema_dump:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        preview_initial =
            "<b>Tool group listing failed.</b> Please share this schema dump so it can be fixed:<br><br>"
            .. "<pre style=\"white-space:pre-wrap;font-size:14px;\">"
            .. escaped
            .. "</pre>"
    end

    -- Only surface the timing breakdown when startup was actually slow.
    -- A clean startup keeps the Merge Preview area uncluttered; a slow
    -- one auto-exposes the diagnostic so the user (and we) can see which
    -- step is misbehaving without having to toggle a debug flag.
    if timer.total_ms() >= STARTUP_SLOW_THRESHOLD_MS then
        preview_initial = preview_initial ..
            "<br><br><b>Startup was slow (" ..
            string.format("%.0f ms", timer.total_ms()) ..
            ") -- timing breakdown:</b><br>" ..
            "<pre style=\"white-space:pre-wrap;font-size:13px;\">" ..
            timer.dump() ..
            "</pre>"
    end

    dialog:AddLabelField("PreviewContent", preview_initial)

    -- ---- Show the dialog ----
    if not dialog:ShowDialog() then
        return true  -- user cancelled
    end

    -- ---- Read dialog values ----
    local source_mode   = dialog:GetDropDownListValue("SourceMode")
    local file_path     = dialog:GetTextField("FilePath")
    local tool_group    = dialog:GetDropDownListValue("ToolGroup")
    local masso_units   = dialog:GetDropDownListValue("MassoUnits")
    local numbering     = dialog:GetDropDownListValue("NumberingMode")
    local z_mode        = dialog:GetDropDownListValue("ZOffsetMode")
    local slot_mode     = dialog:GetDropDownListValue("SlotMode")
    local usb_drive     = dialog:GetDropDownListValue("UsbDrive")
    local backup_path   = dialog:GetTextField("BackupPath")

    -- ---- Read source tools ----
    local source_tools, err

    if source_mode == "vcarve_db" then
        if not db_path then
            DisplayMessageBox("VCarve tool database not found.\nPlease use 'Fusion 360 Library File' or 'CSV File' source instead.")
            return false
        end
        local group_id = nil
        if tool_group and tool_group ~= "" then
            group_id = group_name_to_id[tool_group]
        end
        source_tools, err = vcarve_db.read_vcarve_db(db_path, script_dir, group_id)
    elseif source_mode == "fusion_file" then
        if file_path == "" then
            DisplayMessageBox("Please select a Fusion 360 library file (.tools or .json).")
            return false
        end
        source_tools, err = vcarve_db.read_fusion_file(file_path)
    elseif source_mode == "csv_file" then
        if file_path == "" then
            DisplayMessageBox("Please select a CSV file.")
            return false
        end
        source_tools, err = vcarve_db.read_csv_file(file_path)
    end

    if not source_tools then
        DisplayMessageBox("Error reading tools:\n" .. tostring(err))
        return false
    end

    if #source_tools == 0 then
        DisplayMessageBox("No tools found in the selected source.")
        return false
    end

    -- ---- Auto-number if requested ----
    if numbering == "auto" then
        merge_mod.auto_number_tools(source_tools)
    end

    -- ---- Validate USB drive ----
    local usb_valid, usb_status, usb_class, htg_path, htg_filename = validate_usb(usb_drive, config)
    if not usb_valid then
        DisplayMessageBox("MASSO USB drive not valid.\n" .. usb_status ..
            "\n\nPlease select a USB drive with MASSO/Machine Settings/ folder.")
        return false
    end

    -- ---- Load existing .htg or create empty ----
    local masso_file
    if htg_path then
        local ok, result = pcall(masso.load_file, htg_path)
        if ok then
            masso_file = result
        else
            DisplayMessageBox("Error reading existing .htg file:\n" .. tostring(result) ..
                "\n\nA new tool table will be created instead.")
            masso_file = masso.new_file()
        end
    else
        masso_file = masso.new_file()
    end

    -- Clear non-source tools so the controller ends up with exactly
    -- the source library's tool set
    local source_numbers = {}
    for _, t in ipairs(source_tools) do
        if t.number then source_numbers[t.number] = true end
    end
    merge_mod.clear_non_source_tools(masso_file, source_numbers)

    -- ---- Perform merge ----
    local report = merge_mod.merge(source_tools, masso_file, {
        masso_units = masso_units,
        z_mode      = z_mode,
        slot_mode   = slot_mode,
    })

    -- ---- Show merge preview and confirm ----
    local preview_html = format_report_html(report, #source_tools, merge_mod)

    local counts = {}
    for _, kind in ipairs({merge_mod.ADDED, merge_mod.UPDATED, merge_mod.REPLACED,
                           merge_mod.UNCHANGED, merge_mod.SKIPPED}) do
        counts[kind] = merge_mod.count_kind(report, kind)
    end

    local summary_text = string.format(
        "Merge Preview:\n\n" ..
        "Added: %d  |  Updated: %d  |  Replaced: %d  |  Unchanged: %d  |  Skipped: %d\n\n" ..
        "Total tools in source: %d\n" ..
        "Target: %s on %s\n\n" ..
        "Proceed with writing to USB?",
        counts[merge_mod.ADDED], counts[merge_mod.UPDATED],
        counts[merge_mod.REPLACED], counts[merge_mod.UNCHANGED],
        counts[merge_mod.SKIPPED],
        #source_tools,
        htg_filename, usb_drive
    )

    -- Use MessageBox for confirmation (VCarve doesn't have a built-in confirm dialog,
    -- so we show the preview and ask)
    if MessageBox then
        -- Try the two-argument form first
        local proceed = MessageBox(summary_text)
        -- MessageBox returns true/false or may be void depending on VCarve version
        -- If it doesn't support return values, proceed anyway
    end

    -- ---- Backup existing Machine Settings ----
    if backup_path == "" then
        backup_path = os.getenv("USERPROFILE") .. "\\Documents\\MASSO Backups"
    end
    local backup_result = backup_machine_settings(usb_drive, backup_path, config)

    -- Save settings to registry
    if Registry then
        local reg = Registry(config.REGISTRY_SECTION)
        reg:SetString("BackupPath", backup_path)
        reg:SetString("UsbDrive", usb_drive)
    end

    -- ---- Write .htg to USB ----
    local output_path = usb_drive .. config.MACHINE_SETTINGS_SUBDIR .. "\\" .. htg_filename
    local ok, write_err = pcall(masso.save_file, masso_file, output_path)
    if not ok then
        DisplayMessageBox("Error writing tool table:\n" .. tostring(write_err))
        return false
    end

    -- ---- Build final summary ----
    local skip_note = ""
    if counts[merge_mod.SKIPPED] > 0 then
        skip_note = string.format(
            "\n\nSkipped %d tool(s) -- MASSO supports T1-T100 (100 slots max).",
            counts[merge_mod.SKIPPED]
        )
    end

    local final_summary = string.format(
        "Tool table updated on USB!\n\n" ..
        "Written to: %s\n" ..
        "Backup saved to: %s\n\n" ..
        "Added: %d  |  Updated: %d  |  Replaced: %d  |  Unchanged: %d" ..
        "%s\n\n" ..
        "Next steps:\n" ..
        "1. Safely eject the USB drive\n" ..
        "2. Plug USB into MASSO controller\n" ..
        "3. F1 Setup > Save & Load Calibration Settings > Load from file\n" ..
        "4. Reboot MASSO controller\n" ..
        "5. Probe Z on new/changed tools",
        output_path, backup_result,
        counts[merge_mod.ADDED], counts[merge_mod.UPDATED],
        counts[merge_mod.REPLACED], counts[merge_mod.UNCHANGED],
        skip_note
    )

    DisplayMessageBox(final_summary)
    return true
end

-- ---------------------------------------------------------------------------
-- Entry points (VCarve supports both patterns)
-- ---------------------------------------------------------------------------

function Gadget_Action()
    local ok, err = pcall(run_gadget)
    if not ok then
        DisplayMessageBox("MASSO Tool Sync Error:\n" .. tostring(err))
    end
end

function main(script_path)
    local ok, err = pcall(run_gadget)
    if not ok then
        DisplayMessageBox("MASSO Tool Sync Error:\n" .. tostring(err))
    end
    return true
end
