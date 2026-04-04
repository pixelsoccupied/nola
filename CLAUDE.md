# Nola — Natural On-device Language Assistant

A macOS-native chat app for running LLMs locally using Apple's MLX framework.

## Architecture

- **SwiftUI + SwiftData** — macOS 26+ (Tahoe), Swift 5
- **Xcode project** (not XcodeGen/SPM) — created via Xcode's New Project template
- **No Package.swift** — dependencies managed through Xcode's package resolution
- **Single target** — `Nola` app, plus test targets

## Dependencies (SPM via Xcode)

- `mlx-swift-lm` 2.31.3 — LLM loading & generation (MLXLLM, MLXLMCommon)
- `mlx-swift` — MLX GPU compute
- `swift-transformers` — HuggingFace Hub client

## Key Files

- `NolaApp.swift` — App entry point with AppDelegate for activation policy fix
- `ContentView.swift` — NavigationSplitView (sidebar + detail), date-grouped conversations
- `ChatView.swift` — Chat messages, input bar, empty state, error banner
- `ChatViewModel.swift` — Message sending, streaming, generation, error handling
- `MLXService.swift` — Model loading, caching, generation streams
- `ModelManager.swift` — Scans ~/.cache/huggingface for downloaded models
- `ModelPickerView.swift` — Brain button + unified model picker popover
- `MessageBubble.swift` — Individual message rendering with glass effects
- `HuggingFaceService.swift` — HF API client for fetching model listings
- `HFModelInfo.swift` — Model metadata, size detection, device capability

## Important Patterns

### Activation Policy (Critical)
The app requires `NSApp.setActivationPolicy(.regular)` in an AppDelegate.
Without this, macOS treats the app as a background process and keyboard input
goes to Finder instead of the app. This is needed because the Xcode project
template doesn't always set this up correctly.

### Sidebar Layout (Fragile — Read Carefully)
The sidebar top clipping is a recurring issue. The current working combination is:
- `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` on the NavigationSplitView
- `.navigationSplitViewStyle(.prominentDetail)` for floating sidebar
- `.navigationTitle("Chats")` on the sidebar List — **this reserves toolbar space and prevents clipping**
- `.safeAreaPadding(.top, 8)` for fine-tuning spacing below title — do NOT reduce this value
- Do NOT use `.contentMargins(.top, _)` — it replaces the system safe area and causes clipping
- Do NOT use `.scrollContentBackground(.hidden)` on the sidebar — breaks system glass and causes clipping
- Do NOT use `.containerBackground(material, for:)` on the sidebar — overrides system glass
- Do NOT use `.toolbarBackgroundVisibility(.visible)` — kills the glass effect entirely
- Brain and + buttons are toolbar items (no custom button styles on them)
- `.backgroundExtensionEffect()` on detail views for content behind sidebar glass

### Sidebar Glass Behavior (Apple HIG)
Per Apple's HIG: "Liquid Glass appears more opaque in larger elements like sidebars
to preserve legibility." The sidebar IS glass — it's intentionally thicker/more opaque
than small controls (toolbars, tab bars). Don't fight this.
- The glass picks up color from the detail content behind it via `.backgroundExtensionEffect()`
- ChatView has a subtle gradient background (accent color at 8% opacity) to give the glass warmth
- The sidebar looks more translucent when colorful content is behind it (images, gradients)
- In full screen mode, macOS renders the toolbar with a solid background — this is system
  behavior and `.toolbarBackgroundVisibility(.hidden)` does not override it in full screen

### Model Picker Notification
The model picker popover is owned by `BrainModelButton` in the toolbar. Other
views (like the empty state) open it via `NotificationCenter.default.post(name: .showModelPicker)`.
Defined in `NolaApp.swift` alongside `.newChat`.

### Input Bar & Scrolling
- Input bar uses `.safeAreaInset(edge: .bottom)` — NOT a ZStack overlay
- This ensures ScrollView knows the input bar height and messages never hide behind it
- Auto-scroll triggers on `messages.count` change AND `streamingContent` change
- `StreamingScrollTrigger` is an isolated view that observes streaming without re-evaluating ChatView body
- `send()` guards on `canSend` (requires `mlxService.isReady`) before doing anything — Enter key respects this

