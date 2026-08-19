#!/usr/bin/env bash
# 세 세션이 한 저장소를 나눠 맡을 때 필요한 준비와 인계를 담당한다.
# 저장소의 .claude/team.json 을 읽어 동작하며, 역할 이름은 manager, developer, reviewer 다.
set -euo pipefail

ROLES="manager developer reviewer"

die() { printf '%s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'EOF'
사용법은 다음과 같습니다.

  team.sh setup                     역할마다 쓸 작업 폴더를 만들고 준비 상태를 보고합니다.
  team.sh status                    세 폴더의 브랜치와 의존성과 포트와 열린 PR 을 보고합니다.
  team.sh brief <역할>              그 역할이 쓸 폴더와 포트와 명령을 설정에서 뽑아 보여 줍니다.
  team.sh send --to <역할> --from <역할> --subject "<제목>"
                                    표준 입력으로 받은 내용을 상대 역할의 인박스에 넣습니다.
  team.sh note <이슈 번호>          표준 입력의 내용을 리뷰 기록으로 커밋합니다.
  team.sh read <역할>               인박스에 쌓인 인계를 읽고 읽은 것으로 옮깁니다.
  team.sh log <역할>                이미 읽은 인계를 다시 보여 줍니다.
  team.sh watch <역할>              인박스에 새 인계가 들어오면 한 줄을 내보냅니다.

역할은 manager, developer, reviewer 중 하나입니다.
EOF
}

common_dir() { (cd "$(git rev-parse --git-common-dir)" && pwd); }
main_root() { dirname "$(common_dir)"; }
inbox_root() { printf '%s/team-inbox\n' "$(common_dir)"; }
config_path() { printf '%s/.claude/team.json\n' "$(main_root)"; }

cfg() {
  local p
  p="$(config_path)"
  [ -f "$p" ] || die "설정 파일이 없습니다: $p 를 먼저 만드십시오. 형식은 스킬의 SKILL.md 에 있습니다."
  jq -r "$1 // empty" "$p"
}

# 설정이 온전한지 한 번에 확인한다. 값이 빠진 채로 절반만 출력되는 것을 막는다.
require_config() {
  local p k r missing=""
  p="$(config_path)"
  [ -f "$p" ] || die "설정 파일이 없습니다: $p 을 먼저 만드십시오. 형식은 스킬의 SKILL.md 에 있습니다."
  jq -e . "$p" >/dev/null 2>&1 || die "설정 파일의 JSON 형식이 잘못되었습니다: $p"
  for k in baseBranch branch install checks devServer docs roles; do
    jq -e "has(\"$k\")" "$p" >/dev/null || missing="$missing $k"
  done
  for r in $ROLES; do
    if jq -e ".roles | has(\"$r\")" "$p" >/dev/null; then
      jq -e ".roles.\"$r\" | has(\"dir\") and has(\"port\") and has(\"owns\") and has(\"avoid\")" "$p" >/dev/null \
        || missing="$missing roles.$r 의 dir 과 port 와 owns 와 avoid 중 일부"
    else
      missing="$missing roles.$r"
    fi
  done
  [ -z "$missing" ] || die "설정 $p 에서 빠진 항목이 있습니다:$missing"
}

check_role() {
  case " $ROLES " in *" $1 "*) : ;; *) die "역할 이름이 틀렸습니다: $1. manager, developer, reviewer 중 하나를 쓰십시오." ;; esac
}

