# Codex Overview: план улучшений

Цель: сделать метрики однозначными и пригодными для анализа агентом. Не менять WeightTracker, не добавлять инфраструктуру и сохранить фильтр `Project cwd` и auto-refresh `10s`.

## Правила выполнения

- Задачи выполнять по порядку: контракт из задачи 1 обязателен для остальных.
- Менять только dashboard, существующий telemetry pipeline и `codex-performance-report`.
- После каждой задачи проверять затронутые запросы на одном фиксированном временном диапазоне.
- Не считать активный turn завершённым и не смешивать вложенные вызовы tools с верхнеуровневыми.

## 1. Зафиксировать контракт метрик

**Статус:** выполнено — контракт зафиксирован в `METRIC_CONTRACT.md`.

**Codex:** `gpt-5.6-sol` · **Effort:** `high`

Кратко описать источники и правила расчёта Turns, duration, tokens, cache hit, tool calls и failures: completed/active turns, top-level/nested calls, project scope и момент снимка `as_of`.

**Готово, когда:** для каждой KPI есть одна формула, источник данных и правило фильтрации.

## 2. Добавить контроль полноты данных

**Статус:** выполнено — dashboard и report показывают incomplete/active coverage и machine-readable warnings.

**Codex:** `gpt-5.6-sol` · **Effort:** `high`

Показывать active turns, пропущенные/слишком большие traces и расхождения источников. KPI должны явно относиться к завершённым turns на одном `as_of`.

**Готово, когда:** неполный trace не исчезает молча из KPI и разбивок, а получает понятный warning.

## 3. Исправить rounds и time breakdown

**Статус:** выполнено — rounds, sampling и tools объединяются по Trace ID; other clamp и overlap warning проверены fixture.

**Codex:** `gpt-5.6-terra` · **Effort:** `high`

Считать model rounds, model sampling, tool duration и other time по Trace ID, не полагаясь только на строгую parent/descendant связь. Починить пустую панель `Model rounds / turn`.

**Готово, когда:** известные traces показывают ненулевые rounds и breakdown сходится с общей duration.

## 4. Нормализовать tool failures

**Статус:** выполнено — terminal outcome, project scope, top-level dedup и bounded failure fields используют один набор.

**Codex:** `gpt-5.6-sol` · **Effort:** `high`

Применить `Project cwd`, фильтр события и дедупликацию по верхнеуровневому call. Добавить `failure_class`, nested/retry/recovered status, краткую причину и ссылку на Trace ID.

**Готово, когда:** KPI `Tool failures` и таблица failures считают один и тот же набор событий и объясняют причину каждого сбоя.

## 5. Доработать аналитику tools

**Статус:** выполнено — slowest calls, calls/failures и p50/p95/max используют project-scoped terminal spans.

**Codex:** `gpt-5.6-terra` · **Effort:** `medium`

Починить `Slowest tool calls`; добавить для каждого tool calls, failures, p50, p95 и max duration с project scope и переходом в trace.

**Готово, когда:** медленные успешные calls отделены от быстрых ошибок, а пустая панель не скрывает отсутствие данных.

## 6. Уточнить tokens и cache hit

**Статус:** выполнено — input/cached/non-cached/output/reasoning/total и их inclusion semantics добавлены.

**Codex:** `gpt-5.6-terra` · **Effort:** `medium`

Явно разделить input, cached input, non-cached input, output и reasoning tokens. Показать cache hit по model/turn и исключить двойное суммирование вложенных token spans.

**Готово, когда:** подписи объясняют, что cached входит в input, reasoning входит в output, а totals совпадают с таблицей Turns.

## 7. Снизить observer effect

**Статус:** выполнено — report фиксирует UTC as_of; dashboard показывает bounds и поддерживает абсолютный snapshot.

**Codex:** `gpt-5.6-terra` · **Effort:** `high`

Разделить completed и active turns, зафиксировать единый `as_of` для отчёта и панелей и не позволять текущему анализирующему turn менять уже показанный snapshot.

**Готово, когда:** повторный просмотр одного snapshot даёт те же числа при продолжающейся работе агента.

## 8. Ужесточить privacy и cardinality

**Статус:** выполнено — raw log bodies отбрасываются до Loki; dashboard/report используют bounded trace fields.

**Codex:** `gpt-5.6-sol` · **Effort:** `xhigh`

Не индексировать и не показывать полные tool arguments/output и пользовательские метаданные. Оставить безопасные summary/error kind, а необходимые детали — только в trace с ограничением размера.

**Готово, когда:** в Loki labels и dashboard нет секретов, персональных данных и неограниченных payload; диагностика причин сохраняется.

## 9. Обновить `codex-performance-report`

**Статус:** выполнено — JSON schema 2.0 и Markdown реализуют общий контракт и стабильный as_of.

**Codex:** `gpt-5.6-terra` · **Effort:** `high`

Привести JSON/Markdown к тому же контракту: `as_of`, completed/active turns, coverage warnings, non-cached tokens, model/tool breakdown и дедуплицированные failures.

**Готово, когда:** отчёт по `project + period` компактен, стабилен для машинного анализа и совпадает с dashboard на том же snapshot.

## 10. Добавить регрессионную проверку

**Статус:** выполнено — synthetic fixture, API query checks и UI smoke записаны в `CHECKPOINT.md`.

**Codex:** `gpt-5.6-sol` · **Effort:** `high`

Проверить fixture со слишком большим trace, отсутствующим parent/root, nested failure и активным turn. Сверить dashboard, report и сырые данные; выполнить UI smoke без развёртывания новой инфраструктуры.

**Готово, когда:** все контрольные случаи проходят, расхождений KPI нет, а ограничения и реально выполненные проверки записаны в checkpoint.

## Ожидаемый итог

После задачи 10 dashboard и report используют один контракт, failures объяснимы, неполные данные видимы, а агент может анализировать производительность без ручной сверки Tempo и Loki.

Рекомендации по моделям и effort основаны на [официальном руководстве OpenAI по GPT-5.6](https://developers.openai.com/api/docs/guides/latest-model): Sol — для сложной логики и проверки рисков, Terra — для сбалансированной реализации; повышенный effort используется только там, где он влияет на корректность.
