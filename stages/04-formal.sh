#!/usr/bin/env bash
# ============================================================
# Stage 04 · FORMAL L4 measurement (interleaved block-crossover)
#
# This is the real one. Data from this stage ENTERS the CI.
# Arm A: BF16 vLLM defaults. Arm B: FP8 dynamic quantization
# (Amendment-01). Block-crossover per Amendment-02.
#
# Design:
#   - 6 runs total (protocol L4); each invocation of this stage
#     executes exactly ONE run. Run index auto-increments by
#     scanning completed runs in the log repo — just re-run the
#     same nightly command on later nights.
#   - Per run: 27 prompts (3 tiers x 3 forms x 3 reps), freshly
#     re-sampled from the declared generator (L2 dynamic load).
#     run_seed = 20261003 + run_index. max_tokens per request
#     sampled U{200..800} from the same seeded rng and recorded.
#   - Odd runs measure A first, even runs B first (order-effect
#     cancellation). Pairing by request_id.
#   - ANTI-P-HACKING: this stage prints descriptive per-run means
#     ONLY. No CI, no PASS/FAIL is computed until the independent
#     verdict stage after all 6 runs are complete.
#
# Verify entry: bash stages/04-formal.sh --verify [run_dir]
# Recomputes hashes and per-arm means from the raw log only.
# ============================================================
set -uo pipefail

EFFIQ_HOME="$HOME/effiq"
SCRIPTS_DIR="$EFFIQ_HOME/pilot001"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE="$(tr -d '[:space:]' < "$SCRIPTS_DIR/STAGE" 2>/dev/null || echo 04-formal)"
BASE_SEED=20261003
TOTAL_RUNS=6
MAX_SECONDS=3600               # K8 budget guard

MODEL="Qwen/Qwen2.5-14B-Instruct"

note() { printf '\n=== %s ===\n' "$*"; }

# ---------- --verify ----------
if [ "${1:-}" = "--verify" ]; then
  D="${2:-}"
  [ -n "$D" ] && [ -f "$D/raw.jsonl" ] || { echo "VERIFY: usage: --verify <run_dir containing raw.jsonl>"; exit 1; }
  python3 - "$D" <<'PY'
import hashlib, json, statistics, sys, os
d = sys.argv[1]
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()
for name in ("raw.jsonl", "plan.jsonl"):
    p = os.path.join(d, name)
    if os.path.exists(p): print(f"{name}: sha256={sha(p)}")
rows = [json.loads(l) for l in open(os.path.join(d, "raw.jsonl")) if l.strip()]
print("rows:", len(rows), "| arms:", sorted({r["arm"] for r in rows}),
      "| run_index:", sorted({r["run_index"] for r in rows}))
by = {}
for r in rows: by.setdefault((r["arm"], r["tier_target"]), []).append(r["total_tps"])
for (arm, tier) in sorted(by):
    print(f"arm={arm:6s} tier={tier:5d}: n={len(by[(arm,tier)])} mean_total_tps={statistics.mean(by[(arm,tier)]):.1f}")
print("VERIFY: recomputed from raw log only; descriptive stats only — CI lives in the verdict stage")
PY
  exit $?
fi

# ---------- locate completed runs, decide this run's index ----------
note "0. run bookkeeping"
COMPLETED=$(find "$LOGS_DIR" -type f -path "*/04-formal/run_*/COMPLETE" 2>/dev/null | wc -l | tr -d ' ')
RUN_IDX=$((COMPLETED + 1))
echo "completed formal runs: $COMPLETED / $TOTAL_RUNS"
if [ "$RUN_IDX" -gt "$TOTAL_RUNS" ]; then
  echo "ALL $TOTAL_RUNS FORMAL RUNS COMPLETE — nothing to do; switch STAGE to the verdict stage."
  exit 0
