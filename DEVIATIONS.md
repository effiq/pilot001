# Pilot 001 · Deviation Log

**Status: Retroactive ｜ Compiled 2026-10-06 ｜ Discovery method: three-way reconciliation**

This file documents discrepancies between the frozen Protocol Lock v1.0 text and the as-executed implementation of Pilot 001. It was compiled on 2026-10-06, after the pilot closed with a PASS verdict, by a line-by-line reconciliation of (a) the frozen protocol as published at commit `3faaaa7` (plus Amendment-01/02, commit `d0eabf3`), (b) the executed stage scripts archived in this repository, and (c) the published verdict (VERDICT.md) and raw logs (`effiq/pilot-logs`).

The reconciliation was triggered by the pre-freeze review of the Pilot 002 protocol (v2.0), which caught drafting errors of a class that had never been systematically checked against Pilot 001. This log closes that gap.

**Headline: none of the entries below changes any published number or the PASS verdict.** Each entry states why. The performance-half rule (paired bootstrap, CI lower bound ≥ 1.20×) was verified as an exact three-way match — protocol text, verdict script, and published result — and every published figure was independently recomputed twice from raw logs (`05-verdict.sh --verify` and `06-quality-gate.sh --verify`, byte-identical on separate machines). The discrepancies below live in the protocol-text layer, not the data layer.

---

## D1 — Workload construction (L2)

- **Frozen protocol:** "Data sources: public datasets, sampled and human-rewritten."
- **As executed:** a declarative synthetic generator — template pools (document, code, article forms) with seeded random slot filling, embedded in `stages/04-formal.sh` and `stages/06-quality-gate.sh` (`GENERATOR` blocks). No public datasets were sampled; no human rewriting was performed.
- **Public-facing accuracy:** VERDICT.md declared the true construction from the day of publication ("Workload: declared synthetic generator — 3 forms …"), and the full generator code has been public and inspectable in this repository since the measurement window. No public material claims dataset-derived or human-rewritten prompts.
- **Impact:** none on the verdict. The claim is and was scoped to "the declared workload"; both arms faced identical prompts; the frozen-set hash (`728b2f83…5cf7d`) anchors what was actually run. The realism gap between synthetic-template load and production load is real and is precisely what Pilot 002 addresses with a replayed production trace.
- **Process assessment:** the construction change happened between protocol freeze and script implementation and should have been logged as an amendment. It was not. Logged here.

## D2 — Quality-gate rubric axes (L5)

- **Frozen protocol:** fixed rubric "correctness / completeness / instruction-following, 0–10 each axis".
- **As executed:** `correctness / instruction_following / clarity` (see `stages/06-quality-gate.sh`, `AXES` and the judge prompt), fixed before any quality data was collected and applied identically to both arms under blind assignment.
- **Impact:** none on the verdict. The published quality numbers (VERDICT.md) report the executed axes; the blind comparison used one ruler for both arms throughout. The naming change (`completeness` → `clarity`) should have been logged as an amendment. It was not. Logged here.

## D3 — Quality-gate tolerance, safe direction (L5)

- **Frozen protocol:** FAIL "if any axis of either arm averages more than 0.1 below the other arm" (per-axis condition only).
- **As executed:** stricter — the gate required **both** the overall mean delta **and** every per-axis delta to be ≥ −0.1 (`gate_ok = overall >= -TOL and all(...)` in `stages/06-quality-gate.sh`).
- **Impact:** the executed gate was harder to pass than the frozen protocol required. The result passes under both readings (overall delta +0.149; axis deltas +0.213 / +0.180 / +0.053). Verdict invariant.

## D4 — Day-7 checkpoint probe form (L6)

- **Frozen protocol:** speculative-decoding acceptance probe of "100 requests per prompt tier", checkpoint date 2026-10-12.
- **As executed:** an offline simulation over archived (prompt, output) token streams from 27 probe requests (max_n=4, k_spec=5), run on the first night (2026-10-05), ahead of the checkpoint date. Acceptance 0.134 < 0.50 triggered the pre-registered swap clause, leading to the EAGLE feasibility probe and Amendment-01 — all before any formal measurement data existed. Evidence: `effiq/pilot-logs` 2026-10-05/02-armb-probe, acceptance.jsonl sha256 `fff7dd1f…d287d65`.
- **Impact:** the probe served its decision function (keep/kill speculative decoding) earlier and cheaper than specified; its outputs were exploratory and never entered the CI. Verdict invariant.

## D5 — This log

- **Frozen protocol (L7):** published materials include "the deviation log".
- **Reality:** no deviation log file existed until this one. This file closes that commitment.

---

## Going forward

Starting with Pilot 002, a **pre-freeze protocol↔script reconciliation** (line-by-line, locked items vs. implementing scripts) is a standard gate before the operator's freeze signature, with a second pass before the measurement window opens. The Pilot 002 draft review that prompted this log caught three defects under that procedure; this log is the same procedure applied retroactively to Pilot 001.

*Effiq's governance claim is not "no errors". It is: errors are found, logged, and published — with the evidence to check us.*
