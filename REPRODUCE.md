# Reproduce the Pilot 001 verdict

Every number in [VERDICT.md](VERDICT.md) is recomputed from archived raw logs by scripts in this repository. No GPU is needed for verification (only the original measurement needed one). Requirements: `python3` ≥ 3.10 with `numpy`.

## 1. Layout

Clone both repositories side by side so that `$HOME/effiq` looks like:

```
$HOME/effiq/pilot001      <- this repository (scripts + protocol)
$HOME/effiq/pilot-logs    <- the raw measurement logs
```

```bash
mkdir -p ~/effiq && cd ~/effiq
git clone https://github.com/effiq/pilot001.git
git clone https://github.com/effiq/pilot-logs.git
```

## 2. Performance verdict (Stage 05)

```bash
bash ~/effiq/pilot001/stages/05-verdict.sh --verify
```

This scans the logs for the six formal runs carrying a COMPLETE marker, recomputes the paired per-request ratios, and reruns the bootstrap (seed fixed at 20261006, 100,000 resamples — fully deterministic). The output must contain:

```
mean ratio (geometric, over runs): 1.419x
95% bootstrap CI: [1.387x, 1.442x]
criterion: CI lower bound >= 1.2x  ->  PASS
```

and per-tier:

```
tier  4096: ratio=1.428x CI=[1.331x, 1.488x] PASS
tier  8192: ratio=1.433x CI=[1.414x, 1.445x] PASS
tier 16384: ratio=1.397x CI=[1.389x, 1.411x] PASS
```

If your numbers differ from these, the logs you cloned differ from the ones we published — that is the point of the exercise.

## 3. Quality-gate verdict (Stage 06)

```bash
bash ~/effiq/pilot001/stages/06-quality-gate.sh --verify ~/effiq/pilot-logs/2026-10-06/06-quality-gate/run_1
```

This recomputes the verdict from the archived judge responses and blinding map only — no network, no API key, no GPU. The output must contain:

```
correctness           : A(bf16)=6.487  B(fp8)=6.700  delta=+0.213
instruction_following : A(bf16)=6.087  B(fp8)=6.267  delta=+0.180
clarity               : A(bf16)=5.820  B(fp8)=5.873  delta=+0.053
[overall] pooled delta (B - A): +0.149
criterion: overall delta >= -0.1 AND every axis delta >= -0.1  ->  PASS
```

plus the sha256 of `frozen_set.jsonl`, `gen_A.jsonl`, `gen_B.jsonl`, `judge_raw.jsonl`, and `blind_map.jsonl` (short forms listed in VERDICT.md §6).

## 4. Per-run descriptive recomputation

Any single formal run's descriptive means and hashes can be recomputed with:

```bash
bash ~/effiq/pilot001/stages/04-formal.sh --verify <run_dir>
```

Note this entry prints descriptive statistics only, by design: the CI lives exclusively in the Stage 05 verdict script (anti-p-hacking separation).

## 5. What you cannot reproduce without the original accounts

- The OpenRouter judge calls themselves (they are archived verbatim in `judge_raw.jsonl`; Stage 06 `--verify` recomputes the verdict from that archive).
- The GPU measurements (archived as `raw.jsonl` with per-request timing and token hashes). Rerunning Stage 04 on your own L40S produces *new* data under the same protocol — which we would genuinely welcome as an independent replication.
