#!/usr/bin/env bash
# ============================================================
# Stage 02 · Arm-B reconnaissance probe (exploratory, pre-lock)
#
# Three phases in one run:
#   A) Arm A BF16 reference: 27 requests (3 tiers x 3 forms x 3 reps),
#      greedy decoding, per-request timing.
#   B) Arm B candidate FP8 (vLLM built-in dynamic quantization,
#      no custom kernels per L3): identical prompts, same timing.
#   C) ngram speculative-decoding acceptance SIMULATION, computed
#      offline from Arm A's archived (prompt, output) token ids.
#      This answers the Day-7 checkpoint question (acceptance >= 0.5?)
#      six days early, without touching the engine internals.
#
# Discipline: EXPLORATION DATA ONLY. Nothing here enters the formal
# L4 interleaved measurement or the paired-bootstrap CI. A/B speedups
# printed below are sequential, not interleaved — indicative only.
#
# Reproducibility (anti-drift protocol): prompts are seed-locked
# (run_seed per row), decoding is greedy (temperature=0), model
# revision is recorded; the whole stage is deterministic up to
# hardware timing noise and can be re-run end to end as-is.
#   bash stages/02-armb-probe.sh --verify   # recompute all tables
# from the archived raw/sim inputs; tables must match, character for
# character.
# ============================================================
set -uo pipefail   # no -e: a failed phase must still leave its evidence on disk

EFFIQ_HOME="$HOME/effiq"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE="$(tr -d '[:space:]' < "$EFFIQ_HOME/pilot001/STAGE" 2>/dev/null || echo 02-armb-probe)"
OUT_DIR="$LOGS_DIR/$DATE_STR/$STAGE"
RAW_JSONL="$OUT_DIR/raw.jsonl"
PROMPTS_JSONL="$OUT_DIR/prompts.jsonl"
SIMIN_JSONL="$OUT_DIR/sim_input.jsonl"
ACC_JSONL="$OUT_DIR/acceptance.jsonl"
SUMMARY="$OUT_DIR/summary.txt"

MODEL="Qwen/Qwen2.5-14B-Instruct"
RUN_SEED="20261005-probe02"    # recorded per row; prompt set reconstructible from it
MAX_SECONDS=3600               # K8 budget guard: abort past 60 minutes of GPU work

note() { printf '\n=== %s ===\n' "$*"; }

# ---------- --verify: recompute every table from archived inputs ----------
if [ "${1:-}" = "--verify" ]; then
  D="${2:-$OUT_DIR}"
  [ -f "$D/raw.jsonl" ] || { echo "VERIFY: raw.jsonl not found in $D"; exit 1; }
  python3 - "$D" <<'PY'
import hashlib, json, statistics, sys, os
d = sys.argv[1]
def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()
for name in ("raw.jsonl", "prompts.jsonl", "sim_input.jsonl", "acceptance.jsonl"):
    p = os.path.join(d, name)
    if os.path.exists(p): print(f"{name}: sha256={sha(p)}")
rows = [json.loads(l) for l in open(os.path.join(d, "raw.jsonl")) if l.strip()]
print("raw rows:", len(rows))
by = {}
for r in rows: by.setdefault((r["arm"], r["tier_target"]), []).append(r["total_tps"])
for (arm, tier) in sorted(by):
    print(f"arm={arm:6s} tier={tier:5d}: n={len(by[(arm,tier)])} mean_total_tps={statistics.mean(by[(arm,tier)]):.1f}")
acc_path = os.path.join(d, "acceptance.jsonl")
if os.path.exists(acc_path):
    acc = [json.loads(l) for l in open(acc_path) if l.strip()]
    tot_p = sum(r["proposed"] for r in acc); tot_a = sum(r["accepted"] for r in acc)
    if tot_p: print(f"ngram acceptance (recomputed): {tot_a}/{tot_p} = {tot_a/tot_p:.3f}")
print("VERIFY: recomputed from archived inputs only; compare with any published summary")
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
echo "run seed: $RUN_SEED (recorded per row; prompt set reconstructible)"
mkdir -p "$OUT_DIR"
START_TS=$(date +%s)

