# Деплой на AWS: Route53 + ALB + Fargate + RDS

Планируемый стек для горизонтального масштабирования: Route53 (DNS, опционально)
→ ALB → ECS Fargate (несколько task'ов, автоскейл по CPU) → RDS + ElastiCache.
Ниже — что в текущей архитектуре уже готово к этому, чего не хватает, и что
настроить в инфре отдельно от кода.

**Сама инфраструктура теперь описана как код** — `infra/` (AWS CDK,
TypeScript), см. `infra/README.md`. Всё, что зависит от аккаунта или размера
(instance type, min/max task'ов, домен, имя ECR-репозитория) — в
`infra/config.json`, ничего не захардкожено в стеке.

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

## Готово в инфраструктуре (`infra/`)

- **RDS вместо локального Postgres-контейнера** — `db.t4g.micro`, single-AZ,
  под free tier по умолчанию (`config.database`).
- **ElastiCache вместо локального Redis-контейнера** — `cache.t4g.micro`,
  один узел без реплик, тоже под free tier (`config.redis`).
- **Секрет-менеджмент.** `RAILS_MASTER_KEY` — секрет в Secrets Manager,
  который стек только читает (создаётся отдельной командой до первого
  деплоя, см. `infra/README.md` — намеренно не генерируется CDK, чтобы
  плейсхолдер не подменил собой настоящий ключ). Пароль к RDS — отдельный
  секрет, который **создаёт** сам RDS-конструкт (`fromGeneratedSecret`) и
  прокидывает в task definition как секрет, а не как переменную окружения.
- **Security groups** — доступ к RDS и ElastiCache только с security group
  Fargate-сервиса, сама база и кэш в изолированных подсетях без выхода в
  интернет.
- **ACM-сертификат** — создаётся и валидируется через DNS автоматически,
  если в конфиге заполнен `domain.hostedZoneName` (см. `infra/README.md`);
  если нет — ALB просто слушает HTTP на своём `*.elb.amazonaws.com` имени.
- **Автоскейл ECS по CPU** — `service.autoScaleTaskCount` + target tracking
  на `config.ecs.cpuTargetUtilizationPercent` (по умолчанию 80%), min/max —
  `config.ecs.minCapacity`/`maxCapacity`.
- **NAT Gateway осознанно не используется** (`config.vpc.natGateways: 0`) —
  Fargate-таски в публичных подсетях с публичным IP, это бесплатная замена
  NAT'у для исходящего трафика (тянуть образ из ECR, читать секреты, слать
  логи), раз денег на free-tier аккаунте тратить не на что.

## Чего всё ещё не хватает

- **Миграции гоняются из entrypoint контейнера** (`bin/docker-entrypoint` →
  `db:prepare`) при каждом старте таска, не отдельным release-step. При
  `minCapacity: 1` это не проблема; стоит пересмотреть до того, как начнут
  стартовать несколько task'ов одновременно (автоскейл на старте под
  нагрузкой).
- **Нет CI/CD.** Сборка и пуш образа в ECR, затем
  `aws ecs update-service --force-new-deployment` — всё ещё руками, шаги
  описаны в `infra/README.md`.
