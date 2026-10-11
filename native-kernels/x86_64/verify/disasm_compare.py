#!/usr/bin/env python3
"""Compare the machine code of the x86-64 kernel sources against a git revision.

Usage (from anywhere inside the repository):
    python3 -I native-kernels/x86_64/verify/disasm_compare.py [REV] [-D NAME=VALUE ...]

REV defaults to HEAD. Both trees (REV and the working tree) are assembled with
gcc, each variant file is linked into its own throw-away shared object, and
then compared per symbol:

  * every function (global kernels and local helpers): the normalised
    instruction stream. Absolute addresses are removed; branch/call targets and
    RIP-relative operands are shown as <symbol+offset>, so the comparison does
    not depend on where a function or a table ended up in the file;
  * every rodata object: its bytes, or for self-relative jump tables
    (.long target - table) the list of resolved target symbols.

A refactoring that only moves code into macros/include files, renames local
labels or reorders functions/tables must report "identical" for every symbol.
Exit status: 0 if everything is identical, 1 otherwise (differences printed).
This is a verification tool only; nothing here is part of libpqkernels.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
X86 = os.path.dirname(HERE)                      # native-kernels/x86_64
VARIANTS = ["pqk_x86_scalar.S", "pqk_x86_avx2.S", "pqk_x86_avx512.S"]


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def export_rev(rev, dst):
    top = run(["git", "-C", X86, "rev-parse", "--show-toplevel"]).strip()
    rel = os.path.relpath(X86, top)
    tar = subprocess.run(["git", "-C", top, "archive", rev, rel],
                         check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", dst], input=tar, check=True)
    return os.path.join(dst, rel)


def build(src_dir, name, out_dir, defs):
    obj = os.path.join(out_dir, name + ".o")
    so = os.path.join(out_dir, name + ".so")
    run(["gcc", "-c", *defs, os.path.join(src_dir, name), "-o", obj])
    und = run(["nm", "-u", obj]).split()
    if und:     # e.g. a cpp constant used before its #define became a symbol
        raise SystemExit("%s: undefined symbols %s" % (os.path.join(src_dir, name), und))
    run(["gcc", "-shared", "-nostdlib", "-o", so, obj])
    return so


def symbols(so):
    syms = {}
    for line in run(["readelf", "-sW", so]).splitlines():
        f = line.split()
        if len(f) < 8 or not f[0].endswith(":") or f[3] not in ("FUNC", "OBJECT"):
            continue
        if f[6] in ("UND", "ABS"):
            continue
        syms[f[7]] = (int(f[1], 16), int(f[2]), f[3], f[4])
    return syms


def sections(so):
    secs = {}
    for line in run(["readelf", "-SW", so]).splitlines():
        m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)", line)
        if m:
            secs[m.group(1)] = (int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16))
    return secs


def name_of(addr, syms):
    best = None
    for n, (a, size, _, _) in syms.items():
        if a <= addr < a + max(size, 1) and (best is None or a > syms[best][0]):
            best = n
    if best is None:
        return hex(addr)
    off = addr - syms[best][0]
    return "<%s%s>" % (best, "+0x%x" % off if off else "")


def functions(so, syms):
    out, cur = {}, None
    text = run(["objdump", "-d", "--no-show-raw-insn", "-w", so])
    for line in text.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if m:
            cur = m.group(1)
            out[cur] = []
            continue
        m = re.match(r"^\s*([0-9a-f]+):\s*(.*)$", line)
        if not m or cur is None:
            continue
        ins = m.group(2).strip()
        if not ins or ins.startswith(("nop", "data16", "cs nopw", "xchg   %ax,%ax")):
            continue                    # alignment padding
        ins = re.sub(r"\s+", " ", ins)
        # rip-relative: keep only the resolved symbol in the comment
        mm = re.match(r"(.*?)-?0x[0-9a-f]+\(%rip\)(.*?)\s*# [0-9a-f]+ (<.*>)$", ins)
        if mm:
            ins = "%sREL(%%rip)%s %s" % (mm.group(1), mm.group(2), mm.group(3))
        # direct branches / calls: drop the absolute address
        ins = re.sub(r"\b[0-9a-f]+ (<[^>]+>)", r"\1", ins)
        out[cur].append(ins)
    return out


def objects(so, syms, secs):
    data = open(so, "rb").read()
    text_lo, _, text_size = secs[".text"]
    res = {}
    for n, (a, size, typ, _) in syms.items():
        if typ != "OBJECT":
            continue
        for sname, (sa, soff, ssize) in secs.items():
            if sa <= a < sa + ssize:
                raw = data[soff + a - sa: soff + a - sa + size]
                break
        else:
            continue
        desc = raw.hex()
        if size and size % 4 == 0:
            ents = [int.from_bytes(raw[i:i + 4], "little", signed=True) for i in range(0, size, 4)]
            tg = [a + e for e in ents]
            if all(text_lo <= t < text_lo + text_size for t in tg):
                desc = "jumptable " + " ".join(name_of(t, syms) for t in tg)
        res[n] = desc
    return res


def describe(src_dir, name, out_dir, defs):
    so = build(src_dir, name, out_dir, defs)
    syms = symbols(so)
    funcs = functions(so, syms)
    funcs = {k: v for k, v in funcs.items() if k in syms}
    return funcs, objects(so, syms, sections(so)), {k: v[3] for k, v in syms.items()}


def main():
    args = sys.argv[1:]
    defs, rest = [], []
    i = 0
    while i < len(args):
        if args[i] == "-D":
            defs.append("-D" + args[i + 1]); i += 2
        elif args[i].startswith("-D"):
            defs.append(args[i]); i += 1
        else:
            rest.append(args[i]); i += 1
    rev = rest[0] if rest else "HEAD"
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        old_dir = export_rev(rev, tmp)
        for v in VARIANTS:
            o1 = os.path.join(tmp, "old"); o2 = os.path.join(tmp, "new")
            os.makedirs(o1, exist_ok=True); os.makedirs(o2, exist_ok=True)
            f1, d1, b1 = describe(old_dir, v, o1, defs)
            f2, d2, b2 = describe(X86, v, o2, defs)
            nf = no = 0
            for n in sorted(set(f1) | set(f2)):
                if f1.get(n) != f2.get(n):
                    bad += 1
                    print("%s: function %s DIFFERS" % (v, n))
                    a, b = f1.get(n, ["<missing>"]), f2.get(n, ["<missing>"])
                    for k in range(max(len(a), len(b))):
                        x = a[k] if k < len(a) else ""
                        y = b[k] if k < len(b) else ""
                        if x != y:
                            print("   #%d\n     %s: %s\n     %s: %s" % (k, rev, x, "work", y))
                            break
                else:
                    nf += 1
            for n in sorted(set(d1) | set(d2)):
                if d1.get(n) != d2.get(n):
                    bad += 1
                    print("%s: object %s DIFFERS\n   %s: %s\n   work: %s"
                          % (v, n, rev, d1.get(n), d2.get(n)))
                else:
                    no += 1
            for n in sorted(set(b1) | set(b2)):
                if b1.get(n) != b2.get(n):
                    bad += 1
                    print("%s: binding of %s differs: %s vs %s" % (v, n, b1.get(n), b2.get(n)))
            print("%s: %d functions, %d objects compared" % (v, nf, no))
    print("identical" if not bad else "%d difference(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
