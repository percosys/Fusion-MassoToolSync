"""Write tool libraries back to Fusion 360 via the adsk.cam API.

This module imports ``adsk.cam`` and only works inside a Fusion 360 add-in.
The rest of the fusion2masso library (masso, fusion, mapping) is pure stdlib.
"""

from __future__ import annotations

import json
from typing import TYPE_CHECKING

import adsk.cam  # type: ignore[import-untyped]
import adsk.core  # type: ignore[import-untyped]

if TYPE_CHECKING:
    from .fusion import FusionTool


def push_library_to_fusion(
    tools: list[FusionTool],
    library_name: str,
    location: int = 0,
) -> str:
    """Create a new Fusion 360 local tool library with updated tool numbers.

    Args:
        tools: FusionTools with ``.number`` set and ``.raw_json`` preserved.
        library_name: Name for the new library (e.g. "Shapeoko Aluminum - MASSO").
        location: Library location enum value (0 = Local, 1 = Fusion/Cloud).

    Returns:
        The URL string of the newly created library.

    Raises:
        RuntimeError: If the library already exists or the import fails.
    """
    cam_mgr = adsk.cam.CAMManager.get()
    lib_mgr = cam_mgr.libraryManager
    tool_libs = lib_mgr.toolLibraries

    dest_url = tool_libs.urlByLocation(location)

    # Check if library already exists
    existing = tool_libs.childAssetURLs(dest_url)
    for url in existing:
        if url.toString().endswith(f"/{library_name}"):
            raise RuntimeError(
                f"Library {library_name!r} already exists at {url.toString()}. "
                "Delete it first or choose a different name."
            )

    # Build the new library
    new_lib = adsk.cam.ToolLibrary.createEmpty()

    for tool in tools:
        if tool.raw_json is None or tool.number is None:
            continue
        entry = json.loads(json.dumps(tool.raw_json))
        if "post-process" not in entry:
            entry["post-process"] = {}
        entry["post-process"]["number"] = tool.number
        cam_tool = adsk.cam.Tool.createFromJson(json.dumps(entry))
        new_lib.add(cam_tool)

    result = tool_libs.importToolLibrary(new_lib, dest_url, library_name)
    if not result:
        raise RuntimeError(f"importToolLibrary failed for {library_name!r}")

    return f"{dest_url.toString()}/{library_name}"
