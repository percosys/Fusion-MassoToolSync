"""Parser for Fusion 360 tool library files (.tools ZIP or .json)."""

from __future__ import annotations

import json
import zipfile
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path

MM_PER_INCH = 25.4


@dataclass
class FusionTool:
    """A tool extracted from a Fusion 360 tool library."""

    name: str
    number: int | None  # post-process.number; None if unset
    diameter: float  # in the unit indicated by `unit`
    unit: str  # "mm" or "in"
    guid: str = ""  # unique tool identifier from Fusion
    raw_json: dict | None = None  # original JSON dict for round-tripping
    body_length: float = 0.0  # geometry.LB (in tool's native unit)

    @property
    def diameter_mm(self) -> float:
        if self.unit == "in":
            return self.diameter * MM_PER_INCH
        return self.diameter

    @property
    def body_length_mm(self) -> float:
        if self.unit == "in":
            return self.body_length * MM_PER_INCH
        return self.body_length


def _detect_unit(tool_dict: dict) -> str:
    """Determine the unit of a Fusion tool entry."""
    # Explicit top-level field
    u = tool_dict.get("unit", "")
    if isinstance(u, str):
        low = u.lower()
        if "inch" in low or low == "in":
            return "in"
        if "mill" in low or low == "mm":
            return "mm"

    # Fall back to expressions.tool_diameter suffix
    expr = (tool_dict.get("expressions") or {}).get("tool_diameter", "")
    if isinstance(expr, str):
        expr = expr.strip()
        if expr.endswith("in"):
            return "in"
        if expr.endswith("mm"):
            return "mm"

    return "mm"  # default


def _extract_name(tool_dict: dict) -> str:
    for key in ("description", "product-id"):
        v = tool_dict.get(key)
        if v:
            return str(v)
    return tool_dict.get("guid", "unnamed")


def parse_fusion_library(path: str | Path) -> list[FusionTool]:
    """Parse a Fusion 360 tool library file (.tools or .json)."""
    path = Path(path)
    raw = path.read_bytes()

    # Detect ZIP (.tools) vs plain JSON
    if raw[:4] == b"PK\x03\x04":
        with zipfile.ZipFile(BytesIO(raw)) as zf:
            names = zf.namelist()
            json_name = next(
                (n for n in names if n.endswith(".json")), names[0]
            )
            text = zf.read(json_name).decode("utf-8")
    else:
        text = raw.decode("utf-8")

    lib = json.loads(text)
    entries = lib.get("data", [])

    tools: list[FusionTool] = []
    for entry in entries:
        name = _extract_name(entry)
        pp = entry.get("post-process") or {}
        number = pp.get("number")
        if number is not None:
            number = int(number)
        geom = entry.get("geometry") or {}
        diameter = float(geom.get("DC", 0))
        body_length = float(geom.get("LB", 0))
        unit = _detect_unit(entry)
        guid = entry.get("guid", "")
        tools.append(FusionTool(
            name=name, number=number, diameter=diameter, unit=unit,
            guid=guid, raw_json=entry, body_length=body_length,
        ))

    return tools


def write_fusion_library_json(
    tools: list[FusionTool],
    output_path: str | Path,
) -> Path:
    """Write a Fusion 360 tool library JSON with updated post-process numbers.

    Each tool's ``raw_json`` is used as the base, with ``post-process.number``
    overwritten from ``tool.number``. Tools without ``raw_json`` are skipped.
    """
    output_path = Path(output_path)
    entries: list[dict] = []
    for tool in tools:
        if tool.raw_json is None:
            continue
        entry = json.loads(json.dumps(tool.raw_json))  # deep copy
        if "post-process" not in entry:
            entry["post-process"] = {}
        if tool.number is not None:
            entry["post-process"]["number"] = tool.number
        entries.append(entry)

    lib = {"data": entries, "version": 2}
    output_path.write_text(json.dumps(lib, indent=2), encoding="utf-8")
    return output_path
