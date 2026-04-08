"""Tests for fusion2masso."""

import json
import math
import struct
import tempfile
import zipfile
import zlib
from io import BytesIO
from pathlib import Path

import pytest

from fusion2masso.masso import (
    MassoTool,
    MassoToolFile,
    RECORD_SIZE,
    NUM_RECORDS,
    FILE_SIZE,
    EMPTY_SLOT,
)
from fusion2masso.fusion import FusionTool, parse_fusion_library, write_fusion_library_json, MM_PER_INCH
from fusion2masso.mapping import merge, ChangeKind

FIXTURES = Path(__file__).parent / "fixtures"
REAL_HTG = FIXTURES / "MASSO_Mill_Tools.htg"
REAL_FUSION = FIXTURES / "Tool-Library.tools"


# ---- MASSO round-trip tests ----


def test_round_trip_real_file():
    """Load a real .htg, re-serialize, assert byte-identical."""
    ref = REAL_HTG.read_bytes()
    tf = MassoToolFile.from_bytes(ref)
    out = tf.to_bytes()
    assert ref == out, "Round-trip failed — output differs from input"


def test_real_file_decoded_values():
    """Check known values from the real .htg."""
    tf = MassoToolFile.load(str(REAL_HTG))

    # Record 0: special "Dry Run-Laser Pointer"
    t0 = tf.tools[0]
    assert t0.name == "Dry Run-Laser Pointer"
    assert t0.crc_override == 0  # record 0 CRC is always 0

    # Record 4: "1/8 Endmill Up", slot 4, diameter 3.175 mm
    t4 = tf.tools[4]
    assert t4.name == "1/8 Endmill Up"
    assert t4.slot == 4
    assert math.isclose(t4.diameter, 3.175, rel_tol=1e-3)
    assert t4.z_offset < 0  # has a real Z offset

    # Record 3: "90 V Cut", slot 3, diameter 12.7 mm
    t3 = tf.tools[3]
    assert t3.name == "90 V Cut"
    assert t3.slot == 3
    assert math.isclose(t3.diameter, 12.7, rel_tol=1e-3)


def test_empty_file_round_trip():
    """An empty MassoToolFile serializes correctly and round-trips."""
    tf = MassoToolFile()
    data = tf.to_bytes()
    assert len(data) == FILE_SIZE

    # Every record should be the empty sentinel (byte 57 = 0xFF, rest zero, CRC=0)
    for i in range(NUM_RECORDS):
        rec = data[i * RECORD_SIZE : (i + 1) * RECORD_SIZE]
        assert rec[57] == 0xFF, f"Record {i} byte 57 should be 0xFF"
        # All other bytes zero except byte 56-57 (slot = 0x00FF)
        assert rec[:56] == bytes(56), f"Record {i} data bytes should be zero"
        assert rec[58:] == bytes(6), f"Record {i} trailing bytes should be zero"

    # Round-trip
    tf2 = MassoToolFile.from_bytes(data)
    assert tf2.to_bytes() == data


def test_synthetic_tool_crc_valid():
    """Write a hand-built tool, re-parse, confirm CRC validates."""
    tool = MassoTool(name="Test Tool", z_offset=-50.0, diameter=6.35, slot=10)
    raw = tool.to_bytes()
    assert len(raw) == RECORD_SIZE

    # Re-parse (CRC validation happens in from_bytes)
    parsed = MassoTool.from_bytes(raw)
    assert parsed.name == "Test Tool"
    assert math.isclose(parsed.z_offset, -50.0, abs_tol=1e-4)
    assert math.isclose(parsed.diameter, 6.35, abs_tol=1e-4)
    assert parsed.slot == 10


def test_empty_record_is_detected():
    tf = MassoToolFile()
    assert tf.tools[50].is_empty


# ---- Fusion parser tests ----


def test_parse_fusion_tools_zip():
    """Parse a real .tools ZIP file."""
    if not REAL_FUSION.exists():
        pytest.skip("No fixture .tools file")
    tools = parse_fusion_library(str(REAL_FUSION))
    assert len(tools) > 0
    # First tool should have a number and diameter
    numbered = [t for t in tools if t.number is not None]
    assert len(numbered) > 0
    assert numbered[0].diameter > 0


