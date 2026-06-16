# Kivo Click

Kivo Click is a premium, AI-powered desktop companion for macOS. It lives as a beautiful, modern **Dynamic Island / Notch** floating panel at the top center of your screen. It allows you to interact naturally via voice, see your active screen, and visually point at specific UI elements on any connected monitor with bezier arc animations.

Built with SwiftUI and AppKit bridging, Kivo Click is designed to be native, minimal, private, and ultra-responsive.

---

## 🏝️ The Kivo Dynamic Island UI

Kivo Click replaces the legacy menu bar status dropdowns with a stunning notch-style floating panel:
* **Collapsed State (Pill)**: A thin, iPhone-style pill centered at the top of your screen, displaying a breathing Kivo icon and a live, state-aware status dot (green for listening, amber for thinking, blue for speaking/responding).
* **Expanded State (Panel)**: Expands smoothly on hover (with spring animations and automatic anti-flicker debouncing) to show a tabbed selector:
  * **Kivo Tab**: Displays push-to-talk guidelines, a horizontal model picker, and a voice picker.
  * **Agent Tab**: A background execution area for agentic tasks (like building apps in the background).
  * **Footer**: Quick permissions indicators, Advanced Settings (coming soon), and Quit buttons.

---

## Features & Capabilities

* **On-Device Whisper STT**: Integrated with local, hardware-accelerated **WhisperKit** for ultra-fast (sub-0.5s), offline transcription. Zero API calls for speech-to-text.
* **Offline Text-to-Speech**: Completely free, offline Text-to-Speech using macOS native synthesizers, routed seamlessly through ElevenLabs interfaces.
* **Visual Pointing Overlay**: A transparent overlay hosting the blue Kivo cursor that can fly to and point at specific UI elements referenced by the AI model.
* **Multi-Monitor Screen Capture**: Automatically captures screenshots of connected displays via `ScreenCaptureKit` when you begin talking, allowing the AI to see what you see.
* **Lightweight Proxy Worker**: Routes chat requests securely through a Cloudflare Worker proxy to protect private API keys.

---

## Technical Stack & Architecture

* **App Type**: Menu bar-only / status-bar UI (`LSUIElement = true`) with a floating `NSPanel` overlay.
* **Client Framework**: SwiftUI (macOS native) with AppKit bridging for window level overlaying.
* **AI Chat Engines**:
  - `Gemini 2.5` (`gemini-3.5-flash` for general reasoning)
  - `Flash` (`gemini-2.5-flash-preview` for high speed)
  - `Hybrid` (`llama-3.3-70b-versatile` + reasoning)
* **Speech-to-Text**: Local WhisperKit (CoreML) on Mac Apple Silicon.
* **API Proxy**: Cloudflare Worker (`worker/src/index.ts`) routing chat and TTS fallbacks.

---

## Setup & Installation

### Prerequisites
- macOS 14.2+
- Xcode 15+
- Node.js 18+
- API keys for Google Gemini or Groq.

### 1. Set Up the Cloudflare Worker Proxy
The proxy worker holds your API keys securely so they are never embedded in the client binary.

```bash
cd worker
npm install
```

Set up your secrets (Gemini or Groq):
```bash
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put GROQ_API_KEY
```

Deploy the worker:
```bash
npx wrangler deploy
```
Take note of your deployed URL (e.g., `https://kivo-click-proxy.your-username.workers.dev`).

### 2. Configure Client Proxy URLs
Ensure your worker URL is updated in the Swift codebase:
- `CompanionManager.swift` (`workerBaseURL` property pointing to your worker or `http://localhost:8787` for local development).

### 3. Build & Run
1. Open the Xcode project:
   ```bash
   open leanring-buddy.xcodeproj
   ```
2. Select the **leanring-buddy** scheme.
3. Configure your **Developer Signing Team** under **Signing & Capabilities**.
4. Press **Cmd + R** to build and run.
5. On first launch, the local Whisper AI model will automatically download (~150MB CoreML model) in the background. Once complete, the download banner will disappear, and local transcription will be ready!

---

## Project Structure

```text
leanring-buddy/              # Swift app sources (intentional legacy directory typo)
  leanring_buddyApp.swift       # Entry point & App Delegate
  KivoDynamicIslandManager.swift# Controller managing NSPanel positioning & hover states
  KivoDynamicIslandView.swift   # SwiftUI view for collapsed/expanded island UI
  CompanionManager.swift        # Main state machine & voice pipeline coordinator
  OverlayWindow.swift           # Transparent overlay window hosting blue cursor & animations
  ElementSearchLocator.swift    # Traverses AXUIElement accessibility tree & Vision OCR
  SherpaOnnxModelManager.swift  # Manages local CoreML WhisperKit download & lifecycle
  SherpaOnnxTranscriptionProvider.swift # WhisperKit-based local speech recognition provider
worker/                      # Cloudflare Worker proxy
  src/index.ts                  # Routes chat & TTS requests to upstream APIs
```

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
