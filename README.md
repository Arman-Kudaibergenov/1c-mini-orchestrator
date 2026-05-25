# 1c-mini-orchestrator

Локальный (Windows-laptop) оркестратор для запуска цепочки **аналитик → SDD-писатель → имплементатор → аудитор** над проектами 1С. Аналитик и писатель ходят в 1С через MCP-сервер `codemetadata` (внешний XML-дамп конфигурации), имплементатор делает реальные правки и пушит ветку, аудитор (Codex runtime) повторно проверяет и выносит вердикт.

Заточено под Windows 11 + Windows Terminal (`wt.exe`) + Windows PowerShell 5.1. Lightweight конструкция: один Claude Code в роли L2 (роутер) и спавн L3-агентов в отдельных `wt`-вкладках.

- **L1** = пользователь (открывает терминалы, пишет в чат L2)
- **L2** = Claude-сессия в корне репо (роутер, генератор task-пакетов)
- **L3** = аналитик / писатель / имплементатор / аудитор в отдельных вкладках `wt`

## Status

Все 5 фаз shipped:

| # | Фаза | Артефакт |
|---|---|---|
| 1 | Аналитик | `analysis_report.json` |
| 2 | SDD-писатель | `sdd.md` + `sdd_metadata.json` |
| 3 | Имплементатор | ветка `orchestrator/<task_id>` в git проекта + `impl_metadata.json` |
| 4 | Аудитор (codex runtime) | `audit_report.json` + operator_signoff convention |
| 5 | Hardening | mirror CRLF/LF normalization + phase-agnostic peek/kill |

Rotation / autonomous chain — намеренно отложено (operator-driven цепочка лучше воспроизводится при дебаге фазовых контрактов).

## Entry points

Фазо-агностичные обёртки (Phase 5 Stage C1):

- `scripts/peek-task.ps1 -TaskId X [-Tail N]` — автодетект фазы по packet'у + tail сессии (claude jsonl или codex rollout)
- `scripts/kill-task.ps1 -TaskId X` — автодетект фазы + kill wt-вкладки + стамп `killed_at`

Spawn / validate (по одному на фазу):

- `scripts/spawn-{analyst,sdd-writer,implementer,auditor}.ps1` — открыть новую `wt`-вкладку с L3-агентом под задачу
- `scripts/validate-{analysis,sdd,impl,audit}.ps1 -TaskId X` — Pydantic-валидация + операционные gate'ы

Per-phase peek/kill (`scripts/peek-analyst.ps1` etc.) — DEPRECATED forwarding shims; forward на `peek-task.ps1` / `kill-task.ps1`. Сохранены на один релиз для совместимости.

## Project registry

См. `projects.yaml`. Каждая запись — явный `path_local` + список MCP-серверов.

## Docs

- `docs/phase{1,2,3,4,5}-*-SDD.md` — контракты по фазам
- `docs/phase{1,2,3,4,5}-kickoff-brief.md` — входные брифы по фазам
- `docs/writer-forcing-functions.md` — FF1-FF8 для всех L3-агентов
- `docs/phase4-stage8-signoff-convention.md` — `operator_signoff.txt audit=<verdict>` convention

## Hooks (optional)

См. [`hooks/`](hooks/README.md) — опциональные Claude Code hooks (autonomous chain re-prompting, context state-machine, RLM session save, post-phase auto-validate). Все hooks **opt-in** через `settings.json` + env vars, дефолт OFF.

## Lineage & credits

См. [CREDITS.md](CREDITS.md) и [NOTICE](NOTICE). Лицензия — AGPL-3.0 (см. [LICENSE](LICENSE)).
