"""fitlib - a tiny, dependency-free FIT reader/writer.

Why hand-rolled instead of fit-tool / garmin-fit-sdk encoders?
  * We need to emit *undocumented* field numbers exactly the way a Venu 2S does
    (e.g. set field 2, record fields 135/136/143) - profile-driven encoders refuse
    or drop fields they don't know.
  * We need byte-level control over message order and local-message numbering so
    the output "fingerprint" (see fit_fingerprint.py) looks like the watch's own.
  * Zero dependencies keeps the porting script lightweight (stdlib only).

Only what an activity file needs is implemented: normal headers, definition
messages, little-endian, no developer fields on write (reading skips them),
and the CRC. Compressed-timestamp headers are understood on read.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field
from typing import Any, Iterable

FIT_EPOCH_OFFSET = 631065600  # seconds between 1970-01-01 and 1989-12-31 (FIT epoch)

# base type id -> (struct code, size, invalid value)
BASE_TYPES = {
    0x00: ("B", 1, 0xFF),        # enum
    0x01: ("b", 1, 0x7F),        # sint8
    0x02: ("B", 1, 0xFF),        # uint8
    0x83: ("h", 2, 0x7FFF),      # sint16
    0x84: ("H", 2, 0xFFFF),      # uint16
    0x85: ("i", 4, 0x7FFFFFFF),  # sint32
    0x86: ("I", 4, 0xFFFFFFFF),  # uint32
    0x07: ("s", 1, 0x00),        # string (size = byte length)
    0x88: ("f", 4, None),        # float32
    0x89: ("d", 8, None),        # float64
    0x0A: ("B", 1, 0x00),        # uint8z
    0x8B: ("H", 2, 0x0000),      # uint16z
    0x8C: ("I", 4, 0x00000000),  # uint32z
    0x0D: ("B", 1, 0xFF),        # byte
    0x8E: ("q", 8, 0x7FFFFFFFFFFFFFFF),  # sint64
    0x8F: ("Q", 8, 0xFFFFFFFFFFFFFFFF),  # uint64
    0x90: ("Q", 8, 0x0000000000000000),  # uint64z
}
# friendly aliases used by the writer
ENUM, SINT8, UINT8, SINT16, UINT16, SINT32, UINT32 = 0x00, 0x01, 0x02, 0x83, 0x84, 0x85, 0x86
STRING, FLOAT32, UINT8Z, UINT16Z, UINT32Z, BYTE = 0x07, 0x88, 0x0A, 0x8B, 0x8C, 0x0D

_CRC_TABLE = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
              0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]


def crc16(data: bytes, crc: int = 0) -> int:
    for byte in data:
        tmp = _CRC_TABLE[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ _CRC_TABLE[byte & 0xF]
        tmp = _CRC_TABLE[crc & 0xF]
        crc = (crc >> 4) & 0x0FFF
        crc = crc ^ tmp ^ _CRC_TABLE[(byte >> 4) & 0xF]
    return crc


def unix_to_fit(ts: float) -> int:
    return int(ts) - FIT_EPOCH_OFFSET


def fit_to_unix(ts: int) -> int:
    return ts + FIT_EPOCH_OFFSET


def deg_to_semicircles(deg: float) -> int:
    return int(round(deg * (2 ** 31) / 180.0))


def semicircles_to_deg(sc: int) -> float:
    return sc * 180.0 / (2 ** 31)


# --------------------------------------------------------------------------- read

@dataclass
class FieldDef:
    num: int
    size: int
    base: int


@dataclass
class Definition:
    local: int
    global_num: int
    little_endian: bool
    fields: list[FieldDef]
    dev_fields: list[tuple[int, int, int]] = field(default_factory=list)


@dataclass
class Message:
    global_num: int
    local: int
    fields: dict[int, Any]
    definition: Definition


@dataclass
class FitFile:
    header_size: int
    protocol_version: int
    profile_version: int
    data_size: int
    crc_ok: bool
    events: list  # ordered list of ("def", Definition) | ("msg", Message)

    @property
    def messages(self) -> list[Message]:
        return [e for k, e in self.events if k == "msg"]

    def by_num(self, num: int) -> list[Message]:
        return [m for m in self.messages if m.global_num == num]


def _decode_value(raw: bytes, fd: FieldDef, le: bool):
    code, size, invalid = BASE_TYPES.get(fd.base, ("B", 1, 0xFF))
    if code == "s":
        s = raw.split(b"\x00", 1)[0]
        return s.decode("utf-8", "replace") if s else None
    n = fd.size // size if size else 0
    if n == 0:
        return raw  # malformed size; hand back the bytes
    vals = list(struct.unpack(("<" if le else ">") + code * n, raw[: n * size]))
    if invalid is not None:
        vals = [None if v == invalid else v for v in vals]
    return vals[0] if n == 1 else vals


def read_fit(path_or_bytes) -> FitFile:
    data = path_or_bytes if isinstance(path_or_bytes, (bytes, bytearray)) else open(path_or_bytes, "rb").read()
    hsize = data[0]
    proto = data[1]
    profile = struct.unpack("<H", data[2:4])[0]
    dsize = struct.unpack("<I", data[4:8])[0]
    if data[8:12] != b".FIT":
        raise ValueError("not a FIT file")
    end = hsize + dsize
    crc_ok = crc16(data[:end]) == struct.unpack("<H", data[end:end + 2])[0]
    defs: dict[int, Definition] = {}
    events: list = []
    pos = hsize
    last_ts = None
    while pos < end:
        h = data[pos]; pos += 1
        if h & 0x80:  # compressed timestamp header
            local = (h >> 5) & 0x3
            offset = h & 0x1F
            d = defs[local]
            vals, pos = _read_data(data, pos, d)
            if last_ts is not None:
                ts = (last_ts & ~0x1F) + offset
                if offset < (last_ts & 0x1F):
                    ts += 0x20
                vals[253] = ts
                last_ts = ts
            events.append(("msg", Message(d.global_num, local, vals, d)))
            continue
        local = h & 0x0F
        if h & 0x40:  # definition
            has_dev = bool(h & 0x20)
            arch = data[pos + 1]
            le = arch == 0
            gnum = struct.unpack("<H" if le else ">H", data[pos + 2:pos + 4])[0]
            nf = data[pos + 4]
            pos += 5
            fds = []
            for _ in range(nf):
                fds.append(FieldDef(data[pos], data[pos + 1], data[pos + 2]))
                pos += 3
            devs = []
            if has_dev:
                nd = data[pos]; pos += 1
                for _ in range(nd):
                    devs.append((data[pos], data[pos + 1], data[pos + 2]))
                    pos += 3
            d = Definition(local, gnum, le, fds, devs)
            defs[local] = d
            events.append(("def", d))
        else:
            d = defs[local]
            vals, pos = _read_data(data, pos, d)
            if 253 in vals and vals[253] is not None:
                last_ts = vals[253]
            events.append(("msg", Message(d.global_num, local, vals, d)))
    return FitFile(hsize, proto, profile, dsize, crc_ok, events)


def _read_data(data: bytes, pos: int, d: Definition):
    vals: dict[int, Any] = {}
    for fd in d.fields:
        vals[fd.num] = _decode_value(data[pos:pos + fd.size], fd, d.little_endian)
        pos += fd.size
    for (_num, size, _idx) in d.dev_fields:
        pos += size
    return vals, pos


# -------------------------------------------------------------------------- write

class FitWriter:
    """Writes messages with explicit (field_num, base_type, value) tuples.

    A definition is (re)emitted whenever the field layout for a given global
    message changes, re-using local message numbers round-robin like a device
    does. Values may be scalars, lists (arrays) or str (strings).
    """

    def __init__(self, protocol_version: int = 0x10, profile_version: int = 21115):
        self.protocol_version = protocol_version
        self.profile_version = profile_version
        self._body = bytearray()
        self._layouts: dict[int, tuple] = {}   # local -> layout signature
        self._local_for: dict[tuple, int] = {}  # layout -> local
        self._next_local = 0

    @staticmethod
    def _encode(base: int, value, size_hint: int | None = None) -> bytes:
        code, size, invalid = BASE_TYPES[base]
        if code == "s":
            b = (value or "").encode("utf-8") + b"\x00"
            if size_hint:
                b = b[:size_hint].ljust(size_hint, b"\x00")
            return b
        vals = value if isinstance(value, (list, tuple)) else [value]
        out = bytearray()
        for v in vals:
            if v is None:
                v = invalid if invalid is not None else float("nan")
            out += struct.pack("<" + code, v)
        return bytes(out)

    def write(self, global_num: int, fields: Iterable[tuple[int, int, Any]]):
        fields = [f for f in fields if f is not None]
        encoded = [(num, base, self._encode(base, val)) for (num, base, val) in fields]
        layout = (global_num, tuple((num, len(b), base) for num, base, b in encoded))
        local = self._local_for.get(layout)
        if local is None or self._layouts.get(local) != layout:
            local = self._next_local
            self._next_local = (self._next_local + 1) % 16
            old = self._layouts.get(local)
            if old is not None:
                self._local_for.pop(old, None)
            self._layouts[local] = layout
            self._local_for[layout] = local
            self._body.append(0x40 | local)
            self._body += struct.pack("<BBHB", 0, 0, global_num, len(encoded))
            for num, b, base in layout[1]:
                self._body += struct.pack("<BBB", num, b, base)
        self._body.append(local)
        for _, _, b in encoded:
            self._body += b

    def write_sized(self, global_num: int, fields):
        """Like write(), but each field is (num, base, value, size_or_None).

        size is honoured for strings (fixed-width, like the device writes them);
        None values become the base type's invalid value; NaN/None floats are
        written as 0xFFFFFFFF (FIT's float invalid), matching device output.
        """
        enc = []
        for num, base, val, size in fields:
            code = BASE_TYPES[base][0]
            if isinstance(val, (bytes, bytearray)):
                b = bytes(val)
            elif code in ("f", "d"):
                vals = val if isinstance(val, (list, tuple)) else [val]
                b = b"".join(
                    (b"\xff" * BASE_TYPES[base][1]) if (v is None or v != v) else struct.pack("<" + code, v)
                    for v in vals)
            else:
                b = self._encode(base, val, size if code == "s" else None)
            enc.append((num, base, b))
        self._write_encoded(global_num, enc)

    def _write_encoded(self, global_num, encoded):
        layout = (global_num, tuple((num, len(b), base) for num, base, b in encoded))
        local = self._local_for.get(layout)
        if local is None or self._layouts.get(local) != layout:
            local = self._next_local
            self._next_local = (self._next_local + 1) % 16
            old = self._layouts.get(local)
            if old is not None:
                self._local_for.pop(old, None)
            self._layouts[local] = layout
            self._local_for[layout] = local
            self._body.append(0x40 | local)
            self._body += struct.pack("<BBHB", 0, 0, global_num, len(encoded))
            for num, b, base in layout[1]:
                self._body += struct.pack("<BBB", num, b, base)
        self._body.append(local)
        for _, _, b in encoded:
            self._body += b

    def to_bytes(self) -> bytes:
        header = struct.pack("<BBHI4s", 14, self.protocol_version, self.profile_version,
                             len(self._body), b".FIT")
        header += struct.pack("<H", crc16(header))
        out = header + bytes(self._body)
        return out + struct.pack("<H", crc16(out))
