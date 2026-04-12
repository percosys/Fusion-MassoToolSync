-- config.lua  --  Constants for the MASSO Tool Sync VCarve Pro gadget.

local M = {}

M.VERSION = "0.1.0"
M.GADGET_NAME = "MASSO Tool Sync"
M.REGISTRY_SECTION = "MassoToolSync"

-- MASSO .htg binary format constants
M.RECORD_SIZE   = 64
M.NUM_RECORDS   = 105       -- T0-T104
M.MAX_TOOL_NUM  = 100       -- T1-T100 usable; T0 reserved, T101-T104 multi-spindle
M.FILE_SIZE     = M.RECORD_SIZE * M.NUM_RECORDS   -- 6720
M.NAME_LEN      = 40
M.EMPTY_SLOT    = 0x00FF    -- big-endian uint16 sentinel for "no slot"

-- Firmware version detection
M.FIRMWARE_VERSIONS = {
    { name = "v5.x (current)", filename = "MASSO_Mill_Tools.htg", format = "v5" },
    { name = "v4.x (legacy)",  filename = "MASSO_Tools.htg",      format = "v4" },
}

-- Z offset handling modes
M.Z_MODES = {
    { label = "Zero all Z offsets",        value = "zero"     },
    { label = "Preserve MASSO Z offsets",  value = "preserve" },
    { label = "Use tool body length",      value = "tool_length" },
}

-- Slot assignment modes
M.SLOT_MODES = {
    { label = "Match tool number (T1=Slot 1)", value = "match"      },
    { label = "Leave unassigned",              value = "unassigned"  },
}

-- Unit options
M.MASSO_UNITS = {
    { label = "Millimeters (mm)", value = "mm" },
    { label = "Inches (in)",      value = "in" },
}

-- Tool numbering modes
M.NUMBERING_MODES = {
    { label = "Auto-assign (T1, T2, T3...)",    value = "auto"   },
    { label = "Use VCarve tool numbers",         value = "vcarve" },
}

-- Source modes
M.SOURCE_MODES = {
    { label = "VCarve Tool Database",         value = "vcarve_db" },
    { label = "Fusion 360 Library File",      value = "fusion_file" },
    { label = "CSV File (Name,Diameter,Unit)", value = "csv_file" },
}

M.MACHINE_SETTINGS_SUBDIR = "MASSO\\Machine Settings"
M.MM_PER_INCH = 25.4

return M