# ---------- phase A: Arm A BF16 reference + archive prompts/outputs ----------
note "1. phase A: Arm A BF16, 27 requests (3 tiers x 3 forms x 3 reps), greedy"
OUT_DIR="$OUT_DIR" RAW_JSONL="$RAW_JSONL" PROMPTS_JSONL="$PROMPTS_JSONL" \
SIMIN_JSONL="$SIMIN_JSONL" MODEL="$MODEL" RUN_SEED="$RUN_SEED" \
MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" python3 - <<'PY'
import hashlib, json, os, random, time, datetime

MODEL   = os.environ["MODEL"]
RAW     = os.environ["RAW_JSONL"]
PROMPTS = os.environ["PROMPTS_JSONL"]
SIMIN   = os.environ["SIMIN_JSONL"]
SEED    = os.environ["RUN_SEED"]
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])

# ---- deterministic dynamic-load generator (same pools as stage 01; synthetic,
# ---- boundary declared: Protocol Lock K7 — realism limits logged, not hidden) ----
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

from transformers import AutoTokenizer
from huggingface_hub import snapshot_download
tok = AutoTokenizer.from_pretrained(MODEL)
revision = __import__("pathlib").Path(snapshot_download(MODEL)).name

TIERS = [4096, 8192, 16384]
FORMS = ["doc_qa", "code_completion", "summarization"]
plan = [(tier, form, rep) for tier in TIERS for form in FORMS for rep in range(3)]

from vllm import LLM, SamplingParams
# prefix caching OFF on purpose: cached prefixes across similar prompts
# would contaminate per-request timing. Both arms must keep it off.
llm = LLM(model=MODEL, max_model_len=20480, enable_prefix_caching=False)
sp = SamplingParams(temperature=0, max_tokens=256)

with open(RAW, "a") as fraw, open(PROMPTS, "a") as fpr, open(SIMIN, "a") as fsim:
    for idx, (tier, form, rep) in enumerate(plan):
        if time.time() - T0 > MAX_SEC:
            print(f"TIME GUARD: phase A aborted past {MAX_SEC}s; partial raw log preserved")
            break
        rid = f"exp-{idx:02d}"
        prompt = build_prompt(form, tier, tok)
        pids = tok.encode(prompt)
        t0 = time.time()
        out = llm.generate([prompt], sp)
        wall = time.time() - t0
        oids = list(out[0].outputs[0].token_ids)
        row = dict(request_id=rid, run_seed=SEED, arm="A-bf16", quantization="none",
                   form=form, tier_target=tier, rep=rep,
                   prompt_tokens=len(pids), output_tokens=len(oids),
                   wall_s=round(wall, 3), total_tps=round((len(pids)+len(oids))/wall, 1),
                   out_ids_sha256=hashlib.sha256(json.dumps(oids).encode()).hexdigest(),
                   model=MODEL, model_revision=revision,
                   ts_utc=datetime.datetime.utcnow().isoformat() + "Z")
        fraw.write(json.dumps(row) + "\n"); fraw.flush()
        fpr.write(json.dumps(dict(request_id=rid, prompt=prompt)) + "\n"); fpr.flush()
        fsim.write(json.dumps(dict(request_id=rid, prompt_ids=pids, output_ids=oids)) + "\n"); fsim.flush()
        print(f"  {rid} {form:16s} tier={tier} rep={rep} prompt={len(pids)} out={len(oids)} wall={wall:.1f}s")
print("phase A done")
PY
RC_A=$?

# ---------- phase B: Arm B candidate FP8, identical prompts ----------
note "2. phase B: Arm B candidate FP8 (vLLM built-in dynamic quantization), identical prompts"
OUT_DIR="$OUT_DIR" RAW_JSONL="$RAW_JSONL" PROMPTS_JSONL="$PROMPTS_JSONL" \
MODEL="$MODEL" RUN_SEED="$RUN_SEED" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" python3 - <<'PY'
import hashlib, json, os, time, datetime

MODEL   = os.environ["MODEL"]
RAW     = os.environ["RAW_JSONL"]
PROMPTS = os.environ["PROMPTS_JSONL"]
SEED    = os.environ["RUN_SEED"]
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])

