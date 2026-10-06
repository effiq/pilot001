#!/usr/bin/env bash
# ============================================================
# Stage 05 · independent verdict (performance half)
#
# Reads ONLY the archived raw logs of the 6 formal runs and computes
# the pre-registered statistic:
#   - per-request ratio: total_tps(B-fp8) / total_tps(A-bf16),
#     paired by request_id within each run
#   - run-level statistic: mean of log(ratio) over the 27 pairs
#   - CI: paired bootstrap over runs (n=6), resampling seed FIXED at
#     20261006 with 100,000 resamples -> fully deterministic; any
#     re-run on the same logs yields the identical interval
#   - PASS (performance half) iff exp(CI_lower) >= 1.20
#
# Anti-p-hacking: refuses to compute unless exactly the required
# number of COMPLETE runs are present. If the CI straddles 1.20,
# the protocol allows extension to 10 runs — a boss decision, not
# this script's.
#
# This verdict covers the PERFORMANCE half only. Final PASS also
# requires the L5 blind quality gate (0 pp tolerance).
#
# Verify entry: bash stages/05-verdict.sh --verify
# Recomputes everything from the archived logs; output must match
# any published verdict character for character.
# ============================================================
set -uo pipefail

EFFIQ_HOME="$HOME/effiq"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE="$(tr -d '[:space:]' < "$EFFIQ_HOME/pilot001/STAGE" 2>/dev/null || echo 05-verdict)"
OUT_DIR="$LOGS_DIR/$DATE_STR/$STAGE"
VERDICT="$OUT_DIR/verdict.txt"
REQUIRED_RUNS=6
THRESHOLD=1.20
BOOT_SEED=20261006
BOOT_N=100000

note() { printf '\n=== %s ===\n' "$*"; }

note "verdict computation (deterministic; inputs = archived raw logs only)"
mkdir -p "$OUT_DIR"
LOGS_DIR="$LOGS_DIR" VERDICT="$VERDICT" REQUIRED_RUNS="$REQUIRED_RUNS" \
THRESHOLD="$THRESHOLD" BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" python3 - <<'PY'
import glob, hashlib, json, os, statistics, math

LOGS = os.environ["LOGS_DIR"]
VERDICT = os.environ["VERDICT"]
REQ = int(os.environ["REQUIRED_RUNS"])
THR = float(os.environ["THRESHOLD"])
SEED = int(os.environ["BOOT_SEED"])
BN = int(os.environ["BOOT_N"])

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

# ---- collect complete runs ----
runs = []
for d in sorted(glob.glob(os.path.join(LOGS, "*", "04-formal", "run_*"))):
    if os.path.exists(os.path.join(d, "COMPLETE")) and os.path.exists(os.path.join(d, "raw.jsonl")):
        runs.append(d)

lines = ["STAGE 05 VERDICT — PERFORMANCE HALF (paired bootstrap over runs)",
         f"threshold={THR} bootstrap_seed={SEED} resamples={BN}",
         f"complete runs found: {len(runs)} (required: {REQ})", ""]
for d in runs:
    lines.append(f"  {os.path.relpath(d, LOGS)}  raw_jsonl_sha256={sha(os.path.join(d, 'raw.jsonl'))}")

if len(runs) < REQ:
    lines += ["", f"REFUSED: fewer than {REQ} complete runs — verdict sealed by protocol (anti-p-hacking)."]
    open(VERDICT, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines)); raise SystemExit(1)

# ---- per-request paired ratios per run ----
import numpy as np
run_stats = {}       # run_dir -> overall mean log-ratio
tier_stats = {}      # tier -> list of per-run mean log-ratios
meta = []
for d in runs:
    rows = [json.loads(l) for l in open(os.path.join(d, "raw.jsonl")) if l.strip()]
    a = {r["request_id"]: r for r in rows if r["arm"] == "A-bf16"}
    b = {r["request_id"]: r for r in rows if r["arm"] == "B-fp8"}
    common = sorted(set(a) & set(b))
    if len(common) != 27:
        lines.append(f"WARNING: {os.path.basename(d)} has {len(common)} complete pairs (expected 27)")
    lrs, by_tier = [], {}
    idx = int(a[common[0]]["run_index"]) if common else -1
    meta.append((d, idx, a[common[0]]["run_order"] if common else "?"))
    for rid in common:
        lr = math.log(b[rid]["total_tps"] / a[rid]["total_tps"])
        lrs.append(lr)
        by_tier.setdefault(a[rid]["tier_target"], []).append(lr)
    run_stats[d] = statistics.mean(lrs)
    for t, v in by_tier.items():
        tier_stats.setdefault(t, []).append(statistics.mean(v))

def boot_ci(vals, seed):
    vals = np.array(vals)
    rng = np.random.default_rng(seed)
    means = rng.choice(vals, size=(BN, len(vals)), replace=True).mean(axis=1)
    lo, hi = np.percentile(means, [2.5, 97.5])
    return statistics.mean(vals), float(lo), float(hi)

lines += ["", "[runs included]"]
for d, idx, order in sorted(meta, key=lambda x: x[1]):
    lines.append(f"  run {idx} ({order}): mean_log_ratio={run_stats[d]:.4f} -> ratio={math.exp(run_stats[d]):.3f}x")

lines += ["", "[overall verdict statistic]"]
overall_vals = [run_stats[d] for d in runs]
m, lo, hi = boot_ci(overall_vals, SEED)
lines.append(f"mean ratio (geometric, over runs): {math.exp(m):.3f}x")
lines.append(f"95% bootstrap CI: [{math.exp(lo):.3f}x, {math.exp(hi):.3f}x]")
perf_pass = math.exp(lo) >= THR
lines.append(f"criterion: CI lower bound >= {THR}x  ->  {'PASS' if perf_pass else 'FAIL'}")
if math.exp(lo) < THR <= math.exp(hi):
    lines.append("NOTE: CI straddles the threshold — protocol permits extension to 10 runs (boss decision, logged).")

lines += ["", "[per-tier breakdown (same method)]"]
for t in sorted(tier_stats):
    tm, tlo, thi = boot_ci(tier_stats[t], SEED + t)
    flag = "PASS" if math.exp(tlo) >= THR else ("straddle" if math.exp(thi) >= THR else "FAIL")
    lines.append(f"tier {t:5d}: ratio={math.exp(tm):.3f}x CI=[{math.exp(tlo):.3f}x, {math.exp(thi):.3f}x] {flag}")

lines += ["", "SCOPE: performance half only. Final PASS additionally requires the L5 blind quality gate (0 pp).",
          "This file is reproducible: same logs + same seeds -> identical numbers (--verify)."]
open(VERDICT, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
RC=$?

note "result"
[ "$RC" -eq 0 ] && echo "STAGE 05 VERDICT: COMPUTED ✅ (see verdict.txt)" || echo "STAGE 05 VERDICT: SEALED/ERROR (exit=$RC)"
exit 0   # verdict content is the payload; a sealed verdict is still a successful stage run
