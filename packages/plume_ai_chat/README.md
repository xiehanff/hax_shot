# plume_ai_chat

Reusable Flutter AI chat foundation used by Plume applications.

The package owns generic conversation state, streaming lifecycle, provider transport boundaries and GetX-based UI coordination. Host applications remain responsible for domain context, app routing, visual design and credential persistence.

## Architecture

```text
Host domain adapter
        ↓
AiChatController (GetX)
        ↓
AiConversationPresenter
        ↓
AiChatSession
        ↓
AiBackend
        ↓
DeepSeekBackend / another provider
```

`AiChatSession` and `AiBackend` are framework-independent. GetX is an intentional dependency of the controller/UI coordination layer, not of the transport/runtime layer.

The package does **not** call `Get.put`, `Get.find`, define routes, or persist credentials. The host owns controller lifecycle and dependency registration. Provider credentials are configured on the concrete backend, so the provider-neutral controller/session/request types never need to know what an API key is.

## Basic usage

```dart
final session = AiChatSession(
  backend: DeepSeekBackend(
    apiKeyProvider: () async => apiKey,
  ),
);

final controller = AiChatController(session: session);

final result = await controller.send(
  input: const AiChatInput(text: 'Hello'),
  systemPrompt: 'Answer concisely.',
);
```

The credential provider can read from any host-owned source: secure storage, account state, an in-memory token, or another credential service. Backends that require no authentication do not need to model an API key at all.

`AiChatController` owns the reusable presentation lifecycle as well as GetX invalidation:

- optimistic user message
- AI loading placeholder
- streaming text/reasoning updates
- Stop cleanup
- latest-wins presentation ownership
- follow-up suggestions
- new-conversation reset
- active-turn cancellation when the controller is disposed

The rendered message list is available from `controller.messages`.

A host that already uses GetX may register the controller itself:

```dart
Get.put<AiChatController>(controller, tag: 'my-chat');
```

Registration is optional. A host may also keep the controller as a normal object and pass it to its own widgets. In either case, disposing the controller clears the session and cancels active/pending work.

## Reusable message-list structure

The package deliberately does not impose Plume's colors, Markdown renderer or icons. `AiChatMessageList` owns only list structure, stable message keys and scroll-event plumbing; the host supplies visual builders.

```dart
AiChatMessageList(
  messages: controller.messages,
  controller: scrollController,
  messageBuilder: (context, message, index) {
    return MyChatBubble(message: message);
  },
  trailingBuilder: controller.followUpSuggestions.isEmpty
      ? null
      : (context) => MySuggestions(
            suggestions: controller.followUpSuggestions,
          ),
)
```

This lets another Flutter application reuse the chat lifecycle without taking a dependency on Plume-specific presentation code.

## Streaming and cancellation

`AiChatSession` owns:

- ordered conversation history
- a Turn barrier so a new request never snapshots half-finished history
- active stream cancellation
- Stop-before-first-token rollback
- partial-answer commit after Stop
- generation invalidation when starting a new conversation
- ~40 ms preview batching for high-frequency SSE streams
- latest-wins turns for tool/action workflows

The public history view is immutable. Each transport request still receives an independent immutable history snapshot at the Turn boundary.

## Domain adapters

Provider transport and application context are separate concerns. A host adapter prepares its own text, images or other context and converts them into generic chat turns:

```text
Host context adapter
        ↓
  AiChatController
        ↓
    AiChatSession
```

The package has no dependency on any host application's domain models or extraction APIs.

## Provider-specific options

Generic output limits use `AiRequestOptions.maxOutputTokens`. Provider-only options stay inside `providerOptions` so they do not leak into the core runtime.

```dart
const AiRequestOptions(
  maxOutputTokens: 32768,
  providerOptions: <String, Object?>{
    'reasoning_effort': null,
  },
)
```

For `DeepSeekBackend`, an explicit `reasoning_effort: null` omits that field from the request; if the key is absent, the backend default is used.

## Package boundary

Belongs in `plume_ai_chat`:

- chat input/history/presentation models
- response/follow-up parsing
- session and Turn lifecycle
- provider-neutral backend contract
- DeepSeek HTTP/SSE backend
- GetX chat controller
- generic chat presentation state
- generic message-list structure
- generic follow-tail scrolling behavior

Belongs in the host application:

- domain context extraction and preprocessing
- app navigation
- sidebar/window layout
- API key persistence / secure storage policy
- backend credential provider/configuration
- app-specific colors, fonts, Markdown rendering and attachment UX
- provider/account selection policy specific to the product
