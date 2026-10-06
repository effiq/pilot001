#!/usr/bin/env bash
# ============================================================
# Stage 06 · L5 blind quality gate (final gate of Pilot 001)
#
# The performance half (stage 05) proved FP8 is faster. This stage
# answers the other pre-registered question: does FP8 cost output
# quality on OUR load? Method:
#   1. Frozen evaluation set: 150 prompts (3 forms x 50; tiers
#      4096/8192/16384), generated from the declared L2 generator
#      with FIXED seed 20261003. Rebuilt deterministically; its
#      sha256 is printed and archived.
#   2. Both arms generate answers (temperature=0): A = BF16,
#      B = FP8 dynamic (Amendment-01). Outputs archived as text.
#   3. A blind judge scores every pair on 3 axes (correctness,
#      instruction_following, clarity; 0-10 each). Blinding: a
#      seeded coin (seed 20261007) decides per item whether arm A
#      appears as "response 1" or "response 2"; the judge model
#      never learns which arm produced which text.
#      Judge model policy (documented, pre-registered):
#        - OpenAI/Anthropic/Google models are unreachable from this
#          account (billing-region restriction, OpenRouter policy).
#        - Qwen-family judges are excluded BY DESIGN: a Qwen judge
#          scoring Qwen outputs is a family conflict of interest.
#        - Probe order: DeepSeek V3 snapshots, then GLM (Zhipu);
#          the first reachable model judges ALL items and its
#          identity is archived with every judged row.
#   4. Verdict (pre-registered, point estimates): PASS iff the
#      pooled delta (B - A) and every per-axis delta are >= -0.1.
#      A bootstrap CI of the delta is printed as DESCRIPTIVE ONLY
#      (fixed seed 20261006); the gate decision uses the point
#      estimates, per protocol.
#
# Budget guards (constitution K8): total stage wall clock capped
# (MAX_SECONDS); judge spend capped (BUDGET_USD; expected actual
# spend is under $2 for 150 items).
#
# Resume: every phase skips work already archived in the run dir.
# Re-running the same command after an interruption (including a
# terminal disconnect — processes survive) resumes where it left
# off. An incomplete run dir is reused across days automatically.
#
# Verify entry: bash stages/06-quality-gate.sh --verify [run_dir]
# Recomputes the verdict from the archived logs only. No network,
# no GPU; output must match the archived verdict_q.txt.
# ============================================================
set -uo pipefail

EFFIQ_HOME="$HOME/effiq"
SCRIPTS_DIR="$EFFIQ_HOME/pilot001"
LOGS_DIR="$EFFIQ_HOME/pilot-logs"
DATE_STR="$(date -u +%Y-%m-%d)"

MODEL="Qwen/Qwen2.5-14B-Instruct"
FROZEN_SEED=20261003
BLIND_SEED=20261007
N_ITEMS=150
TOL=0.1
MAX_SECONDS=21000          # K8: whole-stage wall-clock cap (~6 h)
BUDGET_USD=45              # K8: judge spend cap (expected actual < $2)
BOOT_SEED=20261006         # descriptive CI only, fixed for determinism
BOOT_N=100000
KEY_FILE="$HOME/pilot-env/openrouter-key"

note() { printf '\n=== %s ===\n' "$*"; }

set_paths() {
  RUN_DIR="$1"
  FROZEN_JSONL="$RUN_DIR/frozen_set.jsonl"
  GEN_A_JSONL="$RUN_DIR/gen_A.jsonl"
  GEN_B_JSONL="$RUN_DIR/gen_B.jsonl"
  BLIND_JSONL="$RUN_DIR/blind_map.jsonl"
  JUDGE_RAW_JSONL="$RUN_DIR/judge_raw.jsonl"
  VERDICT_TXT="$RUN_DIR/verdict_q.txt"
}

