#!/usr/bin/env python3
"""Extract every member of an ar archive under a unique name.

`ar x` overwrites members that share a name, and Zig archives can contain
several objects with the same name, so number each extracted file instead.
"""
import os
import sys

archive_path, out_dir = sys.argv[1], sys.argv[2]
with open(archive_path, 'rb') as f:
    data = f.read()
if not data.startswith(b'!<arch>\n'):
    sys.exit(f'{archive_path}: not an ar archive')

offset, index = 8, 0
while offset + 60 <= len(data):
    header = data[offset:offset + 60]
    if header[58:60] != b'`\n':
        sys.exit(f'{archive_path}: bad member header at {offset}')
    name = header[0:16].decode().rstrip()
    size = int(header[48:58].decode())
    body = data[offset + 60:offset + 60 + size]
    if name.startswith('#1/'):  # BSD long name stored at the start of the body.
        name_len = int(name[3:])
        name = body[:name_len].rstrip(b'\0').decode()
        body = body[name_len:]
    offset += 60 + size + (size & 1)
    if name.startswith('__.SYMDEF') or name in ('/', '//', '/SYM64/'):
        continue
    index += 1
    base = os.path.basename(name.rstrip('/')) or 'member.o'
    with open(os.path.join(out_dir, f'{index:04d}_{base}'), 'wb') as out:
        out.write(body)
print(f'extracted {index} members from {archive_path}')
