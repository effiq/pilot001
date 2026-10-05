#!/usr/bin/env bash
# ============================================================
# Stage 03 · EAGLE speculative-decoding probe (exploratory, pre-lock)
#
# Trigger: stage 02 found ngram acceptance 0.134 << 0.5 checkpoint,
# invoking the Protocol Lock switch clause (ngram -> EAGLE).
# No official EAGLE head exists for Qwen2.5-14B-Instruct; this probe
# uses the community head listed in the official EAGLE repo's weight
# table: Zjcxy-SmartAI/Eagle-Qwen2.5-14B-Instruct (0.33B).
# The draft head affects SPEED ONLY — verified speculative decoding
# preserves the target model's output; quality remains gated by L5.
#
# Three phases, identical seed-locked prompts (same generator + seed
# as stage 02, so cross-stage numbers line up):
#   A) A2-bf16      vanilla BF16 (tonight's in-session control)
#   B) C-bf16-eagle BF16 + EAGLE head
#   C) D-fp8-eagle  FP8 + EAGLE head (candidate final Arm B)
#
# Invariant check: at temperature=0, C-bf16-eagle outputs MUST be
# token-identical to A2-bf16 outputs. Any divergence = engine-level
# losslessness violation — report, do not explain away.
#
# Caveat recorded per anti-hype discipline: all runs are batch-1
# sequential; speculative speedups shrink with concurrency and the
# formal L4 measurement stays batch-1 interleaved by design.
#
# Discipline: EXPLORATION DATA ONLY — never enters the L4 CI.
# Verify entry: bash stages/03-eagle-probe.sh --verify [dir]
# ============================================================
set -uo pipefail

EFFIQ_HOME="$HOME/effiq"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE="$(tr -d '[:space:]' < "$EFFIQ_HOME/pilot001/STAGE" 2>/dev/null || echo 03-eagle-probe)"
OUT_DIR="$LOGS_DIR/$DATE_STR/$STAGE"
RAW_JSONL="$OUT_DIR/raw.jsonl"
PROMPTS_JSONL="$OUT_DIR/prompts.jsonl"
SUMMARY="$OUT_DIR/summary.txt"

MODEL="Qwen/Qwen2.5-14B-Instruct"
DRAFT="Zjcxy-SmartAI/Eagle-Qwen2.5-14B-Instruct"
RUN_SEED="20261005-probe02"    # identical to stage 02 -> identical prompt set
K_SPEC=5
MAX_SECONDS=4200               # K8 budget guard

note() { printf '\n=== %s ===\n' "$*"; }

# ---------- --verify ----------
if [ "${1:-}" = "--verify" ]; then
  D="${2:-$OUT_DIR}"
  [ -f "$D/raw.jsonl" ] || { echo "VERIFY: raw.jsonl not found in $D"; exit 1; }
  python3 - "$D" <<'PY'
import hashlib, json, statistics, sys, os
d = sys.argv[1]
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()
for name in ("raw.jsonl", "prompts.jsonl"):
    p = os.path.join(d, name)
    if os.path.exists(p): print(f"{name}: sha256={sha(p)}")
rows = [json.loads(l) for l in open(os.path.join(d, "raw.jsonl")) if l.strip()]
print("raw rows:", len(rows))
by = {}
for r in rows: by.setdefault((r["arm"], r["tier_target"]), []).append(r["total_tps"])
for (arm, tier) in sorted(by):
    print(f"arm={arm:12s} tier={tier:5d}: n={len(by[(arm,tier)])} mean_total_tps={statistics.mean(by[(arm,tier)]):.1f}")
h = {}
for r in rows: h.setdefault(r["request_id"], {})[r["arm"]] = r["out_ids_sha256"]
pairs = [(rid, v) for rid, v in h.items() if "A2-bf16" in v and "C-bf16-eagle" in v]
if pairs:
    ident = sum(1 for _, v in pairs if v["A2-bf16"] == v["C-bf16-eagle"])
    print(f"losslessness invariant (A2-bf16 vs C-bf16-eagle): {ident}/{len(pairs)} identical")
print("VERIFY: recomputed from archived inputs only")
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

