#!/usr/bin/env python3
"""Create boot.img in v3/v4 (GKI) format with proper AOSP header.

Standard boot_img_hdr_v3 layout:
  offset 0:    magic[8] = "ANDROID!"
  offset 8:    kernel_size (uint32)
  offset 12:   ramdisk_size (uint32)
  offset 16:   os_version (uint32)
  offset 20:   header_size (uint32)
  offset 24:   reserved[4] (16 bytes, uint32 x 4)
  offset 40:   header_version (uint32) = 3 or 4
  offset 44:   cmdline[1536]
  offset 1580: recovery_dtbo_size (uint32)
  offset 1584: recovery_dtbo_offset (uint64)
  Total struct size: 1592 bytes
  Page size for v3/v4: 4096
"""
import struct
import json
import os

PAGE_SIZE = 4096
HEADER_SIZE = 1592  # sizeof(boot_img_hdr_v3)
BOOT_MAGIC = b'ANDROID!'
BOOT_ARGS_SIZE = 512
BOOT_EXTRA_ARGS_SIZE = 1024
CMDLINE_SIZE = BOOT_ARGS_SIZE + BOOT_EXTRA_ARGS_SIZE  # 1536

KERNEL_PATH = '/workspace/kernel/arch/arm/boot/zImage'
RAMDISK_PATH = '/workspace/ramdisk.cpio.gz'

CMDLINE = (
    'console=tty0 console=ttyMT3,921600n1 root=/dev/ram '
    'vmalloc=496M slub_max_order=0 '
    'androidboot.hardware=mt6765 '
    'androidboot.product.device=mexico'
)

# Android 10, security patch 2021-10
OS_VERSION = 10
OS_PATCH_LEVEL_YEAR = 2021
OS_PATCH_LEVEL_MONTH = 10


def calc_os_version_field():
    """Encode OS version and patch level into uint32."""
    version = (OS_VERSION << 14) | (0 << 7) | 0
    patch = ((OS_PATCH_LEVEL_YEAR - 2000) << 4) | OS_PATCH_LEVEL_MONTH
    return (version << 11) | patch


def pad_to(data, page_size):
    """Pad data to page boundary."""
    pad_len = (page_size - (len(data) % page_size)) % page_size
    return data + b'\x00' * pad_len


def make_boot_header(version, kernel_size, ramdisk_size):
    """Build AOSP boot_img_hdr_v3/v4 header (1592 bytes)."""
    header = b''
    header += BOOT_MAGIC                              # offset 0, 8 bytes
    header += struct.pack('<I', kernel_size)           # offset 8, 4 bytes
    header += struct.pack('<I', ramdisk_size)          # offset 12, 4 bytes
    header += struct.pack('<I', calc_os_version_field())  # offset 16, 4 bytes
    header += struct.pack('<I', HEADER_SIZE)           # offset 20, 4 bytes
    header += struct.pack('<4I', 0, 0, 0, 0)          # offset 24, 16 bytes (reserved[4])
    header += struct.pack('<I', version)               # offset 40, 4 bytes (header_version)
    header += CMDLINE.encode('ascii')[:CMDLINE_SIZE].ljust(CMDLINE_SIZE, b'\x00')  # offset 44, 1536 bytes
    header += struct.pack('<I', 0)                     # offset 1580, 4 bytes (recovery_dtbo_size)
    header += struct.pack('<Q', 0)                     # offset 1584, 8 bytes (recovery_dtbo_offset)

    assert len(header) == HEADER_SIZE, f"Header size mismatch: {len(header)} != {HEADER_SIZE}"

    # Pad header to page boundary
    return pad_to(header, PAGE_SIZE)


def make_boot_img(version, output_path):
    """Create a v3 or v4 boot image."""
    with open(KERNEL_PATH, 'rb') as f:
        kernel = f.read()
    with open(RAMDISK_PATH, 'rb') as f:
        ramdisk = f.read()

    kernel_size = len(kernel)
    ramdisk_size = len(ramdisk)

    # Build header
    header = make_boot_header(version, kernel_size, ramdisk_size)

    # Build data (page-aligned)
    kernel_data = pad_to(kernel, PAGE_SIZE)
    ramdisk_data = pad_to(ramdisk, PAGE_SIZE)

    # Write boot image
    with open(output_path, 'wb') as f:
        f.write(header)
        f.write(kernel_data)
        f.write(ramdisk_data)

    total_size = len(header) + len(kernel_data) + len(ramdisk_data)
    print(f"  boot.img v{version}: {total_size} bytes ({total_size/1024/1024:.1f} MB)")
    print(f"  header_version at offset 40 = {version}")
    print(f"  kernel: {kernel_size} bytes at offset {len(header)}")
    print(f"  ramdisk: {ramdisk_size} bytes at offset {len(header) + len(kernel_data)}")

    return total_size


def make_offsets_json():
    """Generate offsets.json from System.map kernel symbols."""
    system_map = '/workspace/kernel/System.map'

    symbols = {}
    with open(system_map, 'r') as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) >= 3:
                addr_str = parts[0]
                sym_type = parts[1]
                sym_name = parts[2]
                symbols[sym_name] = int(addr_str, 16)

    # Kernel symbol offsets (absolute addresses from System.map)
    needed = [
        'commit_creds',
        'prepare_kernel_cred',
        'kallsyms_lookup_name',
        'init_task',
        'init_cred',
        'selinux_enforcing',
        'selinux_enabled',
        'call_usermodehelper',
    ]

    kernel_syms = {}
    for name in needed:
        if name in symbols:
            kernel_syms[name] = hex(symbols[name])

    print(f"  Symbols from System.map:")
    for name, addr in kernel_syms.items():
        print(f"    {name}: {addr}")

    # Build offsets.json in multiple formats for compatibility
    offsets = {}

    # Format 1: kernel version with "+" (as reported by device)
    offsets["4.14.141+"] = kernel_syms.copy()
    # Format 2: kernel version without "+"
    offsets["4.14.141"] = kernel_syms.copy()
    # Format 3: our compiled kernel version
    offsets["4.9.117+"] = kernel_syms.copy()
    # Format 4: default fallback
    offsets["default"] = kernel_syms.copy()

    return offsets


if __name__ == '__main__':
    print("=== Generating boot.img (v3) ===")
    make_boot_img(3, '/workspace/boot.img')

    print("\n=== Generating boot_v4.img (v4) ===")
    make_boot_img(4, '/workspace/boot_v4.img')

    print("\n=== Generating offsets.json ===")
    offsets = make_offsets_json()

    with open('/workspace/offsets.json', 'w') as f:
        json.dump(offsets, f, indent=2)
    print("  offsets.json created")

    # Verify boot.img header
    print("\n=== Verifying boot.img header ===")
    with open('/workspace/boot.img', 'rb') as f:
        data = f.read(64)
    print(f"  magic: {data[0:8]}")
    print(f"  header_version (offset 40): {struct.unpack('<I', data[40:44])[0]}")
    print(f"  header_size (offset 20): {struct.unpack('<I', data[20:24])[0]}")
    print(f"  kernel_size (offset 8): {struct.unpack('<I', data[8:12])[0]}")
