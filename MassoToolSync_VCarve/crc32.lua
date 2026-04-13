-- VECTRIC LUA SCRIPT
-- crc32.lua  --  Pure Lua CRC32 (ISO 3309 / ITU-T V.42).
-- Matches Python's zlib.crc32() output.
-- Compatible with Lua 5.1, 5.2, 5.3, and 5.4.

local M = {}

-- Pre-computed CRC32 lookup table (polynomial 0xEDB88320, reflected).
local crc_table = {}

-- ---------------------------------------------------------------------------
-- Detect available bit operations. We NEVER use Lua 5.3 syntax operators
-- (~, &, >>) directly because they cause parse errors on older Lua versions.
-- ---------------------------------------------------------------------------

local _xor, _band, _rshift

-- Try bit32 (Lua 5.2, also available in some 5.3 builds)
local ok_bit32, bit32_lib = pcall(require, "bit32")
if not ok_bit32 then
    -- bit32 might be a global in Lua 5.2
    if type(bit32) == "table" then
        ok_bit32 = true
        bit32_lib = bit32
    end
end

if ok_bit32 and bit32_lib then
    _xor    = bit32_lib.bxor
    _band   = bit32_lib.band
    _rshift = bit32_lib.rshift
else
    -- Try LuaJIT's bit library
    local ok_bit, bit_lib = pcall(require, "bit")
    if not ok_bit then
        if type(bit) == "table" then
            ok_bit = true
            bit_lib = bit
        end
    end

    if ok_bit and bit_lib then
        _xor    = bit_lib.bxor
        _band   = bit_lib.band
        _rshift = bit_lib.rshift
    else
        -- Try loading Lua 5.3+ operators via load() to avoid parse errors
        local load_fn = load or loadstring
        local ok53, xor53 = pcall(load_fn, "return function(a,b) return a ~ b end")
        if ok53 and xor53 then
            _xor = xor53()
            local _, band53 = pcall(load_fn, "return function(a,b) return a & b end")
            _band = band53 and band53() or nil
            local _, rsh53 = pcall(load_fn, "return function(a,b) return a >> b end")
            _rshift = rsh53 and rsh53() or nil
        end

        if not _xor then
            -- Pure math fallback (slowest, but works everywhere)
            _band = function(a, b)
                local result = 0
                local bit_val = 1
                for _ = 1, 32 do
                    if a % 2 >= 1 and b % 2 >= 1 then
                        result = result + bit_val
                    end
                    a = math.floor(a / 2)
                    b = math.floor(b / 2)
                    bit_val = bit_val * 2
                end
                return result
            end

            _xor = function(a, b)
                local result = 0
                local bit_val = 1
                for _ = 1, 32 do
                    local a_bit = a % 2
                    local b_bit = b % 2
                    if a_bit ~= b_bit then
                        result = result + bit_val
                    end
                    a = math.floor(a / 2)
                    b = math.floor(b / 2)
                    bit_val = bit_val * 2
                end
                return result
            end

            _rshift = function(a, n)
                return math.floor(a / (2 ^ n))
            end
        end
    end
end

-- Build the lookup table
local function build_table()
    for i = 0, 255 do
        local crc = i
        for _ = 1, 8 do
            if _band(crc, 1) == 1 then
                crc = _xor(_rshift(crc, 1), 0xEDB88320)
            else
                crc = _rshift(crc, 1)
            end
        end
        crc_table[i] = crc
    end
end

build_table()

--- Compute CRC32 of a byte string.
-- @param data  string of raw bytes
-- @return      unsigned 32-bit integer CRC
function M.compute(data)
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        local byte = string.byte(data, i)
        local index = _band(_xor(crc, byte), 0xFF)
        crc = _xor(_rshift(crc, 8), crc_table[index])
    end
    return _band(_xor(crc, 0xFFFFFFFF), 0xFFFFFFFF)
end

return M
