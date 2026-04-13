-- VECTRIC LUA SCRIPT
-- merge.lua  --  Merge source tools into a MASSO tool table.
-- Port of MassoToolSync/fusion2masso/mapping.py to Lua.

local config = require("config")
local masso  = require("masso_htg")

local M = {}

-- Change kinds
M.ADDED     = "ADDED"
M.UPDATED   = "UPDATED"
M.REPLACED  = "REPLACED"
M.UNCHANGED = "UNCHANGED"
M.SKIPPED   = "SKIPPED"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Convert a length value between mm and inches.
local function convert_length(value, from_unit, to_unit)
    if from_unit == to_unit then return value end
    if from_unit == "in" and to_unit == "mm" then
        return value * config.MM_PER_INCH
    end
    if from_unit == "mm" and to_unit == "in" then
        return value / config.MM_PER_INCH
    end
    return value
end

--- Approximate equality for floating point.
local function is_close(a, b, rel_tol, abs_tol)
    rel_tol = rel_tol or 1e-4
    abs_tol = abs_tol or 1e-4
    local diff = math.abs(a - b)
    if diff <= abs_tol then return true end
    local largest = math.max(math.abs(a), math.abs(b))
    return diff <= rel_tol * largest
end

-- ---------------------------------------------------------------------------
-- Auto-numbering
-- ---------------------------------------------------------------------------

--- Assign sequential tool numbers starting from `start`.
-- Mutates each tool's `.number` in place. Tools beyond MAX_TOOL_NUM get number=nil.
function M.auto_number_tools(tools, start)
    start = start or 1
    local num = math.max(start, 1)
    for _, t in ipairs(tools) do
        if num > config.MAX_TOOL_NUM then
            t.number = nil
        else
            t.number = num
            num = num + 1
        end
    end
    return tools
end

-- ---------------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------------

