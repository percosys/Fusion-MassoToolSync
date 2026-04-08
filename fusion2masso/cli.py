"""CLI for fusion2masso: inspect and merge subcommands."""

from __future__ import annotations

import argparse
import sys

from .masso import MassoToolFile, EMPTY_SLOT
from .fusion import parse_fusion_library, write_fusion_library_json
from .mapping import merge, ChangeKind


def cmd_inspect(args: argparse.Namespace) -> None:
    tf = MassoToolFile.load(args.path)
    print(f"{'#':>4s}  {'Name':<40s}  {'Slot':>4s}  {'Z offset':>10s}  {'Diameter':>10s}")
    print("-" * 76)
    for i, tool in enumerate(tf.tools):
        if not args.all and tool.is_empty:
            continue
        slot_str = str(tool.slot) if tool.slot != EMPTY_SLOT else "-"
        print(
            f"{i:4d}  {tool.name:<40s}  {slot_str:>4s}  "
            f"{tool.z_offset:10.4f}  {tool.diameter:10.4f}"
        )


def cmd_merge(args: argparse.Namespace) -> None:
    # Load Fusion library
    fusion_tools = parse_fusion_library(args.fusion)

    # Load existing MASSO file (or start empty)
    if args.masso:
        masso_file = MassoToolFile.load(args.masso)
    else:
        masso_file = MassoToolFile()

    report = merge(fusion_tools, masso_file, masso_units=args.masso_units)

    # Print report
    sections = [
        (ChangeKind.ADDED, "ADDED (Z set to 0 — must probe on machine)"),
        (ChangeKind.UPDATED, "UPDATED (Z preserved)"),
        (ChangeKind.REPLACED, "REPLACED (Z preserved but tool changed — RE-PROBE!)"),
    ]

    for kind, header in sections:
        changes = report.by_kind(kind)
        if changes:
            print(f"\n{header}:")
            for c in changes:
                detail = f"  — {c.reason}" if c.reason else ""
                print(f"  T{c.number:<4d} {c.fusion_name}{detail}")

    unchanged = report.by_kind(ChangeKind.UNCHANGED)
    if unchanged:
        print(f"\nUNCHANGED: {len(unchanged)} tool(s)")

    skipped = report.by_kind(ChangeKind.SKIPPED)
    if skipped:
        print(f"\nSKIPPED:")
        for c in skipped:
            num_str = f"T{c.number}" if c.number >= 0 else "T?"
            print(f"  {num_str:<5s} {c.fusion_name} — {c.reason}")

    if report.warnings:
        print(f"\nWarnings:")
        for w in report.warnings:
            print(f"  ⚠ {w}")

    if args.dry_run:
        print("\n(dry run — no file written)")
        return

    if args.output:
        masso_file.save(args.output)
        print(f"\nWrote {args.output}")
        _print_next_steps()
    else:
        print("\nNo -o/--output specified; use --dry-run to preview or -o to write.")

    if args.sync_fusion_json:
        written = write_fusion_library_json(fusion_tools, args.sync_fusion_json)
        print(f"\nWrote Fusion library JSON with updated numbers: {written}")
        print("Import into Fusion 360 via CAM → Tool Library → Import.")


def _print_next_steps() -> None:
    print(
        """
Next steps:
  1. Copy the output file to USB:/MASSO/Machine Settings/
     (filename is usually MASSO_Mill_Tools.htg — older firmware used MASSO_Tools.htg)
  2. On MASSO: F1 Setup → Save & Load Calibration Settings → Load from file
  3. Reboot the MASSO controller
  4. Probe Z on any newly added tools (Z was set to 0)"""
    )


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="fusion2masso",
        description="Sync Fusion 360 tool libraries to MASSO G3 .htg files",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # inspect
    p_inspect = sub.add_parser("inspect", help="Dump a MASSO .htg tool table")
    p_inspect.add_argument("path", help="Path to .htg file")
    p_inspect.add_argument("--all", action="store_true", help="Include empty records")

    # merge
    p_merge = sub.add_parser("merge", help="Merge Fusion tools into MASSO .htg")
    p_merge.add_argument("fusion", help="Fusion 360 .tools or .json file")
    p_merge.add_argument("--masso", help="Existing MASSO .htg to merge into")
    p_merge.add_argument("-o", "--output", help="Output .htg path")
    p_merge.add_argument("--dry-run", action="store_true", help="Preview without writing")
    p_merge.add_argument(
        "--fusion-units",
        choices=["mm", "in", "auto"],
        default="auto",
        help="Override Fusion tool units (default: auto-detect)",
    )
    p_merge.add_argument(
        "--masso-units",
        choices=["mm", "in"],
        default="mm",
        help="MASSO controller units (default: mm)",
    )
    p_merge.add_argument(
        "--sync-fusion-json",
        metavar="PATH",
        help="Write a Fusion .json library with updated tool numbers",
    )

    args = parser.parse_args(argv)
    if args.command == "inspect":
        cmd_inspect(args)
    elif args.command == "merge":
        cmd_merge(args)


if __name__ == "__main__":
    main()
