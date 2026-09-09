#!/usr/bin/env python3
# apply_oc_atf.py - reproducible RG DS Plus CPU-overclock ATF patch (2160 MHz).
#
# RK3568 armclk is owned by ATF (BL31) via SCMI; the kernel DT opp + kernel clk
# tables are NOT enough - ATF clamps to its own rate/PLL tables. rkbin ships BL31
# as a prebuilt blob (no source), so the OC is applied as a deterministic binary
# patch to the built uboot.img FIT, exactly matching the shipped RG DS (which runs
# 2160/900). This script is that patch step: run it on the uboot.img produced by
# build-uboot.sh to get an overclock-capable u-boot.
#
# What it does (self-locating, works across rebuilds):
#   For each FIT copy in uboot.img (RK ships two: primary @0 and mirror @0x200000):
#     1. parse the FIT (FDT) to find the atf-3 image data range + its sha256 hash node.
#     2. inside atf-3, replace the CPU 312 MHz entry with 2160 MHz in BOTH ATF tables
#        (the SCMI rate list AND the separate PLL-config table - patching only one
#        makes the kernel report the freq while the PLL runs wrong). 1992 is kept;
#        the little-used 312 MHz step is sacrificed, exactly as the RG DS OC does.
#          - rate-list entry:  {0x1298be00, 0}            -> {0x80befc00, 0}
#          - PLL-config entry: {0x1298be00,1,0x4e,6,1,1,0,0}
#                              -> {0x80befc00,1,0x5a,1,1,1,0,0x33}   (2160=24*90, FBDIV 0x5a)
#     3. recompute the atf-3 sha256 over the patched data and write it into the hash node.
#   then verify with `dumpimage -l`.
#
# Usage: apply_oc_atf.py <uboot.img>   (patches in place; writes <uboot.img>.bak once)
import sys, struct, hashlib, subprocess, os

RATE_312 = struct.pack('<II', 312000000, 0)
RATE_2160 = struct.pack('<II', 2160000000, 0)
# PLL entry = {rate, const=1, fbdiv, postdiv1, refdiv, postdiv2, dsmpd, band}
PLL_312 = struct.pack('<8I', 312000000, 1, 0x4e, 6, 1, 1, 0, 0)
PLL_2160 = struct.pack('<8I', 2160000000, 1, 0x5a, 1, 1, 1, 0, 0x33)

def be32(b, o): return struct.unpack('>I', b[o:o+4])[0]

def parse_fit(buf, base):
    """Return (atf_data_abs, atf_data_len, hash_value_abs) for the atf-3 image
    in the FIT whose FDT header starts at file offset `base`."""
    magic = be32(buf, base)
    if magic != 0xd00dfeed:
        raise ValueError("no FDT magic at 0x%x" % base)
    totalsize   = be32(buf, base+4)
    off_struct  = be32(buf, base+8)
    off_strings = be32(buf, base+12)
    size_struct = be32(buf, base+36)
    strings = buf[base+off_strings: base+off_strings+be32(buf, base+32)]
    def s(o):  # NUL-terminated string from the strings block
        e = strings.index(b'\0', o); return strings[o:e].decode()
    p = base + off_struct
    end = p + size_struct
    path = []
    cur = {}                      # props of the node we're inside
    atf = {'data-offset': None, 'data-position': None, 'data-size': None, 'hash_value_abs': None}
    in_atf = False; in_atf_hash = False
    while p < end:
        tag = be32(buf, p); p += 4
        if tag == 1:              # BEGIN_NODE
            name = s2 = b''
            z = buf.index(b'\0', p); name = buf[p:z].decode(); p = (z+4) & ~3
            path.append(name)
            in_atf = (len(path) >= 2 and path[1] == 'images' and path[-1].startswith('atf-3'))
            in_atf_hash = in_atf and False
            if in_atf and len(path) >= 4 and path[-1].startswith('hash'):
                in_atf_hash = True
        elif tag == 2:            # END_NODE
            path.pop()
            in_atf = (len(path) >= 2 and path[1] == 'images' and path[-1].startswith('atf-3'))
        elif tag == 3:            # PROP
            plen = be32(buf, p); poff = be32(buf, p+4); p += 8
            val = buf[p: p+plen]; valabs = p; p = (p + plen + 3) & ~3
            nm = s(poff)
            # atf-3 image node props
            if len(path) >= 3 and path[1]=='images' and path[2].startswith('atf-3'):
                if len(path) == 3 and nm == 'data-offset':   atf['data-offset']   = struct.unpack('>I', val)[0]
                if len(path) == 3 and nm == 'data-position': atf['data-position'] = struct.unpack('>I', val)[0]
                if len(path) == 3 and nm == 'data-size':     atf['data-size']     = struct.unpack('>I', val)[0]
                if len(path) == 4 and path[3].startswith('hash') and nm == 'value':
                    atf['hash_value_abs'] = valabs
        elif tag == 9:            # END
            break
        # tag 4 (NOP) -> loop
    if atf['data-size'] is None or atf['hash_value_abs'] is None or \
       (atf['data-offset'] is None and atf['data-position'] is None):
        raise ValueError("atf-3 data/hash not found in FIT @0x%x: %r" % (base, atf))
    if atf['data-position'] is not None:      # absolute within this FIT image
        data_abs = base + atf['data-position']
    else:                                     # relative to end of FIT header
        data_abs = base + ((totalsize + 3) & ~3) + atf['data-offset']
    return data_abs, atf['data-size'], atf['hash_value_abs']

def patch_atf(buf, data_abs, data_len):
    seg = bytearray(buf[data_abs: data_abs+data_len]); changes = 0
    i = seg.find(PLL_312)
    if i >= 0: seg[i:i+32] = PLL_2160; changes += 1
    # CPU rate 312 sits right after the CPU 216 MHz entry (disambiguates from other clocks)
    anchor = struct.pack('<II', 216000000, 0) + RATE_312
    j = seg.find(anchor)
    if j >= 0:
        k = j + 8; seg[k:k+8] = RATE_2160; changes += 1
    else:                                   # fallback: first standalone 312 rate pair
        k = seg.find(RATE_312)
        if k >= 0: seg[k:k+8] = RATE_2160; changes += 1
    return bytes(seg), changes

def main():
    path = sys.argv[1]
    buf = bytearray(open(path, 'rb').read())
    if not os.path.exists(path + '.bak'):
        open(path + '.bak', 'wb').write(buf)
    copies = [0]
    if len(buf) >= 0x400000 and be32(buf, 0x200000) == 0xd00dfeed:
        copies.append(0x200000)
    total = 0
    for base in copies:
        data_abs, data_len, hash_abs = parse_fit(buf, base)
        newdata, ch = patch_atf(buf, data_abs, data_len)
        buf[data_abs: data_abs+data_len] = newdata
        h = hashlib.sha256(newdata).digest()
        buf[hash_abs: hash_abs+32] = h
        total += ch
        print("FIT@0x%06x: atf-3 data 0x%x len 0x%x, %d table(s) patched, sha256=%s"
              % (base, data_abs, data_len, ch, h.hex()))
    open(path, 'wb').write(buf)
    print("patched %d tables total across %d FIT copies" % (total, len(copies)))
    try:
        r = subprocess.run(['dumpimage', '-l', path], capture_output=True, text=True)
        print("dumpimage -l:", "OK" if r.returncode == 0 else "FAIL\n"+r.stderr)
    except FileNotFoundError:
        print("(dumpimage not found - skipping verify)")

if __name__ == '__main__':
    main()
