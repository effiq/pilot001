#!/usr/bin/env bash
# ============================================================
# Stage 00 · pre-flight checks
# Verify the environment can run Pilot 001: GPU / vLLM / weights / smoke inference.
# Discipline: this stage produces NO PASS/FAIL experiment data and never touches
# the frozen evaluation set. It only proves the environment is runnable.
# ============================================================
set -uo pipefail   # no -e on purpose: gather as much info as possible before exiting

FAIL=0
note() { printf '\n=== %s ===\n' "$*"; }
bad() { echo "FATAL: $*"; FAIL=1; }

note "0. time / host / GPU"
date -u
hostname || true
nvidia-smi || bad "no GPU or driver issue"

note "1. disk space (14B weights need ~30GB; container disk should be >= 60GB)"
df -h / "$HOME" || true

note "2. python"
python3 --version || bad "no python3"

note "3. vLLM install (pre-flight installs latest mainline; version is recorded in the log)"
pip install -q --upgrade pip
pip install -q vllm huggingface_hub
python3 -c "import vllm; print('vllm version:', vllm.__version__)" || bad "vllm install failed"

note "4. download primary weights Qwen/Qwen2.5-14B-Instruct and record revision hash"
python3 - <<'PY'
import pathlib, sys
try:
    from huggingface_hub import snapshot_download
    p = snapshot_download("Qwen/Qwen2.5-14B-Instruct")
    print("local path:", p)
    print("revision hash:", pathlib.Path(p).name)   # snapshot dir name == commit hash
except Exception as e:
    print("FATAL: weight download failed:", e)
    sys.exit(1)
PY
[ $? -ne 0 ] && bad "weight download failed"

note "5. smoke inference (BF16 defaults, one short prompt, max_tokens=32; not experiment data)"
python3 - <<'PY'
import sys
try:
    from vllm import LLM, SamplingParams
    llm = LLM(model="Qwen/Qwen2.5-14B-Instruct", max_model_len=1024)
    out = llm.generate(["用一句话介绍你自己。"],
                       SamplingParams(temperature=0, max_tokens=32))
    print("SMOKE-OUTPUT:", out[0].outputs[0].text[:200])
except Exception as e:
    print("FATAL: smoke inference failed:", e)
    sys.exit(1)
PY
[ $? -ne 0 ] && bad "smoke inference failed"

note "6. summary"
if [ "$FAIL" -eq 0 ]; then
  echo "PRE-FLIGHT: ALL GREEN ✅"
else
  echo "PRE-FLIGHT: FAILURES PRESENT ❌ (see FATAL lines above)"
fi
exit "$FAIL"
