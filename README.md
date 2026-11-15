# Safari Agent

Локальный MCP-сервер для Claude Code, который управляет одной вкладкой Safari («вкладкой агента»): читает страницу, кликает, вводит текст. Состоит из трёх частей:

- `helper/` — Swift-бинарник `safari-claude-helper` (режимы `daemon`, `mcp`, `install`, `uninstall`, `status`). Демон запускается через launchd по сокету `127.0.0.1:47821` и сам завершается без активности.
- `extension/` — Safari Web Extension (Manifest V2, постоянная фоновая страница).
- `app/` — контейнерное macOS-приложение «Safari Agent», в которое упаковано расширение.

## Требования

- macOS с установленным Xcode (проверено на Xcode 27.2) и Safari 26.
- Claude Code (`claude`), по умолчанию ищется `/opt/homebrew/bin/claude`, иначе из `PATH`.
- Apple ID (бесплатный Personal Team) для стабильной подписи — желательно, но не обязательно.

## Установка

1. Xcode → Settings → Accounts: войдите с Apple ID (Personal Team). Узнайте Team ID.
2. Соберите приложение и установите в `~/Applications`:
   ```
   DEVELOPMENT_TEAM=<TEAM_ID> scripts/build-app.sh
   ```
   Без `DEVELOPMENT_TEAM` сборка подписывается ad-hoc; тогда в Safari нужно включать Разработка → «Разрешить неподписанные расширения» (сбрасывается при каждом запуске Safari). `scripts/build-app.sh --no-install` только собирает в `build/`.
3. Откройте `~/Applications/Safari Agent.app` один раз.
4. Safari → Настройки → Расширения: включите «Safari Agent» и разрешите доступ ко всем сайтам.
5. Установите хелпер:
   ```
   cd helper && swift build -c release && .build/release/safari-claude-helper install
   ```
   Команда копирует бинарник в `~/.local/bin`, подписывает его (сертификат Apple Development, если есть, иначе ad-hoc), создаёт токен, регистрирует LaunchAgent и выполняет `claude mcp add --scope user safari -- ~/.local/bin/safari-claude-helper mcp`. Если регистрация не удалась, команда будет напечатана для ручного запуска.
6. Системные настройки → Конфиденциальность и безопасность → Универсальный доступ: включите `safari-claude-helper`. При ad-hoc подписи разрешение сбрасывается после каждой пересборки.

## Проверка

```
safari-claude-helper status
```

Показывает: загружен ли LaunchAgent, выдан ли Accessibility, есть ли токен, подключено ли расширение Safari. Затем в новой сессии `claude`: «открой example.com во вкладке агента, прочитай страницу и нажми на ссылку».

## Удаление

```
safari-claude-helper uninstall
```

Выгружает LaunchAgent, удаляет бинарник, токен и регистрацию MCP. Приложение `~/Applications/Safari Agent.app` и разрешение Accessibility удалите вручную.

## Известные ограничения

- Во фоновой вкладке действия идут через DOM (синтетические события), а не через реальные клики и ввод: надёжный «доверенный» путь доступен, только когда вкладка видима и Safari на переднем плане.
- Курсор агента не анимируется внутри iframe.
- Чат-панели пока нет (запланирована на фазу 2).

## Проверено

Сквозная проверка с владельцем ещё не проведена.
