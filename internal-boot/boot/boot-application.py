"""Mark a linked image as a Windows boot application.

The Windows boot manager starts the handoff wrapper from a BCD entry, and its PE loader
refuses a subsystem 10 EFI application with 0xC000007B (STATUS_INVALID_IMAGE_FORMAT) -
that is exactly how the first Gate C attempt failed. memtest.efi, which this machine's
boot manager does start from a BCD entry, is IMAGE_SUBSYSTEM_WINDOWS_BOOT_APPLICATION
(16). lld-link has no name for that value, so it is written here, after linking, and
only after the header has been checked to be the shape that value is meant for.

Firmware ignores the subsystem value, so the same bytes still load if the image is ever
started from a USB firmware entry instead.

The second Gate C attempt failed with 0xC0000221 (STATUS_IMAGE_CHECKSUM_MISMATCH): the boot
manager does check the PE checksum, and lld-link leaves it zero unless /RELEASE is passed.
Editing the header after linking also invalidates any checksum that was there, so the value is
recomputed here, after the last byte of the image has been decided.
"""
import struct
import sys
from pathlib import Path

WINDOWS_BOOT_APPLICATION = 16
EFI_APPLICATION = 10


def compute_checksum(data):
    """The checksum the Windows loader verifies: 16-bit word sum, plus the file length."""
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    optional = pe + 24
    body = bytearray(data)
    struct.pack_into('<I', body, optional + 64, 0)
    total = 0
    size = len(body)
    for offset in range(0, size - (size % 2), 2):
        total += struct.unpack_from('<H', body, offset)[0]
        total = (total & 0xffff) + (total >> 16)
    if size % 2:
        total += body[size - 1]
        total = (total & 0xffff) + (total >> 16)
    total = (total & 0xffff) + (total >> 16)
    return (total + size) & 0xffffffff


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
    if before not in (WINDOWS_BOOT_APPLICATION, EFI_APPLICATION):
        raise ValueError('only an EFI application may be promoted; found subsystem %d' % before)
    if before == EFI_APPLICATION:
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
    # Always (re)write the checksum: an image that is already promoted may still carry
    # the zero lld-link leaves behind, and that is exactly what 0xC0000221 reports.
    checksum = compute_checksum(data)
    struct.pack_into('<I', data, optional + 64, checksum)
    Path(path).write_bytes(bytes(data))
    return before, WINDOWS_BOOT_APPLICATION

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: boot-application.py <image.efi>')
    old, new = patch(sys.argv[1])
    print('%s: subsystem %d -> %d, checksum written' % (Path(sys.argv[1]).name, old, new))

