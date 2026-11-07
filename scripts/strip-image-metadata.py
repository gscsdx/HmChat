#!/usr/bin/env python3
"""Remove nonessential PNG metadata without decoding or changing any image pixels."""
import argparse
import pathlib
import struct
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('files', nargs='+', type=pathlib.Path)
args = parser.parse_args()
signature = b'\x89PNG\r\n\x1a\n'
allowed = {b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'sRGB', b'gAMA', b'cHRM'}
for path in args.files:
    data = path.read_bytes()
    if not data.startswith(signature):
        raise SystemExit(f'Not a PNG: {path.name}')
    offset = 8
    output = bytearray(signature)
    removed = 0
    ended = False
    while offset + 12 <= len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        end = offset + size + 12
        kind = data[offset + 4:offset + 8]
        if end > len(data) or zlib.crc32(data[offset + 4:end - 4]) != struct.unpack('>I', data[end - 4:end])[0]:
            raise SystemExit(f'Invalid PNG: {path.name}')
        if kind in allowed:
            output.extend(data[offset:end])
        elif kind[:1].isupper():
            raise SystemExit(f'Unsupported critical PNG chunk: {path.name}')
        else:
            removed += 1
        offset = end
        if kind == b'IEND':
            ended = True
            break
    if not ended or offset != len(data):
        raise SystemExit(f'Invalid PNG ending: {path.name}')
    path.write_bytes(output)
    print(f'{path.name}: removed {removed} metadata chunks; compressed image data unchanged')
