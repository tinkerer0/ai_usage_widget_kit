# AI Usage Widget

macOS 바탕화면에 Codex·Claude·Grok·Cursor 구독 사용량을 붙여 두는 작은 위젯입니다.

각 도구의 CLI/앱이 이미 저장해 둔 로그인으로 HTTP usage API만 호출합니다. `claude`나 `codex exec` 같은 프로세스를 띄워 로그를 만들지 않습니다.

> 이 저장소는 소스 공개입니다. 공증(notarized) 설치 패키지는 없습니다. 아래 명령으로 로컬에서 빌드하세요. ad-hoc 서명이라 Gatekeeper가 막을 수 있습니다.

## 하는 일

- 바탕화면 아이콘 레이어에만 표시됩니다. 다른 앱 위로는 올라오지 않습니다.
- Codex 주간, Claude 5시간/주간/Fable, Grok 주간, Cursor 세션/주간 사용량을 한 패널에 모읍니다.
- 15분마다 HTTP로 갱신합니다. 메뉴바에서 수동 새로고침도 됩니다.
- 시작 시 LaunchAgent(`local.aiusage.widgetkit.agent`, KeepAlive)를 설치해 로그인 후에도 유지합니다.

## 요구 사항

- macOS 14 이상
- Xcode 또는 Xcode Command Line Tools
- 표시할 도구에 이미 로그인되어 있을 것

자격 증명은 위젯이 만들지 않습니다. 각 CLI/앱이 저장한 파일을 읽기만 합니다.

| 제공자 | 읽는 위치 |
| --- | --- |
| Codex | `~/.codex/auth.json` |
| Claude | `~/.claude/.credentials.json` (키체인은 조회하지 않음) |
| Grok | `~/.grok/auth.json` |
| Cursor | Cursor `state.vscdb`의 `cursorAuth/accessToken` |

Claude Code가 토큰을 키체인에만 두면 위젯은 Claude 줄을 비운 채로 둡니다. 키체인 조회는 macOS 암호 대화상자를 반복해서 띄울 수 있어 넣지 않았습니다.

## 빌드

```sh
git clone https://github.com/tinkerer0/ai_usage_widget_kit.git
cd ai_usage_widget_kit
./scripts/build.sh
open "dist/AI Usage Widget.app"
```

`/Applications`에 넣으려면:

```sh
cp -R "dist/AI Usage Widget.app" /Applications/
open -a "AI Usage Widget"
```

직접 xcodebuild를 쓰려면:

```sh
xcodebuild -project AIUsageWidgetKit.xcodeproj \
  -scheme "AI Usage Widget" \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=-
```

산출물은 `build/Build/Products/Release/AI Usage Widget.app` 입니다.

## 개인정보

자세한 내용은 [PRIVACY.md](PRIVACY.md)를 보세요. 보안 보고는 [SECURITY.md](SECURITY.md)입니다.

위젯은 계정을 만들지 않고, 사용량을 이 저장소로 보내지 않습니다. 요청은 각 제공자의 usage 엔드포인트로만 갑니다. 로컬 스냅샷(`~/Library/Application Support/AIUsageWidget/snapshot.json`)에는 퍼센트와 리셋 시각만 있고 토큰은 없습니다.

설정에 넣는 OpenAI/Anthropic admin API 키는 위젯 전용 키체인 서비스 `AIUsageWidget`에만 저장되며, 없어도 구독 사용량 표시는 동작합니다.

패널 아이콘은 각 제품의 상표입니다. 소속·후원은 아닙니다.

## 기여·피드백

제가 이런 분야를 접한 지 얼마 안 돼서 부족한 점이 많습니다. 고칠 점이나 알려주실 내용이 있다면 issue나 PR로 남겨주시면 너무 감사하겠습니다.

## License

MIT. Copyright (c) 2026 tinkerer0.
