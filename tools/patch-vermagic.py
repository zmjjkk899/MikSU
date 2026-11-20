#!/usr/bin/env python3
"""Rewrite the vermagic entry inside a kernel module's .modinfo section.

The DDK ships a prebuilt scripts/mod/modpost whose VERMAGIC_STRING is baked in
at compile time, so MODULE_ARCH_VERMAGIC cannot be changed through the kernel
headers. This patcher instead appends a fresh .modinfo payload at the end of the
file and repoints the section header at it, which leaves every other section
untouched (no sh_offset rewriting, no relocation churn).

Usage:
    patch_vermagic.py <in.ko> <out.ko> "<new vermagic>"
"""
import struct
import sys


def parse(data):
    if data[:4] != b"\x7fELF":
        raise SystemExit("not an ELF file")
    is64 = data[4] == 2
    end = "<" if data[5] == 1 else ">"

    if is64:
        e_shoff, = struct.unpack_from(end + "Q", data, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(end + "HHH", data, 0x3A)
        fmt = end + "IIQQQQIIQQ"
    else:
        e_shoff, = struct.unpack_from(end + "I", data, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(end + "HHH", data, 0x2E)
        fmt = end + "IIIIIIIIII"

    def sh(i):
        return list(struct.unpack_from(fmt, data, e_shoff + i * e_shentsize))

    return {
        "is64": is64, "end": end, "fmt": fmt,
        "e_shoff": e_shoff, "e_shentsize": e_shentsize,
        "e_shnum": e_shnum, "e_shstrndx": e_shstrndx,
        "sh": sh,
    }


def section_name(data, info, name_off):
    s = info["sh"](info["e_shstrndx"])
    base, size = s[4], s[5]
    blob = data[base:base + size]
    stop = blob.find(b"\x00", name_off)
    return blob[name_off:stop].decode("latin1")


def main():
    if len(sys.argv) != 4:
        raise SystemExit('usage: patch_vermagic.py <in.ko> <out.ko> "<arch vermagic>"')
    src, dst, new_arch = sys.argv[1], sys.argv[2], sys.argv[3]

    data = bytearray(open(src, "rb").read())
    info = parse(data)

    # locate .modinfo
    target = None
    for i in range(info["e_shnum"]):
        s = info["sh"](i)
        if section_name(data, info, s[0]) == ".modinfo":
            target = (i, s)
            break
    if target is None:
        raise SystemExit("no .modinfo section")
    idx, shdr = target
    off, size = shdr[4], shdr[5]

    entries = [e for e in data[off:off + size].split(b"\x00") if e]

    # Only the trailing arch segment is replaced. The release string and the
    # SMP/preempt/mod_unload/modversions flags produced by the DDK must stay:
    # they describe the module ABI the vendor kernel actually expects.
    old_vm = None
    for e in entries:
        if e.startswith(b"vermagic="):
            old_vm = e[len(b"vermagic="):].decode("latin1")
            break

    if old_vm:
        head, sep, tail = old_vm.rpartition(" ")
        new_vm = (head + " " + new_arch) if sep else new_arch
    else:
        new_vm = new_arch

    out_entries = []
    replaced = False
    for e in entries:
        if e.startswith(b"vermagic="):
            out_entries.append(b"vermagic=" + new_vm.encode())
            replaced = True
        else:
            out_entries.append(bytes(e))
    if not replaced:
        out_entries.append(b"vermagic=" + new_vm.encode())

    # serialize exactly like the kernel does: NUL terminated, NUL padded to 4
    blob = b"".join(e + b"\x00" for e in out_entries)
    pad = (-len(blob)) % 4
    blob += b"\x00" * pad

    # append the new payload, 4-byte aligned, then repoint the section header
    while len(data) % 4:
        data.append(0)
    new_off = len(data)
    data += blob

    # rewrite sh_offset (word 4) and sh_size (word 5) in place
    if info["is64"]:
        struct.pack_into(info["end"] + "Q", data, info["e_shoff"] + idx * info["e_shentsize"] + 24, new_off)
        struct.pack_into(info["end"] + "Q", data, info["e_shoff"] + idx * info["e_shentsize"] + 32, len(blob))
    else:
        struct.pack_into(info["end"] + "I", data, info["e_shoff"] + idx * info["e_shentsize"] + 16, new_off)
        struct.pack_into(info["end"] + "I", data, info["e_shoff"] + idx * info["e_shentsize"] + 20, len(blob))

    open(dst, "wb").write(data)

    print("section      :", f".modinfo (index {idx})")
    print("old vermagic :", old_vm if old_vm else "<none>")
    print("new vermagic :", new_vm)
    print("arch segment :", new_arch)
    print("delta bytes  :", len(data) - len(open(src, "rb").read()))


if __name__ == "__main__":
    main()
