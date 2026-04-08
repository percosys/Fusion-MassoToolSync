"""fusion2masso — Fusion 360 → MASSO G3 tool library bridge."""

from .masso import MassoTool, MassoToolFile
from .fusion import FusionTool, parse_fusion_library, write_fusion_library_json
from .mapping import merge, auto_number_tools, MergeReport, Change, ChangeKind

__all__ = [
    "MassoTool",
    "MassoToolFile",
    "FusionTool",
    "parse_fusion_library",
    "write_fusion_library_json",
    "merge",
    "auto_number_tools",
    "MergeReport",
    "Change",
    "ChangeKind",
]
