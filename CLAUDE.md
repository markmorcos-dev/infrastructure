# infrastructure

Helm chart + CI that deploys the apps (see README.md).

## Rules for every change

- Every change ships with **unit tests, an integration test, and visual tests** where there is a UI.
  Scripts get shell tests under `scripts/tests/` with stubbed `kubectl`/`npx` (unit: each rule; integration: the full lifecycle),
  run by `.github/workflows/test-scripts.yaml`.
- Run the relevant tests before pushing.
