# Деплой на AWS: Route53 + ALB + Fargate + RDS

Планируемый стек для горизонтального масштабирования: Route53 (DNS) → ALB →
ECS Fargate (несколько task'ов) → RDS. Ниже — что в текущей архитектуре уже
готово к этому, чего не хватает, и что настроить в инфре отдельно от кода.

## Уже готово в коде

- **Action Cable в проде — Redis-адаптер**, не `async` (`config/cable.yml`).
  Бродкасты из одного task'а долетают до сокетов, которые держит другой —
  критично для игры на вебсокетах при нескольких инстансах.
- **Сессии — cookie-store** (Devise), без server-side session-стораджа —
  sticky sessions на ALB не нужны.
- **Таймер хода не живёт в процессе.** `deadline_at` — в БД,
  `resolve_if_expired!` вызывается лениво при следующем запросе
  (`battles#show`/`state`). Какой task обслужит игрока — не важно.
- **Очередь матчмейкинга — в БД** (`QueueEntry`), не in-memory. `Matchmaker`
  уже рассчитан на конкурентный доступ (`claim`/`restore` в
  `app/models/matchmaker.rb`) — параллельные `join` с разных task'ов не
  потеряют игрока.
- **`Battle#resolve_turn!` под `with_lock`** — блокировка на уровне БД, а не
  процесса: с несколькими task'ами гонка резолвится так же, как с несколькими
  тредами внутри одного.
- Фоновых воркеров и ActiveJob сейчас нет — нечего гонять между task'ами.
- **`GET /up`** (`rails/health#show`) — готовый health-check эндпоинт для ALB
  target group.
- **`config.force_ssl = true`** — ALB терминирует TLS и шлёт
  `X-Forwarded-Proto`, Rails понимает это из коробки, `assume_ssl` не нужен.
- **Postgres везде, не только в проде.** `config/database.yml` больше не
  SQLite — один и тот же `adapter: postgresql` во всех окружениях,
  подключение через `DATABASE_HOST`/`DATABASE_USERNAME`/`DATABASE_PASSWORD`/
  `DATABASE_NAME`. В RDS достаточно завести те же переменные.
- **Гем `redis` добавлен.** `cable.yml` указывал на Redis-адаптер и раньше, но
  самого гема в `Gemfile` не было — в проде это уронило бы Action Cable при
  первом же бродкасте. Теперь он есть, `REDIS_URL` подхватывается как в
  проде, так и локально.
- **`Dockerfile` собирает production-образ** (multi-stage, ассеты
  прекомпилируются без секретов через `SECRET_KEY_BASE_DUMMY=1`) — прогнан
  локально через `docker compose up --build` против настоящих Postgres и
  Redis (тоже в docker-compose), включая полный прогон RSpec поверх реального
  Postgres. Это тот образ, который пойдёт в ECR.
- **`Gemfile.lock` знает про `x86_64-linux` и `aarch64-linux`** (добавлено
  `bundle lock --add-platform`), так что образ соберётся что на обычном
  x86_64 Fargate, что на Graviton — `bcrypt` при этом собирается из исходников
  (`force_ruby_platform: true`), так что построится под архитектуру
  контейнера сам, независимо от хоста, на котором собирали образ.

## Чего не хватает

- **RDS вместо локального Postgres-контейнера.** Код уже ничего не знает про
  разницу — `DATABASE_HOST` и соседние переменные меняются на адрес RDS
  инстанса, без правок в `database.yml`.
- **ElastiCache вместо локального Redis-контейнера** — аналогично, меняется
  только `REDIS_URL`.
- **Секрет-менеджмент.** `RAILS_MASTER_KEY` сейчас читается из `.env`/ENV на
  докер-хосте; в ECS его нужно класть в Secrets Manager/SSM и подключать через
  task definition, не зашивать в образ и не хранить в открытом ENV таск-дефы.

## Настроить в инфре (не в коде)

- **RAILS_MASTER_KEY** — через Secrets Manager/SSM Parameter Store в task
  definition, не зашивать в образ.
- **Security groups** — Fargate-таски должны иметь сетевой доступ и к RDS, и к
  ElastiCache.
- **ACM-сертификат** на домен из Route53, повешенный на ALB listener (443).
- **Миграции** гонять не из entrypoint каждого контейнера (иначе несколько
  task'ов при одновременном старте мигрируют параллельно), а отдельным one-off
  ECS task / release-step. Сейчас `bin/docker-entrypoint` гоняет `db:prepare`
  при каждом старте контейнера — нормально для одного task'а на докер-хосте,
  но не то, что нужно при нескольких task'ах в ECS.
