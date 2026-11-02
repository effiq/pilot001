# Independent Verification & Re-Measurement — Pilot 001

This repository ships with its complete verdict evidence bundled under `retest/`.
You can check every published number yourself, with no account, no API key, and
no assistance from us. Two tracks are offered:

- **Track 1 — audit / recompute** (no GPU): re-derive the verdict from the
  bundled raw archives, byte-for-byte.
- **Track 2 — independent re-measurement** (one rented GPU): re-run the
  measurement under the same protocol on your own hardware and compare against
  the pre-registered pass criteria.

Hardware scope note: a measurement like this is anchored to a declared
environment (see `retest/environment.lock`). Track 1 verifies the published
numbers exactly. Track 2 produces *new* data under the same protocol — the
correct comparison is against the pre-registered pass criteria, not against our
point estimates to the last decimal.

---

## Track 1 — audit / recompute (no GPU)

Requirements: Linux or macOS, `bash`, `python3` ≥ 3.10 with `numpy`. Nothing
else. No network beyond the initial clone. On Debian/Ubuntu (incl. WSL):
`sudo apt install -y python3-numpy`; elsewhere: `pip3 install numpy`.

If `~/effiq/pilot001` already exists from an older clone, move it aside first:
`mv ~/effiq/pilot001 ~/effiq/pilot001-old` (and `rm -f ~/effiq/pilot-logs`).

```bash
mkdir -p ~/effiq && cd ~/effiq
git clone https://github.com/effiq/pilot001.git
ln -s "$HOME/effiq/pilot001/retest/pilot-logs" ~/effiq/pilot-logs
```

### Performance half (stage 05)

```bash
bash ~/effiq/pilot001/stages/05-verdict.sh --verify
```

Expected output (deterministic: bootstrap seed 20261006, 100,000 resamples):

```
mean ratio (geometric, over runs): 1.419x
95% bootstrap CI: [1.387x, 1.442x]
criterion: CI lower bound >= 1.2x  ->  PASS
```

and per tier:

```
tier  4096: ratio=1.428x CI=[1.331x, 1.488x] PASS
tier  8192: ratio=1.433x CI=[1.414x, 1.445x] PASS
tier 16384: ratio=1.397x CI=[1.389x, 1.411x] PASS
```

### Quality half (stage 06)

```bash
bash ~/effiq/pilot001/stages/06-quality-gate.sh --verify ~/effiq/pilot-logs/2026-10-06/06-quality-gate/run_1
```

Expected:

```
correctness           : A(bf16)=6.487  B(fp8)=6.700  delta=+0.213
instruction_following : A(bf16)=6.087  B(fp8)=6.267  delta=+0.180
clarity               : A(bf16)=5.820  B(fp8)=5.873  delta=+0.053
[overall] pooled delta (B - A): +0.149
criterion: overall delta >= -0.1 AND every axis delta >= -0.1  ->  PASS
```

If any number differs, the archive in your hands differs from the one we
published — that is the point of the exercise, and we want to hear about it
(please open an issue).

### Integrity

`retest/MANIFEST.sha256` lists every bundled evidence file. Verify with:

```bash
cd ~/effiq/pilot001/retest && sha256sum -c MANIFEST.sha256
```

---

## Track 2 — independent re-measurement (rented GPU)

Both arms of Pilot 001 are stock configurations — BF16 defaults vs vLLM's
built-in FP8 dynamic quantization (`--quantization fp8`). No custom artifact of
ours is involved, so the entire measurement can be re-run by anyone.

1. Rent one NVIDIA L40S 48GB (any cloud; on-demand hourly is sufficient —
   the full measurement took hours, not days).
2. Install the pinned stack from `retest/environment.lock`
   (vLLM 0.31.0 / torch 2.13.0+cu130).
3. Clone this repo to `~/effiq/pilot001` on the machine, then point the STAGE
   file at the formal stage — the repo ships with STAGE parked at its final
   position (`06-quality-gate`), and the formal stage names its output
   directories after it:

   ```bash
   echo 04-formal > ~/effiq/pilot001/STAGE
   bash ~/effiq/pilot001/stages/00-preflight.sh   # environment self-check
   for i in 1 2 3 4 5 6; do bash ~/effiq/pilot001/stages/04-formal.sh; done
   bash ~/effiq/pilot001/stages/05-verdict.sh
   ```

   (Verified 2026-11-02 by walking the reader path on a GPU-less machine:
   without the STAGE step, fresh runs land in the wrong directory and the
   verdict script finds nothing. The remaining scripts read their stage
   identity from their own headers, so no equivalent step is needed for the
   other pilots.)

4. Compare your verdict against the pre-registered criterion
   (CI lower bound ≥ 1.20×), not against our 1.419× point estimate to the last
   decimal — cross-machine noise is real and expected.

The quality half scores outputs with a third-party judge model accessed via
API. To re-run it you need your own API access to a judge model; judge-model
behavior drifts over time, so treat a quality re-run as a new measurement
under the same protocol (same frozen set, same blinding seeds — both are in
the bundled archive).

What you cannot reproduce without our accounts: nothing material. The workload
is synthetic and declared, the seeds are frozen in the scripts, and the model
revision is pinned (`cf98f3b3…caa8`).
