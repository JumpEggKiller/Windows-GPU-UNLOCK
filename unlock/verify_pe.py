"""Validate the built executable, rather than infer properties from linker flags."""
import argparse
import hashlib
import json
import re
import struct
from pathlib import Path

def write_checksum(path):
    """Store the PE checksum the Windows loader verifies and lld-link leaves zero.

    Separate from inspect() on purpose: verification must be able to fail, so the repair
    is an explicit step a build script asks for, never a side effect of checking.
    """
    data = bytearray(Path(path).read_bytes())
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    optional = pe + 24
    struct.pack_into('<I', data, optional + 64, 0)
    total = 0
    for offset in range(0, len(data) - (len(data) % 2), 2):
        total += struct.unpack_from('<H', data, offset)[0]
        total = (total & 0xffff) + (total >> 16)
    if len(data) % 2:
        total += data[-1]
        total = (total & 0xffff) + (total >> 16)
    total = (total & 0xffff) + (total >> 16)
    value = (total + len(data)) & 0xffffffff
    struct.pack_into('<I', data, optional + 64, value)
    Path(path).write_bytes(bytes(data))
    return value

def inspect(path, map_path, boot_application=False):
    data = Path(path).read_bytes()
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    def u16(at): return struct.unpack_from('<H', data, at)[0]
    def u32(at): return struct.unpack_from('<I', data, at)[0]
    require(data[:2] == b'MZ', 'DOS signature')
    pe = u32(0x3c)
    require(data[pe:pe+4] == b'PE\0\0', 'PE signature')
    require(u16(pe+4) == 0x8664, 'must be AMD64')
    optional = pe+24
    require(u16(optional) == 0x20b, 'must be PE32+')
    subsystem = u16(optional+68)
    image_base = struct.unpack_from('<Q', data, optional+24)[0]
    characteristics = u16(optional+70)
    if boot_application:
        # An image the Windows boot manager is asked to start from a BCD entry is a
        # boot application (IMAGE_SUBSYSTEM_WINDOWS_BOOT_APPLICATION, 16), mapped at
        # a real preferred base, exactly like the memtest.efi that ships next to
        # bootmgfw.efi. The boot manager route is closed for our own images (0xC0000428,
        # untrusted signature), but the shape stays checkable for its own tests.
        require(subsystem == 16, 'must be a Windows boot application (subsystem 16)')
        require(image_base != 0 and image_base % 0x10000 == 0,
                'boot application needs a page aligned non-zero image base')
    else:
        require(subsystem == 10, 'must be EFI application')
        require(image_base == 0, 'expected image base 0')
        require(characteristics & 0x140 == 0x140, 'ASLR and NX flags required')
    # The Windows loader verifies the PE checksum and reports 0xC0000221
    # (STATUS_IMAGE_CHECKSUM_MISMATCH) for a zero or stale one; lld-link leaves it zero.
    # Firmware does not care, but an image that cannot be started by every loader on this
    # machine is a trap for the next person, so every image we build must be correct.
    stored = u32(optional+64)
    body = bytearray(data)
    struct.pack_into('<I', body, optional+64, 0)
    total = 0
    for offset in range(0, len(body) - (len(body) % 2), 2):
        total += struct.unpack_from('<H', body, offset)[0]
        total = (total & 0xffff) + (total >> 16)
    if len(body) % 2:
        total += body[-1]
        total = (total & 0xffff) + (total >> 16)
    total = (total & 0xffff) + (total >> 16)
    computed = (total + len(body)) & 0xffffffff
    require(stored != 0, 'image must carry a PE checksum')
    require(stored == computed,
            'PE checksum does not match the image (0x%08x != 0x%08x)' % (stored, computed))
    entry = u32(optional+16)
    require(entry != 0, 'entry point missing')
    require(u32(optional+108) >= 16, 'data directory missing')
    for index, name in [(1, 'imports'), (12, 'IAT'), (13, 'delay imports')]:
        require(data[optional+112+8*index:optional+120+8*index] == b'\0'*8, name)
    require(u32(optional+112+8*5+4) != 0, 'relocations missing')
    table = optional+u16(pe+20)
    executable_entry = False
    for i in range(u16(pe+6)):
        at = table+40*i
        if u32(at+12) <= entry < u32(at+12)+u32(at+8):
            executable_entry = bool(u32(at+36) & 0x20000000)
    require(executable_entry, 'entry must be in executable section')
    text = Path(map_path).read_text()
    found = re.search(r'^\s*[0-9A-Fa-f]+:[0-9A-Fa-f]+\s+efi_main\s+([0-9A-Fa-f]+)', text, re.M)
    # The map lists absolute virtual addresses, so subtract the preferred base to get
    # the entry RVA the header carries. With image base 0 this is the old comparison.
    require(found and int(found[1], 16) - image_base == entry, 'entry does not match efi_main map symbol')
    return dict(path=Path(path).name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                machine='AMD64', subsystem=subsystem, entry='efi_main', entry_rva=entry,
                image_base=image_base, dll_characteristics=characteristics,
                imports=0, iat=0, delay_imports=0,
                nx=bool(characteristics & 0x100), dynamic_base=bool(characteristics & 0x40))

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('efi'); p.add_argument('map'); p.add_argument('--output', required=True)
    p.add_argument('--boot-application', action='store_true',
                   help='the image is started by the Windows boot manager, so it must be '
                        'a subsystem 16 boot application with a non-zero image base')
    p.add_argument('--write-checksum', action='store_true',
                   help='store the PE checksum before verifying (lld-link leaves it zero)')
    a = p.parse_args()
    if a.write_checksum:
        print('%s: checksum 0x%08x written' % (Path(a.efi).name, write_checksum(a.efi)))
    result = inspect(a.efi, a.map, a.boot_application)
    Path(a.output).write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))
