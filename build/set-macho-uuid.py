#!/usr/bin/env python3
"""Give a copied Mach-O its own LC_UUID.

The inbox helper is a copy of the app's executable. With the same UUID,
macOS treats the two as one program: network activity and privacy prompts
from the app are labelled with the helper's name. A UUID derived from the
helper's bundle identifier keeps them apart and is the same on every build.

usage: set-macho-uuid.py <binary> <seed>
"""
import struct
import sys
import uuid

FAT_MAGICS = {0xCAFEBABE: (">", 20, False), 0xCAFEBABF: (">", 32, True)}
THIN_MAGICS = {0xFEEDFACF: ("<", 32), 0xCFFAEDFE: (">", 32), 0xFEEDFACE: ("<", 28), 0xCEFAEDFE: (">", 28)}
LC_UUID = 0x1B


def patch_slice(data, offset, value):
    magic = struct.unpack_from("<I", data, offset)[0]
    if magic not in THIN_MAGICS:
        raise SystemExit(f"not a Mach-O slice at {offset:#x}")
    endian, header_size = THIN_MAGICS[magic]
    ncmds = struct.unpack_from(endian + "I", data, offset + 16)[0]
    cursor = offset + header_size
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(endian + "II", data, cursor)
        if cmd == LC_UUID:
            data[cursor + 8:cursor + 24] = value
            return True
        cursor += size
    return False


def main():
    path, seed = sys.argv[1], sys.argv[2]
    value = uuid.uuid5(uuid.NAMESPACE_DNS, seed).bytes
    data = bytearray(open(path, "rb").read())
    magic = struct.unpack_from(">I", data, 0)[0]
    patched = 0
    if magic in FAT_MAGICS:
        _, entry_size, is64 = FAT_MAGICS[magic]
        count = struct.unpack_from(">I", data, 4)[0]
        for index in range(count):
            entry = 8 + index * entry_size
            offset = struct.unpack_from(">Q" if is64 else ">I", data, entry + 8)[0]
            patched += patch_slice(data, offset, value)
    else:
        patched += patch_slice(data, 0, value)
    if not patched:
        raise SystemExit("no LC_UUID found")
    open(path, "wb").write(data)
    print(f"LC_UUID {uuid.UUID(bytes=value)} set in {patched} slice(s)")


if __name__ == "__main__":
    main()
