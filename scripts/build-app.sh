#!/bin/bash
# Builds "Safari Agent.app" (container for the Safari web extension) and installs it to ~/Applications.
# Usage: scripts/build-app.sh [--no-install]
# Env:   DEVELOPMENT_TEAM=<team id>  sign with a Personal Team (otherwise ad-hoc "Sign to Run Locally")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/app/Safari Agent/Safari Agent.xcodeproj"
RESOURCES="$ROOT/app/Safari Agent/Safari Agent Extension/Resources/"
BUILD="$ROOT/build"

install=1
[ "${1:-}" = "--no-install" ] && install=0

rsync -a --delete "$ROOT/extension/" "$RESOURCES"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
  signing=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
else
  signing=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO)
  echo "⚠️  DEVELOPMENT_TEAM не задан: сборка с ad-hoc подписью." >&2
  echo "    Safari потребует «Разрешить неподписанные расширения» (Разработка), и это сбрасывается при каждом запуске Safari," >&2
  echo "    пока не настроен Personal Team (Xcode → Settings → Accounts)." >&2
fi

xcodebuild -project "$PROJECT" -scheme "Safari Agent" -configuration Debug \
  -derivedDataPath "$BUILD" "${signing[@]}" build

APP="$BUILD/Build/Products/Debug/Safari Agent.app"
[ -d "$APP" ] || { echo "Сборка не найдена: $APP" >&2; exit 1; }

if [ "$install" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Safari Agent.app"
  cp -R "$APP" "$HOME/Applications/Safari Agent.app"
  echo "Установлено: ~/Applications/Safari Agent.app (откройте его один раз)"
else
  echo "Собрано: $APP"
fi
