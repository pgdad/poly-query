#!/usr/bin/env python3
"""Structure checks for the x86-64 kernel sources (CR-5).

Usage: python3 -I native-kernels/x86_64/verify/structure_check.py [-v]

Checks, on the working tree:
  1. every gas macro, cpp constant (except the per-kernel SAVED list), helper
     function and constant table is defined in exactly one place;
  2. the shared headers (*.h) emit no bytes when included;
  3. every variant defines exactly the 20 kernels of include/pq_kernels.h
     (global FUNC symbols pqk_x86_<variant>_<kernel>);
  4. label scheme: labels in kernel bodies are .L<kernel>_<step>; no numeric
     labels outside building-block macros;
  5. every kernel has a header comment with Args/Returns/Clobbers/Algorithm/
     Tail and its body (with the building-block macros it expands) carries
     the [check] [main] [tail] [result] skeleton markers;
  6. the "Clobbers:" list of every kernel matches the caller-saved registers
     the machine code can write, computed from the disassembly (following
     direct calls and every function reachable through jump tables or
     RIP-relative function addresses): it must contain every written
     register except those the kernel itself pushes and pops (a pair may
     only bracket a helper call, so those are optional), and nothing that
     is never written. Every callee-saved register that is written must be
     pushed and popped.
Exit status 0 if all checks pass. Verification tool only.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
X86 = os.path.dirname(HERE)
NK = os.path.dirname(X86)
VARIANTS = {"scalar": "pqk_x86_scalar.S", "avx2": "pqk_x86_avx2.S", "avx512": "pqk_x86_avx512.S"}
HEADERS = ["pqk_x86_common.h", "pqk_x86_consts.h", "pqk_x86_simd.h",
           "pqk_x86_scalar.h", "pqk_x86_avx2.h", "pqk_x86_avx512.h"]
CALLEE_SAVED = {"rbx", "rbp", "r12", "r13", "r14", "r15"}
VERBOSE = "-v" in sys.argv
errors = []


def err(msg):
    errors.append(msg)
    print("FAIL: " + msg)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def read(name):
    return open(os.path.join(X86, name)).read()


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)


# ---------------------------------------------------------------- 1. defined once
def check_defined_once():
    seen = {}
    files = HEADERS + list(VARIANTS.values())
    for f in files:
        code = strip_comments(read(f))
        for kind, rx in (("macro", r"^\s*\.macro\s+(\w+)"),
                         ("#define", r"^\s*#\s*define\s+(\w+)"),
                         ("helper", r"^\s*LFUNC\s+(\w+)"),
                         ("kernel", r"^\s*FUNC\s+(\w+)")):
            for m in re.finditer(rx, code, flags=re.M):
                name = m.group(1)
                if kind == "#define" and name in ("SAVED",):
                    continue            # per-kernel register list, #undef'd
                if kind == "#define" and name.endswith("_H"):
                    continue            # include guards
                seen.setdefault((kind, name), []).append(f)
    # helper functions are file-local: one definition per variant file is the
    # rule; a helper defined by a header macro (DEFINE_LVP ...) is emitted
    # once per variant, defined once in source.
    n = 0
    for (kind, name), fs in sorted(seen.items()):
        n += 1
        if len(fs) > 1:
            err("%s %s defined %d times: %s" % (kind, name, len(fs), ", ".join(fs)))
    print("defined-once: %d definitions checked" % n)


# ---------------------------------------------------------------- 2. headers emit nothing
def check_headers_empty():
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "h.S")
        with open(src, "w") as f:
            f.write("".join('#include "%s"\n' % h for h in HEADERS))
        obj = os.path.join(tmp, "h.o")
        run(["gcc", "-c", "-I" + X86, src, "-o", obj])
        out = run(["size", "-A", obj])
        total = sum(int(l.split()[1]) for l in out.splitlines()[2:] if len(l.split()) >= 2
                    and l.split()[1].isdigit())
        syms = [l for l in run(["nm", obj]).splitlines() if l.strip()]
        if total or syms:
            err("headers emit %d bytes / symbols %s" % (total, syms))
        else:
            print("headers: emit no bytes and no symbols")


# ---------------------------------------------------------------- 3. kernel set
def abi_kernels():
    h = open(os.path.join(NK, "include", "pq_kernels.h")).read()
    names = re.findall(r"\bpqk_(\w+)\s*\(", h)
    skip = {"abi_version", "abi_revision", "init", "set_variant", "variant", "available_variants"}
    return [n for n in dict.fromkeys(names) if n not in skip]


def check_kernel_set(kernels):
    for v, f in VARIANTS.items():
        code = strip_comments(read(f))
        funcs = re.findall(r"^\s*FUNC\s+(\w+)", code, flags=re.M)
        want = ["pqk_x86_%s_%s" % (v, k) for k in kernels]
        if sorted(funcs) != sorted(want):
            err("%s: kernels %s, expected %s" % (f, sorted(set(funcs) ^ set(want)), len(want)))
        else:
            print("%s: %d/%d kernels" % (f, len(funcs), len(kernels)))


# ---------------------------------------------------------------- 4/5. labels, comments, skeleton
def macro_bodies():
    bodies = {}
    for f in HEADERS + list(VARIANTS.values()):
        for m in re.finditer(r"^\s*\.macro\s+(\w+)(.*?)^\s*\.endm", read(f), flags=re.M | re.S):
            bodies[m.group(1)] = m.group(2)
    return bodies


def expand(text, bodies, depth=0):
    """text plus the bodies of the macros it invokes (recursively)."""
    out = [text]
    if depth > 6:
        return text
    for m in re.finditer(r"^\s*([A-Z][A-Z0-9_]+)\b", strip_comments(text), flags=re.M):
        if m.group(1) in bodies:
            out.append(expand(bodies[m.group(1)], bodies, depth + 1))
    return "\n".join(out)


def check_kernels(kernels):
    bodies = macro_bodies()
    for v, f in VARIANTS.items():
        text = read(f)
        # numeric labels anywhere outside .macro bodies
        outside = re.sub(r"^\s*\.macro\b.*?^\s*\.endm", "", strip_comments(text), flags=re.M | re.S)
        for m in re.finditer(r"^\s*(\d+):", outside, flags=re.M):
            err("%s: numeric label %s: outside a macro" % (f, m.group(1)))
        for m in re.finditer(r"^FUNC\s+(\w+)\n(.*?)^ENDF\s+\1", text, flags=re.M | re.S):
            name, body = m.group(1), m.group(2)
            k = name[len("pqk_x86_%s_" % v):]
            for lab in re.findall(r"^\s*(\.L[\w.]+):", strip_comments(body), flags=re.M):
                if not lab.startswith(".L%s_" % k):
                    err("%s: label %s in %s does not follow .L%s_<step>" % (f, lab, name, k))
            # header comment: the last comment block before FUNC naming this kernel
            before = text[:m.start()]
            blocks = list(re.finditer(r"/\* =+\n(.*?)\* =+ \*/", before, flags=re.S))
            hdr = None
            for b in reversed(blocks):
                if name in b.group(1):
                    hdr = b.group(1)
                    break
            if hdr is None:
                err("%s: no header comment for %s" % (f, name))
            else:
                for field in ("Args:", "Returns:", "Clobbers:", "Algorithm:", "Tail:"):
                    if field not in hdr:
                        err("%s: header of %s lacks %s" % (f, name, field))
            full = expand(body, bodies)
            for mark in ("[check]", "[main]", "[tail]", "[result]"):
                if mark not in full:
                    err("%s: %s lacks skeleton marker %s" % (f, name, mark))
    print("labels / header comments / skeleton markers checked")


# ---------------------------------------------------------------- 6. clobbers
GPR = {}
for r in ("ax", "bx", "cx", "dx"):
    for n in ("r%s" % r, "e%s" % r, r, r[0] + "l", r[0] + "h"):
        GPR[n] = "r" + r
for r in ("si", "di", "bp", "sp"):
    for n in ("r%s" % r, "e%s" % r, r, r + "l"):
        GPR[n] = "r" + r
for i in range(8, 16):
    for s in ("", "d", "w", "b"):
        GPR["r%d%s" % (i, s)] = "r%d" % i
NOWRITE = re.compile(r"^(cmp|test|bt$|ucomisd|vucomisd|comisd|vptest|vtestp|kortest|ktest|j|call|ret|push|nop|prefetch|vzeroupper)")


def reg_name(op):
    op = re.sub(r"\{.*", "", op.strip())
    m = re.fullmatch(r"%([a-z0-9]+)", op)
    if not m:
        return None
    r = m.group(1)
    if r in GPR:
        return GPR[r]
    m2 = re.fullmatch(r"[xyz]mm(\d+)", r)
    if m2:
        return "v" + m2.group(1)
    if re.fullmatch(r"k[0-7]", r):
        return r
    return None


def split_ops(s):
    ops, depth, cur = [], 0, ""
    for c in s:
        if c in "({":
            depth += 1
        elif c in ")}":
            depth -= 1
        if c == "," and depth == 0:
            ops.append(cur)
            cur = ""
        else:
            cur += c
    if cur.strip():
        ops.append(cur)
    return [o.strip() for o in ops]


def analyse(so):
    text = run(["objdump", "-d", "--no-show-raw-insn", "-w", so])
    syms = {}
    for line in run(["readelf", "-sW", so]).splitlines():
        f = line.split()
        if len(f) >= 8 and f[3] in ("FUNC", "OBJECT") and f[6] not in ("UND", "ABS"):
            syms[f[7]] = (int(f[1], 16), int(f[2]), f[3])
    data = open(so, "rb").read()
    secs = {}
    for line in run(["readelf", "-SW", so]).splitlines():
        m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)", line)
        if m:
            secs[m.group(1)] = (int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16))

    def func_at(addr):
        for n, (a, s, t) in syms.items():
            if t == "FUNC" and a <= addr < a + s:
                return n
        return None

    def table_targets(name):
        a, size, t = syms[name]
        for sa, soff, ssz in secs.values():
            if sa <= a < sa + ssz:
                raw = data[soff + a - sa: soff + a - sa + size]
                break
        else:
            return []
        out = []
        for i in range(0, size - size % 4, 4):
            tgt = a + int.from_bytes(raw[i:i + 4], "little", signed=True)
            fn = func_at(tgt)
            if fn is None:
                return []
            out.append(fn)
        return out

    info, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if m:
            cur = m.group(1)
            info[cur] = {"w": set(), "calls": set(), "push": set(), "pop": set()}
            continue
        m = re.match(r"^\s*[0-9a-f]+:\s*(\S+)\s*(.*?)\s*(#.*)?$", line)
        if not m or cur is None:
            continue
        mn, rest, cmt = m.group(1), m.group(2), m.group(3) or ""
        d = info[cur]
        ops = split_ops(rest) if rest else []
        for sym in re.findall(r"<([^>+]+)", cmt + " " + rest):
            if sym in syms and sym != cur:
                if syms[sym][2] == "FUNC":
                    d["calls"].add(sym)
                else:
                    d["calls"].update(table_targets(sym))
        if mn == "push":
            d["push"].add(reg_name(ops[0]))
            continue
        if mn == "pop":
            d["pop"].add(reg_name(ops[0]))
            d["w"].add(reg_name(ops[0]))
            continue
        if mn in ("cqto", "cqo"):
            d["w"].add("rdx")
            continue
        if NOWRITE.match(mn):
            continue
        if mn.startswith("xchg"):
            for o in ops:
                d["w"].add(reg_name(o))
            continue
        if mn.startswith("imul") and len(ops) == 1:
            d["w"].update({"rax", "rdx"})
            continue
        if ops:
            d["w"].add(reg_name(ops[-1]))
    for d in info.values():
        d["w"].discard(None)
        d["w"].discard("rsp")
    memo = {}

    def written(f, stack=()):
        if f in memo:
            return memo[f]
        if f in stack:
            return set()
        d = info.get(f, {"w": set(), "calls": set(), "push": set(), "pop": set()})
        w = set(d["w"])
        for c in d["calls"]:
            w |= written(c, stack + (f,))
        memo[f] = w
        return w
    return info, written


def parse_clobbers(hdr):
    m = re.search(r"Clobbers:(.*?)\bflags\b", hdr, flags=re.S)
    if not m:
        return None
    txt = re.sub(r"\n\s*\*", " ", m.group(1))
    out = set()
    for tok in [t.strip() for t in txt.split(",") if t.strip()]:
        r = re.fullmatch(r"([a-z]*?)(\d+)-[a-z]*?(\d+)", tok)
        if r:
            base = r.group(1)
            for i in range(int(r.group(2)), int(r.group(3)) + 1):
                out.add(normalise(base + str(i)))
        else:
            out.add(normalise(tok))
    return out


def normalise(r):
    if r in GPR:
        return GPR[r]
    m = re.fullmatch(r"[xyz]mm(\d+)", r)
    if m:
        return "v" + m.group(1)
    return r


def show(s):
    def key(r):
        return (0 if r.startswith("r") else 1 if r.startswith("v") else 2,
                int(re.sub(r"\D", "", r) or -1), r)
    return " ".join(sorted(s, key=key)) or "-"


def check_clobbers():
    with tempfile.TemporaryDirectory() as tmp:
        for v, f in VARIANTS.items():
            obj = os.path.join(tmp, v + ".o")
            so = os.path.join(tmp, v + ".so")
            run(["gcc", "-c", os.path.join(X86, f), "-o", obj])
            run(["gcc", "-shared", "-nostdlib", "-o", so, obj])
            info, written = analyse(so)
            text = read(f)
            ok = 0
            for m in re.finditer(r"^FUNC\s+(\w+)$", text, flags=re.M):
                name = m.group(1)
                blocks = list(re.finditer(r"/\* =+\n(.*?)\* =+ \*/", text[:m.start()], flags=re.S))
                hdr = next((b.group(1) for b in reversed(blocks) if name in b.group(1)), "")
                doc = parse_clobbers(hdr)
                w = written(name)
                d = info[name]
                saved = d["push"] & d["pop"]     # pushed and popped: preserved
                bad_cs = (w & CALLEE_SAVED) - saved
                if bad_cs:
                    err("%s: %s writes callee-saved %s without saving it" % (f, name, show(bad_cs)))
                strict = w - CALLEE_SAVED       # every caller-saved write
                comp = strict - saved           # minus pushed-and-popped ones
                if doc is None:
                    err("%s: %s: unparsable Clobbers line" % (f, name))
                    continue
                if not (comp <= doc <= strict):
                    err("%s: %s Clobbers mismatch\n      documented, never written: %s\n      written, not documented:   %s"
                        % (f, name, show(doc - strict), show(comp - doc)))
                else:
                    ok += 1
                if VERBOSE:
                    print("  %s: %s (saved: %s)" % (name, show(comp), show(saved)))
            print("%s: clobber lists verified for %d kernels" % (f, ok))


def main():
    kernels = abi_kernels()
    check_defined_once()
    check_headers_empty()
    check_kernel_set(kernels)
    check_kernels(kernels)
    check_clobbers()
    print("structure check: %s" % ("ok" if not errors else "%d problem(s)" % len(errors)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
