-- VECTRIC LUA SCRIPT
-- vcarve_db.lua  --  Read tools from VCarve Pro's SQLite tool database (.vtdb)
--                     and from Fusion 360 library files (.tools / .json).

local config = require("config")

local M = {}

-- ---------------------------------------------------------------------------
-- VCarve Tool Database (.vtdb via sqlite3 CLI)
-- ---------------------------------------------------------------------------

--- Locate the VCarve tool database path.
-- Tries the VCarve API first, then falls back to known paths.
function M.get_db_path()
    -- Try VCarve API
    if GetToolDatabaseLocation then
        local loc = GetToolDatabaseLocation()
        if loc and loc ~= "" then
            local path = loc .. "\\tools.vtdb"
            local f = io.open(path, "r")
            if f then f:close(); return path end
            -- Also try without backslash (in case loc ends with one)
            path = loc .. "tools.vtdb"
            f = io.open(path, "r")
            if f then f:close(); return path end
        end
    end

    -- Known default paths
    local candidates = {
        "C:\\ProgramData\\Vectric\\VCarve Pro\\ToolDatabase\\tools.vtdb",
        "C:\\ProgramData\\Vectric\\VCarve\\ToolDatabase\\tools.vtdb",
        "C:\\Users\\Public\\Documents\\Vectric Files\\Tool Database\\tools.vtdb",
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then f:close(); return path end
    end
    return nil
end

--- Find the sqlite3 executable.
-- Checks gadget resources folder first, then system PATH.
local function find_sqlite3(gadget_dir)
    -- Check bundled copy in gadget's resources folder
    if gadget_dir then
        local bundled = gadget_dir .. "\\resources\\sqlite3.exe"
        local f = io.open(bundled, "r")
        if f then f:close(); return '"' .. bundled .. '"' end
    end

    -- Check system PATH
    local handle = io.popen("where sqlite3.exe 2>nul")
    if handle then
        local result = handle:read("*l")
        handle:close()
        if result and result ~= "" then
            return '"' .. result:match("^%s*(.-)%s*$") .. '"'
        end
    end

    return nil
end

--- Parse a line of CSV output (handles quoted fields).
local function parse_csv_line(line)
    local fields = {}
    local pos = 1
    while pos <= #line do
        if line:sub(pos, pos) == '"' then
            -- Quoted field
            local end_quote = pos + 1
            while end_quote <= #line do
                if line:sub(end_quote, end_quote) == '"' then
                    if line:sub(end_quote + 1, end_quote + 1) == '"' then
                        end_quote = end_quote + 2  -- escaped quote
                    else
                        break
                    end
                else
                    end_quote = end_quote + 1
                end
            end
            local value = line:sub(pos + 1, end_quote - 1):gsub('""', '"')
            fields[#fields + 1] = value
            pos = end_quote + 1
            if line:sub(pos, pos) == "," then pos = pos + 1 end
        else
            -- Unquoted field
            local comma = line:find(",", pos)
            if comma then
                fields[#fields + 1] = line:sub(pos, comma - 1)
                pos = comma + 1
            else
                fields[#fields + 1] = line:sub(pos)
                pos = #line + 1
            end
        end
    end
    return fields
end

--- Read tools from the VCarve .vtdb database using sqlite3 CLI.
-- @param db_path     Path to tools.vtdb
-- @param gadget_dir  Path to gadget directory (for bundled sqlite3)
-- @param group_name  Optional: filter by group/folder name (nil = all tools)
-- @return tools      Array of tool tables, or nil + error message
function M.read_vcarve_db(db_path, gadget_dir, group_name)
    local sqlite3 = find_sqlite3(gadget_dir)
    if not sqlite3 then
        return nil, "sqlite3.exe not found. Please install SQLite CLI tools or place sqlite3.exe in the gadget's resources folder."
    end

    -- Query to extract tool data
    -- We join through the entity/geometry/cutting_data tables
    local sql = [[
SELECT
    tg.name_format,
    tg.diameter,
    tg.flute_length,
    tg.overall_length,
    tg.units,
    tg.tool_type,
    tcd.tool_number,
    te.uuid
FROM tool_entity te
JOIN tool_geometry tg ON te.geometry_id = tg.id
JOIN tool_cutting_data tcd ON te.cutting_data_id = tcd.id
ORDER BY tcd.tool_number, tg.name_format
]]

    -- Escape single quotes in db_path for shell
    local safe_path = db_path:gsub("'", "''")
    local cmd = string.format(
        '%s -csv -header "%s" "%s" 2>&1',
        sqlite3, safe_path, sql:gsub("\n", " "):gsub('"', '\\"')
    )

    local handle = io.popen(cmd)
    if not handle then
        return nil, "Failed to execute sqlite3 command"
    end

    local output = handle:read("*a")
    handle:close()

    -- Check for errors
    if output:match("^Error:") or output:match("^Parse error") then
        -- Try alternative column names (schema may vary by VCarve version)
        return M._read_vcarve_db_fallback(db_path, sqlite3)
    end

    local lines = {}
    for line in output:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end

    if #lines < 2 then
        return nil, "No tools found in database (or query returned no results)"
    end

    -- Parse header to find column indices
    local header = parse_csv_line(lines[1])
    local col_idx = {}
    for i, name in ipairs(header) do
        col_idx[name:lower()] = i
    end

    local tools = {}
    for i = 2, #lines do
        local fields = parse_csv_line(lines[i])
        local tool = {
            name        = fields[col_idx["name_format"] or 1] or "unnamed",
            diameter    = tonumber(fields[col_idx["diameter"] or 2]) or 0,
            body_length = tonumber(fields[col_idx["flute_length"] or 3]) or 0,
            unit        = "mm",  -- will be decoded below
            number      = tonumber(fields[col_idx["tool_number"] or 7]),
            id          = fields[col_idx["uuid"] or 8] or "",
            tool_type   = tonumber(fields[col_idx["tool_type"] or 6]) or 1,
        }

        -- Decode units: VCarve typically uses 1=mm, 0=inches
        local units_raw = tonumber(fields[col_idx["units"] or 5])
        if units_raw == 0 then
            tool.unit = "in"
        end

        tools[#tools + 1] = tool
    end

    return tools
end

--- Fallback query with alternative column names for different VCarve versions.
function M._read_vcarve_db_fallback(db_path, sqlite3)
    -- Try to discover the actual schema first
    local schema_cmd = string.format(
        '%s "%s" ".schema tool_geometry" 2>&1',
        sqlite3, db_path
    )
    local handle = io.popen(schema_cmd)
    if not handle then
        return nil, "Failed to read database schema"
    end
    local schema = handle:read("*a")
    handle:close()

    -- Try a simpler query that's more likely to work
    local sql = [[
SELECT
    tg.name_format,
    tg.diameter,
    tcd.tool_number
FROM tool_entity te
JOIN tool_geometry tg ON te.geometry_id = tg.id
JOIN tool_cutting_data tcd ON te.cutting_data_id = tcd.id
ORDER BY tcd.tool_number
]]

    local cmd = string.format(
        '%s -csv -header "%s" "%s" 2>&1',
        sqlite3, db_path, sql:gsub("\n", " "):gsub('"', '\\"')
    )

    handle = io.popen(cmd)
    if not handle then
        return nil, "Failed to execute sqlite3 fallback query"
    end

    local output = handle:read("*a")
    handle:close()

    if output:match("^Error:") or output:match("^Parse error") then
        return nil, "Cannot read VCarve database. Schema:\n" .. schema
    end

    local lines = {}
    for line in output:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end

    if #lines < 2 then
        return nil, "No tools found in database"
    end

    local tools = {}
    for i = 2, #lines do
        local fields = parse_csv_line(lines[i])
        tools[#tools + 1] = {
            name        = fields[1] or "unnamed",
            diameter    = tonumber(fields[2]) or 0,
            body_length = 0,
            unit        = "mm",
            number      = tonumber(fields[3]),
            id          = "",
            tool_type   = 1,
        }
    end
    return tools
end

--- List tool groups/folders in the VCarve database.
function M.list_groups(db_path, gadget_dir)
    local sqlite3 = find_sqlite3(gadget_dir)
    if not sqlite3 then return {} end

    local sql = "SELECT id, name FROM tool_tree_entry WHERE entity_id IS NULL ORDER BY name"
    local cmd = string.format(
        '%s -csv -header "%s" "%s" 2>&1',
        sqlite3, db_path, sql
    )

    local handle = io.popen(cmd)
    if not handle then return {} end
    local output = handle:read("*a")
    handle:close()

    local groups = {}
    local first = true
    for line in output:gmatch("[^\r\n]+") do
        if first then
            first = false  -- skip header
        else
            local fields = parse_csv_line(line)
            groups[#groups + 1] = {
                id   = tonumber(fields[1]) or 0,
                name = fields[2] or "Unknown",
            }
        end
    end
    return groups
end

-- ---------------------------------------------------------------------------
-- Fusion 360 Library Import (.tools ZIP or .json)
-- ---------------------------------------------------------------------------

--- Parse a Fusion 360 tool library JSON string.
-- @param json_text  The JSON content as a string
-- @return tools     Array of tool tables
function M.parse_fusion_json(json_text)
    -- Minimal JSON parser for Fusion tool libraries.
    -- Fusion libraries have structure: {"data": [...], "version": 2}
    -- Each tool entry has: description, guid, geometry.DC, geometry.LB,
    -- unit, post-process.number, expressions.tool_diameter

    local tools = {}

    -- Extract each tool object from the "data" array
    -- We use pattern matching since we don't have a full JSON parser
    -- Find the "data" array content
    local data_start = json_text:find('%[', json_text:find('"data"'))
    if not data_start then return tools end

    -- Parse individual tool objects by tracking brace depth
    local pos = data_start + 1
    local len = #json_text

    while pos < len do
        -- Skip whitespace
        pos = json_text:find("[^%s]", pos) or len + 1
        if pos > len then break end

        local ch = json_text:sub(pos, pos)
        if ch == "]" then break end  -- end of data array
        if ch == "," then pos = pos + 1; goto next_tool end

        if ch == "{" then
            -- Find matching closing brace
            local depth = 1
            local obj_start = pos
            pos = pos + 1
            while pos <= len and depth > 0 do
                local c = json_text:sub(pos, pos)
                if c == "{" then depth = depth + 1
                elseif c == "}" then depth = depth - 1
                elseif c == '"' then
                    -- Skip string content
                    pos = pos + 1
                    while pos <= len do
                        c = json_text:sub(pos, pos)
                        if c == "\\" then pos = pos + 1
                        elseif c == '"' then break end
                        pos = pos + 1
                    end
                end
                pos = pos + 1
            end
            local obj_text = json_text:sub(obj_start, pos - 1)

            -- Extract fields from this tool object
            local function get_string(text, key)
                local pattern = '"' .. key .. '"%s*:%s*"([^"]*)"'
                return text:match(pattern)
            end
            local function get_number(text, key)
                local pattern = '"' .. key .. '"%s*:%s*([%d%.%-]+)'
                local val = text:match(pattern)
                return val and tonumber(val) or nil
            end

            local name = get_string(obj_text, "description")
                      or get_string(obj_text, "product%-id")
                      or get_string(obj_text, "guid")
                      or "unnamed"
            local guid = get_string(obj_text, "guid") or ""
            local diameter = get_number(obj_text, "DC") or 0
            local body_length = get_number(obj_text, "LB") or 0
            local number = get_number(obj_text, "number")
            if number then number = math.floor(number) end

            -- Detect unit
            local unit = "mm"
            local unit_str = get_string(obj_text, "unit") or ""
            if unit_str:lower():find("inch") or unit_str:lower() == "in" then
                unit = "in"
            end
            -- Fallback: check expressions.tool_diameter suffix
            if unit == "mm" then
                local expr = get_string(obj_text, "tool_diameter") or ""
                if expr:match("in$") then unit = "in" end
            end

            tools[#tools + 1] = {
                name        = name,
                number      = number,
                diameter    = diameter,
                body_length = body_length,
                unit        = unit,
                id          = guid,
            }
        end
        ::next_tool::
    end

    return tools
end

--- Read a Fusion 360 tool library file (.tools ZIP or .json).
function M.read_fusion_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, "Cannot open file: " .. tostring(err) end
    local data = f:read("*a")
    f:close()

    -- Check if it's a ZIP file (.tools format)
    if data:sub(1, 4) == "PK\3\4" then
        -- ZIP file — need to extract the JSON inside
        -- Use PowerShell to extract on Windows
        local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "."
        local temp_json = temp_dir .. "\\masso_fusion_import.json"
        local cmd = string.format(
            'powershell -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; '
            .. '$zip = [IO.Compression.ZipFile]::OpenRead(\'%s\'); '
            .. '$entry = ($zip.Entries | Where-Object { $_.Name -like \'*.json\' } | Select-Object -First 1); '
            .. '[IO.Compression.ZipFileExtensions]::ExtractToFile($entry, \'%s\', $true); '
            .. '$zip.Dispose()" 2>&1',
            path:gsub("'", "''"), temp_json:gsub("'", "''")
        )
        os.execute(cmd)

        local jf = io.open(temp_json, "r")
        if not jf then
            return nil, "Failed to extract JSON from .tools ZIP file"
        end
        local json_text = jf:read("*a")
        jf:close()
        os.remove(temp_json)
        return M.parse_fusion_json(json_text)
    else
        -- Plain JSON
        return M.parse_fusion_json(data)
    end
end

-- ---------------------------------------------------------------------------
-- CSV Import
-- ---------------------------------------------------------------------------

--- Read tools from a simple CSV file.
-- Expected columns: Name, Diameter, Unit, ToolNumber, BodyLength
-- Header row is optional (auto-detected).
function M.read_csv_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, "Cannot open file: " .. tostring(err) end

    local tools = {}
    local line_num = 0
    local has_header = false

    for line in f:lines() do
        line_num = line_num + 1
        line = line:match("^%s*(.-)%s*$")  -- trim
        if line == "" or line:sub(1, 1) == "#" then goto next_csv end

        local fields = parse_csv_line(line)

        -- Detect header row
        if line_num == 1 then
            local first = (fields[1] or ""):lower()
            if first == "name" or first == "tool" or first == "description" then
                has_header = true
                goto next_csv
            end
        end

        local name     = fields[1] or "unnamed"
        local diameter = tonumber(fields[2]) or 0
        local unit     = (fields[3] or "mm"):lower():match("^%s*(.-)%s*$")
        if unit ~= "in" and unit ~= "inches" then unit = "mm" end
        if unit == "inches" then unit = "in" end
        local number      = tonumber(fields[4])
        if number then number = math.floor(number) end
        local body_length = tonumber(fields[5]) or 0

        tools[#tools + 1] = {
            name        = name,
            number      = number,
            diameter    = diameter,
            body_length = body_length,
            unit        = unit,
            id          = "",
        }
        ::next_csv::
    end
    f:close()
    return tools
end

return M