--- Merge source tools into a MASSO tool file (mutates masso_file in place).
--
-- @param source_tools  Array of tool tables: {name, number, diameter, unit, id, body_length}
-- @param masso_file    Table from masso_htg.new_file() or masso_htg.file_from_bytes()
-- @param opts          Table with keys:
--                        masso_units: "mm" or "in" (default "mm")
--                        z_mode: "preserve", "zero", "tool_length" (default "preserve")
--                        slot_mode: "match" or "unassigned" (default "match")
-- @return report       {changes = {...}, warnings = {...}}
function M.merge(source_tools, masso_file, opts)
    opts = opts or {}
    local masso_units = opts.masso_units or "mm"
    local z_mode      = opts.z_mode or "preserve"
    local slot_mode   = opts.slot_mode or "match"

    local report = { changes = {}, warnings = {} }
    local seen_numbers = {}  -- number -> name

    for _, ft in ipairs(source_tools) do
        local num = ft.number

        if num == nil then
            report.changes[#report.changes + 1] = {
                kind = M.SKIPPED, number = -1, name = ft.name,
                reason = "no tool number", id = ft.id or "",
            }
            goto continue
        end

        if num == 0 then
            report.changes[#report.changes + 1] = {
                kind = M.SKIPPED, number = 0, name = ft.name,
                reason = "tool 0 is MASSO reserved", id = ft.id or "",
            }
            goto continue
        end

        if num < 0 or num > config.MAX_TOOL_NUM then
            report.changes[#report.changes + 1] = {
                kind = M.SKIPPED, number = num, name = ft.name,
                reason = string.format("number %d out of range 1-%d", num, config.MAX_TOOL_NUM),
                id = ft.id or "",
            }
            goto continue
        end

        if seen_numbers[num] then
            report.warnings[#report.warnings + 1] = string.format(
                "Duplicate tool number %d: '%s' (already used by '%s') -- skipped",
                num, ft.name, seen_numbers[num]
            )
            report.changes[#report.changes + 1] = {
                kind = M.SKIPPED, number = num, name = ft.name,
                reason = "duplicate number", id = ft.id or "",
            }
            goto continue
        end
        seen_numbers[num] = ft.name

        -- Convert diameter to MASSO units
        local new_diameter = convert_length(ft.diameter, ft.unit, masso_units)
        local new_name = ft.name:sub(1, 40)
        if #ft.name > 40 then
            report.warnings[#report.warnings + 1] = string.format(
                "T%d name truncated to 40 chars: '%s'", num, ft.name
            )
        end

        -- Determine Z offset for this tool
        local function z_for_tool()
            if z_mode == "zero" then return 0.0 end
            if z_mode == "tool_length" then
                return -convert_length(ft.body_length or 0, ft.unit, masso_units)
            end
            return 0.0  -- preserve: default for new tools
        end

        local existing = masso_file.tools[num]
        local new_slot = (slot_mode == "match") and num or config.EMPTY_SLOT

        -- Empty slot: add new tool
        if masso.is_empty(existing) then
            masso_file.tools[num] = {
                name = new_name,
                z_offset = z_for_tool(),
                diameter = new_diameter,
                slot = new_slot,
                crc_override = nil,
            }
            report.changes[#report.changes + 1] = {
                kind = M.ADDED, number = num, name = ft.name, id = ft.id or "",
            }
            goto continue
        end

        -- Slot is occupied — check for match
        local old_name = existing.name
        local old_diam = existing.diameter
        local name_match = old_name:lower() == new_name:lower()
        local diam_match = is_close(old_diam, new_diameter)

        if name_match and diam_match then
            -- Same tool — check if Z or slot needs updating
            local changes_made = {}

            if z_mode ~= "preserve" then
                local new_z = z_for_tool()
                if not is_close(existing.z_offset, new_z) then
                    existing.z_offset = new_z
                    changes_made[#changes_made + 1] = string.format("Z offset -> %.4f", new_z)
                end
            end

            if existing.slot ~= new_slot then
                local old_label = (existing.slot == config.EMPTY_SLOT) and "unassigned" or tostring(existing.slot)
                local new_label = (new_slot == config.EMPTY_SLOT) and "unassigned" or tostring(new_slot)
                existing.slot = new_slot
                changes_made[#changes_made + 1] = string.format("slot %s -> %s", old_label, new_label)
            end

            if #changes_made > 0 then
                existing.crc_override = nil  -- force CRC recomputation
                report.changes[#report.changes + 1] = {
                    kind = M.UPDATED, number = num, name = ft.name,
                    reason = table.concat(changes_made, ", "), id = ft.id or "",
                }
            else
                report.changes[#report.changes + 1] = {
                    kind = M.UNCHANGED, number = num, name = ft.name, id = ft.id or "",
                }
            end
            goto continue
        end

        -- Different tool — update name and diameter
        existing.name = new_name
        existing.diameter = new_diameter
        existing.crc_override = nil  -- force CRC recomputation
        if z_mode ~= "preserve" then
            existing.z_offset = z_for_tool()
        end
        existing.slot = new_slot

        if not name_match then
            local reason = string.format("was '%s' -- tool is physically different", old_name)
            if z_mode == "preserve" then
                reason = reason .. ", RE-PROBE Z!"
            end
            report.changes[#report.changes + 1] = {
                kind = M.REPLACED, number = num, name = ft.name,
                reason = reason, id = ft.id or "",
            }
        else
            report.changes[#report.changes + 1] = {
                kind = M.UPDATED, number = num, name = ft.name,
                reason = string.format("diameter %.4f -> %.4f", old_diam, new_diameter),
                id = ft.id or "",
            }
        end

        ::continue::
    end

    return report
end

-- ---------------------------------------------------------------------------
-- Utility: clear non-source tools
-- ---------------------------------------------------------------------------

--- Blank out MASSO slots that are NOT in the source tool set.
-- Keeps tools at slots matching source numbers (so merge can detect
-- UNCHANGED/UPDATED/REPLACED and preserve Z offsets).
function M.clear_non_source_tools(masso_file, source_numbers)
    for i = 1, config.NUM_RECORDS - 1 do
        if not source_numbers[i] then
            masso_file.tools[i] = masso.new_tool()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Report helpers
-- ---------------------------------------------------------------------------

--- Filter changes by kind.
function M.by_kind(report, kind)
    local result = {}
    for _, c in ipairs(report.changes) do
        if c.kind == kind then
            result[#result + 1] = c
        end
    end
    return result
end

--- Count changes by kind.
function M.count_kind(report, kind)
    return #M.by_kind(report, kind)
end

return M