run_verdict() {
  RUN_DIR="$RUN_DIR" FROZEN_JSONL="$FROZEN_JSONL" GEN_A_JSONL="$GEN_A_JSONL" \
  GEN_B_JSONL="$GEN_B_JSONL" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" VERDICT_TXT="$VERDICT_TXT" \
  N_ITEMS="$N_ITEMS" TOL="$TOL" BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" python3 - <<'PY'
import hashlib, json, os, statistics

RUN_DIR = os.environ["RUN_DIR"]
FROZEN  = os.environ["FROZEN_JSONL"]
GEN_A   = os.environ["GEN_A_JSONL"]
GEN_B   = os.environ["GEN_B_JSONL"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
VERDICTF= os.environ["VERDICT_TXT"]
N_ITEMS = int(os.environ["N_ITEMS"])
TOL     = float(os.environ["TOL"])
BSEED   = int(os.environ["BOOT_SEED"])
BN      = int(os.environ["BOOT_N"])
AXES    = ["correctness", "instruction_following", "clarity"]

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"

lines = ["STAGE 06 VERDICT — L5 BLIND QUALITY GATE",
         f"tolerance={TOL} (10-pt scale; pre-registered: quality degradation > {TOL} -> FAIL)",
         "judge blinded to arm identity; judge model archived per row", ""]
for name, p in [("frozen_set.jsonl", FROZEN), ("gen_A.jsonl", GEN_A),
                ("gen_B.jsonl", GEN_B), ("judge_raw.jsonl", JRAW),
                ("blind_map.jsonl", os.path.join(RUN_DIR, "blind_map.jsonl"))]:
    lines.append(f"  {name}: sha256={sha(p)}")

frozen = {json.loads(l)["request_id"]: json.loads(l) for l in open(FROZEN) if l.strip()}
rows = [json.loads(l) for l in open(JRAW) if l.strip()] if os.path.exists(JRAW) else []
lines += ["", f"judged items: {len(rows)} / {N_ITEMS}"]

if len(rows) < N_ITEMS:
    lines += ["", f"REFUSED: quality gate incomplete ({len(rows)}/{N_ITEMS}) — verdict sealed by protocol.",
              "Re-run the stage to resume judging; no PASS/FAIL is computed on partial data."]
    open(VERDICTF, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines)); raise SystemExit(1)

def load_gen(p):
    return {json.loads(l)["request_id"]: json.loads(l) for l in open(p) if l.strip()}
gA, gB = load_gen(GEN_A), load_gen(GEN_B)

jmodels = sorted({r["judge_model"] for r in rows})
lines += ["", f"judge model(s) used: {', '.join(jmodels)}"]

# ---- unblind ----
per_item = []   # (request_id, form, {axis: (A,B)})
for r in rows:
    rid = r["request_id"]
    sA = r["scores_r1"] if r["a_is_response_1"] else r["scores_r2"]
    sB = r["scores_r2"] if r["a_is_response_1"] else r["scores_r1"]
    per_item.append((rid, frozen[rid]["form"], {a: (sA[a], sB[a]) for a in AXES}))

lines += ["", "[per-axis results: mean over 150 items, 10-pt scale]"]
axis_delta = {}
for a in AXES:
    mA = statistics.mean(sc[a][0] for _, _, sc in per_item)
    mB = statistics.mean(sc[a][1] for _, _, sc in per_item)
    axis_delta[a] = mB - mA
    lines.append(f"  {a:22s}: A(bf16)={mA:.3f}  B(fp8)={mB:.3f}  delta={mB-mA:+.3f}")

item_delta = [statistics.mean(sc[a][1] - sc[a][0] for a in AXES) for _, _, sc in per_item]
overall = statistics.mean(item_delta)
lines += ["", f"[overall] pooled delta (B - A): {overall:+.3f}"]

gate_ok = overall >= -TOL and all(d >= -TOL for d in axis_delta.values())
lines += ["", f"criterion: overall delta >= -{TOL} AND every axis delta >= -{TOL}  ->  {'PASS' if gate_ok else 'FAIL'}"]

ident = sum(1 for rid, _, _ in per_item if gA[rid]["output_text"] == gB[rid]["output_text"])
lines += ["", f"[descriptive] textually identical outputs across arms: {ident}/{N_ITEMS}",
          "[descriptive] per-form pooled delta (B - A):"]
for form in ("doc_qa", "code_completion", "summarization"):
    v = [statistics.mean(sc[a][1] - sc[a][0] for a in AXES) for _, f, sc in per_item if f == form]
    lines.append(f"  {form:16s}: {statistics.mean(v):+.3f} (n={len(v)})")

import numpy as np
vals = np.array(item_delta)
rng = np.random.default_rng(BSEED)
means = rng.choice(vals, size=(BN, len(vals)), replace=True).mean(axis=1)
lo, hi = np.percentile(means, [2.5, 97.5])
lines += ["", f"[descriptive] 95% bootstrap CI of overall delta: [{lo:+.3f}, {hi:+.3f}] "
              f"(seed={BSEED}, resamples={BN}; the gate decision uses the point estimates above, per protocol)"]

lines += ["", "This file is reproducible from the archived logs alone: bash stages/06-quality-gate.sh --verify <run_dir>"]
open(VERDICTF, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
}

# ---------- --verify ----------
if [ "${1:-}" = "--verify" ]; then
  D="${2:-}"
  if [ -z "$D" ]; then D="$(ls -dt "$LOGS_DIR"/*/06-quality-gate/run_* 2>/dev/null | head -1)"; fi
  [ -n "$D" ] && [ -d "$D" ] || { echo "VERIFY: usage: --verify <run_dir> (no run dir found)"; exit 1; }
  set_paths "$D"
  note "verify: recomputing verdict from archived logs in $D (no network, no GPU)"
  run_verdict
  exit $?
fi

# ---------- run bookkeeping: resume an incomplete run dir if one exists ----------
note "0. run bookkeeping"
RUN_DIR=""
for cand in $(ls -dt "$LOGS_DIR"/*/06-quality-gate/run_* 2>/dev/null); do
  if [ ! -f "$cand/COMPLETE" ]; then RUN_DIR="$cand"; echo "resuming incomplete run dir: $RUN_DIR"; break; fi
done
if [ -z "$RUN_DIR" ]; then
  RUN_DIR="$LOGS_DIR/$DATE_STR/06-quality-gate/run_1"
  SUFFIX=2
  while [ -e "$RUN_DIR" ]; do RUN_DIR="$LOGS_DIR/$DATE_STR/06-quality-gate/run_1-r${SUFFIX}"; SUFFIX=$((SUFFIX+1)); done
  mkdir -p "$RUN_DIR"
  echo "new run dir: $RUN_DIR"
fi
set_paths "$RUN_DIR"

# ---------- preflight ----------
note "1. time / host / GPU / tool versions"
date -u
hostname || true
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv || true
GIT_REV=$(git -C "$SCRIPTS_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
echo "scripts_rev=$GIT_REV"
pip install -q vllm huggingface_hub
python3 -c "import vllm, torch; print('vllm:', vllm.__version__, '| torch:', torch.__version__, '| gpu:', torch.cuda.get_device_name(0))"

if [ ! -f "$KEY_FILE" ]; then
  echo "REFUSED: judge key not found at $KEY_FILE"
  echo "Store the OpenRouter key of the effiq-judge account first (same pattern as the GitHub token):"
  echo '  mkdir -p ~/pilot-env && chmod 700 ~/pilot-env && read -s -p "paste key, enter: " K && echo && printf '"'"'%s'"'"' "$K" > ~/pilot-env/openrouter-key && chmod 600 ~/pilot-env/openrouter-key && unset K && wc -c ~/pilot-env/openrouter-key'
  exit 1
fi
PERMS=$(stat -c %a "$KEY_FILE" 2>/dev/null || echo "?")
[ "$PERMS" = "600" ] || echo "WARNING: $KEY_FILE permissions are $PERMS (expected 600)"

echo "banner: L5 BLIND QUALITY GATE — final gate of Pilot 001"
START_TS=$(date +%s)

# ---------- phase 2: frozen evaluation set ----------
note "2. frozen evaluation set (seed $FROZEN_SEED, $N_ITEMS items)"
FROZEN_JSONL="$FROZEN_JSONL" FROZEN_SEED="$FROZEN_SEED" N_ITEMS="$N_ITEMS" MODEL="$MODEL" python3 - <<'PY'
import hashlib, json, os, random

FROZEN = os.environ["FROZEN_JSONL"]
SEED = int(os.environ["FROZEN_SEED"])
N_ITEMS = int(os.environ["N_ITEMS"])

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

existing = []
if os.path.exists(FROZEN):
    existing = [json.loads(l) for l in open(FROZEN) if l.strip()]

if len(existing) == N_ITEMS:
    print(f"frozen set already present: {FROZEN} ({len(existing)} items) — resume, no rebuild")
else:
    if existing:
        print(f"WARNING: {FROZEN} has {len(existing)} items (expected {N_ITEMS}); rebuilding from seed {SEED}")
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
    # 50 items per form; tier split 17/17/16 (16k tier slightly lighter for wall-clock reasons)
    PLAN = [(form, tier, rep) for form in FORMS for tier in TIERS
            for rep in range(16 if tier == 16384 else 17)]
    assert len(PLAN) == N_ITEMS, f"plan size {len(PLAN)} != {N_ITEMS}"

    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(os.environ["MODEL"])
    with open(FROZEN, "w") as fp:
        for idx, (form, tier, rep) in enumerate(PLAN):
            prompt = build_prompt(form, tier, tok)
            mt = rng.randint(200, 800)
            rec = dict(request_id=f"fz-{idx:03d}", form=form, tier_target=tier,
                       rep=rep, max_tokens=mt, prompt=prompt)
            fp.write(json.dumps(rec, sort_keys=True) + "\n"); fp.flush()
    print(f"frozen set built: {N_ITEMS} items, seed={SEED}")

print(f"frozen_set_sha256={sha(FROZEN)}")
PY

# ---------- phase 3: generation, arm A (BF16) ----------
note "3. generation: arm A (BF16 reference)"
FROZEN_JSONL="$FROZEN_JSONL" GEN_JSONL="$GEN_A_JSONL" ARM="A-bf16" QUANT="none" \
MODEL="$MODEL" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" GIT_REV="$GIT_REV" python3 - <<'PY'
import hashlib, json, os, time, datetime

MODEL   = os.environ["MODEL"]
FROZEN  = os.environ["FROZEN_JSONL"]
GEN     = os.environ["GEN_JSONL"]
ARM     = os.environ["ARM"]
QUANT   = os.environ["QUANT"]
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])

frozen = [json.loads(l) for l in open(FROZEN) if l.strip()]
done = set()
if os.path.exists(GEN):
    for l in open(GEN):
        if l.strip(): done.add(json.loads(l)["request_id"])
todo = [r for r in frozen if r["request_id"] not in done]
print(f"arm {ARM}: {len(done)} already generated, {len(todo)} to go")
if not todo:
    print(f"arm {ARM}: nothing to do — resume complete")
    raise SystemExit(0)

from transformers import AutoTokenizer
from huggingface_hub import snapshot_download
tok = AutoTokenizer.from_pretrained(MODEL)
revision = __import__("pathlib").Path(snapshot_download(MODEL)).name

from vllm import LLM, SamplingParams
# prefix caching OFF (consistency with the formal measurement stage)
kw = dict(model=MODEL, max_model_len=20480, enable_prefix_caching=False)
if QUANT == "fp8":
    kw["quantization"] = "fp8"
llm = LLM(**kw)

with open(GEN, "a") as fg:
    for rec in todo:
        if time.time() - T0 > MAX_SEC:
            print(f"TIME GUARD: generation aborted past {MAX_SEC}s; partial log preserved, stage NOT complete — re-run to resume")
            break
        sp = SamplingParams(temperature=0, max_tokens=rec["max_tokens"])
        t0 = time.time()
        out = llm.generate([rec["prompt"]], sp)
        wall = time.time() - t0
        o = out[0].outputs[0]
        oids = list(o.token_ids)
        row = dict(request_id=rec["request_id"], arm=ARM, quantization=QUANT,
                   form=rec["form"], tier_target=rec["tier_target"],
                   max_tokens=rec["max_tokens"],
                   prompt_tokens=len(tok.encode(rec["prompt"])), output_tokens=len(oids),
                   wall_s=round(wall, 3),
                   out_ids_sha256=hashlib.sha256(json.dumps(oids).encode()).hexdigest(),
                   output_text=o.text,
                   model=MODEL, model_revision=revision, scripts_rev=os.environ["GIT_REV"],
                   ts_utc=datetime.datetime.utcnow().isoformat() + "Z")
        fg.write(json.dumps(row, sort_keys=True) + "\n"); fg.flush()
        print(f"  {row['request_id']} {ARM} out_tokens={len(oids)} wall={wall:.1f}s")
print(f"arm {ARM} phase done")
PY

# ---------- phase 4: generation, arm B (FP8, Amendment-01) ----------
note "4. generation: arm B (FP8 dynamic, Amendment-01)"
FROZEN_JSONL="$FROZEN_JSONL" GEN_JSONL="$GEN_B_JSONL" ARM="B-fp8" QUANT="fp8" \
MODEL="$MODEL" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" GIT_REV="$GIT_REV" python3 - <<'PY'
import hashlib, json, os, time, datetime

MODEL   = os.environ["MODEL"]
FROZEN  = os.environ["FROZEN_JSONL"]
GEN     = os.environ["GEN_JSONL"]
ARM     = os.environ["ARM"]
QUANT   = os.environ["QUANT"]
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])

frozen = [json.loads(l) for l in open(FROZEN) if l.strip()]
done = set()
if os.path.exists(GEN):
    for l in open(GEN):
        if l.strip(): done.add(json.loads(l)["request_id"])
todo = [r for r in frozen if r["request_id"] not in done]
print(f"arm {ARM}: {len(done)} already generated, {len(todo)} to go")
if not todo:
    print(f"arm {ARM}: nothing to do — resume complete")
    raise SystemExit(0)

from transformers import AutoTokenizer
from huggingface_hub import snapshot_download
tok = AutoTokenizer.from_pretrained(MODEL)
revision = __import__("pathlib").Path(snapshot_download(MODEL)).name

from vllm import LLM, SamplingParams
# prefix caching OFF (consistency with the formal measurement stage)
kw = dict(model=MODEL, max_model_len=20480, enable_prefix_caching=False)
if QUANT == "fp8":
    kw["quantization"] = "fp8"
llm = LLM(**kw)

with open(GEN, "a") as fg:
    for rec in todo:
        if time.time() - T0 > MAX_SEC:
            print(f"TIME GUARD: generation aborted past {MAX_SEC}s; partial log preserved, stage NOT complete — re-run to resume")
            break
        sp = SamplingParams(temperature=0, max_tokens=rec["max_tokens"])
        t0 = time.time()
        out = llm.generate([rec["prompt"]], sp)
        wall = time.time() - t0
        o = out[0].outputs[0]
        oids = list(o.token_ids)
        row = dict(request_id=rec["request_id"], arm=ARM, quantization=QUANT,
                   form=rec["form"], tier_target=rec["tier_target"],
                   max_tokens=rec["max_tokens"],
                   prompt_tokens=len(tok.encode(rec["prompt"])), output_tokens=len(oids),
                   wall_s=round(wall, 3),
                   out_ids_sha256=hashlib.sha256(json.dumps(oids).encode()).hexdigest(),
                   output_text=o.text,
                   model=MODEL, model_revision=revision, scripts_rev=os.environ["GIT_REV"],
                   ts_utc=datetime.datetime.utcnow().isoformat() + "Z")
        fg.write(json.dumps(row, sort_keys=True) + "\n"); fg.flush()
        print(f"  {row['request_id']} {ARM} out_tokens={len(oids)} wall={wall:.1f}s")
print(f"arm {ARM} phase done")
PY

# ---------- phase 5: blind judging via OpenRouter ----------
note "5. blind judging (judge sees no arm labels; blind seed $BLIND_SEED)"
FROZEN_JSONL="$FROZEN_JSONL" GEN_A_JSONL="$GEN_A_JSONL" GEN_B_JSONL="$GEN_B_JSONL" \
BLIND_JSONL="$BLIND_JSONL" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" BLIND_SEED="$BLIND_SEED" \
KEY_FILE="$KEY_FILE" BUDGET_USD="$BUDGET_USD" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" \
GIT_REV="$GIT_REV" python3 - <<'PY'
import hashlib, json, os, time, datetime, random
import urllib.request, urllib.error

FROZEN  = os.environ["FROZEN_JSONL"]
GEN_A   = os.environ["GEN_A_JSONL"]
GEN_B   = os.environ["GEN_B_JSONL"]
BLINDF  = os.environ["BLIND_JSONL"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
BLSEED  = int(os.environ["BLIND_SEED"])
KEYF    = os.environ["KEY_FILE"]
BUDGET  = float(os.environ["BUDGET_USD"])
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])
AXES    = ["correctness", "instruction_following", "clarity"]

# Judge model policy (documented, pre-registered):
#   - OpenAI / Anthropic / Google models are NOT reachable: the billing region
#     of this account is blocked from those providers by OpenRouter policy.
#   - Qwen-family judges are excluded BY DESIGN: a Qwen judge scoring Qwen
#     outputs would be a family-conflict of interest.
#   - Probe order below; first model that answers becomes the judge and its
#     identity is archived with every judged row. Prices are USD per 1M
#     tokens (input/output), as listed on OpenRouter on 2026-10-06; used for
#     the budget guard only, not for any verdict math.
CANDIDATES = [
    ("deepseek/deepseek-chat-v3-0324", 0.29, 1.14),
    ("deepseek/deepseek-chat-v3.1",    0.25, 0.95),
    ("deepseek/deepseek-v3.1-terminus",0.27, 1.00),
    ("z-ai/glm-4.6",                   0.43, 1.75),
]
FALLBACK_PRICE = (1.00, 3.00)   # conservative, if an unlisted model ever answers

if not os.path.exists(KEYF):
    print(f"REFUSED: judge key file missing: {KEYF}")
    print("Store the OpenRouter key of the effiq-judge account there (chmod 600) and re-run.")
    raise SystemExit(1)
KEY = open(KEYF).read().strip()
if not KEY.startswith("sk-or-"):
    print("REFUSED: key file does not look like an OpenRouter key (expected sk-or-... prefix)")
    raise SystemExit(1)

def call_api(model, messages, max_tokens, timeout=120):
    body = json.dumps(dict(model=model, messages=messages, temperature=0,
                           max_tokens=max_tokens)).encode()
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions", data=body,
        headers={"Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json",
                 "HTTP-Referer": "https://github.com/effiq/pilot001",
                 "X-Title": "effiq-pilot001-quality-gate"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

# ---- probe judge model ----
judge_model, pin, pout = None, None, None
for cand, cin, cout in CANDIDATES:
    try:
        resp = call_api(cand, [dict(role="user", content="Reply with the single word: ok")], max_tokens=4, timeout=60)
        txt = resp["choices"][0]["message"]["content"]
        judge_model, pin, pout = cand, cin, cout
        print(f"judge model selected: {cand} (probe ok)")
        break
    except Exception as e:
        print(f"judge candidate {cand}: unavailable ({type(e).__name__}: {e})")
if judge_model is None:
    print("REFUSED: no judge model reachable — check key balance/region; nothing judged.")
    raise SystemExit(1)

# ---- load data ----
frozen = [json.loads(l) for l in open(FROZEN) if l.strip()]
def load_gen(p):
    return {json.loads(l)["request_id"]: json.loads(l) for l in open(p) if l.strip()}
gA, gB = load_gen(GEN_A), load_gen(GEN_B)

# ---- blind map (seeded, archived; the judge never learns which arm is which) ----
blind = {}
if os.path.exists(BLINDF):
    for l in open(BLINDF):
        if l.strip():
            r = json.loads(l); blind[r["request_id"]] = r["a_is_response_1"]
else:
    rng = random.Random(BLSEED)
    with open(BLINDF, "w") as fb:
        for rec in frozen:
            v = rng.random() < 0.5
            blind[rec["request_id"]] = v
            fb.write(json.dumps(dict(request_id=rec["request_id"], a_is_response_1=v), sort_keys=True) + "\n")
        fb.flush()
    print(f"blind map built (seed={BLSEED}): {len(blind)} items")

judged = {}
if os.path.exists(JRAW):
    for l in open(JRAW):
        if l.strip():
            r = json.loads(l); judged[r["request_id"]] = r

def est_cost(model, ptoks, ctoks):
    cin, cout = FALLBACK_PRICE
    for cand, i_, o_ in CANDIDATES:
        if cand == model: cin, cout = i_, o_
    return (ptoks * cin + ctoks * cout) / 1e6

spent = sum(est_cost(r["judge_model"], r.get("prompt_tokens", 0), r.get("completion_tokens", 0))
            for r in judged.values())
print(f"judge resume: {len(judged)} already judged, est. spent so far ${spent:.3f} (budget guard ${BUDGET:.0f})")

SYSTEM = ("You are an impartial, strict evaluator of AI assistant outputs. You compare two "
          "responses to the same user prompt and score each on three axes. Be objective and "
          "consistent across items. Output ONLY valid JSON, no markdown, no commentary.")
TEMPLATE = """[USER PROMPT]
{prompt}

[RESPONSE 1]
{r1}

[RESPONSE 2]
{r2}

Score each response on three axes, integers 0-10:
- correctness: factual/technical correctness relative to what the prompt asks.
- instruction_following: does it do what was asked, completely, without missing parts or extraneous content.
- clarity: coherence, organization, fluency.

Return ONLY this JSON:
{{"response_1": {{"correctness": X, "instruction_following": Y, "clarity": Z}},
 "response_2": {{"correctness": X, "instruction_following": Y, "clarity": Z}}}}"""

def parse_scores(content):
    c = content.strip()
    if c.startswith("```"):
        c = c.strip("`")
        if c.lower().startswith("json"): c = c[4:]
    i, j = c.find("{"), c.rfind("}")
    obj = json.loads(c[i:j+1])
    out = {}
    for k in ("response_1", "response_2"):
        sc = obj[k]
        vals = {a: int(sc[a]) for a in AXES}
        if not all(0 <= v <= 10 for v in vals.values()): raise ValueError("score out of range")
        out[k] = vals
    return out

n_new, n_fail = 0, 0
with open(JRAW, "a") as fj:
    for rec in frozen:
        rid = rec["request_id"]
        if rid in judged or rid not in gA or rid not in gB:
            continue
        if time.time() - T0 > MAX_SEC:
            print(f"TIME GUARD: judging aborted past {MAX_SEC}s; partial judge log preserved — re-run to resume")
            break
        if spent > BUDGET:
            print(f"BUDGET GUARD: est. spend ${spent:.2f} exceeds ${BUDGET:.0f}; aborting (boss decision required)")
            break
        r1, r2 = ((gA[rid]["output_text"], gB[rid]["output_text"]) if blind[rid]
                  else (gB[rid]["output_text"], gA[rid]["output_text"]))
        msgs = [dict(role="system", content=SYSTEM),
                dict(role="user", content=TEMPLATE.format(prompt=rec["prompt"], r1=r1, r2=r2))]
        ok = False
        for attempt, pause in enumerate((5, 15, 30)):
            try:
                resp = call_api(judge_model, msgs, max_tokens=300)
                content = resp["choices"][0]["message"]["content"]
                scores = parse_scores(content)
                u = resp.get("usage", {})
                row = dict(request_id=rid, judge_model=judge_model,
                           a_is_response_1=blind[rid],
                           scores_r1=scores["response_1"], scores_r2=scores["response_2"],
                           prompt_tokens=u.get("prompt_tokens", 0),
                           completion_tokens=u.get("completion_tokens", 0),
                           raw_content=content, scripts_rev=os.environ["GIT_REV"],
                           ts_utc=datetime.datetime.utcnow().isoformat() + "Z")
                fj.write(json.dumps(row, sort_keys=True) + "\n"); fj.flush()
                spent += est_cost(judge_model, row["prompt_tokens"], row["completion_tokens"])
                n_new += 1; ok = True
                if n_new % 10 == 0 or n_new == 1:
                    print(f"  judged {rid} ({len(judged)+n_new}/{len(frozen)}), est. spent ${spent:.3f}")
                break
            except Exception as e:
                print(f"  judge error on {rid} (attempt {attempt+1}): {type(e).__name__}: {e}")
                time.sleep(pause)
        if not ok:
            n_fail += 1
            print(f"  {rid}: all retries failed — left for next resume")

print(f"judge phase done: new={n_new} failed={n_fail} total_judged={len(judged)+n_new}/{len(frozen)} est_spent=${spent:.3f}")
PY

# ---------- phase 6: verdict ----------
note "6. quality-gate verdict (recomputed from archived logs)"
run_verdict
RC_V=$?

# ---------- completeness gate ----------
NA=$(wc -l < "$GEN_A_JSONL" 2>/dev/null || echo 0)
NB=$(wc -l < "$GEN_B_JSONL" 2>/dev/null || echo 0)
NJ=$(wc -l < "$JUDGE_RAW_JSONL" 2>/dev/null || echo 0)
if [ "$NA" -ge "$N_ITEMS" ] && [ "$NB" -ge "$N_ITEMS" ] && [ "$NJ" -ge "$N_ITEMS" ] && [ "$RC_V" -eq 0 ]; then
  date -u > "$RUN_DIR/COMPLETE"
  echo "STAGE 06 QUALITY GATE: COMPLETE ✅ (genA=$NA genB=$NB judged=$NJ; see verdict_q.txt)"
  exit 0
else
  echo "STAGE 06 QUALITY GATE: INCOMPLETE ❌ (genA=$NA genB=$NB judged=$NJ; no COMPLETE marker — re-run the same command to resume)"
  exit 1
fi
