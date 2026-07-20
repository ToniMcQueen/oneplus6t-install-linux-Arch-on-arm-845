#!/usr/bin/env python3
import argparse
import os
import struct
import sys


SPARSE_MAGIC = 0xED26FF3A
SPARSE_HEADER = "<IHHHHIIII"
SPARSE_HEADER_SIZE = struct.calcsize(SPARSE_HEADER)


def read_image_info(path):
    size = os.path.getsize(path)
    with open(path, "rb") as image:
        header = image.read(SPARSE_HEADER_SIZE)

    if len(header) < SPARSE_HEADER_SIZE:
        return {
            "format": "raw",
            "file_size_bytes": size,
            "virtual_size_bytes": size,
            "block_size": 0,
            "total_blocks": 0,
            "total_chunks": 0,
        }

    (
        magic,
        major,
        minor,
        file_hdr_sz,
        chunk_hdr_sz,
        block_size,
        total_blocks,
        total_chunks,
        checksum,
    ) = struct.unpack(SPARSE_HEADER, header)

    if magic != SPARSE_MAGIC:
        return {
            "format": "raw",
            "file_size_bytes": size,
            "virtual_size_bytes": size,
            "block_size": 0,
            "total_blocks": 0,
            "total_chunks": 0,
        }

    if file_hdr_sz < SPARSE_HEADER_SIZE:
        raise ValueError(f"invalid sparse header size: {file_hdr_sz}")

    if chunk_hdr_sz < 12:
        raise ValueError(f"invalid sparse chunk header size: {chunk_hdr_sz}")

    return {
        "format": "android-sparse",
        "file_size_bytes": size,
        "virtual_size_bytes": block_size * total_blocks,
        "block_size": block_size,
        "total_blocks": total_blocks,
        "total_chunks": total_chunks,
        "sparse_major": major,
        "sparse_minor": minor,
        "image_checksum": checksum,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Print raw or Android sparse image virtual size information."
    )
    parser.add_argument("image")
    parser.add_argument(
        "--field",
        choices=[
            "format",
            "file_size_bytes",
            "virtual_size_bytes",
            "block_size",
            "total_blocks",
            "total_chunks",
        ],
        help="Print only one field value.",
    )
    parser.add_argument(
        "--shell",
        action="store_true",
        help="Print shell assignment style output.",
    )
    args = parser.parse_args()

    try:
        info = read_image_info(args.image)
    except Exception as exc:
        print(f"android-sparse-info: {exc}", file=sys.stderr)
        return 1

    if args.field:
        print(info[args.field])
        return 0

    for key in (
        "format",
        "file_size_bytes",
        "virtual_size_bytes",
        "block_size",
        "total_blocks",
        "total_chunks",
    ):
        if args.shell:
            print(f"IMAGE_{key.upper()}={info[key]}")
        else:
            print(f"{key}: {info[key]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