def test_parse_fusion_json():
    """Parse a plain JSON Fusion library."""
    lib = {
        "data": [
            {
                "description": "Quarter Inch Endmill",
                "geometry": {"DC": 0.25},
                "post-process": {"number": 5},
                "unit": "inches",
            },
            {
                "description": "6mm Ball",
                "geometry": {"DC": 6.0},
                "post-process": {"number": 10},
                "unit": "millimeters",
            },
            {
                "description": "No Number Tool",
                "geometry": {"DC": 3.0},
                "post-process": {},
            },
        ]
    }
    with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as f:
        json.dump(lib, f)
        f.flush()
        tools = parse_fusion_library(f.name)

    assert len(tools) == 3
    assert tools[0].name == "Quarter Inch Endmill"
    assert tools[0].number == 5
    assert tools[0].unit == "in"
    assert math.isclose(tools[0].diameter, 0.25)

    assert tools[1].unit == "mm"
    assert tools[1].number == 10

    assert tools[2].number is None


def test_parse_fusion_unit_from_expressions():
    """Detect unit from expressions.tool_diameter when unit field is missing."""
    lib = {
        "data": [
            {
                "description": "Expr Tool",
                "geometry": {"DC": 0.125},
                "post-process": {"number": 1},
                "expressions": {"tool_diameter": "0.125 in"},
            }
        ]
    }
    with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as f:
        json.dump(lib, f)
        f.flush()
        tools = parse_fusion_library(f.name)

    assert tools[0].unit == "in"


def test_parse_fusion_zip_manual():
    """Create a ZIP .tools file manually and parse it."""
    lib = {"data": [{"description": "Zip Tool", "geometry": {"DC": 10}, "post-process": {"number": 3}}]}
    buf = BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("tools.json", json.dumps(lib))
    with tempfile.NamedTemporaryFile(suffix=".tools", delete=False) as f:
        f.write(buf.getvalue())
        f.flush()
        tools = parse_fusion_library(f.name)

    assert len(tools) == 1
    assert tools[0].name == "Zip Tool"
    assert tools[0].number == 3


# ---- Merge tests ----


def _make_masso_with_tool(num: int, name: str, z: float, diameter: float, slot: int) -> MassoToolFile:
    mf = MassoToolFile()
    mf.tools[num] = MassoTool(name=name, z_offset=z, diameter=diameter, slot=slot)
    return mf


def test_merge_unchanged():
    """Same name + same diameter → UNCHANGED, Z preserved."""
    mf = _make_masso_with_tool(5, "My Endmill", -50.0, 6.35, 5)
    ft = [FusionTool(name="My Endmill", number=5, diameter=6.35, unit="mm")]
    report = merge(ft, mf)

    assert len(report.by_kind(ChangeKind.UNCHANGED)) == 1
    assert math.isclose(mf.tools[5].z_offset, -50.0)


def test_merge_replaced():
    """Different name at same slot → REPLACED, Z preserved."""
    mf = _make_masso_with_tool(5, "Old Tool", -75.0, 6.35, 5)
    ft = [FusionTool(name="New Tool", number=5, diameter=6.35, unit="mm")]
    report = merge(ft, mf)

    replaced = report.by_kind(ChangeKind.REPLACED)
    assert len(replaced) == 1
    assert "RE-PROBE" in replaced[0].reason
    assert math.isclose(mf.tools[5].z_offset, -75.0)  # Z preserved
    assert mf.tools[5].name == "New Tool"


def test_merge_added():
    """Empty target slot → ADDED, Z = 0."""
    mf = MassoToolFile()
    ft = [FusionTool(name="Brand New", number=10, diameter=3.175, unit="mm")]
    report = merge(ft, mf)

    assert len(report.by_kind(ChangeKind.ADDED)) == 1
    assert mf.tools[10].name == "Brand New"
    assert mf.tools[10].z_offset == 0.0
    assert math.isclose(mf.tools[10].diameter, 3.175)


