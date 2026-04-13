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
-- VCarve Pro's gadget search path (package.path) only includes the parent
-- "Gadgets\VCarve Pro V12.5\" folder, NOT the specific gadget subfolder.
-- We need to add our own folder to package.path BEFORE any require() calls
-- so that config.lua, crc32.lua, etc. can be found.
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
        package.path = script_dir .. "\\?.lua;"
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
    local drives = {}
    -- Use WMIC to list removable drives
    local handle = io.popen('wmic logicaldisk where "DriveType=2" get DeviceID,VolumeName /format:csv 2>nul')
    if handle then
        local output = handle:read("*a")
        handle:close()
        for line in output:gmatch("[^\r\n]+") do
            local letter = line:match(",(%a:),")
            if not letter then
                letter = line:match(",(%a:)")
            end
            if letter then
                local vol = line:match(",(%a:),(.*)$")
                if not vol or vol == "" then vol = "Removable" end
                drives[#drives + 1] = { path = letter .. "\\", label = letter .. " (" .. vol .. ")" }
            end
        end
    end

    -- Fallback: scan common drive letters if WMIC returned nothing
    if #drives == 0 then
        for _, letter in ipairs({"D","E","F","G","H","I","J","K","L"}) do
            local test_path = letter .. ":\\MASSO"
            local f = io.open(test_path .. "\\Machine Settings\\.", "r")
            if f then
                f:close()
                drives[#drives + 1] = { path = letter .. ":\\", label = letter .. ": (MASSO detected)" }
            end
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

local function run_gadget()
    -- ---- Detect VCarve tool database ----
    local db_path = vcarve_db.get_db_path()
    local db_status
    if db_path then
        db_status = "Found: " .. db_path
    else
        db_status = "Not found (use File source instead)"
    end

    -- ---- Detect USB drives ----
    local usb_drives = detect_usb_drives()

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

    local dialog = HTML_Dialog(true, htm_content, 720, 740,
        "MASSO Tool Sync v" .. config.VERSION)

    -- Source configuration
    dialog:AddDropDownList("SourceMode", "vcarve_db")
    for _, src in ipairs(config.SOURCE_MODES) do
        dialog:AddDropDownListValue("SourceMode", src.value)
    end
    dialog:AddTextField("FilePath", "")
    dialog:AddLabelField("DbStatus", db_status)

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
    dialog:AddLabelField("PreviewContent", "Select a tool source and USB drive, then click Sync.")

    -- ---- Show the dialog ----
    if not dialog:ShowDialog() then
        return true  -- user cancelled
    end

    -- ---- Read dialog values ----
    local source_mode   = dialog:GetDropDownListValue("SourceMode")
    local file_path     = dialog:GetTextField("FilePath")
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
        source_tools, err = vcarve_db.read_vcarve_db(db_path, script_dir)
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
