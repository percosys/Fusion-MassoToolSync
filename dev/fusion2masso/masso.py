"""Reader/writer for the MASSO G3 Touch .htg tool table binary format."""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass, field

RECORD_SIZE = 64
NUM_RECORDS = 105       # total records in the .htg file (T0-T104)
MAX_TOOL_NUM = 104      # highest usable tool number (T1-T104; T0 is reserved)
FILE_SIZE = RECORD_SIZE * NUM_RECORDS
NAME_LEN = 40
EMPTY_SLOT = 0x00FF  # big-endian uint16 sentinel for "no slot"


def _empty_record() -> bytearray:
    """Return the canonical empty record (all zero except byte 57 = 0xFF)."""
    rec = bytearray(RECORD_SIZE)
    struct.pack_into(">H", rec, 56, EMPTY_SLOT)
    return rec


@dataclass
class MassoTool:
    """One record in a MASSO tool table."""

    name: str = ""
    z_offset: float = 0.0
    diameter: float = 0.0
    slot: int = EMPTY_SLOT
    crc_override: int | None = None  # set only for record 0

    @property
    def is_empty(self) -> bool:
        return self.slot == EMPTY_SLOT and not self.name

    def to_bytes(self) -> bytes:
        rec = bytearray(RECORD_SIZE)
        name_bytes = self.name.encode("ascii", errors="replace")[:NAME_LEN]
        rec[0 : len(name_bytes)] = name_bytes
        struct.pack_into("<f", rec, 40, self.z_offset)
        struct.pack_into("<f", rec, 52, self.diameter)
        struct.pack_into(">H", rec, 56, self.slot)
        if self.crc_override is not None:
            struct.pack_into("<I", rec, 60, self.crc_override)
        elif self.is_empty:
            pass  # CRC stays 0 for empty records
        else:
            crc = zlib.crc32(bytes(rec[:60])) & 0xFFFFFFFF
            struct.pack_into("<I", rec, 60, crc)
        return bytes(rec)

    @classmethod
    def from_bytes(cls, data: bytes, *, is_record_zero: bool = False) -> MassoTool:
        if len(data) != RECORD_SIZE:
            raise ValueError(f"Record must be {RECORD_SIZE} bytes, got {len(data)}")
        name_raw = data[0:NAME_LEN]
        name = name_raw.split(b"\x00")[0].decode("ascii", errors="replace")
        z_offset = struct.unpack_from("<f", data, 40)[0]
        diameter = struct.unpack_from("<f", data, 52)[0]
        slot = struct.unpack_from(">H", data, 56)[0]
        crc_stored = struct.unpack_from("<I", data, 60)[0]

        tool = cls(name=name, z_offset=z_offset, diameter=diameter, slot=slot)

        # Preserve original CRC for record 0 (always zero by design) and for
        # records written by the MASSO controller which may use a different
        # CRC algorithm.  When we re-serialize a tool we touched, we
        # recompute the CRC; for untouched tools the override keeps the
        # original bytes intact.
        if is_record_zero:
            tool.crc_override = crc_stored
        else:
            is_empty = slot == EMPTY_SLOT and name == ""
            if not is_empty:
                crc_calc = zlib.crc32(data[:60]) & 0xFFFFFFFF
                if crc_stored != crc_calc:
                    # MASSO controller may write its own CRC variant.
                    # Preserve the stored CRC so untouched records round-trip.
                    tool.crc_override = crc_stored

        return tool


@dataclass
class MassoToolFile:
    """The full 105-record MASSO .htg tool table."""

    tools: list[MassoTool] = field(default_factory=lambda: [])

    def __post_init__(self) -> None:
        # Pad to 105 records if needed
        while len(self.tools) < NUM_RECORDS:
            self.tools.append(MassoTool())

    @classmethod
    def from_bytes(cls, data: bytes) -> MassoToolFile:
        if len(data) != FILE_SIZE:
            raise ValueError(f".htg file must be {FILE_SIZE} bytes, got {len(data)}")
        tools: list[MassoTool] = []
        for i in range(NUM_RECORDS):
            rec = data[i * RECORD_SIZE : (i + 1) * RECORD_SIZE]
            tools.append(MassoTool.from_bytes(rec, is_record_zero=(i == 0)))
        return cls(tools=tools)

    @classmethod
    def load(cls, path: str) -> MassoToolFile:
        with open(path, "rb") as f:
            return cls.from_bytes(f.read())

    def clear_tools(self) -> None:
        """Reset all tool slots to empty, preserving record 0."""
        for i in range(1, NUM_RECORDS):
            self.tools[i] = MassoTool()

    def to_bytes(self) -> bytes:
        parts = []
        for tool in self.tools:
            parts.append(tool.to_bytes())
        return b"".join(parts)

    def save(self, path: str) -> None:
        data = self.to_bytes()
        assert len(data) == FILE_SIZE
        with open(path, "wb") as f:
            f.write(data)
