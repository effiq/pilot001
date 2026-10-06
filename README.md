# Effiq Pilot 001 — Execution Scripts

**Optimization is the product. Measurement is the moat.**

Execution layer for Pilot 001. This repository is written to an "assume it leaks" standard: no credentials, no pricing, no partner information. The measurement protocol is pre-registered; all results — PASS or FAIL — will be published together with the raw logs.

## Layout

tonight.sh        nightly entry point: update scripts → run current stage → push logs
STAGE             current stage id (switched by the maintainer)
stages/           stage scripts
00-preflight.sh pre-flight checks: GPU / vLLM / weight revision / smoke inference

## Design principles

- Logs are pushed to a separate public repository, [effiq/pilot-logs](https://github.com/effiq/pilot-logs); the pod-side token holds write access to that repository only
- Stage scripts are idempotent: re-running after an interruption is safe and produces no duplicate experiment data
- Pre-registration discipline: rules frozen before data collection cannot be modified silently — changes require a new versioned protocol
