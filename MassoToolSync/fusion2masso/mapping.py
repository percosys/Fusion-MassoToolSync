"""Merge Fusion 360 tools into a MASSO tool table."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import Enum

from .fusion import FusionTool, MM_PER_INCH
from .masso import MassoTool, MassoToolFile, NUM_RECORDS, MAX_TOOL_NUM, EMPTY_SLOT


class ChangeKind(Enum):
    ADDED = "ADDED"
    UPDATED = "UPDATED"
    REPLACED = "REPLACED"
    UNCHANGED = "UNCHANGED"
    SKIPPED = "SKIPPED"


@dataclass
class Change:
    kind: ChangeKind
    number: int
    fusion_name: str
    reason: str = ""
    fusion_guid: str = ""


@dataclass
class MergeReport:
    changes: list[Change] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def by_kind(self, kind: ChangeKind) -> list[Change]:
        return [c for c in self.changes if c.kind == kind]


def _convert_length(value: float, from_unit: str, to_unit: str) -> float:
    """Convert a length value between mm and inches."""
    if from_unit == to_unit:
        return value
    if from_unit == "in" and to_unit == "mm":
        return value * MM_PER_INCH
    if from_unit == "mm" and to_unit == "in":
        return value / MM_PER_INCH
    return value


def auto_number_tools(
    fusion_tools: list[FusionTool],
    start: int = 1,
) -> list[FusionTool]:
    """Assign sequential tool numbers starting from ``start``.

    Mutates each tool's ``.number`` in place and returns the same list.
    Skips number 0 (MASSO reserved). Tools beyond T104 get ``number=None``
    so they are cleanly skipped by merge and Fusion sync.
    """
    num = max(start, 1)
    for ft in fusion_tools:
        if num > MAX_TOOL_NUM:
            ft.number = None
        else:
            ft.number = num
            num += 1
    return fusion_tools


def merge(
    fusion_tools: list[FusionTool],
    masso_file: MassoToolFile,
    *,
    masso_units: str = "mm",
    z_mode: str = "preserve",
    slot_mode: str = "match",
) -> MergeReport:
    """Merge Fusion tools into a MASSO tool file (mutates masso_file in place).

    z_mode controls Z offset handling:
      - "preserve": keep existing MASSO Z offsets, new tools get Z=0 (default)
      - "zero": set all Z offsets to 0
      - "fusion_length": use -body_length from Fusion (converted to masso_units)

    slot_mode controls slot assignment for new tools:
      - "match": set slot = tool number (default)
      - "unassigned": leave slot empty (0x00FF)
    """
    report = MergeReport()
    seen_numbers: dict[int, str] = {}

    for ft in fusion_tools:
        if ft.number is None:
            report.changes.append(
                Change(ChangeKind.SKIPPED, -1, ft.name, "no post-process number",
                       fusion_guid=ft.guid)
            )
            continue

        num = ft.number

        if num == 0:
            report.changes.append(
                Change(ChangeKind.SKIPPED, 0, ft.name, "tool 0 is MASSO reserved",
                       fusion_guid=ft.guid)
            )
            continue

        if num < 0 or num > MAX_TOOL_NUM:
            report.changes.append(
                Change(ChangeKind.SKIPPED, num, ft.name, f"number {num} out of range 1-{MAX_TOOL_NUM}",
                       fusion_guid=ft.guid)
            )
            continue

        if num in seen_numbers:
            report.warnings.append(
                f"Duplicate post-process number {num}: {ft.name!r} "
                f"(already used by {seen_numbers[num]!r}) — skipped"
            )
            report.changes.append(
                Change(ChangeKind.SKIPPED, num, ft.name, "duplicate number",
                       fusion_guid=ft.guid)
            )
            continue
        seen_numbers[num] = ft.name

        new_diameter = _convert_length(ft.diameter, ft.unit, masso_units)
        new_name = ft.name[:40]
        if len(ft.name) > 40:
            report.warnings.append(
                f"T{num} name truncated to 40 chars: {ft.name!r}"
            )

        def _z_for_tool() -> float:
            if z_mode == "zero":
                return 0.0
            if z_mode == "fusion_length":
                return -_convert_length(ft.body_length, ft.unit, masso_units)
            return 0.0  # preserve: default for new tools

        existing = masso_file.tools[num]

        new_slot = num if slot_mode == "match" else EMPTY_SLOT

        if existing.is_empty:
            masso_file.tools[num] = MassoTool(
                name=new_name, z_offset=_z_for_tool(), diameter=new_diameter,
                slot=new_slot,
            )
            report.changes.append(Change(ChangeKind.ADDED, num, ft.name,
                                        fusion_guid=ft.guid))
            continue

        # Slot is occupied
        old_name = existing.name
        old_diam = existing.diameter
        name_match = old_name.lower() == new_name.lower()
        diam_match = math.isclose(old_diam, new_diameter, rel_tol=1e-4, abs_tol=1e-4)

        if name_match and diam_match:
            changes_made = []
            if z_mode != "preserve":
                new_z = _z_for_tool()
                if not math.isclose(existing.z_offset, new_z, abs_tol=1e-4):
                    existing.z_offset = new_z
                    changes_made.append(f"Z offset → {new_z:.4f}")
            if existing.slot != new_slot:
                old_label = "unassigned" if existing.slot == EMPTY_SLOT else str(existing.slot)
                new_label = "unassigned" if new_slot == EMPTY_SLOT else str(new_slot)
                existing.slot = new_slot
                changes_made.append(f"slot {old_label} → {new_label}")
            if changes_made:
                existing.crc_override = None
                report.changes.append(Change(
                    ChangeKind.UPDATED, num, ft.name,
                    ", ".join(changes_made), fusion_guid=ft.guid))
            else:
                report.changes.append(Change(
                    ChangeKind.UNCHANGED, num, ft.name,
                    fusion_guid=ft.guid))
            continue

        # Update name and diameter
        existing.name = new_name
        existing.diameter = new_diameter
        existing.crc_override = None  # recompute CRC for modified record
        if z_mode != "preserve":
            existing.z_offset = _z_for_tool()
        existing.slot = new_slot

        if not name_match:
            reason = f"was {old_name!r} — tool is physically different"
            if z_mode == "preserve":
                reason += ", RE-PROBE Z!"
            report.changes.append(
                Change(ChangeKind.REPLACED, num, ft.name, reason,
                       fusion_guid=ft.guid)
            )
        else:
            report.changes.append(
                Change(ChangeKind.UPDATED, num, ft.name,
                       f"diameter {old_diam:.4f} → {new_diameter:.4f}",
                       fusion_guid=ft.guid)
            )

    return report
