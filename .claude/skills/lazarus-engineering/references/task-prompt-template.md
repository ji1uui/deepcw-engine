# Task Prompt Template — Engineering + UX + Quality

<goal>
利用者が何をできるようになるか。
</goal>

<context>
背景、関連仕様、現在の問題。
</context>

<experience_outcome>
Communicate / Discover / Collect / Compete / Learn / Experiment
</experience_outcome>

<scope>
変更対象:
非対象:
</scope>

<technical_requirements>
- ...
</technical_requirements>

<ux_requirements>
- visibility:
- control:
- recovery:
- latency:
- accessibility:
</ux_requirements>

<platform_requirements>
- Windows:
- macOS:
- architecture:
</platform_requirements>

<state_time_requirements>
- states:
- transitions:
- clock/timing:
</state_time_requirements>

<data_compatibility_requirements>
- schema/API/ABI:
- migration:
- backward compatibility:
</data_compatibility_requirements>

<observability_requirements>
- logs:
- diagnostics:
- performance metrics:
</observability_requirements>

<security_privacy_requirements>
- secrets:
- privacy:
- plugin/dependency trust:
- TX safety:
</security_privacy_requirements>

<acceptance_criteria>
Technical:
- ...

UX:
- ...

Compatibility:
- ...

Performance:
- ...
</acceptance_criteria>

<verification>
- Build
- Unit
- Integration
- Golden WAV
- Replay
- Performance
- Cross-platform
- UX scenario
- Compatibility
- Packaging
</verification>

<instructions>
1. CLAUDE.mdと該当Skill、関連architecture docsを読む。
2. 対象コード、caller/callee、tests、platform差異、既存UI patternを調査する。
3. current technical behavior / state model / user workflowをモデル化する。
4. 必要な最小変更を実装する。
5. technical + UX + compatibility + performance acceptance criteriaを検証する。
6. failure / rollback / diagnosticsを確認する。
7. 差分を自己レビューする。
8. Changes / UX impact / Verification / Regression / Compatibility / Remaining risks / Not verified を報告する。
</instructions>
