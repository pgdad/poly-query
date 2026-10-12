#!/usr/bin/env python3
"""Charts for docs/story/: standalone copies of the main report charts plus a timeline of agents
running in parallel (with the waits imposed by the subscription usage gate).

  story_assets.py [--waves-log /srv/polyquery/waves.log]

Reads docs/results/report.html and experiments/runs/*/manifest.json; writes docs/story/charts/*.svg.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/story/charts"
# Report chart index -> file name (order of the charts in report.html).
PICK = {0: "dev-time", 2: "cost", 4: "conformance", 5: "latency", 6: "memory", 9: "loc", 8: "http-throughput"}
LOCAL = dt.timezone(dt.timedelta(hours=-4), "EDT")


def light_vars(html: str) -> str:
    return re.search(r":root\{color-scheme:light;(.*?)\}", html).group(1)


def standalone(svg: str, title: str, vars_: str) -> str:
    style = (f"<style>svg{{{vars_}}} .lbl,.val{{fill:#0b0b0b;font:12px system-ui,sans-serif}} .val{{fill:#52514e}}"
             " .axis{stroke:#d9d8d4} .ttl{font:600 14px system-ui,sans-serif;fill:#0b0b0b}</style>")
    m = re.match(r"<svg([^>]*)>", svg)
    attrs = m.group(1)
    vb = re.search(r'viewBox="([\d.\s-]+)"', attrs)
    x, y, w, h = (float(v) for v in vb.group(1).split())
    body = svg[m.end():-len("</svg>")]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x} {y - 28} {w} {h + 28}" width="{w}" '
            f'height="{h + 28}">{style}<rect x="{x}" y="{y - 28}" width="{w}" height="{h + 28}" fill="#fcfcfb"/>'
            f'<text class="ttl" x="{x + 4}" y="{y - 10}">{title}</text>{body}</svg>')


def report_charts() -> list[str]:
    html = (ROOT / "docs/results/report.html").read_text()
    vars_ = light_vars(html)
    written = []
    for i, m in enumerate(re.finditer(r"<svg.*?</svg>", html, re.S)):
        if i not in PICK:
            continue
        # The chart title is the figcaption just before the SVG.
        cap = re.findall(r"<figcaption>(.*?)</figcaption>", html[:m.start()], re.S)[-1]
        cap = re.sub(r"<[^>]+>", "", cap).strip()
        cap = re.sub(r"\s*\(1m, [^)]*\)", " (1M rows)", cap)   # drop the internal benchmark id
        p = OUT / f"{PICK[i]}.svg"
        p.write_text(standalone(m.group(0), cap, vars_))
        written.append(p.name)
    return written


def gate_waits(log: Path) -> list[tuple[dt.datetime, dt.datetime, str]]:
    """Runs that waited at the usage gate: (prepared, launched, run id)."""
    if not log.exists():
        return []
    text = log.read_text(errors="replace")
    gated = set(re.findall(r"\[([^\]]+)\] usage gate: five_hour", text))
    launched = {rid: dt.datetime.fromisoformat(ts) for ts, rid in
                re.findall(r"^(\S+) \[([^\]]+)\] agent launched", text, re.M)}
    out = []
    for rid in sorted(gated):
        stamp = dt.datetime.strptime(rid.rsplit("-", 1)[1], "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc)
        if rid in launched:
            out.append((stamp, launched[rid], rid))
    return out


def timeline(waves_log: Path) -> str:
    runs = []
    for f in (ROOT / "experiments/runs").glob("*/manifest.json"):
        m = json.loads(f.read_text())
        if m.get("started") and m.get("wall_seconds"):
            s = dt.datetime.fromisoformat(m["started"])
            runs.append((s, s + dt.timedelta(seconds=m["wall_seconds"]), m["language"]))
    t0 = min(r[0] for r in runs).replace(minute=0, second=0)
    t1 = max(r[1] for r in runs)
    step = dt.timedelta(minutes=10)
    buckets = []
    t = t0
    while t < t1:
        six = sum(1 for a, b, lang in runs if a < t + step and b > t and not lang.endswith("asm") and "asm" not in lang)
        asm = sum(1 for a, b, lang in runs if a < t + step and b > t and "asm" in lang)
        buckets.append((t, six, asm))
        t += step
    W, H, L, B, T = 900, 320, 44, 46, 52
    pw, ph = W - L - 16, H - B - T
    ymax = max(s + a for _, s, a in buckets) + 1
    span = (t1 - t0).total_seconds()

    def x(when: dt.datetime) -> float:
        return L + pw * (when - t0).total_seconds() / span

    def y(v: float) -> float:
        return T + ph - ph * v / ymax

    bw = pw * step.total_seconds() / span
    parts = []
    for a, b, _ in gate_waits(waves_log):
        parts.append(f'<rect x="{x(a):.1f}" y="{T}" width="{max(x(b) - x(a), 1):.1f}" height="{ph}" fill="#eda100" '
                     f'opacity="0.18"/>')
    for v in range(0, ymax + 1, 2):
        parts.append(f'<line class="axis" x1="{L}" x2="{L + pw}" y1="{y(v):.1f}" y2="{y(v):.1f}"/>'
                     f'<text class="val" x="{L - 6}" y="{y(v) + 4:.1f}" text-anchor="end">{v}</text>')
    for t, six, asm in buckets:
        if six:
            parts.append(f'<rect x="{x(t):.1f}" y="{y(six):.1f}" width="{bw:.1f}" height="{y(0) - y(six):.1f}" '
                         f'fill="#2a78d6"/>')
        if asm:
            parts.append(f'<rect x="{x(t):.1f}" y="{y(six + asm):.1f}" width="{bw:.1f}" '
                         f'height="{y(six) - y(six + asm):.1f}" fill="#6250d6"/>')
    day = (t0.astimezone(LOCAL) + dt.timedelta(hours=1)).replace(minute=0, second=0, microsecond=0)
    while day < t1:
        lt = day.astimezone(LOCAL)
        if lt.hour % 6 == 0:
            parts.append(f'<line class="axis" x1="{x(day):.1f}" x2="{x(day):.1f}" y1="{T + ph}" y2="{T + ph + 5}"/>'
                         f'<text class="val" x="{x(day):.1f}" y="{T + ph + 18}" text-anchor="middle">'
                         f'{lt.strftime("%a %H:%M")}</text>')
        day += dt.timedelta(hours=1)
    legend = ('<rect x="4" y="30" width="10" height="10" fill="#2a78d6"/><text class="lbl" x="18" y="39">six engines</text>'
              '<rect x="106" y="30" width="10" height="10" fill="#6250d6"/><text class="lbl" x="120" y="39">assembly kernels and engines</text>'
              '<rect x="300" y="30" width="10" height="10" fill="#eda100" opacity="0.4"/>'
              '<text class="lbl" x="314" y="39">a run waits at the usage gate (5-hour window above 80 %)</text>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
            '<style>.lbl,.val{fill:#0b0b0b;font:12px system-ui,sans-serif}.val{fill:#52514e}.axis{stroke:#d9d8d4}'
            '.ttl{font:600 14px system-ui,sans-serif;fill:#0b0b0b}</style>'
            f'<rect width="{W}" height="{H}" fill="#fcfcfb"/>'
            '<text class="ttl" x="4" y="19">Agent sessions active in each 10-minute slot (US Eastern time)</text>'
            f'{legend}{"".join(parts)}'
            f'<text class="val" x="{L + pw / 2}" y="{H - 6}" text-anchor="middle">'
            'gaps: the orchestrator (one Claude session) reviewing, merging and planning the next wave</text></svg>')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--waves-log", default="/srv/polyquery/waves.log")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    names = report_charts()
    (OUT / "parallel-agents.svg").write_text(timeline(Path(a.waves_log)))
    print("wrote", ", ".join(names + ["parallel-agents.svg"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
