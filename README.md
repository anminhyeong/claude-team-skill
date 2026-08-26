# claude-team-skill

한 저장소를 세 개의 Claude Code 세션이 나눠 맡게 만드는 `team` 스킬입니다.

관리자는 단계를 이슈로 쪼개고 결정을 내리고 병합합니다. 개발자는 이슈 하나를 브랜치에서 구현해 PR 을 엽니다. 리뷰어는 그 PR 을 검수하고 기록을 남깁니다. 창을 세 개 열고 각 창에서 슬래시 명령 하나만 치면 각 세션이 자기 역할을 맡습니다.

## 왜 폴더와 포트를 나누는가

세션마다 git worktree 폴더를 따로 씁니다. git 은 폴더 하나에 브랜치 하나만 꺼내 놓으므로, 같은 폴더를 셋이 쓰면 한 세션이 브랜치를 옮길 때 나머지가 보던 파일까지 바뀝니다. 개발 서버의 포트도 역할마다 나눠 씁니다. 포트를 고정하지 않으면 이미 떠 있을 때 조용히 다음 포트로 옮겨 붙어서 같은 폴더에 서버가 겹겹이 쌓입니다.

## 세션끼리 인계하는 방법

한 세션이 자기 몫을 마치면 다음 세션에게 직접 알립니다. 사용자가 그 사이를 옮겨 줄 필요가 없습니다.

인계는 저장소가 공유하는 `.git/team-inbox/` 에 파일로 주고받습니다. 받는 쪽이 그 폴더를 지켜보고 있어서 십여 초 안에 알림을 받습니다. 세션 이름으로 상대를 찾지 않는 이유는, 이름이 창을 열 때마다 바뀌고 다른 프로젝트의 세션과 섞여서 어느 것이 상대인지 가릴 수 없기 때문입니다. 파일로 두면 지난 인계를 나중에 다시 읽을 수도 있습니다.

## 미리 있어야 하는 것

`git` 과 `jq` 가 있어야 합니다. 우분투나 데비안이면 `sudo apt install jq` 로 넣습니다. 최소 설치된 서버에는 `jq` 가 없는 일이 흔하고, 없으면 스킬이 무엇이 없는지 알려 주고 멈춥니다.

`gh` 와 `ss` 는 없어도 돌아갑니다. `gh` 가 없으면 열린 PR 목록만 빠지고, `ss` 가 없으면 포트가 차 있는지 확인하는 부분만 빠집니다.

## 설치하는 방법

플러그인으로 설치하면 두 줄로 끝납니다.

```sh
claude plugin marketplace add anminhyeong/claude-team-skill
claude plugin install team@claude-team-skill
```

나중에 갱신할 때는 `claude plugin update team` 을 씁니다.

이 저장소가 비공개이면 받아 가는 기계에도 GitHub 인증이 있어야 합니다. 그 기계에서 `gh auth login` 을 하거나, 저장소를 읽을 수 있는 토큰을 git 자격 증명에 넣어 두어야 클론이 됩니다. 인증이 없으면 마켓플레이스를 붙이는 단계에서 실패합니다.

플러그인을 쓰지 않고 개인 스킬로 두고 싶으면 저장소를 클론해서 `install.sh` 를 돌립니다. 이 스크립트가 `skills/team` 을 `~/.claude/skills/team` 으로 복사합니다.

```sh
git clone https://github.com/anminhyeong/claude-team-skill.git
cd claude-team-skill && ./install.sh
```

설치한 뒤 새 창을 열어야 스킬 목록에 잡힙니다. 이미 열려 있는 창에서는 잡히지 않습니다. 스킬 목록은 창을 열 때 한 번 읽기 때문입니다.

## 다른 기계에 넣는 방법

이미 쓰고 있는 기계에서 다른 서버로 통째로 옮기는 것이 가장 간단합니다. GitHub 인증도 클론도 필요하지 않습니다.

```sh
tar -C ~/.claude/skills -cf - team \
  | ssh <서버> 'mkdir -p ~/.claude/skills && tar -C ~/.claude/skills -xf - \
      && chmod +x ~/.claude/skills/team/scripts/team.sh'
```

넣은 뒤 그 서버에서 다음으로 확인합니다. 두 줄이 모두 나오면 새 창을 열어 `/team status` 를 부릅니다.

```sh
ls ~/.claude/skills/team/SKILL.md
command -v git jq
```

`~/.claude/skills/` 는 그 기계의 모든 저장소에서 잡히는 자리입니다. 저장소마다 따로 넣을 필요가 없습니다.

## 쓰는 방법

창을 세 개 열고 각 창에서 한 줄만 칩니다.

- 첫 창에서 `/team setup` 을 부르면 역할별 worktree 폴더를 만들고 준비 상태를 보고합니다.
- 창마다 `/team manager` 와 `/team developer` 와 `/team reviewer` 를 하나씩 부릅니다.
- 진행 중에 `/team status` 를 부르면 세 폴더의 브랜치와 의존성과 포트, 읽지 않은 인계, 열린 PR 을 한 번에 봅니다.
- 리뷰어는 `/team note <이슈 번호>` 로 검수 기록을 남깁니다.

## 저장소마다 해야 할 준비

기준 브랜치, 역할별 폴더와 포트, 설치와 검사 명령, 읽을 문서, 역할별로 고치는 것과 고치지 않는 것을 `<저장소>/.claude/team.json` 에 적습니다.

이 파일은 커밋하지 않습니다. 폴더 경로와 포트가 기계마다 다르므로 각자 자기 기계에서 만듭니다. 형식과 각 항목의 뜻은 `skills/team/SKILL.md` 의 "설정 파일" 절에 있습니다.

## 이 저장소의 구성

| 무엇 | 어디 |
| --- | --- |
| 스킬 본문과 역할별 절차 | `skills/team/SKILL.md` 와 `skills/team/roles/` |
| 준비와 인계를 담당하는 스크립트 | `skills/team/scripts/team.sh` |
| 플러그인 정보 | `.claude-plugin/plugin.json` |
| 마켓플레이스 목록 | `.claude-plugin/marketplace.json` |

`skills/team/` 이 원본입니다. 여기를 고친 뒤 `./install.sh` 를 돌리면 자기 기계의 개인 스킬에 반영됩니다.