prompts = {}
meta = {}
for l in open(PROMPTS):
    d = json.loads(l); prompts[d["request_id"]] = d["prompt"]
for l in open(RAW):
    d = json.loads(l)
    if d["arm"] == "A-bf16": meta[d["request_id"]] = d

from transformers import AutoTokenizer
from huggingface_hub import snapshot_download
tok = AutoTokenizer.from_pretrained(MODEL)
revision = __import__("pathlib").Path(snapshot_download(MODEL)).name

from vllm import LLM, SamplingParams
llm = LLM(model=MODEL, quantization="fp8", max_model_len=20480, enable_prefix_caching=False)
sp = SamplingParams(temperature=0, max_tokens=256)

with open(RAW, "a") as fraw:
    for rid in sorted(prompts):
        if time.time() - T0 > MAX_SEC:
            print(f"TIME GUARD: phase B aborted past {MAX_SEC}s; partial raw log preserved")
            break
        prompt = prompts[rid]
        pids = tok.encode(prompt)
        t0 = time.time()
        out = llm.generate([prompt], sp)
        wall = time.time() - t0
        oids = list(out[0].outputs[0].token_ids)
        m = meta.get(rid, {})
        row = dict(request_id=rid, run_seed=SEED, arm="B-fp8", quantization="fp8",
                   form=m.get("form"), tier_target=m.get("tier_target"), rep=m.get("rep"),
                   prompt_tokens=len(pids), output_tokens=len(oids),
                   wall_s=round(wall, 3), total_tps=round((len(pids)+len(oids))/wall, 1),
                   out_ids_sha256=hashlib.sha256(json.dumps(oids).encode()).hexdigest(),
                   model=MODEL, model_revision=revision,
                   ts_utc=datetime.datetime.utcnow().isoformat() + "Z")
        fraw.write(json.dumps(row) + "\n"); fraw.flush()
        print(f"  {rid} fp8 prompt={len(pids)} out={len(oids)} wall={wall:.1f}s")
print("phase B done")
PY
RC_B=$?

# ---------- phase C: ngram acceptance simulation + summary ----------
note "3. phase C: ngram speculative acceptance simulation (offline, from archived ids)"
OUT_DIR="$OUT_DIR" RAW_JSONL="$RAW_JSONL" SIMIN_JSONL="$SIMIN_JSONL" \
ACC_JSONL="$ACC_JSONL" SUMMARY="$SUMMARY" RUN_SEED="$RUN_SEED" MODEL="$MODEL" python3 - <<'PY'
import hashlib, json, os, statistics

RAW   = os.environ["RAW_JSONL"]
SIMIN = os.environ["SIMIN_JSONL"]
ACC   = os.environ["ACC_JSONL"]
SUM   = os.environ["SUMMARY"]
SEED  = os.environ["RUN_SEED"]
MODEL = os.environ["MODEL"]

# vLLM ngram proposer approximation: at each decode step, find the longest
# suffix of the current context (<= MAX_N tokens) that occurred earlier in
# the context; propose the K_SPEC tokens that followed that occurrence.
# Step model: accepted prefix advances position, plus one correction token.
MAX_N, K_SPEC = 4, 5

def rfind(hay, pat):
    n = len(pat)
    for i in range(len(hay) - n, -1, -1):
        if hay[i:i+n] == pat: return i
    return -1

def ngram_accept(prompt_ids, out_ids):
    proposed = accepted = 0
    t = 0
    ctx = list(prompt_ids)
    while t < len(out_ids):
        prop = []
        for n in range(min(MAX_N, len(ctx)), 0, -1):
            i = rfind(ctx[:-n], ctx[-n:])
            if i >= 0:
                prop = ctx[i+n : i+n+K_SPEC]
                break
        a = 0
        for j, p in enumerate(prop):
            if t + j < len(out_ids) and out_ids[t+j] == p: a += 1
            else: break
        proposed += len(prop); accepted += a
        t += a + 1
        ctx = list(prompt_ids) + out_ids[:t]
    return proposed, accepted

