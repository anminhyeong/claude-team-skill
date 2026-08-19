#!/usr/bin/env bash
# 플러그인으로 설치하지 않고 개인 스킬로 쓰고 싶을 때 이 파일을 돌린다.
# skills/team 을 ~/.claude/skills/team 으로 복사한다.
set -euo pipefail

src="$(cd "$(dirname "$0")/skills/team" && pwd)"
dst="$HOME/.claude/skills/team"

if [ -e "$dst" ]; then
  printf '%s 가 이미 있습니다. 덮어씁니다.\n' "$dst"
  rm -rf "$dst"
fi
mkdir -p "$(dirname "$dst")"
cp -r "$src" "$dst"
chmod +x "$dst/scripts/team.sh"
printf '%s 에 설치했습니다. 새 창을 열어 /team status 로 확인하십시오.\n' "$dst"
