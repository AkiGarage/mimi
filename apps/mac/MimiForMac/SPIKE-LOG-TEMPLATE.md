# M1実機スパイク記録（テンプレート）

音声内容、URL、window title、API key、raw audioは記録しない。各行は同じ
build commitで、source app/versionごとに5分試験を行う。

| Backend | Source app/version（名前のみ） | macOS / Mac model | Duration | buffers | sample format | RMS range | checksum | Result | Notes |
| --- | --- | --- | ---: | ---: | --- | --- | --- | --- | --- |
| ScreenCaptureKit | Safari |  | 5 min |  |  |  |  |  |  |
| ScreenCaptureKit | Chrome |  | 5 min |  |  |  |  |  |  |
| ScreenCaptureKit | Other app |  | 5 min |  |  |  |  |  |  |
| Core Audio Process Tap | Safari |  | 5 min |  | tap boundary only |  |  |  | IO bridge pending |
| Core Audio Process Tap | Chrome |  | 5 min |  | tap boundary only |  |  |  | IO bridge pending |
| Core Audio Process Tap | Other app |  | 5 min |  | tap boundary only |  |  |  | IO bridge pending |

## Permission / lifecycle observations

- Permission decision:
- Stop callback ceased:
- Source-ended event:
- Mimi/self exclusion configuration:
- Device/sleep recovery:
