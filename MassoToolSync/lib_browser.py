"""Enumerate and export Fusion 360 CAM tool libraries."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import adsk.cam
import adsk.core


def get_local_libraries() -> list[tuple[str, str]]:
    """Return (display_name, url_string) pairs for all local tool libraries."""
    cam_mgr = adsk.cam.CAMManager.get()
    tool_libs = cam_mgr.libraryManager.toolLibraries
    local_url = tool_libs.urlByLocation(0)  # Local
    results = []
    for child_url in tool_libs.childAssetURLs(local_url):
        url_str = child_url.toString()
        # Extract display name from URL (last segment)
        name = url_str.rsplit("/", 1)[-1] if "/" in url_str else url_str
        results.append((name, url_str))
    return results


def export_library_to_json(url_string: str) -> str:
    """Export a Fusion tool library to a temp JSON file.

    Returns the path to the temp file. Caller is responsible for cleanup.
    The JSON is in the format expected by ``parse_fusion_library()``.
    """
    cam_mgr = adsk.cam.CAMManager.get()
    tool_libs = cam_mgr.libraryManager.toolLibraries
    url = adsk.core.URL.create(url_string)
    lib = tool_libs.toolLibraryAtURL(url)

    entries = []
    for i in range(lib.count):
        tool = lib.item(i)
        tool_json = tool.toJson()
        entries.append(json.loads(tool_json))

    lib_data = {"data": entries, "version": 2}

    fd, tmp_path = tempfile.mkstemp(suffix=".json", prefix="masso_export_")
    import os
    os.close(fd)
    Path(tmp_path).write_text(json.dumps(lib_data, indent=2), encoding="utf-8")
    return tmp_path
