#!/usr/bin/env python3
"""Deterministic synthetic bank-statement CSV exports for pqledger (spec/apps/pqledger.md).

  bankgen.py --style us-checking|us-card|de-giro --from 2026-01 --to 2026-03 [--seed 1]
             [--per-month 40] [--out FILE]

Styles (the matching pqledger [account] settings are printed with --print-config):
  us-checking  Date (YYYY-MM-DD), Description, Amount (signed, '.' decimals), quoted fields
  us-card      "Transaction Date" (MM/DD/YYYY), Description, Amount (charges positive -> invert_sign),
               "$" currency symbol, thousands ',' and parenthesized refunds
  de-giro      ';' delimiter, a 2-line preamble, Buchungstag (DD.MM.YYYY), Verwendungszweck,
               Soll/Haben (debit/credit), ',' decimals and '.' thousands, CRLF line ends
The same seed and arguments always produce the same bytes.
"""
from __future__ import annotations

import argparse
import calendar
import random
import sys
from decimal import Decimal

MERCHANTS = [
    ("Whole Foods Market #{n}", 25, 180), ("Trader Joe's #{n}", 15, 120), ("SAFEWAY {n}", 10, 150),
    ("Shell Oil {n}", 30, 80), ("Chevron #{n}", 25, 90), ("SQ *Blue Bottle Coffee {n}", 4, 15),
    ("Starbucks Store {n}", 4, 12), ("AMAZON.COM*{c} AMZN.COM/BILL", 8, 240), ("Netflix.com", 15, 16),
    ("Spotify USA", 11, 12), ("UBER   *TRIP {c}", 9, 45), ("Lyft Ride {n}", 8, 40), ("CVS/PHARMACY #{n}", 6, 70),
    ("Home Depot #{n}", 12, 400), ("REI #{n}", 20, 300), ("Chipotle {n}", 9, 25), ("Pacific Gas & Electric", 60, 220),
    ("Comcast Cable", 70, 110), ("Café Mélange", 5, 30), ("7-Eleven 12", 3, 20),
]
DE_MERCHANTS = [
    ("REWE Markt GmbH {n}", 8, 120), ("EDEKA Center {n}", 10, 90), ("Aral Tankstelle {n}", 30, 90),
    ("DB Vertrieb GmbH", 15, 140), ("Lidl Dienstleistung {n}", 6, 70), ("Bäckerei Schäfer", 3, 15),
    ("Stadtwerke München", 60, 160), ("Telekom Deutschland", 30, 60),
]


def month_range(a: str, b: str) -> list[tuple[int, int]]:
    y, m = map(int, a.split("-"))
    y2, m2 = map(int, b.split("-"))
    out = []
    while (y, m) <= (y2, m2):
        out.append((y, m))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out


def money(r: random.Random, lo: int, hi: int) -> Decimal:
    return Decimal(r.randint(lo * 100, hi * 100)).scaleb(-2)


def transactions(style: str, months, seed: int, per_month: int):
    """[(year, month, day, description, amount)] money out negative, sorted by date."""
    out = []
    pool = DE_MERCHANTS if style == "de-giro" else MERCHANTS
    for y, m in months:
        r = random.Random(f"{seed}-{style}-{y}-{m}")
        days = calendar.monthrange(y, m)[1]
        if style != "us-card":
            pay = "Gehalt ACME GmbH" if style == "de-giro" else "PAYROLL ACME CORP"
            out.append((y, m, min(15, days), pay, Decimal("4250.00") if style != "de-giro" else Decimal("3810.55")))
            rent = "Miete Hausverwaltung" if style == "de-giro" else "RENT - OAKWOOD APTS"
            out.append((y, m, 1, rent, Decimal("-1850.00") if style != "de-giro" else Decimal("-1120.00")))
        for _ in range(per_month):
            tmpl, lo, hi = pool[r.randrange(len(pool))]
            desc = tmpl.format(n=r.choice([str(r.randint(100, 9999)), str(r.randint(100, 9999))]),
                               c="".join(r.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6)))
            out.append((y, m, r.randint(1, days), desc, -money(r, lo, hi)))
        if r.random() < 0.5 and out:
            y0, m0, d0, desc, amt = out[-1]
            out.append((y0, m0, min(days, d0 + 2), desc, -amt))  # a refund
    out.sort(key=lambda t: (t[0], t[1], t[2]))
    return out


def fmt_us(v: Decimal) -> str:
    return f"{v:.2f}"


def fmt_card(v: Decimal) -> str:
    s = f"{abs(v):,.2f}"
    return f"(${s})" if v < 0 else f"${s}"


def fmt_de(v: Decimal) -> str:
    s = f"{v:,.2f}"
    return s.replace(",", "_").replace(".", ",").replace("_", ".")


def render(style: str, txs) -> bytes:
    if style == "us-checking":
        lines = ["Date,Description,Amount"]
        for y, m, d, desc, amt in txs:
            lines.append(f'{y:04d}-{m:02d}-{d:02d},"{desc}",{fmt_us(amt)}')
        return ("\n".join(lines) + "\n").encode("utf-8")
    if style == "us-card":
        lines = ['"Transaction Date","Description","Amount"']
        for y, m, d, desc, amt in txs:
            lines.append(f'{m:02d}/{d:02d}/{y:04d},"{desc}","{fmt_card(-amt)}"')
        return ("\n".join(lines) + "\n").encode("utf-8")
    lines = ["Kontoumsätze Girokonto;;;", "Zeitraum;;;", "Buchungstag;Verwendungszweck;Soll;Haben"]
    for y, m, d, desc, amt in txs:
        soll, haben = (fmt_de(-amt), "") if amt < 0 else ("", fmt_de(amt))
        lines.append(f"{d:02d}.{m:02d}.{y:04d};{desc};{soll};{haben}")
    return ("\r\n".join(lines) + "\r\n").encode("utf-8")


CONFIG = {
    "us-checking": "",
    "us-card": "date_column = Transaction Date\ndate_format = MM/DD/YYYY\ncurrency_symbol = $\n"
               "thousands_separator = ,\ninvert_sign = true\n",
    "de-giro": "delimiter = ;\nskip_lines = 2\ndate_column = Buchungstag\ndate_format = DD.MM.YYYY\n"
               "description_column = Verwendungszweck\namount_mode = debit_credit\ndebit_column = Soll\n"
               "credit_column = Haben\ndecimal_separator = ,\nthousands_separator = .\n",
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--style", choices=sorted(CONFIG), required=True)
    ap.add_argument("--from", dest="frm", required=True)
    ap.add_argument("--to", required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--per-month", type=int, default=40)
    ap.add_argument("--out")
    ap.add_argument("--print-config", action="store_true", help="print the [account] keys for this style")
    a = ap.parse_args()
    if a.print_config:
        sys.stdout.write(CONFIG[a.style])
        return 0
    data = render(a.style, transactions(a.style, month_range(a.frm, a.to), a.seed, a.per_month))
    if a.out:
        with open(a.out, "wb") as f:
            f.write(data)
    else:
        sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
