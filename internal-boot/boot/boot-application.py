"""Write the PE checksum of a linked image, and optionally promote it to subsystem 16.

Three cold boots bought the history this file records:

1. Plain EFI application shape, started from a Windows Boot Manager entry: 0xC000007B
   (STATUS_INVALID_IMAGE_FORMAT).
2. memtest.efi's shape - IMAGE_SUBSYSTEM_WINDOWS_BOOT_APPLICATION (16), a high fixed
   image base, no placement flags: the format was accepted, and the answer became
   0xC0000221 (STATUS_IMAGE_CHECKSUM_MISMATCH). The boot manager does verify the PE
   checksum, and lld-link leaves it zero unless /RELEASE is passed. Editing the header
   after linking invalidates any checksum that was there, so it is recomputed here.
3. Same image with a correct checksum: 0xC0000428 (STATUS_INVALID_IMAGE_HASH). The boot
   manager only starts images bearing a signature it trusts, which an image built here
   can never carry, so the boot manager route is closed. The wrapper is instead loaded by
   firmware from a Boot#### load option - and for firmware the plain EFI application shape
   (subsystem 10, image base 0, ASLR/NX placement flags) is the correct one.

The default action is therefore only the checksum; promotion to 16 stays available for
reference and for its own tests.
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


def patch(path, promote=False):
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
    if not promote:
        if before != EFI_APPLICATION:
            raise ValueError('a firmware-loaded wrapper must stay an EFI application (subsystem 10); found %d' % before)
        base = struct.unpack_from('<Q', data, optional + 24)[0]
        if base != 0:
            raise ValueError('a firmware-loaded wrapper must keep image base 0; found %#x' % base)
    else:
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
            # memtest.efi, the reference image for that loader, carries zero placement flags.
            # HIGH_ENTROPY_VA without DYNAMIC_BASE is contradictory anyway, so clear the word
            # rather than leave a set of advisory bits that no loader here reads.
            struct.pack_into('<H', data, optional + 70, 0)
    # Always (re)write the checksum: lld-link leaves it zero, and 0xC0000221 is what the
    # Windows loader reports for that. Recomputed after the last byte of the image is fixed.
    checksum = compute_checksum(data)
    struct.pack_into('<I', data, optional + 64, checksum)
    Path(path).write_bytes(bytes(data))
    return before, struct.unpack_from('<H', data, at)[0]

if __name__ == '__main__':
    promote = '--promote' in sys.argv[1:]
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 1:
        raise SystemExit('usage: boot-application.py [--promote] <image.efi>')
    old, new = patch(args[0], promote)
    print('%s: subsystem %d -> %d, checksum written' % (Path(args[0]).name, old, new))

