-- masso_htg.lua  --  Reader/writer for the MASSO G3 Touch .htg tool table binary format.
-- Port of MassoToolSync/fusion2masso/masso.py to Lua.
--
-- Binary record layout (64 bytes per tool, 105 records = 6720 bytes):
--   Offset  Size  Type          Field
--   0       40    ASCII string  Tool name (null-terminated)
--   40      4     float32 LE    Z offset
--   44      8     zeros         Reserved
--   52      4     float32 LE    Diameter
--   56      2     uint16 BE     Slot (0x00FF = empty/unassigned)
--   58      2     zeros         Reserved
--   60      4     uint32 LE     CRC32 of bytes 0-59

local crc32 = require("crc32")
local config = require("config")

local M = {}

-- ---------------------------------------------------------------------------
-- Binary packing helpers
-- Lua 5.3+ has string.pack/unpack; detect and provide fallback.
-- ---------------------------------------------------------------------------

local has_string_pack = (string.pack ~= nil)

local pack_float_le, unpack_float_le
local pack_uint16_be, unpack_uint16_be
local pack_uint32_le, unpack_uint32_le

if has_string_pack then
    pack_float_le   = function(v) return string.pack("<f", v) end
    unpack_float_le = function(s, pos) return string.unpack("<f", s, pos) end
    pack_uint16_be  = function(v) return string.pack(">H", v) end
    unpack_uint16_be = function(s, pos) return string.unpack(">H", s, pos) end
    pack_uint32_le  = function(v) return string.pack("<I4", v) end
    unpack_uint32_le = function(s, pos) return string.unpack("<I4", s, pos) end
else
    -- Lua 5.1/5.2 fallback using string.byte / string.char

    -- IEEE 754 single-precision float <-> 4 bytes (little-endian)
    pack_float_le = function(v)
        if v == 0 then
            -- handle +0.0
            return "\0\0\0\0"
        end
        local sign = 0
        if v < 0 then sign = 1; v = -v end
        local mantissa, exponent = math.frexp(v)
        -- frexp returns m in [0.5, 1.0) with v = m * 2^e
        -- IEEE 754: 1.fraction * 2^(exp-127), stored exponent = exp+127-1
        exponent = exponent + 126
        mantissa = (mantissa * 2 - 1) * 8388608  -- 2^23
        mantissa = math.floor(mantissa + 0.5)
        if mantissa >= 8388608 then
            mantissa = mantissa - 8388608
            exponent = exponent + 1
        end
        local b0 = mantissa % 256
        local b1 = math.floor(mantissa / 256) % 256
        local b2 = math.floor(exponent % 2) * 128 + math.floor(mantissa / 65536)
        local b3 = sign * 128 + math.floor(exponent / 2)
        return string.char(b0, b1, b2, b3)
    end

    unpack_float_le = function(s, pos)
        pos = pos or 1
        local b0, b1, b2, b3 = string.byte(s, pos, pos + 3)
        local sign = (b3 >= 128) and 1 or 0
        local exponent = (b3 % 128) * 2 + math.floor(b2 / 128)
        local mantissa = (b2 % 128) * 65536 + b1 * 256 + b0
        if exponent == 0 and mantissa == 0 then
            return 0.0, pos + 4
        end
        if exponent == 0 then
            -- denormalized
            local v = math.ldexp(mantissa / 8388608, -126)
            return (sign == 1) and -v or v, pos + 4
        end
        local v = math.ldexp(1 + mantissa / 8388608, exponent - 127)
        return (sign == 1) and -v or v, pos + 4
    end

    pack_uint16_be = function(v)
        local hi = math.floor(v / 256)
        local lo = v % 256
        return string.char(hi, lo)
    end

    unpack_uint16_be = function(s, pos)
        pos = pos or 1
        local hi, lo = string.byte(s, pos, pos + 1)
        return hi * 256 + lo, pos + 2
    end

    pack_uint32_le = function(v)
        local b0 = v % 256
        local b1 = math.floor(v / 256) % 256
        local b2 = math.floor(v / 65536) % 256
        local b3 = math.floor(v / 16777216) % 256
        return string.char(b0, b1, b2, b3)
    end

    unpack_uint32_le = function(s, pos)
        pos = pos or 1
        local b0, b1, b2, b3 = string.byte(s, pos, pos + 3)
        return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216, pos + 4
    end
end

-- ---------------------------------------------------------------------------
-- MassoTool record
-- ---------------------------------------------------------------------------

--- Create a new empty MassoTool table.
function M.new_tool()
    return {
        name         = "",
        z_offset     = 0.0,
        diameter     = 0.0,
        slot         = config.EMPTY_SLOT,
        crc_override = nil,     -- set for record 0 or controller-written CRC
    }
end

--- Check if a tool record is empty.
function M.is_empty(tool)
    return tool.slot == config.EMPTY_SLOT and tool.name == ""