### Model Loading
- Only one model loaded at a time — previous model evicted from memory
- `MLX.GPU.set(cacheLimit: 0)` flushes GPU memory before loading new model
- Models stored in `~/.cache/huggingface` (shared HF cache)
- App sandbox is DISABLED for filesystem/network access
- Auto-loads last used model on launch
- Chat template validated immediately after loading (before `.ready` state)

### Concurrency
- File I/O (model scanning, directory enumeration) uses `nonisolated static` functions
  — do NOT run `FileManager.enumerator` on `@MainActor`, it blocks the UI
- `HubApi.default` is `@MainActor` (not `nonisolated`) — only used from MainActor code
- Generation stops when user switches conversations (`onChange(of: selectedConversation)`)

### Branding & Color
- Accent color: burnished gold (#C0873A light / #D4A04E dark), NOT plain orange
- Increased contrast variants defined in AccentColor asset
- Brand color used for: user message bubble tints, send button, brain icon (loading), accent links
- Warning/error colors use system `.orange` — semantically distinct from brand
- `.orange` in the codebase = warnings only (e.g., "Too large", error labels)
- `.accentColor` = brand identity (brain loading state, interactive elements)

### Streaming Performance (Critical — Read Carefully)
Streaming tokens arrive at 30-80/sec. ChatView.body must NOT re-evaluate per-token.
- `sortedMessages` is cached as `@State`, updated only when `messages.count` changes
  — never call `conversation.sortedMessages` inside the view builder during streaming
  — SwiftData change tracking on `message.content` writes can trigger re-sorts and
    cause all message bubbles to briefly show duplicate/wrong content
- `StreamingMessageBubble` isolates observation of `streamingContent` + `tokensPerSecond`
  — only this one view re-renders per-token, not the entire message list
- `StreamingScrollTrigger` isolates the auto-scroll onChange from ChatView.body
- SwiftData writes are throttled to every ~10 tokens to reduce change-tracking overhead
- Do NOT use `onChange(of: chatViewModel.streamingContent)` directly in ChatView
  — this causes ChatView.body to track `streamingContent`, defeating the isolation
- Do NOT use `GlassEffectContainer` with ScrollView + dynamic message lists
  — it tries to manage spacing between all glass children, breaking LazyVStack layout
  — individual `.glassEffect()` modifiers on each bubble work correctly without a container

### Model Compatibility
- After loading, MLXService validates the chat template with a dry-run `prepare()` call
- If the Jinja template is broken/missing, the model never reaches `.ready` state
- Failed models are persisted in UserDefaults as incompatible
- Model picker shows "Incompatible" badge on previously-failed models (grayed out)
- Users can still retry loading incompatible models (Load button stays available)

### Error Handling
- Generation errors show as an actionable banner above the input bar, NOT inline in message text
- `ChatViewModel.GenerationError` maps known error types to user-friendly messages
  — Jinja/template errors → "This model doesn't support chat"
  — Tokenizer errors → "This model's tokenizer isn't compatible"
- Empty assistant messages are removed on error (no blank bubble left behind)
- Error banner offers "Try Another" button that opens the model picker
- Errors auto-clear on conversation switch

### Liquid Glass (macOS 26)
- Glass on navigation layer only: input bar (capsule), message bubbles
- User messages tinted with `.accentColor` (burnished gold)
- Do NOT use `.interactive()` on message bubbles — they are not tappable controls
- No glass-on-glass stacking — don't add `.buttonStyle(.glass)` to toolbar items
- `.buttonStyle(.glassProminent)` only for text CTA buttons, NOT icon-only buttons
- Brain icon uses `.symbolEffect(.pulse)` for loading — no manual TimelineView animation

### Motion & Accessibility
- All custom animations respect `accessibilityReduceMotion`
- Prefer SF Symbol effects (`.symbolEffect`) over manual animation — they auto-respect Reduce Motion
- Message timestamp on hover uses `.overlay` with opacity — no layout shift
- Keep animations brief and purposeful per Apple Motion guidelines

### Info.plist
- Auto-generated (`GENERATE_INFOPLIST_FILE = YES`) + merged with `Nola/Info.plist`
- `NSPrefersDisplaySafeAreaCompatibilityMode = false` — app is camera-housing-aware

## Build & Run

```
open Nola.xcodeproj
# Cmd+R to build and run
# Cmd+Shift+K for clean build
```

## Data Storage

- SwiftData store: `~/Library/Application Support/default.store`
- To reset: delete `default.store*` files and relaunch
