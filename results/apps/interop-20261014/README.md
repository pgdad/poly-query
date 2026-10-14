# pqledger ledger interoperability — 2026-10-14

`tools/validation/pqledger_interop.py` (produce / consume / readback; AArch64 phases via
`tools/remote/arm_interop.sh` on spark), engines at master after the app-pqledger merges.
Expected outputs and expected PQCF rows come only from the engine-free reference
(`tools/validation/pqledger_ref.py`) run on the same files.

* `interop.json` — every check and failure (none); `results/` — per-phase output.
* `raw-ledgers.tar.gz` — the eight produced ledgers and the 72 written copies.
* Result: all 8 implementations produce ledgers row-identical to the reference; every
  implementation reads and writes every other's ledger (and the reference's), and every
  producer reads its ledger back after each of the others wrote to it.
