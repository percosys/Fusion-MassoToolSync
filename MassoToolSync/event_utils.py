"""Event handler utilities for Fusion 360 add-ins.

Based on Autodesk's fusionAddInUtils (permissive license).
Simplified to be self-contained with no external dependencies.
"""

import sys
import traceback
from typing import Callable

import adsk.core

_handlers = []


def add_handler(
    event: adsk.core.Event,
    callback: Callable,
    *,
    name: str = None,
    local_handlers: list = None,
):
    """Adds an event handler to the specified event.

    Automatically determines the correct handler type from the event.
    Keeps a reference to prevent garbage collection.
    """
    module = sys.modules[event.__module__]
    handler_type = module.__dict__[event.add.__annotations__["handler"]]
    handler = _create_handler(handler_type, callback, name, local_handlers)
    event.add(handler)
    return handler


def clear_handlers():
    global _handlers
    _handlers = []


def _create_handler(handler_type, callback, name, local_handlers):
    name = name or handler_type.__name__

    class Handler(handler_type):
        def __init__(self):
            super().__init__()

        def notify(self, args):
            try:
                callback(args)
            except Exception:
                msg = f"MASSO Tool Sync error in {name}:\n{traceback.format_exc()}"
                print(msg)
                try:
                    app = adsk.core.Application.get()
                    app.log(msg, adsk.core.LogLevels.ErrorLogLevel,
                            adsk.core.LogTypes.FileLogType)
                except Exception:
                    pass

    handler = Handler()
    (local_handlers if local_handlers is not None else _handlers).append(handler)
    return handler