def test_merge_skip_zero():
    """Tool number 0 → SKIPPED."""
    mf = MassoToolFile()
    ft = [FusionTool(name="Bad Tool", number=0, diameter=1.0, unit="mm")]
    report = merge(ft, mf)

    skipped = report.by_kind(ChangeKind.SKIPPED)
    assert len(skipped) == 1
    assert "reserved" in skipped[0].reason


def test_merge_inch_to_mm_conversion():
    """Inch Fusion tool merged into mm MASSO → diameter converted."""
    mf = MassoToolFile()
    ft = [FusionTool(name="Quarter Inch", number=7, diameter=0.25, unit="in")]
    report = merge(ft, mf, masso_units="mm")

    assert len(report.by_kind(ChangeKind.ADDED)) == 1
    assert math.isclose(mf.tools[7].diameter, 6.35, abs_tol=0.001)


def test_merge_result_valid_htg():
    """After merge, the result must be a valid .htg — re-parse validates CRC."""
    mf = MassoToolFile.load(str(REAL_HTG))
    original_t4_z = mf.tools[4].z_offset

    ft = [
        FusionTool(name="New Tool At 20", number=20, diameter=8.0, unit="mm"),
    ]
    report = merge(ft, mf)
    assert len(report.by_kind(ChangeKind.ADDED)) == 1

    # Serialize and re-parse (CRC validation happens in from_bytes)
    data = mf.to_bytes()
    assert len(data) == FILE_SIZE
    mf2 = MassoToolFile.from_bytes(data)

    # New tool present
    assert mf2.tools[20].name == "New Tool At 20"
    assert math.isclose(mf2.tools[20].diameter, 8.0, abs_tol=0.001)

    # Existing tool (T4) unchanged
    assert mf2.tools[4].name == "1/8 Endmill Up"
    assert math.isclose(mf2.tools[4].z_offset, original_t4_z)


def test_merge_duplicate_number():
    """Duplicate post-process number → second occurrence skipped with warning."""
    mf = MassoToolFile()
    ft = [
        FusionTool(name="First", number=5, diameter=3.0, unit="mm"),
        FusionTool(name="Duplicate", number=5, diameter=4.0, unit="mm"),
    ]
    report = merge(ft, mf)

    assert len(report.by_kind(ChangeKind.ADDED)) == 1
    assert len(report.by_kind(ChangeKind.SKIPPED)) == 1
    assert len(report.warnings) == 1
    assert "Duplicate" in report.warnings[0]


def test_merge_out_of_range():
    """Number >= 105 → SKIPPED."""
    mf = MassoToolFile()
    ft = [FusionTool(name="Big Number", number=200, diameter=1.0, unit="mm")]
    report = merge(ft, mf)

    assert len(report.by_kind(ChangeKind.SKIPPED)) == 1
    assert "out of range" in report.by_kind(ChangeKind.SKIPPED)[0].reason


def test_merge_updated_diameter():
    """Same name, different diameter → UPDATED, Z preserved."""
    mf = _make_masso_with_tool(5, "My Endmill", -50.0, 6.35, 5)
    ft = [FusionTool(name="My Endmill", number=5, diameter=8.0, unit="mm")]
    report = merge(ft, mf)

    updated = report.by_kind(ChangeKind.UPDATED)
    assert len(updated) == 1
    assert math.isclose(mf.tools[5].z_offset, -50.0)
    assert math.isclose(mf.tools[5].diameter, 8.0)


# ---- CLI smoke test ----


def test_cli_inspect(capsys):
    """CLI inspect subcommand runs without error."""
    from fusion2masso.cli import main

    main(["inspect", str(REAL_HTG)])
    out = capsys.readouterr().out
    assert "1/8 Endmill Up" in out
    assert "90 V Cut" in out


def test_cli_merge_dry_run(capsys):
    """CLI merge --dry-run runs without error."""
    if not REAL_FUSION.exists():
        pytest.skip("No fixture .tools file")
    from fusion2masso.cli import main

    main(["merge", str(REAL_FUSION), "--masso", str(REAL_HTG), "--dry-run"])
    out = capsys.readouterr().out
    assert "dry run" in out.lower()


# ---- Fusion write-back tests ----


