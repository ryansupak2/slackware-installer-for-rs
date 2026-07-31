#!/usr/bin/env python3
"""Build a scaled color emoji font from Noto Color Emoji.

Parses the CBDT/CBLC tables, scales each PNG glyph to CELL_HEIGHT,
and writes a new TTF with scaled bitmaps that won't cause BadLength.

Usage: python3 build-scaled-emoji-font.py <input.ttf> <output.ttf> <cell_h>
"""

import struct, sys, io, zlib
from PIL import Image


def parse_cblc(data, tbl_offset):
    """Return list of (gid, w, h, bx, by, adv, png_off, png_len)."""
    num_sizes = struct.unpack('>I', data[tbl_offset+4:tbl_offset+8])[0]
    off = tbl_offset + 8
    glyphs = []

    for _ in range(num_sizes):
        # BitmapSize record: 48 bytes
        sub_rel = struct.unpack('>I', data[off:off+4])[0]
        num_subs = struct.unpack('>I', data[off+8:off+12])[0]
        sub_array = off + sub_rel

        for si in range(num_subs):
            e = sub_array + si * 8
            first, last = struct.unpack('>HH', data[e:e+4])
            add_off = struct.unpack('>I', data[e+4:e+8])[0]

            hdr = sub_array + add_off
            idx_fmt = struct.unpack('>H', data[hdr:hdr+2])[0]
            img_fmt = struct.unpack('>H', data[hdr+2:hdr+4])[0]
            base_off = struct.unpack('>I', data[hdr+4:hdr+8])[0]
            if img_fmt != 17:
                continue

            rec_size = 4 if idx_fmt == 1 else 6
            for gi in range(first, last + 1):
                r = hdr + 8 + (gi - first) * rec_size
                gid = struct.unpack('>H', data[r:r+2])[0]
                png_rel = struct.unpack('>H', data[r+2:r+4])[0] if idx_fmt == 1 else struct.unpack('>I', data[r+2:r+6])[0]
                poff = base_off + png_rel
                h, w = struct.unpack('>bb', data[poff:poff+2])
                bx, by = struct.unpack('>bb', data[poff+2:poff+4])
                adv = struct.unpack('>B', data[poff+4:poff+5])[0]
                plen = struct.unpack('>I', data[poff+5:poff+9])[0]
                glyphs.append((gid, w, h, bx, by, adv, poff + 9, plen))
        off += 48
    return glyphs


def scale_png(png_data, cell_h):
    """Scale PNG to cell_h height, return (scaled_png_bytes, w, h)."""
    img = Image.open(io.BytesIO(png_data))
    ow, oh = img.size
    nh = max(1, cell_h)
    nw = max(1, int(ow * cell_h / max(oh, 1)))
    img = img.resize((nw, nh), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format='PNG')
    return buf.getvalue(), nw, nh


def calc_checksum(d):
    """TTF table checksum: sum of uint32s."""
    s = 0
    for i in range(0, len(d), 4):
        s = (s + struct.unpack('>I', d[i:i+4])[0]) & 0xFFFFFFFF
    return s


def pad4(d):
    return d + b'\x00' * ((4 - len(d) % 4) % 4)


