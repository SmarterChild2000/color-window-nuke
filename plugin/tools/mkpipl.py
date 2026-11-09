#!/usr/bin/env python3
"""Write (or --verify) an Illustrator PiPL resource.

Produces the same bytes as the official Adobe SDK generator
(<SDK>/tools/pipl/create_pipl.py, called with only a plug-in name):
  int32 pipl-count=1, int32 version=0, int32 propertyCount, then properties of
  { vendor[4], key[4], int32 id=0, int32 length, data }.
String values are padded with NULs to a multiple of 4 and the padded length is
stored. Properties: kind=SPEA, ivrs=2, mi32="" (empty Mac code descriptor:
default entry point PluginMain), pinm=<name>.

Release builds call Adobe's generator directly (plugin/build.sh --sdk); this
file only keeps dev builds byte-identical and verifies the result.
"""
import struct
import sys


def pad4(data):
    return data + b'\0' * ((4 - len(data) % 4) % 4)


def prop(key, data):
    return b'ADBE' + key + struct.pack('>ii', 0, len(data)) + data


def build(name):
    props = [prop(b'kind', b'SPEA'), prop(b'ivrs', struct.pack('>i', 2)),
             prop(b'mi32', b''), prop(b'pinm', pad4(name.encode()))]
    return struct.pack('>iii', 1, 0, len(props)) + b''.join(props)


def parse(blob):
    _, _, count = struct.unpack('>iii', blob[:12])
    off, out = 12, {}
    for _ in range(count):
        vendor, key = blob[off:off + 4], blob[off + 4:off + 8]
        _, length = struct.unpack('>ii', blob[off + 8:off + 16])
        out[key.decode()] = blob[off + 16:off + 16 + length]
        off += 16 + length + (4 - length % 4) % 4
        assert vendor == b'ADBE'
    assert off == len(blob), 'trailing bytes'
    return out


if __name__ == '__main__':
    if sys.argv[1] == '--verify':
        p = parse(open(sys.argv[2], 'rb').read())
        ok = p.get('kind') == b'SPEA' and 'pinm' in p and 'ivrs' in p
        print('PiPL ok: %s' % p['pinm'].rstrip(b'\0').decode() if ok else 'PiPL INVALID')
        sys.exit(0 if ok else 1)
    out, name = sys.argv[1], sys.argv[2]
    with open(out, 'wb') as f:
        f.write(build(name))
