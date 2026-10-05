Pilot 001 · Protocol Lock (Pre-Registration)
Version 1.0 ｜ Frozen 2026-10-05 ｜ Status Active
Measurement window 2026-10-05 → 2026-11-04 (30 days)
Day-7 checkpoint 2026-10-12 ｜ Day-30 verdict 2026-11-04
This document is the pre-registered protocol for Effiq Pilot 001. Once frozen, no locked item may be modified during data collection. The only legal path for change is a new version (v1.1, v2.0, …) with the reason and date recorded; silent edits are prohibited. Results — PASS or FAIL — will be published with complete evidence.
0. Pilot definition
Under realistic long-context workloads (prompts of 4K–16K tokens, outputs of 200–800 tokens), measure the end-to-end speedup of "FP8/INT8 quantization + speculative decoding" versus "default BF16 configuration". Success criterion: paired-bootstrap 95% CI lower bound ≥ 1.20×, with zero quality degradation on a blind review gate.
1. Locked items
L1 — Model
• Primary: Qwen2.5-14B-Instruct (native long-context support, first-class vLLM citizen).
• Fallback: Llama-3.1-8B-Instruct — only if the primary hits a blocking engineering issue on mainline vLLM; switching requires a deviation-log entry. No silent switches.
• Weights: Hugging Face official repository, model revision hash recorded. Both arms use the identical weight files; quantization happens at load time.
L2 — Workload construction
• Three task shapes (1/3 each): long-document QA (multi-document RAG form), code completion (long repo context), long-document summarization.
• Prompt lengths: 4K / 8K / 16K tiers, equal shares. Target output length: 200–800 tokens.
• Data sources: public datasets, sampled and human-rewritten. Fixed seed 20261003. A frozen set of 150 items; its hash is archived after construction. Any modification constitutes a new experiment.
• Performance and quality are measured separately: performance on dynamically generated workloads (re-sampled per run), quality on the frozen 150-item set.
L3 — Two arms
• Arm A (baseline): BF16 weights + default vLLM configuration (mainline release; version recorded).
• Arm B (optimized): FP8 or INT8 quantized weights (choice within the pre-registered menu, see §2) + speculative decoding.
• Hardware boundary: one 48GB-class GPU. Locked to L40S for the entire pilot (frozen 2026-10-05 after pre-flight).
• Explicit non-goals: no custom kernels, no vLLM source modifications, no unreleased/non-mainline features. Every difference between arms must be traceable in config files.
L4 — Measurement protocol
• Request-level interleaving on one machine: A,B,A,B,… across 6 interleaved runs (if the CI straddles the 1.20 boundary, runs increase to 10 per the pre-registered rule — never more).
• Statistics: paired bootstrap over interleaved pairs. Report point estimate and 95% CI of the speedup ratio R.
• Anti-p-hacking clauses: no extending declared windows, no dropping outliers, no cherry-picking run subsets, no metric changes mid-measurement. All raw logs are retained and published.
• Pre-registered verdict: PASS ⟺ CI lower bound ≥ 1.20×. Otherwise FAIL. There is no "close enough".
L5 — Quality gate (blind)
• Both arms run the frozen 150-item set once, temperature 0.
• Blind review: the judge is not told which arm produced an output; output order is randomized; rubric and prompts are delivered separately.
• Judge: fixed rubric (correctness / completeness / instruction-following, 0–10 each axis); judge model version locked and recorded.
• Tolerance: 0 pp — if any axis of either arm averages more than 0.1 below the other arm, the quality gate is FAIL, regardless of performance.
L6 — Time window, budget, stop-loss
• Total window: 30 days from the freeze date.
• Day-7 checkpoint (2026-10-12): speculative-decoding acceptance-rate probe (100 requests per prompt tier). Mean acceptance < 0.5 triggers the pre-registered draft swap (ngram ↔ EAGLE-class). The window does not extend.
• Day 30 (2026-11-04): no confirmed CI ≥ 1.20× → stop-loss executes: all external narrative work halts; review before any new decision.
• Budget hard cap: GPU $60 + judge API $50 = $110 total. Hitting either cap stops the pilot. Additional spend requires written approval.
L7 — Publication
• Results (PASS or FAIL) are published within 7 days after the window closes, as a public article plus complete evidence.
• Published materials: both arms' config files, weight hashes, raw logs, the CI computation script, and the deviation log.
2. Pre-registered exploration space (not locked)
The following decisions may be made from data inside the window, but every change must enter the deviation log:
1. Quantization scheme: FP8 (W8A8) vs INT8 — chosen from day-7 prefill-speed data.
2. Draft method: ngram vs EAGLE-class — switchable within the menu.
3. vLLM patch-level upgrades (version recorded per change).
3. Verification
Every figure published from this pilot is reproducible from artifacts: raw logs, configuration files, and a CI computation script that recomputes the reported interval from the raw data in one command. The PASS/FAIL verdict is produced by the statistics script from raw logs — not by narrative.
￼
Frozen 2026-10-05. Signed by the operator. This document ships before any result does.