def test_fusion_tool_has_guid():
    """Parsed Fusion tools have guid and raw_json."""
    if not REAL_FUSION.exists():
        pytest.skip("No fixture .tools file")
    tools = parse_fusion_library(str(REAL_FUSION))
    assert all(t.guid for t in tools), "Every tool should have a guid"
    assert all(t.raw_json is not None for t in tools), "Every tool should have raw_json"


def test_fusion_guid_in_json_parser():
    """guid is parsed from JSON library entries."""
    lib = {
        "data": [
            {
                "description": "Test Tool",
                "guid": "abc-123-def",
                "geometry": {"DC": 6.0},
                "post-process": {"number": 5},
            }
        ]
    }
    with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as f:
        json.dump(lib, f)
        f.flush()
        tools = parse_fusion_library(f.name)

    assert tools[0].guid == "abc-123-def"
    assert tools[0].raw_json is not None
    assert tools[0].raw_json["guid"] == "abc-123-def"


def test_merge_populates_fusion_guid():
    """Merge report Change objects include fusion_guid."""
    mf = MassoToolFile()
    ft = [FusionTool(name="Test", number=5, diameter=3.0, unit="mm", guid="guid-42")]
    report = merge(ft, mf)

    assert report.changes[0].fusion_guid == "guid-42"


def test_write_fusion_library_json_round_trip():
    """Parse → assign numbers → write JSON → re-parse → verify numbers match."""
    lib = {
        "data": [
            {
                "description": "Tool A",
                "guid": "guid-a",
                "geometry": {"DC": 6.0, "SFDM": 6.0, "LCF": 20.0},
                "post-process": {"number": 1, "comment": "original"},
                "unit": "millimeters",
                "vendor": "ACME",
            },
            {
                "description": "Tool B",
                "guid": "guid-b",
                "geometry": {"DC": 3.175},
                "post-process": {"number": 1},
                "unit": "millimeters",
            },
        ]
    }
    with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as f:
        json.dump(lib, f)
        f.flush()
        tools = parse_fusion_library(f.name)

    # Assign new numbers
    tools[0].number = 10
    tools[1].number = 20

    # Write
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as out:
        write_fusion_library_json(tools, out.name)
        # Re-parse
        tools2 = parse_fusion_library(out.name)

    assert tools2[0].number == 10
    assert tools2[1].number == 20
    assert tools2[0].name == "Tool A"
    assert tools2[1].name == "Tool B"
    # Verify other fields preserved
    assert tools2[0].raw_json["vendor"] == "ACME"
    assert tools2[0].raw_json["post-process"]["comment"] == "original"
    assert tools2[0].raw_json["geometry"]["LCF"] == 20.0


def test_write_fusion_library_preserves_all_fields():
    """raw_json fields beyond what FusionTool parses are preserved in write-back."""
    lib = {
        "data": [
            {
                "description": "Full Tool",
                "guid": "guid-full",
                "geometry": {"DC": 6.35, "SFDM": 6.35, "LCF": 25.4, "NOF": 2},
                "post-process": {"number": 1, "break-control": False, "live": True},
                "start-values": {"presets": [{"n": 10000, "f": 1000}]},
                "BMC": "carbide",
                "type": "flat end mill",
                "unit": "millimeters",
            }
        ]
    }
    with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as f:
        json.dump(lib, f)
        f.flush()
        tools = parse_fusion_library(f.name)

    tools[0].number = 42

    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as out:
        write_fusion_library_json(tools, out.name)
        result = json.loads(Path(out.name).read_text())

    entry = result["data"][0]
    assert entry["post-process"]["number"] == 42
    assert entry["BMC"] == "carbide"
    assert entry["start-values"]["presets"][0]["n"] == 10000
    assert entry["geometry"]["NOF"] == 2
    assert entry["post-process"]["break-control"] is False


