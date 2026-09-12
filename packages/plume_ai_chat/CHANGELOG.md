# Changelog

## 0.2.0 — breaking change

Removed four public extension points that had no production consumer inside this
repository. Verified with a whole-repo search for each symbol before removal
(`lib/` of `hax_shot` has zero hits; the only callers were this package's own
widget tests):

| Removed symbol | File | Note |
| --- | --- | --- |
| `AiChatSubmissionPreparer` + `submit(prepareSubmission:)` | `lib/src/controller/ai_chat_controller.dart` | Host-side async preparation before transport |
| `AiChatFallbackBuilder` + `submit(fallbackBuilder:)` | `lib/src/controller/ai_chat_controller.dart` | Transport retry inside the same presentation turn |
| `AiChatController.presentLocalError()` | `lib/src/controller/ai_chat_controller.dart` | Host-side preparation failure rendering |
| `DeepSeekBackendException.canFallbackToText` | `lib/src/backend/deepseek_backend.dart` | Retry policy for multimodal rejections |
| `AiChatUpdateId.settings` | `lib/src/controller/ai_chat_controller.dart` | Dead notification id; never passed to `update()` |

Removing the first three also removed the private state `_awaitingLocalWork`
and the `_executeSubmission` wrapper; `stop()` now only stops the active
`AiChatSession` turn.

### Not changed

These are actively used by the host application and were intentionally kept:

- `send(stopPrevious:, deferHistoryCommit:)` and the `displayText` /
  `displayImageBytes` filling inside `send()`.
- Stop / latest-wins / stale-async ownership semantics (including the
  `sendId != _latestSendId` guards) and transport-error propagation.

### Hosts must update

Replace host-side preparation/fallback with host code that builds the final
`AiChatSubmission` before calling `submit(...)`, and render local failures with
`AiConversationPresenter` through the host's own UI. No replacement API is
provided for `canFallbackToText`; hosts decide their own retry policy.

### Tests

Removed the cases that only covered the deleted extension points
(`test/ai_chat_controller_stale_async_test.dart` in full,
`test/ai_chat_controller_test.dart` prepared/fallback cases). Kept the
`stopPrevious`, latest-wins, Stop, stale-history and transport-error
regressions in `test/ai_chat_controller_test.dart`,
`test/ai_chat_session_test.dart` and
`test/ai_chat_session_stop_priority_test.dart`.

## 0.1.0

Initial version.
