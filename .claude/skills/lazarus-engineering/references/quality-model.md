# Software Quality Model

本プロジェクトの品質は単一指標では評価しない。

## Quality Dimensions
1. Correctness
2. Robustness
3. Real-time Safety
4. Determinism
5. Performance
6. Cross-platform Compatibility
7. Maintainability
8. UX Quality
9. Recoverability
10. Observability
11. Data Compatibility
12. Security / Privacy
13. Release Readiness

## Product Quality Principle
> Algorithm Quality × Implementation Correctness × Real-time Behavior ×
> Robustness × UX × Compatibility × Verification

いずれか1つが著しく低い場合、製品品質は成立しない。

## Evidence
品質主張には可能な限り対応する証拠を持つ。
- tests
- Golden WAV
- benchmark
- replay
- UX scenario
- CI matrix
- migration test
- package smoke test
