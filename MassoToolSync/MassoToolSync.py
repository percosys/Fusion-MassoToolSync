"""MASSO Tool Sync — Fusion 360 add-in entry point."""

import os
import sys
import traceback

import adsk.core

# Add this directory to sys.path so modules can be imported directly
_this_dir = os.path.dirname(os.path.abspath(__file__))
if _this_dir not in sys.path:
    sys.path.insert(0, _this_dir)

# Keep handler references alive at module level
_handlers = []


def run(context):
    try:
        # Force reimport of all our modules to pick up code changes
        for mod_name in list(sys.modules.keys()):
            if mod_name in ('command', 'config', 'event_utils', 'lib_browser') \
               or mod_name.startswith('fusion2masso'):
                del sys.modules[mod_name]

        import command
        command.start()
    except Exception:
        app = adsk.core.Application.get()
        app.userInterface.messageBox(
            f"MASSO Tool Sync failed to start:\n{traceback.format_exc()}"
        )


def stop(context):
    try:
        import command
        command.stop()
    except Exception:
        app = adsk.core.Application.get()
        app.userInterface.messageBox(
            f"MASSO Tool Sync failed to stop:\n{traceback.format_exc()}"
        )