# 폴더가 아직 없어도 절대 경로를 계산한다.
abspath() {
  local p="$1"
  case "$p" in /*) ;; *) p="$(main_root)/$p" ;; esac
  p="${p%/}"
  p="${p%/.}"
  [ -n "$p" ] || p="$(main_root)"
  printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")"
}

role_dir() { abspath "$(cfg ".roles.\"$1\".dir")"; }
role_port() { cfg ".roles.\"$1\".port"; }

port_state() {
  local port="$1"
  command -v ss >/dev/null || { printf '포트 %s 의 상태는 확인하지 못했습니다\n' "$port"; return; }
  if ss -ltn 2>/dev/null | grep -q ":$port[[:space:]]"; then
    printf '포트 %s 에 서버가 떠 있습니다\n' "$port"
  else
    printf '포트 %s 에는 서버가 없습니다\n' "$port"
  fi
}

cmd_setup() {
  local base root r d
  base="$(cfg .baseBranch)"
  [ -n "$base" ] || die "설정에 baseBranch 가 없습니다."
  root="$(main_root)"
  for r in $ROLES; do
    d="$(role_dir "$r")"
    if [ "$d" = "$root" ]; then
      printf '%s 는 저장소 폴더 %s 를 그대로 씁니다.\n' "$r" "$d"
      continue
    fi
    if [ -d "$d" ]; then
      printf '%s 의 폴더 %s 는 이미 있습니다.\n' "$r" "$d"
    else
      git -C "$root" worktree add --detach "$d" "$base" >/dev/null 2>&1
      printf '%s 의 폴더 %s 를 %s 위치에 새로 만들었습니다.\n' "$r" "$d" "$base"
    fi
  done
  mkdir -p "$(inbox_root)"
  printf '\n'
  cmd_status
}

pending_count() {
  local d
  d="$(inbox_root)/$1"
  [ -d "$d" ] || { printf '0\n'; return; }
  find "$d" -maxdepth 1 -name '*.md' | wc -l | tr -d ' '
}

cmd_status() {
  local root install r d br node n
  root="$(main_root)"
  install="$(cfg .install)"
  printf '저장소는 %s 입니다.\n' "$root"
  for r in $ROLES; do
    d="$(role_dir "$r")"
    if [ ! -d "$d" ]; then
      printf '%s: 폴더 %s 가 아직 없습니다. team.sh setup 을 돌리십시오.\n' "$r" "$d"
      continue
    fi
    br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '알 수 없음')"
    if [ "$br" = HEAD ]; then
      br="브랜치를 꺼내지 않은 상태이며 커밋은 $(git -C "$d" rev-parse --short HEAD) 이고"
    else
      br="브랜치는 $br 이고"
    fi
    if [ -d "$d/node_modules" ]; then
      node="의존성은 설치되어 있으며"
    else
      node="의존성이 없어서 그 폴더에서 $install 을 한 번 돌려야 하며"
    fi
    printf '%s 역할은 %s 폴더를 씁니다. %s %s %s.\n' \
      "$r" "$d" "$br" "$node" "$(port_state "$(role_port "$r")")"
  done
  for r in $ROLES; do
    n="$(pending_count "$r")"
    [ "$n" -gt 0 ] && printf '%s 의 인박스에 읽지 않은 인계가 %s 건 있습니다.\n' "$r" "$n"
  done
  if command -v gh >/dev/null && git -C "$root" remote | grep -q .; then
    if out="$(gh pr list --limit 10 2>/dev/null)"; then
      if [ -n "$out" ]; then
        printf '\n열려 있는 PR 은 다음과 같습니다.\n%s\n' "$out"
      else
        printf '\n열려 있는 PR 이 없습니다.\n'
      fi
    else
      printf '\nPR 목록을 가져오지 못했습니다. GitHub 저장소가 아니거나 gh 인증이 풀렸는지 보십시오.\n'
    fi
  fi
}

cmd_brief() {
  local r="$1" p
  check_role "$r"
  p="$(config_path)"
  printf '역할은 %s 입니다.\n' "$r"
  printf '작업 폴더는 %s 입니다.\n' "$(role_dir "$r")"
  printf '기준 브랜치는 %s 이고 작업 브랜치 이름은 %s 형태로 짓습니다.\n' "$(cfg .baseBranch)" "$(cfg .branch)"
  printf '개발 서버는 %s 로 띄웁니다.\n' "$(cfg .devServer | sed "s/{port}/$(role_port "$r")/")"
  printf '먼저 읽을 문서는 %s 입니다.\n' "$(jq -r '.docs | join(", ")' "$p")"
  printf '고친 뒤 돌릴 검사는 %s 입니다.\n' "$(jq -r '.checks | join(", ")' "$p")"
  printf '이 역할이 고치는 것은 %s 입니다.\n' "$(jq -r ".roles.\"$r\".owns | join(\", \")" "$p")"
  printf '이 역할이 고치지 않는 것은 %s 입니다.\n' "$(jq -r ".roles.\"$r\".avoid | join(\", \")" "$p")"
  printf '리뷰 기록은 %s 에 남깁니다.\n' "$(cfg .reviewNote)"
  local pend notes
  pend="$(pending_count "$r")"
  if [ "$pend" -gt 0 ]; then
    printf '읽지 않은 인계가 %s 건 있으니 team.sh read %s 로 읽으십시오.\n' "$pend" "$r"
  else
    printf '읽지 않은 인계는 없습니다.\n'
  fi
  notes="$(cfg ".roles.\"$r\".notes")"
  [ -n "$notes" ] && printf '이 저장소에만 해당하는 지침은 다음과 같습니다. %s\n' "$notes"
  return 0
}

cmd_send() {
  local to="" from="" subject="" dir f body
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="$2"; shift 2 ;;
      --from) from="$2"; shift 2 ;;
      --subject) subject="$2"; shift 2 ;;
      *) die "모르는 인자입니다: $1" ;;
    esac
  done
  [ -n "$to" ] && [ -n "$from" ] && [ -n "$subject" ] || die "--to 와 --from 과 --subject 를 모두 주십시오."
  check_role "$to"; check_role "$from"
  dir="$(inbox_root)/$to"
  mkdir -p "$dir/read"
  body="$(cat)"
  [ -n "$body" ] || die "인계할 내용을 표준 입력으로 주십시오."
  f="$dir/$(date +%Y%m%d-%H%M%S)-$from.md"
  {
    printf '# %s\n\n' "$subject"
    printf '보낸 역할은 %s 이고 보낸 시각은 %s 입니다.\n\n' "$from" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n' "$body"
  } > "$f"
  printf '%s 의 인박스에 넣었습니다: %s\n' "$to" "$f"
  printf '상대 세션이 인박스를 지켜보고 있으면 십여 초 안에 알림을 받습니다.\n'
}

cmd_read() {
  local r="$1" dir f n=0
  check_role "$r"
  dir="$(inbox_root)/$r"
  mkdir -p "$dir/read"
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    printf '===== %s\n' "$(basename "$f")"
    cat "$f"
    printf '\n'
    mv "$f" "$dir/read/"
    n=$((n+1))
  done
  [ "$n" -eq 0 ] && printf '읽지 않은 인계가 없습니다.\n'
  return 0
}

cmd_log() {
  local r="$1" dir f n=0
  check_role "$r"
  dir="$(inbox_root)/$r/read"
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    printf '===== %s\n' "$(basename "$f")"
    cat "$f"
    printf '\n'
    n=$((n+1))
  done
  [ "$n" -eq 0 ] && printf '지난 인계가 없습니다.\n'
  return 0
}

# 리뷰어 폴더는 브랜치를 꺼내지 않은 상태이고 기준 브랜치는 관리자 폴더가 쥐고 있어서,
# 리뷰어가 기준 브랜치를 바로 꺼낼 수 없다. 그래서 임시 브랜치를 뻗어 내 기록만 담는다.
cmd_note() {
  local n="$1" path base d body branch
  [ -n "$n" ] || die "이슈 번호를 주십시오."
  path="$(cfg .reviewNote | sed "s/{n}/$n/g")"
  [ -n "$path" ] || die "설정에 reviewNote 가 없습니다."
  base="$(cfg .baseBranch)"
  d="$(role_dir reviewer)"
  [ -d "$d" ] || die "리뷰어 폴더 $d 가 없습니다. team.sh setup 을 먼저 돌리십시오."
  if [ -n "$(git -C "$d" status --porcelain)" ]; then
    die "리뷰어 폴더에 커밋하지 않은 변경이 있습니다. 먼저 정리하십시오."
  fi
  body="$(cat)"
  [ -n "$body" ] || die "리뷰 기록의 내용을 표준 입력으로 주십시오."
  branch="note/$n"
  git -C "$d" fetch -q origin
  if git -C "$d" show-ref --verify --quiet "refs/heads/$branch"; then
    die "브랜치 $branch 가 이미 있습니다. 지난 기록을 아직 올리지 않았는지 보십시오."
  fi
  git -C "$d" switch -q -c "$branch" "origin/$base"
  mkdir -p "$d/$(dirname "$path")"
  printf '%s\n' "$body" > "$d/$path"
  git -C "$d" add "$path"
  git -C "$d" commit -qm "검수 - 이슈 #$n 의 검수 기록을 남겼다"
  git -C "$d" switch -q --detach "origin/$base"
  printf '%s 에 기록을 적고 %s 브랜치에 커밋했습니다. 리뷰어 폴더는 브랜치를 꺼내지 않은 상태로 돌려 두었습니다.\n' "$path" "$branch"
  printf '기준 브랜치로 올리는 것은 사용자의 승인이 필요합니다. 승인을 받은 뒤 다음 두 명령을 차례로 돌리십시오.\n'
  printf '  git -C %s push origin %s:%s\n' "$d" "$branch" "$base"
  printf '  git -C %s branch -D %s\n' "$d" "$branch"
}

cmd_watch() {
  local r="$1" dir f seen=" "
  check_role "$r"
  dir="$(inbox_root)/$r"
  mkdir -p "$dir/read"
  while true; do
    for f in "$dir"/*.md; do
      [ -e "$f" ] || continue
      case "$seen" in *" $f "*) continue ;; esac
      seen="$seen$f "
      printf '%s 에게 새 인계가 왔습니다. 제목은 %s 이고 team.sh read %s 로 읽습니다.\n' \
        "$r" "$(head -1 "$f" | sed 's/^# *//')" "$r"
    done
    sleep 10
  done
}

[ $# -gt 0 ] || { usage; exit 1; }
sub="$1"; shift
case "$sub" in -h|--help|help) usage; exit 0 ;; esac
require_config
case "$sub" in
  setup)  cmd_setup ;;
  status) cmd_status ;;
  brief)  [ $# -eq 1 ] || die "역할 이름을 하나 주십시오."; cmd_brief "$1" ;;
  send)   cmd_send "$@" ;;
  note)   [ $# -eq 1 ] || die "이슈 번호를 하나 주십시오."; cmd_note "$1" ;;
  read)   [ $# -eq 1 ] || die "역할 이름을 하나 주십시오."; cmd_read "$1" ;;
  log)    [ $# -eq 1 ] || die "역할 이름을 하나 주십시오."; cmd_log "$1" ;;
  watch)  [ $# -eq 1 ] || die "역할 이름을 하나 주십시오."; cmd_watch "$1" ;;
  *) die "모르는 명령입니다: $sub" ;;
esac
