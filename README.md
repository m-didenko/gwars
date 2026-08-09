# GanjaWars-lite

Минимальный PvP MVP на Rails, вдохновлённый [ganjawars.ru](https://ganjawars.ru): два игрока по очереди
атакуют друг друга, пока у одного не закончится HP.

## Стек

- Rails 7.1, Ruby 3.2.2 (rbenv), SQLite
- Devise — аутентификация
- Turbo (`broadcasts_refreshes`) — realtime-обновление страницы боя для обоих игроков без ручного JS

## Запуск

```bash
export PATH="$HOME/.rbenv/shims:$PATH"   # если ruby 3.2.2 не в PATH по умолчанию
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server
```

Открыть `http://localhost:3000`, залогиниться под одним из сидовых игроков в двух разных
браузерах/вкладках-инкогнито:

| Email | Пароль | Персонаж |
|---|---|---|
| player1@example.com | password123 | Al Capone |
| player2@example.com | password123 | Lucky Luciano |

Один игрок жмёт «Challenge» напротив другого персонажа на главной, второй — «Accept challenge»
на странице боя, дальше по очереди «Attack!».

## Игровая механика (MVP)

- `Character`: hp/max_hp/attack/defense/gold (стартовые значения — 100/100/10/2/0, генерятся автоматически).
- `Battle`: pending → active → finished, хранит `current_turn` и `winner`.
- `Battle#attack!` — единая точка боевой логики: считает урон, проверяет чей ход, обновляет HP,
  переключает ход или завершает бой.
- `BattleAction` — лог каждого удара (для истории боя).

Вне scope: синдикаты, экономика, PvE, матчмейкинг, несколько типов оружия — см. секцию "Explicitly
out of scope" в исходном плане.

## Заметка про окружение (macOS, rbenv)

На этой машине Ruby 3.2.2 из rbenv собран под x86_64 и выполняется через Rosetta на Apple Silicon,
при этом системный компилятор по умолчанию таргетит нативный arm64. Это ломает precompiled/собираемые
нативные гемы (`bootsnap`, `bcrypt`) несовпадением архитектур при `dlopen`. Решение в этом проекте:

- `bootsnap` вообще убран из Gemfile (не обязателен, только ускоряет boot).
- `bcrypt` собран вручную с явными флагами `-arch x86_64` (`gem install bcrypt -- --with-cflags="-arch x86_64" --with-ldflags="-arch x86_64"`)
  и уже лежит в gem-окружении rbenv 3.2.2 — обычный `bundle install` подхватывает готовую сборку.
- `concurrent-ruby` запинен на `1.3.5` в Gemfile, чтобы избежать конфликта версий
  `concurrent-ruby-ext` в системном gem-окружении.

Если где-то ещё вылезет `LoadError: ... incompatible architecture`, чинить тем же способом:
`gem uninstall <gem> -x`, затем `gem install <gem> -- --with-cflags="-arch x86_64" --with-ldflags="-arch x86_64"`.
