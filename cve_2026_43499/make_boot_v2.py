#!/usr/bin/env python3
"""Custom mkbootimg supporting header version 0/1/2 with DTB."""
import struct, hashlib

def pad(data, page_size):
    pad_len = (page_size - (len(data) % page_size)) % page_size
    return data + b'\x00' * pad_len

def make_bootimg(kernel_path, ramdisk_path, dtb_path, output_path,
                 base=0x40000000, kernel_offset=0x00008000,
                 ramdisk_offset=0x07000000, second_offset=0x00f00000,
                 tags_offset=0x00000100, page_size=2048,
                 header_version=2, board="", cmdline="",
                 os_version=0, os_patch_level=0):

    with open(kernel_path, 'rb') as f:
        kernel = f.read()
    with open(ramdisk_path, 'rb') as f:
        ramdisk = f.read()
    with open(dtb_path, 'rb') as f:
        dtb = f.read()

    kernel_size = len(kernel)
    ramdisk_size = len(ramdisk)
    dtb_size = len(dtb)

    kernel_addr = base + kernel_offset
    ramdisk_addr = base + ramdisk_offset
    second_addr = base + second_offset
    tags_addr = base + tags_offset

    # Calculate offsets for data sections
    num_kernel_pages = (kernel_size + page_size - 1) // page_size
    num_ramdisk_pages = (ramdisk_size + page_size - 1) // page_size
    num_second_pages = 0
    num_dtbo_pages = 0
    dtb_offset = page_size * (1 + num_kernel_pages + num_ramdisk_pages +
                              num_second_pages + num_dtbo_pages)

    # Calculate header size (depends on version)
    # Base: 8+40+16+512+32+1024 = 1632
    header_size = 1632
    if header_version >= 1:
        header_size += 4 + 8 + 4  # recovery_dtbo_size, recovery_dtbo_offset, header_size
    if header_version >= 2:
        header_size += 4 + 8  # dtb_size, dtb_offset

    # Build header
    magic = b'ANDROID!'
    header = struct.pack('<8s', magic)
    header += struct.pack('<10I',
        kernel_size, kernel_addr,
        ramdisk_size, ramdisk_addr,
        0, second_addr,  # second_size=0
        tags_addr,
        page_size,
        header_version,
        (os_version << 11) | os_patch_level)
    header += struct.pack('<16s', board.encode()[:16])
    header += struct.pack('<512s', cmdline.encode()[:512])

    # SHA-1 id
    sha = hashlib.sha1()
    sha.update(kernel)
    sha.update(struct.pack('<I', kernel_size))
    sha.update(ramdisk)
    sha.update(struct.pack('<I', ramdisk_size))
    sha.update(struct.pack('<I', 0))  # second size
    if header_version >= 1:
        sha.update(struct.pack('<I', 0))  # recovery_dtbo size
    if header_version >= 2:
        sha.update(dtb)
        sha.update(struct.pack('<I', dtb_size))
    # ID field is 32 bytes: 20-byte SHA-1 + 12 zero bytes
    header += struct.pack('<32s', sha.digest())

    # Extra cmdline
    extra_cmdline = cmdline.encode()[512:1536] if len(cmdline) > 512 else b''
    header += struct.pack('<1024s', extra_cmdline)

    # V1+ fields
    if header_version >= 1:
        header += struct.pack('<I', 0)  # recovery_dtbo_size
        header += struct.pack('<Q', 0)  # recovery_dtbo_offset
        header += struct.pack('<I', header_size)  # header_size

    # V2 fields
    if header_version >= 2:
        header += struct.pack('<I', dtb_size)
        header += struct.pack('<Q', dtb_offset)

    # Pad header to page size
    header = pad(header, page_size)

    # Build data sections (page-aligned)
    data = b''
    data += pad(kernel, page_size)
    data += pad(ramdisk, page_size)
    # second (empty, no pages)
    # recovery_dtbo (empty, no pages)
    data += pad(dtb, page_size)

    with open(output_path, 'wb') as f:
        f.write(header)
        f.write(data)

    print(f"Created {output_path}")
    print(f"  kernel: {kernel_size} bytes @ 0x{kernel_addr:08x}")
    print(f"  ramdisk: {ramdisk_size} bytes @ 0x{ramdisk_addr:08x}")
    print(f"  dtb: {dtb_size} bytes @ offset {dtb_offset}")
    print(f"  header version: {header_version}, size: {header_size}")
    print(f"  total: {len(header) + len(data)} bytes")

if __name__ == '__main__':
    make_bootimg(
        kernel_path='/workspace/kernel/arch/arm/boot/zImage',
        ramdisk_path='/workspace/ramdisk.cpio.gz',
        dtb_path='/workspace/kernel/arch/arm/boot/dts/k62v1_32_mexico.dtb',
        output_path='/workspace/boot.img',
        base=0x40000000,
        kernel_offset=0x00008000,
        ramdisk_offset=0x07000000,
        second_offset=0x00f00000,
        tags_offset=0x00000100,
        page_size=2048,
        header_version=2,
        board='MLD-AL10',
        cmdline='console=tty0 console=ttyMT3,921600n1 root=/dev/ram vmalloc=496M slub_max_order=0 androidboot.hardware=mt6765 androidboot.product.device=mexico',
        os_version=(10 << 14),  # 10.0.0
        os_patch_level=((2021 - 2000) << 4) | 10,  # 2021-10
    )
