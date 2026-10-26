"""Mark a linked image as a Windows boot application.

The Windows boot manager starts the handoff wrapper from a BCD entry, and its PE loader
refuses a subsystem 10 EFI application with 0xC000007B (STATUS_INVALID_IMAGE_FORMAT) -
that is exactly how the first Gate C attempt failed. memtest.efi, which this machine's
boot manager does start from a BCD entry, is IMAGE_SUBSYSTEM_WINDOWS_BOOT_APPLICATION
(16). lld-link has no name for that value, so it is written here, after linking, and
only after the header has been checked to be the shape that value is meant for.

Firmware ignores the subsystem value, so the same bytes still load if the image is ever
started from a USB firmware entry instead.
"""
import struct
import sys
from pathlib import Path

WINDOWS_BOOT_APPLICATION = 16
EFI_APPLICATION = 10

def patch(path):
    data = bytearray(Path(path).read_bytes())
    if data[:2] != b'MZ':
        raise ValueError('DOS signature missing')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('PE signature missing')
    if struct.unpack_from('<H', data, pe + 4)[0] != 0x8664:
        raise ValueError('must be AMD64')
    optional = pe + 24
    if struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise ValueError('must be PE32+')
    at = optional + 68
    before = struct.unpack_from('<H', data, at)[0]
    if before == WINDOWS_BOOT_APPLICATION:
        return before, before
    if before != EFI_APPLICATION:
        raise ValueError('only an EFI application may be promoted; found subsystem %d' % before)
    base = struct.unpack_from('<Q', data, optional + 24)[0]
    if base == 0 or base % 0x10000:
        raise ValueError('a boot application needs a page aligned non-zero image base')
    flags = struct.unpack_from('<H', data, optional + 70)[0]
    if flags & 0x140:
        raise ValueError('a boot application must not advertise ASLR or NX placement flags')
    struct.pack_into('<H', data, at, WINDOWS_BOOT_APPLICATION)
    # memtest.efi, the reference image for this loader, carries zero placement flags.
    # HIGH_ENTROPY_VA without DYNAMIC_BASE is contradictory anyway, so clear the word
    # rather than leave a set of advisory bits that no loader here reads.
    struct.pack_into('<H', data, optional + 70, 0)
    Path(path).write_bytes(bytes(data))
    return before, WINDOWS_BOOT_APPLICATION

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: boot-application.py <image.efi>')
    old, new = patch(sys.argv[1])
    print('%s: subsystem %d -> %d' % (Path(sys.argv[1]).name, old, new))
