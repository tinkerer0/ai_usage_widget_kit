# 개인정보

AI Usage Widget은 계정을 만들지 않고, 이 GitHub 저장소나 별도의 수집 서버로 데이터를 보내지 않습니다.

## 위젯이 읽는 것

표시할 도구에 이미 로그인되어 있으면, 그 도구가 저장한 로컬 자격 증명을 읽어 usage API를 호출합니다.

| 제공자 | 로컬에서 읽는 것 | 네트워크 |
| --- | --- | --- |
| Codex | `~/.codex/auth.json` | `chatgpt.com` usage |
| Claude | `~/.claude/.credentials.json` | `api.anthropic.com` oauth usage |
| Grok | `~/.grok/auth.json` | xAI billing |
| Cursor | Cursor `state.vscdb`의 access token | Cursor dashboard usage (비공식) |

Claude Code 키체인은 조회하지 않습니다. 토큰 값, 이메일, 계정 ID는 화면에 그리지 않고 로그로 남기지도 않습니다.

설정에 OpenAI/Anthropic admin API 키를 넣으면 위젯 전용 키체인 서비스 `AIUsageWidget`에만 저장됩니다. 넣지 않아도 구독 사용량 표시는 동작합니다.

## 기기에 남는 것

`~/Library/Application Support/AIUsageWidget/snapshot.json`에는 제공자 이름, 사용량 퍼센트, 리셋 시각만 있습니다. 토큰은 넣지 않습니다.

LaunchAgent 표준 출력/에러 파일도 같은 폴더에 만들 수 있습니다. 앱 코드는 `print`/`NSLog`로 비밀값을 찍지 않습니다.

## 이 저장소에 올리지 말 것

- `auth.json`, `.credentials.json`, `.env`, 키체인 export
- 사용량·메뉴바·설정 화면 캡처 (이메일, 퍼센트, 계정명이 보일 수 있음)
- 실제 토큰이 들어 있는 로그

## 삭제

앱을 지운 뒤 `~/Library/Application Support/AIUsageWidget/`와 LaunchAgent `local.aiusage.widgetkit.agent`를 지우면 위젯이 만든 로컬 파일이 제거됩니다. 각 CLI의 로그인 파일은 해당 도구가 소유하므로 위젯이 지우지 않습니다.