end

--- Serialize a single MassoTool to a 64-byte string.
function M.tool_to_bytes(tool)
    -- Build 64-byte record
    local name_bytes = tool.name:sub(1, config.NAME_LEN)
    -- Pad name to 40 bytes with zeros
    name_bytes = name_bytes .. string.rep("\0", config.NAME_LEN - #name_bytes)

    local z_bytes   = pack_float_le(tool.z_offset)           -- offset 40
    local reserved1 = "\0\0\0\0\0\0\0\0"                     -- offset 44, 8 bytes
    local dia_bytes = pack_float_le(tool.diameter)            -- offset 52
    local slot_bytes = pack_uint16_be(tool.slot)              -- offset 56
    local reserved2 = "\0\0"                                  -- offset 58

    local payload = name_bytes .. z_bytes .. reserved1 .. dia_bytes .. slot_bytes .. reserved2
    assert(#payload == 60, "payload must be 60 bytes, got " .. #payload)

    local crc_val
    if tool.crc_override ~= nil then
        crc_val = tool.crc_override
    elseif M.is_empty(tool) then
        crc_val = 0
    else
        crc_val = crc32.compute(payload)
    end
    local crc_bytes = pack_uint32_le(crc_val)

    return payload .. crc_bytes
end

--- Deserialize a 64-byte string into a MassoTool table.
-- @param data            64-byte string
-- @param is_record_zero  boolean, true for record 0
function M.tool_from_bytes(data, is_record_zero)
    assert(#data == config.RECORD_SIZE,
        string.format("Record must be %d bytes, got %d", config.RECORD_SIZE, #data))

    -- Name: first null-terminated portion of bytes 0-39
    local name_raw = data:sub(1, config.NAME_LEN)
    local null_pos = name_raw:find("\0")
    local name = null_pos and name_raw:sub(1, null_pos - 1) or name_raw

    local z_offset  = unpack_float_le(data, 41)   -- Lua strings are 1-indexed
    local diameter  = unpack_float_le(data, 53)
    local slot      = unpack_uint16_be(data, 57)
    local crc_stored = unpack_uint32_le(data, 61)

    local tool = M.new_tool()
    tool.name     = name
    tool.z_offset = z_offset
    tool.diameter = diameter
    tool.slot     = slot

    -- Preserve original CRC for record 0 and for records where the
    -- controller wrote a CRC variant we can't reproduce.
    if is_record_zero then
        tool.crc_override = crc_stored
    else
        local empty = (slot == config.EMPTY_SLOT and name == "")
        if not empty then
            local payload = data:sub(1, 60)
            local crc_calc = crc32.compute(payload)
            if crc_stored ~= crc_calc then
                tool.crc_override = crc_stored
            end
        end
    end

    return tool
end

-- ---------------------------------------------------------------------------
-- MassoToolFile — the full 105-record tool table
-- ---------------------------------------------------------------------------

--- Create a new empty tool file (105 empty records).
function M.new_file()
    local tools = {}
    for i = 0, config.NUM_RECORDS - 1 do
        tools[i] = M.new_tool()
    end
    return { tools = tools }
end

--- Load a tool file from raw bytes (6720 bytes).
function M.file_from_bytes(data)
    assert(#data == config.FILE_SIZE,
        string.format(".htg file must be %d bytes, got %d", config.FILE_SIZE, #data))

    local file = { tools = {} }
    for i = 0, config.NUM_RECORDS - 1 do
        local offset = i * config.RECORD_SIZE
        local rec = data:sub(offset + 1, offset + config.RECORD_SIZE)
        file.tools[i] = M.tool_from_bytes(rec, i == 0)
    end
    return file
end

--- Load a .htg file from disk.
function M.load_file(path)
    local f, err = io.open(path, "rb")
    if not f then error("Cannot open " .. path .. ": " .. tostring(err)) end
    local data = f:read("*a")
    f:close()
    return M.file_from_bytes(data)
end

--- Serialize the full tool file to a byte string (6720 bytes).
function M.file_to_bytes(file)
    local parts = {}
    for i = 0, config.NUM_RECORDS - 1 do
        parts[#parts + 1] = M.tool_to_bytes(file.tools[i])
    end
    local result = table.concat(parts)
    assert(#result == config.FILE_SIZE,
        string.format("Output must be %d bytes, got %d", config.FILE_SIZE, #result))
    return result
end

--- Save the tool file to disk.
function M.save_file(file, path)
    local data = M.file_to_bytes(file)
    local f, err = io.open(path, "wb")
    if not f then error("Cannot write " .. path .. ": " .. tostring(err)) end
    f:write(data)
    f:close()
end

--- Reset all tool slots to empty, preserving record 0.
function M.clear_tools(file)
    for i = 1, config.NUM_RECORDS - 1 do
        file.tools[i] = M.new_tool()
    end
end

return M