def test_cli_merge_sync_fusion_json(capsys, tmp_path):
    """CLI merge with --sync-fusion-json writes updated library."""
    if not REAL_FUSION.exists():
        pytest.skip("No fixture .tools file")
    from fusion2masso.cli import main

    out_htg = str(tmp_path / "out.htg")
    out_json = str(tmp_path / "synced.json")
    main([
        "merge", str(REAL_FUSION),
        "--masso", str(REAL_HTG),
        "-o", out_htg,
        "--sync-fusion-json", out_json,
    ])

    # Verify JSON was written and has tools
    synced = json.loads(Path(out_json).read_text())
    assert len(synced["data"]) > 0
    # Tool numbers should match what was in the source
    for entry in synced["data"]:
        assert "number" in entry.get("post-process", {})


# ---- body_length and z_mode tests ----


def test_body_length_parsed():
    """FusionTool.body_length is parsed from geometry.LB."""
    lib = {
        "data": [
            {
                "description": "Endmill",
                "geometry": {"DC": 6.35, "LB": 22.86},
                "post-process": {"number": 1},
                "unit": "millimeters",
            }
        ]
    }
    with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as f:
        json.dump(lib, f)
        f.flush()
        tools = parse_fusion_library(f.name)

    assert math.isclose(tools[0].body_length, 22.86)
    assert math.isclose(tools[0].body_length_mm, 22.86)


def test_body_length_inch_conversion():
    """body_length_mm converts inches to mm."""
    t = FusionTool(name="Test", number=1, diameter=0.25, unit="in", body_length=0.9)
    assert math.isclose(t.body_length_mm, 0.9 * 25.4, abs_tol=0.01)


def test_z_mode_zero():
    """z_mode='zero' sets all Z offsets to 0."""
    mf = _make_masso_with_tool(5, "My Endmill", -50.0, 6.35, 5)
    ft = [FusionTool(name="My Endmill", number=5, diameter=6.35, unit="mm")]
    report = merge(ft, mf, z_mode="zero")

    assert mf.tools[5].z_offset == 0.0
    # Z changed from -50 to 0, so it's UPDATED not UNCHANGED
    assert len(report.by_kind(ChangeKind.UPDATED)) == 1
    assert "Z offset" in report.by_kind(ChangeKind.UPDATED)[0].reason


def test_z_mode_zero_on_added():
    """z_mode='zero' sets Z=0 for new tools (same as default)."""
    mf = MassoToolFile()
    ft = [FusionTool(name="New", number=10, diameter=3.0, unit="mm", body_length=20.0)]
    merge(ft, mf, z_mode="zero")
    assert mf.tools[10].z_offset == 0.0


def test_z_mode_fusion_length():
    """z_mode='fusion_length' uses -body_length as Z offset."""
    mf = MassoToolFile()
    ft = [FusionTool(name="Endmill", number=10, diameter=6.35, unit="mm", body_length=22.86)]
    merge(ft, mf, z_mode="fusion_length", masso_units="mm")
    assert math.isclose(mf.tools[10].z_offset, -22.86, abs_tol=0.01)


def test_z_mode_fusion_length_inch_to_mm():
    """z_mode='fusion_length' converts inches to mm."""
    mf = MassoToolFile()
    ft = [FusionTool(name="Quarter", number=7, diameter=0.25, unit="in", body_length=0.9)]
    merge(ft, mf, z_mode="fusion_length", masso_units="mm")
    assert math.isclose(mf.tools[7].z_offset, -0.9 * 25.4, abs_tol=0.01)


def test_z_mode_fusion_length_overwrites_existing():
    """z_mode='fusion_length' overwrites existing Z on occupied slots."""
    mf = _make_masso_with_tool(5, "Old Name", -99.0, 6.35, 5)
    ft = [FusionTool(name="New Name", number=5, diameter=6.35, unit="mm", body_length=30.0)]
    merge(ft, mf, z_mode="fusion_length")
    assert math.isclose(mf.tools[5].z_offset, -30.0, abs_tol=0.01)


def test_z_mode_preserve_keeps_existing():
    """z_mode='preserve' (default) keeps existing Z on occupied slots."""
    mf = _make_masso_with_tool(5, "Old", -75.0, 6.35, 5)
    ft = [FusionTool(name="New", number=5, diameter=6.35, unit="mm", body_length=30.0)]
    merge(ft, mf, z_mode="preserve")
    assert math.isclose(mf.tools[5].z_offset, -75.0)