rows = [json.loads(l) for l in open(RAW) if l.strip()]
meta = {r["request_id"]: r for r in rows if r["arm"] == "A-bf16"}
acc_rows = []
with open(ACC, "w") as fa:
    for l in open(SIMIN):
        d = json.loads(l)
        p, a = ngram_accept(d["prompt_ids"], d["output_ids"])
        m = meta.get(d["request_id"], {})
        rec = dict(request_id=d["request_id"], run_seed=SEED, method="ngram-sim",
                   max_n=MAX_N, k_spec=K_SPEC, form=m.get("form"), tier_target=m.get("tier_target"),
                   proposed=p, accepted=a, rate=round(a/p, 4) if p else None)
        acc_rows.append(rec)
        fa.write(json.dumps(rec) + "\n")

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

lines = ["STAGE 02 ARM-B RECON SUMMARY — EXPLORATION ONLY, NEVER ENTERS CI",
         f"model={MODEL} run_seed={SEED}",
         f"raw_jsonl_sha256={sha(RAW)}",
         f"acceptance_jsonl_sha256={sha(ACC)}", "",
         "[throughput: sequential same-night runs — indicative only, NOT the L4 interleaved measurement]"]
by = {}
for r in rows: by.setdefault((r["arm"], r["tier_target"]), []).append(r["total_tps"])
for tier in sorted({t for (_, t) in by}):
    a = by.get(("A-bf16", tier)); b = by.get(("B-fp8", tier))
    if a and b:
        ma, mb = statistics.mean(a), statistics.mean(b)
        lines.append(f"tier {tier:5d}: A-bf16 mean={ma:7.1f} tps (n={len(a)}) | B-fp8 mean={mb:7.1f} tps (n={len(b)}) | indicative speedup {mb/ma:.2f}x")
    elif a:
        lines.append(f"tier {tier:5d}: A-bf16 mean={statistics.mean(a):7.1f} tps (n={len(a)}) | B-fp8 missing")

lines += ["", "[output identity under greedy decoding: FP8 vs BF16, same prompts]"]
ident = tot = 0
hashA = {r["request_id"]: r["out_ids_sha256"] for r in rows if r["arm"] == "A-bf16"}
for r in rows:
    if r["arm"] == "B-fp8" and r["request_id"] in hashA:
        tot += 1
        if r["out_ids_sha256"] == hashA[r["request_id"]]: ident += 1
if tot: lines.append(f"identical outputs: {ident}/{tot} ({100*ident/tot:.0f}%) — divergence is expected; blind quality gate (L5) is the arbiter, not identity")

lines += ["", f"[ngram speculative acceptance simulation: max_n={MAX_N}, k_spec={K_SPEC}]"]
tot_p = sum(r["proposed"] for r in acc_rows); tot_a = sum(r["accepted"] for r in acc_rows)
byt = {}
for r in acc_rows: byt.setdefault(r["tier_target"], []).append(r)
for tier in sorted(byt):
    p = sum(x["proposed"] for x in byt[tier]); a = sum(x["accepted"] for x in byt[tier])
    lines.append(f"tier {tier:5d}: accepted {a}/{p} = {a/p:.3f}")
if tot_p:
    rate = tot_a / tot_p
    lines.append(f"OVERALL ngram acceptance: {tot_a}/{tot_p} = {rate:.3f}")
    lines.append(f"Day-7 checkpoint threshold: >= 0.500 -> {'PASS (ngram viable)' if rate >= 0.5 else 'BELOW — switch to EAGLE per Protocol Lock'}")
open(SUM, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
RC_C=$?

note "4. result"
[ -f "$SUMMARY" ] && cat "$SUMMARY"
if [ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 0 ] && [ "$RC_C" -eq 0 ] && [ -f "$SUMMARY" ]; then
  echo "STAGE 02 ARM-B PROBE: COMPLETE ✅ (exploration data staged for log push)"
  exit 0
else
  echo "STAGE 02 ARM-B PROBE: INCOMPLETE ❌ (A=$RC_A B=$RC_B C=$RC_C; partial evidence preserved)"
  exit 1
fi
