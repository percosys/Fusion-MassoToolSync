"""Constants for the MASSO Tool Sync add-in."""

import os

VERSION = "0.1.0"
ADDIN_NAME = "MassoToolSync"

CMD_ID = "massoToolSync_syncCommand"
CMD_NAME = "MASSO Tool Sync"
CMD_DESC = "Sync Fusion 360 tool libraries to MASSO G3 CNC tool tables"

WORKSPACE_ID = "CAMEnvironment"
PANEL_ID = "CAMManagePanel"
IS_PROMOTED = True

FIRMWARE_VERSIONS = {
    "v5.x (current)": {"filename": "MASSO_Mill_Tools.htg", "format": "v5"},
    "v4.x (legacy)": {"filename": "MASSO_Tools.htg", "format": "v4"},
}

Z_MODES = {
    "Zero all Z offsets": "zero",
    "Preserve MASSO Z offsets": "preserve",
    "Use Fusion body length (LB)": "fusion_length",
}

SLOT_MODES = {
    "Match tool number (T1=Slot 1)": "match",
    "Leave unassigned": "unassigned",
}

MASSO_UNITS = {
    "Millimeters (mm)": "mm",
    "Inches (in)": "in",
}

MACHINE_SETTINGS_SUBDIR = os.path.join("MASSO", "Machine Settings")
DEFAULT_BACKUP_DIR = os.path.expanduser("~/Documents/MASSO Backups")
USER_SETTINGS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "user_settings.json")

DEBUG = False