def build(input_path, output_path, cell_h):
    with open(input_path, 'rb') as f:
        data = f.read()

    # Parse TTF header and table directory
    _, num_tables, _, _, _ = struct.unpack('>IHHHH', data[:12])
    tables = {}
    for i in range(num_tables):
        tag, cs, off, ln = struct.unpack('>4sIII', data[12+i*16:28+i*16])
        tables[tag.decode('ascii')] = (off, ln, cs)

    if 'CBLC' not in tables or 'CBDT' not in tables:
        sys.exit("Not a CBDT/CBLC color font")

    glyphs = parse_cblc(data, tables['CBLC'][0])
    print(f"Found {len(glyphs)} glyphs", file=sys.stderr)

    # Scale all glyphs
    scaled = {}
    for gid, w, h, bx, by, adv, poff, plen in glyphs:
        try:
            png, nw, nh = scale_png(data[poff:poff+plen], cell_h)
            sx = nw / max(w, 1); sy = nh / max(h, 1)
            scaled[gid] = (png, nw, nh, int(bx*sx), int(by*sy), max(1, int(adv*sx)))
        except Exception as e:
            pass  # skip broken glyphs

    print(f"Scaled {len(scaled)} glyphs to {cell_h}px", file=sys.stderr)
    if not scaled:
        sys.exit("No glyphs!")

    gids = sorted(scaled)

    # Build CBDT
    cbdt = bytearray()
    offsets = {}
    for gid in gids:
        offsets[gid] = len(cbdt)
        png, w, h, bx, by, adv = scaled[gid]
        cbdt += struct.pack('>bbbbB', h, w, bx, by, adv)
        cbdt += struct.pack('>I', len(png))
        cbdt += png

    # Build CBLC (one BitmapSize, one sub-table, format 1)
    cblc = bytearray()
    cblc += struct.pack('>HHI', 3, 0, 1)  # major=3, minor=0, 1 size

    # BitmapSize placeholder (48 bytes)
    bms_pos = len(cblc)
    cblc += b'\x00' * 48

    # IndexSubTableArray (one entry: 8 bytes) + sub-table header (8 bytes) + glyph data
    idx_array_pos = len(cblc)
    add_off = 8  # just past this entry
    cblc += struct.pack('>HHI', gids[0], gids[-1], add_off)

    # Sub-table header (format 1): indexFormat=1, imageFormat=17, imageDataOffset=0
    # (CBDT offsets are absolute within cbdt, imageDataOffset is 0)
    sub_hdr_pos = len(cblc)
    cblc += struct.pack('>HHI', 1, 17, 0)

    # Glyph entries
    for gid in gids:
        cblc += struct.pack('>HH', gid, offsets[gid])

    # Fill BitmapSize
    max_w = max(scaled[g][1] for g in gids)
    max_h = max(scaled[g][2] for g in gids)
    bms = bytearray()
    bms += struct.pack('>I', idx_array_pos - bms_pos)  # subtable array offset
    bms += struct.pack('>I', 0)   # indexTablesSize (unused)
    bms += struct.pack('>I', 1)   # numberOfIndexSubTables
    bms += struct.pack('>I', 0)   # colorRef
    bms += b'\x00' * 12  # hori line metrics
    bms += b'\x00' * 12  # vert line metrics
    bms += struct.pack('>H', gids[0])   # startGlyph
    bms += struct.pack('>H', gids[-1])  # endGlyph
    bms += struct.pack('>BB', cell_h, cell_h)  # ppemX, ppemY
    bms += struct.pack('>BB', 32, 0)    # bitDepth=32, flags
    cblc[bms_pos:bms_pos+48] = bms

    # Assemble output TTF
    orig_tables = {k: v for k, v in tables.items() if k not in ('CBDT', 'CBLC')}
    all_tags = sorted(list(orig_tables.keys()) + ['CBDT', 'CBLC'])

    dir_size = 12 + len(all_tags) * 16
    data_start = (dir_size + 3) & ~3  # pad to 4 bytes

    head_data = bytearray(data[tables['head'][0]:tables['head'][0]+tables['head'][1]])
    head_data[8:12] = b'\x00\x00\x00\x00'  # zero checksumAdjustment

    out = bytearray(data[:4])  # sfVersion
    out += struct.pack('>HHHH', len(all_tags), 0, 0, 0)  # directory header
    out += b'\x00' * (len(all_tags) * 16)  # placeholder directory
    out += b'\x00' * (data_start - len(out))

    # Write tables in alphabetical order
    dir_entries = bytearray()
    cur = data_start
    table_data_out = {}

    for tag in all_tags:
        if tag == 'CBDT':
            raw = bytes(cbdt)
        elif tag == 'CBLC':
            raw = bytes(cblc)
        elif tag == 'head':
            raw = bytes(head_data)
        else:
            raw = data[orig_tables[tag][0]:orig_tables[tag][0]+orig_tables[tag][1]]

        padded = pad4(raw)
        cs = calc_checksum(padded)
        dir_entries += struct.pack('>4sIII', tag.encode('ascii'), cs, cur, len(raw))
        table_data_out[tag] = padded
        cur += len(padded)

    out[12:12+len(dir_entries)] = dir_entries

    for tag in all_tags:
        out += table_data_out[tag]

    # Compute head checksumAdjustment for entire font
    total = 0
    for i in range(0, len(out), 4):
        total = (total + struct.unpack('>I', out[i:i+4])[0]) & 0xFFFFFFFF
    adjustment = (0xB1B0AFBA - total) & 0xFFFFFFFF

    # Find head in output
    _, head_off, _ = [(o, l) for t, o, l in [(tag, off, ln) 
        for tag, (off, ln, _) in tables.items() if tag == 'head']][0]
    # head_off is original, we need output offset
    # head is written at position determined by alphabetical order
    for i, tag in enumerate(all_tags):
        if tag == 'head':
            e = struct.unpack('>4sIII', dir_entries[i*16:(i+1)*16])
            head_out = e[2]
            struct.pack_into('>I', out, head_out + 8, adjustment)
            break

    with open(output_path, 'wb') as f:
        f.write(out)

    print(f"Wrote {output_path} ({len(out)} bytes, {len(gids)} glyphs)", file=sys.stderr)


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(f"Usage: {sys.argv[0]} <in.ttf> <out.ttf> [cell_h]")
    build(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 29)
