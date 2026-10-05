#!/usr/bin/env bash
# ============================================================
# Stage 01 · measurement-pipeline calibration (Arm A, BF16 defaults)
#
# Purpose: prove the full measurement chain works end to end —
# dynamic load generation -> per-request timing -> raw JSONL ->
# sha256 -> summary. The 9 requests here are a plumbing test.
#
# Discipline: CALIBRATION DATA ONLY. These numbers are NOT part of
# the formal L4 interleaved measurement and MUST NEVER enter the
# paired-bootstrap CI. The formal A/B measurement is a later stage.
#
# Verification entry (anti-drift protocol): re-run the summary from
# the raw log at any time:
#   bash stages/01-calibration.sh --verify [path/to/raw.jsonl]
# It prints the dataset hash and recomputed stats; they must match
# any report that cites this run, character for character.
# ============================================================
set -uo pipefail   # no -e: a failed request must still leave its row in the raw log

# ---------- locate output dir exactly like tonight.sh does ----------
EFFIQ_HOME="$HOME/effiq"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE="$(tr -d '[:space:]' < "$EFFIQ_HOME/pilot001/STAGE" 2>/dev/null || echo 01-calibration)"
OUT_DIR="$LOGS_DIR/$DATE_STR/$STAGE"
RAW_JSONL="$OUT_DIR/raw.jsonl"
SUMMARY="$OUT_DIR/summary.txt"

MODEL="Qwen/Qwen2.5-14B-Instruct"
RUN_SEED="20261005-cal01"      # recorded in every row; load is reconstructible from it
MAX_SECONDS=2700               # K8 budget guard: abort the stage past 45 minutes

note() { printf '\n=== %s ===\n' "$*"; }

# ---------- --verify mode: recompute everything from the raw log ----------
if [ "${1:-}" = "--verify" ]; then
  TARGET="${2:-$RAW_JSONL}"
  [ -f "$TARGET" ] || { echo "VERIFY: raw log not found: $TARGET"; exit 1; }
  python3 - "$TARGET" <<'PY'
import hashlib, json, statistics, sys
path = sys.argv[1]
blob = open(path, "rb").read()
print("dataset sha256:", hashlib.sha256(blob).hexdigest())
rows = [json.loads(l) for l in blob.decode().splitlines() if l.strip()]
print("rows:", len(rows))
by_tier = {}
for r in rows:
    by_tier.setdefault(r["tier_target"], []).append(r["total_tps"])
for tier in sorted(by_tier):
    v = by_tier[tier]
    print(f"tier {tier}: n={len(v)} mean_total_tps={statistics.mean(v):.1f} "
          f"min={min(v):.1f} max={max(v):.1f}")
if rows:
    print(f"overall mean_total_tps={statistics.mean(r['total_tps'] for r in rows):.1f}")
print("VERIFY: recomputed from raw log only; compare with any published summary")
PY
  exit $?
fi

# ---------- normal run ----------
note "0. time / host / GPU / tool versions"
date -u
hostname || true
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv || true
pip install -q vllm huggingface_hub
python3 -c "import vllm, torch; print('vllm:', vllm.__version__, '| torch:', torch.__version__, '| gpu:', torch.cuda.get_device_name(0))"

note "1. calibration run: 9 requests = 3 tiers (4K/8K/16K) x 3 task forms, Arm A BF16"
echo "banner: CALIBRATION DATA ONLY — never enters the formal L4 measurement or the CI"
echo "run seed: $RUN_SEED (recorded per row; load reconstructible)"
mkdir -p "$OUT_DIR"

START_TS=$(date +%s)
RAW_JSONL="$RAW_JSONL" SUMMARY="$SUMMARY" MODEL="$MODEL" RUN_SEED="$RUN_SEED" \
MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" python3 - <<'PY'
import hashlib, json, os, random, statistics, time, datetime

MODEL      = os.environ["MODEL"]
RAW_JSONL  = os.environ["RAW_JSONL"]
SUMMARY    = os.environ["SUMMARY"]
RUN_SEED   = os.environ["RUN_SEED"]
MAX_SEC    = int(os.environ["MAX_SECONDS"])
START_TS   = int(os.environ["START_TS"])