echo "banner: EXPLORATION DATA ONLY — never enters the formal L4 measurement or the CI"
echo "run seed: $RUN_SEED (identical to stage 02 -> identical prompts); draft: $DRAFT"
mkdir -p "$OUT_DIR"
START_TS=$(date +%s)

# ---------- shared generator, emitted once via phase A ----------
GENERATOR='
import json, os, random

SEED = os.environ["RUN_SEED"]
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

# ---------- one phase runner, parameterized ----------
run_phase() {
  local ARM="$1" QUANT="$2" USE_EAGLE="$3"
  note "phase: arm=$ARM quant=$QUANT eagle=$USE_EAGLE"
  GENERATOR="$GENERATOR" OUT_DIR="$OUT_DIR" RAW_JSONL="$RAW_JSONL" PROMPTS_JSONL="$PROMPTS_JSONL" \
  MODEL="$MODEL" DRAFT="$DRAFT" RUN_SEED="$RUN_SEED" ARM="$ARM" QUANT="$QUANT" USE_EAGLE="$USE_EAGLE" \
  K_SPEC="$K_SPEC" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" python3 - <<'PY'
import hashlib, json, os, time, datetime

MODEL   = os.environ["MODEL"]
DRAFT   = os.environ["DRAFT"]
RAW     = os.environ["RAW_JSONL"]
PROMPTS = os.environ["PROMPTS_JSONL"]
SEED    = os.environ["RUN_SEED"]
ARM     = os.environ["ARM"]
QUANT   = os.environ["QUANT"]
EAGLE   = os.environ["USE_EAGLE"] == "1"
K_SPEC  = int(os.environ["K_SPEC"])
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])

exec(os.environ["GENERATOR"])   # provides build_prompt, PLAN, rng (seeded identically)

from transformers import AutoTokenizer
from huggingface_hub import snapshot_download
tok = AutoTokenizer.from_pretrained(MODEL)
revision = __import__("pathlib").Path(snapshot_download(MODEL)).name

# prompts: regenerate identically, or reuse the archived set from phase A
prompts = {}
if os.path.exists(PROMPTS):
    for l in open(PROMPTS):
        d = json.loads(l); prompts[d["request_id"]] = d["prompt"]

from vllm import LLM, SamplingParams
# prefix caching OFF: cached prefixes across similar prompts would contaminate timing
kw = dict(model=MODEL, max_model_len=20480, enable_prefix_caching=False)
if QUANT == "fp8":
    kw["quantization"] = "fp8"
if EAGLE:
    kw["speculative_config"] = dict(method="eagle", model=DRAFT,
                                    num_speculative_tokens=K_SPEC,
                                    draft_tensor_parallel_size=1)
llm = LLM(**kw)
sp = SamplingParams(temperature=0, max_tokens=256)

first_phase = not prompts
with open(RAW, "a") as fraw:
    fpr = open(PROMPTS, "a") if first_phase else None
    for idx, (tier, form, rep) in enumerate(PLAN):
        if time.time() - T0 > MAX_SEC:
            print(f"TIME GUARD: phase {ARM} aborted past {MAX_SEC}s; partial raw log preserved")
            break
        rid = f"exp-{idx:02d}"
        prompt = prompts.get(rid) or build_prompt(form, tier, tok)
        if fpr: fpr.write(json.dumps(dict(request_id=rid, prompt=prompt)) + "\n"); fpr.flush()
        ptoks = len(tok.encode(prompt))
        t0 = time.time()
        out = llm.generate([prompt], sp)
        wall = time.time() - t0
        oids = list(out[0].outputs[0].token_ids)
        row = dict(request_id=rid, run_seed=SEED, arm=ARM,
                   quantization=QUANT, spec=("eagle" if EAGLE else "none"), k_spec=(K_SPEC if EAGLE else 0),
                   draft_model=(DRAFT if EAGLE else None),
                   form=form, tier_target=tier, rep=rep,
                   prompt_tokens=ptoks, output_tokens=len(oids),
                   wall_s=round(wall, 3), total_tps=round((ptoks+len(oids))/wall, 1),
                   out_ids_sha256=hashlib.sha256(json.dumps(oids).encode()).hexdigest(),
                   model=MODEL, model_revision=revision,
                   ts_utc=datetime.datetime.utcnow().isoformat() + "Z")
        fraw.write(json.dumps(row) + "\n"); fraw.flush()
        print(f"  {rid} {ARM} tier={tier} rep={rep} out={len(oids)} wall={wall:.1f}s tps={row['total_tps']}")
    if fpr: fpr.close()