fi
RUN_DIR="$LOGS_DIR/$DATE_STR/$STAGE/run_${RUN_IDX}"
SUFFIX=2
while [ -e "$RUN_DIR" ]; do RUN_DIR="$LOGS_DIR/$DATE_STR/$STAGE/run_${RUN_IDX}-r${SUFFIX}"; SUFFIX=$((SUFFIX+1)); done
mkdir -p "$RUN_DIR"
RAW_JSONL="$RUN_DIR/raw.jsonl"
PLAN_JSONL="$RUN_DIR/plan.jsonl"
SUMMARY="$RUN_DIR/summary.txt"
RUN_SEED=$((BASE_SEED + RUN_IDX))
if [ $((RUN_IDX % 2)) -eq 1 ]; then ORDER="A-first"; else ORDER="B-first"; fi
GIT_REV=$(git -C "$SCRIPTS_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
echo "this run: index=$RUN_IDX seed=$RUN_SEED order=$ORDER dir=$RUN_DIR scripts_rev=$GIT_REV"

# ---------- env record ----------
note "1. time / host / GPU / tool versions"
date -u
hostname || true
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv || true
pip install -q vllm huggingface_hub
python3 -c "import vllm, torch; print('vllm:', vllm.__version__, '| torch:', torch.__version__, '| gpu:', torch.cuda.get_device_name(0))"

echo "banner: FORMAL L4 MEASUREMENT — this data enters the CI (after all 6 runs)"
START_TS=$(date +%s)

# ---------- shared generator ----------
GENERATOR='
import os, random

SEED = int(os.environ["RUN_SEED"])
rng = random.Random(SEED)
DOC_POOL = [
    "The {t} report describes quarter-over-quarter changes in {m}, noting that {a} rose by {n}% while {b} fell by {k}%.",
    "In section {s}, the authors argue that {m} depends primarily on {a}, citing measurements collected over {n} months.",
    "Field observations in region {s} indicate that {a} interacts with {b} when {m} exceeds {n} units.",
    "The committee reviewed {n} submissions on {m} and flagged {k} of them for inconsistencies in {a}.",
    "Historical records show that between year {n} and year {k}, {m} shifted from {a}-dominated to {b}-dominated regimes.",
    "Operators observed that raising {a} by {n}% reduced {b} latency by {k}%, but only when {m} remained below threshold {s}.",
    "Appendix {s} lists {n} edge cases where {m} diverges from the nominal model; each involves {a} exceeding {b}.",
    "The whitepaper compares {a} and {b} under {m} constraints, concluding that hybrid schemes outperform either alone by {n}%.",
]
CODE_POOL = [
    "def process_{f}(items, limit={n}):\n    total = 0\n    for it in items:\n        if it.value > limit:\n            total += it.value\n    return total",
    "class {F}Store:\n    def __init__(self, capacity={n}):\n        self.capacity = capacity\n        self.data = {{}}\n    def put(self, key, value):\n        if len(self.data) >= self.capacity:\n            self.data.pop(next(iter(self.data)))\n        self.data[key] = value",
    "def fetch_{f}(session, url, retries={k}):\n    for attempt in range(retries):\n        try:\n            return session.get(url, timeout={n})\n        except Exception:\n            time.sleep(2 ** attempt)\n    return None",
    "async def stream_{f}(queue):\n    while True:\n        item = await queue.get()\n        if item is None:\n            break\n        await handle_{f}(item, batch_size={n})",
]
ART_POOL = [
    "Analysts noted on day {n} that the {t} market reacted strongly to the announcement, with {a} outperforming {b} by {k} points.",
    "The city council released a {n}-page plan covering {a}, {b}, and phased timelines stretching to year {k}.",
    "Researchers at institute {s} published results showing {a} improving {m} outcomes by {n}% in a cohort of {k} participants.",
    "Critics of the proposal argue that {m} targets are unachievable without restructuring {a}; supporters point to pilot {s} as counterevidence.",
    "In an interview, the lead engineer said the team spent {n} weeks isolating a regression caused by {a} interacting with {b}.",
    "The editorial compares coverage of {m} across {n} outlets and finds framing differences concentrated on {a} versus {b}.",
]
VARS = dict(
    t=["annual", "interim", "technical", "policy", "field", "audit"],
    m=["throughput", "efficiency", "compliance", "reliability", "demand", "stability"],
    a=["alpha", "beta", "gamma", "delta", "sigma", "kappa"],
    b=["omega", "rho", "tau", "zeta", "eta", "iota"],
    s=["7", "12", "C", "D4", "north", "west"],
    f=["orders", "metrics", "events", "records", "images", "signals"],
)
def fill(t):
    return t.format(**{k: rng.choice(v) if isinstance(v, list) else v for k, v in VARS.items()},
                    n=rng.randint(3, 97), k=rng.randint(2, 48),
                    F=rng.choice(["Order", "Metric", "Event", "Record"]))

def build_prompt(form, target_tokens, tok):
    if form == "doc_qa":
        header = "You are given several documents. Answer the question at the end using only the documents.\n\n"
        i = 0; body = ""
        while True:
            body += f"[Doc {i+1}]\n" + " ".join(fill(rng.choice(DOC_POOL)) for _ in range(6)) + "\n\n"
            prompt = (header + body +
                      "Question: Based on the documents, how does alpha relate to throughput when efficiency exceeds its threshold?\nAnswer:")
            if len(tok.encode(prompt)) >= target_tokens: return prompt
            i += 1
    if form == "code_completion":
        header = "Below is a repository snapshot. Complete the last function so it fits the codebase style.\n\n"
        i = 0; body = ""
        while True:
            body += f"# file: module_{i}.py\n" + fill(rng.choice(CODE_POOL)) + "\n\n"
            prompt = (header + body +
                      "# file: main.py\ndef compute_pipeline(records):\n    # complete this function\n")
            if len(tok.encode(prompt)) >= target_tokens: return prompt
            i += 1
    header = "Read the following article and write a concise summary (3-5 sentences).\n\n"
    body = ""
    while True:
        body += " ".join(fill(rng.choice(ART_POOL)) for _ in range(8)) + "\n\n"
        prompt = header + body + "Summary:"
        if len(tok.encode(prompt)) >= target_tokens: return prompt

TIERS = [4096, 8192, 16384]
FORMS = ["doc_qa", "code_completion", "summarization"]
PLAN = [(tier, form, rep) for tier in TIERS for form in FORMS for rep in range(3)]
'

# ---------- one arm-block runner ----------
run_arm() {
  local ARM="$1" QUANT="$2"
  note "run $RUN_IDX ($ORDER): arm block $ARM"
  GENERATOR="$GENERATOR" RUN_DIR="$RUN_DIR" RAW_JSONL="$RAW_JSONL" PLAN_JSONL="$PLAN_JSONL" \
  MODEL="$MODEL" RUN_SEED="$RUN_SEED" RUN_IDX="$RUN_IDX" ARM="$ARM" QUANT="$QUANT" ORDER="$ORDER" \
  GIT_REV="$GIT_REV" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" python3 - <<'PY'
import hashlib, json, os, time, datetime

MODEL  = os.environ["MODEL"]
RAW    = os.environ["RAW_JSONL"]
PLANF  = os.environ["PLAN_JSONL"]
ARM    = os.environ["ARM"]
QUANT  = os.environ["QUANT"]
MAX_SEC= int(os.environ["MAX_SECONDS"])
T0     = int(os.environ["START_TS"])

exec(os.environ["GENERATOR"])   # build_prompt, PLAN, rng (seeded by RUN_SEED)

from transformers import AutoTokenizer
from huggingface_hub import snapshot_download
tok = AutoTokenizer.from_pretrained(MODEL)
revision = __import__("pathlib").Path(snapshot_download(MODEL)).name

# plan: first arm block of the run writes it; second reads it (identity guaranteed)
plan = []
if os.path.exists(PLANF):
    for l in open(PLANF):
        plan.append(json.loads(l))
else:
    with open(PLANF, "w") as fp:
        for idx, (tier, form, rep) in enumerate(PLAN):
            prompt = build_prompt(form, tier, tok)
            mt = rng.randint(200, 800)          # L2: output length 200-800, sampled, recorded
            rec = dict(request_id=f"r{os.environ['RUN_IDX']}-{idx:02d}", tier_target=tier,
                       form=form, rep=rep, max_tokens=mt, prompt=prompt)
            plan.append(rec)
            fp.write(json.dumps(rec) + "\n"); fp.flush()

from vllm import LLM, SamplingParams
# prefix caching OFF: cached prefixes across similar prompts would contaminate timing
kw = dict(model=MODEL, max_model_len=20480, enable_prefix_caching=False)
if QUANT == "fp8":
    kw["quantization"] = "fp8"
llm = LLM(**kw)

with open(RAW, "a") as fraw:
    for rec in plan:
        if time.time() - T0 > MAX_SEC:
            print(f"TIME GUARD: run aborted past {MAX_SEC}s; partial raw log preserved, run NOT marked complete")
            break
        prompt = rec["prompt"]
        ptoks = len(tok.encode(prompt))
        sp = SamplingParams(temperature=0, max_tokens=rec["max_tokens"])
        t0 = time.time()
        out = llm.generate([prompt], sp)
        wall = time.time() - t0
        oids = list(out[0].outputs[0].token_ids)
        row = dict(request_id=rec["request_id"], run_index=int(os.environ["RUN_IDX"]),
                   run_seed=int(os.environ["RUN_SEED"]), run_order=os.environ["ORDER"],
                   arm=ARM, quantization=QUANT, form=rec["form"], tier_target=rec["tier_target"],
                   rep=rec["rep"], max_tokens=rec["max_tokens"],
                   prompt_tokens=ptoks, output_tokens=len(oids),
                   wall_s=round(wall, 3), total_tps=round((ptoks+len(oids))/wall, 1),
                   out_ids_sha256=hashlib.sha256(json.dumps(oids).encode()).hexdigest(),
                   model=MODEL, model_revision=revision, scripts_rev=os.environ["GIT_REV"],
                   ts_utc=datetime.datetime.utcnow().isoformat() + "Z")
        fraw.write(json.dumps(row) + "\n"); fraw.flush()
        print(f"  {row['request_id']} {ARM} tier={rec['tier_target']} wall={wall:.1f}s tps={row['total_tps']}")
print(f"arm block {ARM} done")
PY
  return $?
}

RC_A=1; RC_B=1
if [ "$ORDER" = "A-first" ]; then
  run_arm "A-bf16" "none" && RC_A=0
  run_arm "B-fp8"  "fp8"  && RC_B=0
else
  run_arm "B-fp8"  "fp8"  && RC_B=0
  run_arm "A-bf16" "none" && RC_A=0
fi

# ---------- per-run summary: descriptive only, NO CI (anti-p-hacking) ----------
note "2. run summary (descriptive only — CI is computed by the verdict stage after 6 runs)"
RAW_JSONL="$RAW_JSONL" SUMMARY="$SUMMARY" MODEL="$MODEL" RUN_IDX="$RUN_IDX" RUN_SEED="$RUN_SEED" \
ORDER="$ORDER" GIT_REV="$GIT_REV" COMPLETED="$COMPLETED" TOTAL_RUNS="$TOTAL_RUNS" python3 - <<'PY'
import hashlib, json, os, statistics

RAW = os.environ["RAW_JSONL"]; SUM = os.environ["SUMMARY"]
rows = [json.loads(l) for l in open(RAW) if l.strip()]
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

lines = [f"FORMAL RUN {os.environ['RUN_IDX']}/{os.environ['TOTAL_RUNS']} — DESCRIPTIVE ONLY, NO CI",
         f"model={os.environ['MODEL']} run_seed={os.environ['RUN_SEED']} order={os.environ['ORDER']}",
         f"scripts_rev={os.environ['GIT_REV']}",
         f"raw_jsonl_sha256={sha(RAW)} rows={len(rows)}", ""]
by = {}
for r in rows: by.setdefault((r["arm"], r["tier_target"]), []).append(r["total_tps"])
for tier in sorted({t for (_, t) in by}):
    seg = []
    for arm in ("A-bf16", "B-fp8"):
        v = by.get((arm, tier))
        if v: seg.append(f"{arm}: mean={statistics.mean(v):.1f} tps n={len(v)}")
    lines.append(f"tier {tier:5d}: " + " | ".join(seg))
lines += ["", "CI intentionally withheld until all runs complete (anti-p-hacking)."]
open(SUM, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

# ---------- completeness gate ----------
N_ROWS=$(wc -l < "$RAW_JSONL" 2>/dev/null || echo 0)
if [ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 0 ] && [ "$N_ROWS" -ge 54 ]; then
  date -u > "$RUN_DIR/COMPLETE"
  echo "STAGE 04 FORMAL RUN $RUN_IDX: COMPLETE ✅ ($N_ROWS rows; $((COMPLETED + 1))/$TOTAL_RUNS runs done)"
  exit 0
else
  echo "STAGE 04 FORMAL RUN $RUN_IDX: INCOMPLETE ❌ (A=$RC_A B=$RC_B rows=$N_ROWS; no COMPLETE marker, re-run will retry this index)"
  exit 1
fi