# ---- deterministic dynamic-load generator (synthetic, boundary declared:
# ---- Protocol Lock K7 — static protocol; realism limits logged, not hidden) ----
rng = random.Random(RUN_SEED)

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
    parts = []
    if form == "doc_qa":
        header = "You are given several documents. Answer the question at the end using only the documents.\n\n"
        while True:
            body = "".join(f"[Doc {i+1}]\n" + " ".join(fill(rng.choice(DOC_POOL)) for _ in range(6)) + "\n\n"
                           for i in range(len(parts) + 4))
            prompt = header + body + "Question: Based on the documents, how does alpha relate to throughput when efficiency exceeds its threshold?\nAnswer:"
            if len(tok.encode(prompt)) >= target_tokens: return prompt
            parts.append(1)
    if form == "code_completion":
        header = "Below is a repository snapshot. Complete the last function so it fits the codebase style.\n\n"
        i = 0
        body = ""
        while True:
            body += f"# file: module_{i}.py\n" + fill(rng.choice(CODE_POOL)) + "\n\n"
            prompt = (header + body +
                      "# file: main.py\ndef compute_pipeline(records):\n    # complete this function\n")
            if len(tok.encode(prompt)) >= target_tokens: return prompt
            i += 1
    # summarization
    header = "Read the following article and write a concise summary (3-5 sentences).\n\n"
    body = ""
    while True:
        body += " ".join(fill(rng.choice(ART_POOL)) for _ in range(8)) + "\n\n"
        prompt = header + body + "Summary:"
        if len(tok.encode(prompt)) >= target_tokens: return prompt

from transformers import AutoTokenizer
from huggingface_hub import snapshot_download
tok = AutoTokenizer.from_pretrained(MODEL)
revision = __import__("pathlib").Path(snapshot_download(MODEL)).name

TIERS = [4096, 8192, 16384]
FORMS = ["doc_qa", "code_completion", "summarization"]
plan = [(tier, form) for tier in TIERS for form in FORMS]   # 9 requests

from vllm import LLM, SamplingParams
# prefix caching OFF on purpose: cached prefixes across similar prompts
# would contaminate per-request timing. Both arms must keep it off.
llm = LLM(model=MODEL, max_model_len=20480, enable_prefix_caching=False)
sp = SamplingParams(temperature=0, max_tokens=256)

rows = []
for idx, (tier, form) in enumerate(plan):
    if time.time() - START_TS > MAX_SEC:
        print(f"TIME GUARD: stage aborted after {MAX_SEC}s; partial raw log preserved")
        break
    prompt = build_prompt(form, tier, tok)
    ptoks = len(tok.encode(prompt))
    t0 = time.time()
    out = llm.generate([prompt], sp)
    wall = time.time() - t0
    otoks = len(out[0].outputs[0].token_ids)
    row = dict(request_id=f"cal-{idx:02d}", run_seed=RUN_SEED, arm="A", form=form,
               tier_target=tier, prompt_tokens=ptoks, output_tokens=otoks,
               wall_s=round(wall, 3), total_tps=round((ptoks + otoks) / wall, 1),
               model=MODEL, model_revision=revision,
               ts_utc=datetime.datetime.utcnow().isoformat() + "Z")
    rows.append(row)
    with open(RAW_JSONL, "a") as f:        # append per row: a crash still leaves evidence
        f.write(json.dumps(row) + "\n")
    print(f"  {row['request_id']} {form:16s} tier={tier} prompt={ptoks} out={otoks} "
          f"wall={wall:.1f}s total_tps={row['total_tps']}")

blob = open(RAW_JSONL, "rb").read()
digest = hashlib.sha256(blob).hexdigest()
by_tier = {}
for r in rows: by_tier.setdefault(r["tier_target"], []).append(r["total_tps"])
lines = ["STAGE 01 CALIBRATION SUMMARY — NOT FORMAL MEASUREMENT, NEVER ENTERS CI",
         f"model={MODEL} revision={revision}", f"run_seed={RUN_SEED} rows={len(rows)}",
         f"raw_jsonl_sha256={digest}"]
for tier in sorted(by_tier):
    v = by_tier[tier]
    lines.append(f"tier {tier}: n={len(v)} mean_total_tps={statistics.mean(v):.1f}")
open(SUMMARY, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
RC=$?

note "2. summary"
[ -f "$SUMMARY" ] && cat "$SUMMARY"
if [ "$RC" -eq 0 ] && [ -f "$RAW_JSONL" ]; then
  echo "STAGE 01 CALIBRATION: COMPLETE ✅ (raw.jsonl + summary.txt staged for log push)"
else
  echo "STAGE 01 CALIBRATION: INCOMPLETE ❌ (exit=$RC; partial raw log preserved if any)"
fi
exit "$RC"