print(f"phase {ARM} done")
PY
  return $?
}

RC_A=1; RC_B=1; RC_C=1
run_phase "A2-bf16"      "none" "0" && RC_A=0
run_phase "C-bf16-eagle" "none" "1" && RC_B=0
run_phase "D-fp8-eagle"  "fp8"  "1" && RC_C=0

# ---------- summary ----------
note "summary"
OUT_DIR="$OUT_DIR" RAW_JSONL="$RAW_JSONL" SUMMARY="$SUMMARY" MODEL="$MODEL" DRAFT="$DRAFT" \
RUN_SEED="$RUN_SEED" K_SPEC="$K_SPEC" python3 - <<'PY'
import hashlib, json, os, statistics

RAW = os.environ["RAW_JSONL"]; SUM = os.environ["SUMMARY"]
rows = [json.loads(l) for l in open(RAW) if l.strip()]
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

lines = ["STAGE 03 EAGLE PROBE SUMMARY — EXPLORATION ONLY, NEVER ENTERS CI",
         f"model={os.environ['MODEL']} draft={os.environ['DRAFT']} k_spec={os.environ['K_SPEC']}",
         f"run_seed={os.environ['RUN_SEED']} rows={len(rows)}",
         f"raw_jsonl_sha256={sha(RAW)}", "",
         "[batch-1 sequential timing — indicative only, NOT the L4 interleaved measurement;",
         " speculative gains shrink with concurrency; L4 stays batch-1 by design]"]
by = {}
for r in rows: by.setdefault((r["arm"], r["tier_target"]), []).append(r["total_tps"])
arms = sorted({a for (a, _) in by})
for tier in sorted({t for (_, t) in by}):
    seg = []
    base = by.get(("A2-bf16", tier))
    for arm in arms:
        v = by.get((arm, tier))
        if not v: continue
        m = statistics.mean(v)
        extra = f" ({m/statistics.mean(base):.2f}x vs A2)" if base and arm != "A2-bf16" else ""
        seg.append(f"{arm}: {m:.1f} tps n={len(v)}{extra}")
    lines.append(f"tier {tier:5d}: " + " | ".join(seg))

lines += ["", "[losslessness invariant: greedy C-bf16-eagle vs A2-bf16, must be identical]"]
h = {}
for r in rows: h.setdefault(r["request_id"], {})[r["arm"]] = r["out_ids_sha256"]
pairs = [(rid, v) for rid, v in h.items() if "A2-bf16" in v and "C-bf16-eagle" in v]
if pairs:
    ident = [rid for rid, v in pairs if v["A2-bf16"] == v["C-bf16-eagle"]]
    lines.append(f"identical: {len(ident)}/{len(pairs)}")
    if len(ident) < len(pairs):
        bad = [rid for rid, v in pairs if v["A2-bf16"] != v["C-bf16-eagle"]]
        lines.append(f"DIVERGENT request_ids: {','.join(sorted(bad))} — engine-level finding, investigate, do not explain away")
else:
    lines.append("skipped (one of the two arms missing)")

open(SUM, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

# capture any engine-reported speculative metrics verbatim from the stage log
if [ -f "$OUT_DIR/stage.log" ]; then
  grep -i -E "accept|speculat" "$OUT_DIR/stage.log" | grep -v "banner\|run seed" | tail -15 || true
fi

if [ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 0 ] && [ "$RC_C" -eq 0 ] && [ -f "$SUMMARY" ]; then
  echo "STAGE 03 EAGLE PROBE: COMPLETE ✅ (exploration data staged for log push)"
  exit 0
else
  echo "STAGE 03 EAGLE PROBE: PARTIAL ⚠️ (A=$RC_A B=$RC_B C=$RC_C; evidence preserved)"
  [ -f "$SUMMARY" ] && exit 0 || exit 1
fi
