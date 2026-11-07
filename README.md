# Omni Chat

A personal Android chat app in the style of the big AI assistants, built clean-room with Flutter. Bring your own API keys.

- **Many providers**: OpenAI, Anthropic, Google Gemini, OpenRouter, Groq, DeepSeek, Mistral, Together, NVIDIA, xAI, Perplexity, Ollama, LM Studio, or any OpenAI-compatible URL. Switch provider and model per chat.
- **Many files and images per message**: up to 50 (default 20). Photos, camera, PDF, Word, Excel, PowerPoint, text and code.
- **Skills**: instruction packs plus the tools they may use. Switch them on per chat or let the assistant load them when they fit. Import `SKILL.md` files.
- **Tools**: web search, page reading, current time, memory.
- Streaming Markdown answers, chat history with search, temporary chats, custom instructions, dark/light theme.

Keys and chats stay on the phone (app-private storage). Each message goes directly to the provider you choose.

Build: push to `main`; GitHub Actions publishes `omni-chat.apk` as release `build-N`.
See `replica/` for the recon notes and feature list.

## Omni Chat Agent

The conversation can orchestrate multi-step work without a separate security-only screen:

- Agent task plans and a live in-chat timeline.
- A persistent local registry of Termux tools, executable paths, versions, capabilities and verification state.
- Read-only Termux tool discovery and allowlisted batch package installation after one explicit approval.
- Program scope extraction from explicit host entries (including Markdown asset tables), out-of-scope precedence, and a user review/confirmation gate before any target-facing command.
- Custom Python helpers are syntax-checked and tested in the in-app Pyodide sandbox, saved locally, and only transferred to Termux after a second approval showing the source and exact target.
- Termux shell commands require per-command approval. Target-facing commands must pass the scope gate. Destructive testing is blocked.

### Termux setup

1. Install a current Termux build from a supported source.
2. In Termux, set `allow-external-apps = true` in `~/.termux/termux.properties`, then restart Termux.
3. Enable Termux tools in Omni Chat settings and grant the Android **Run commands in Termux environment** permission.
4. Use the chat tools to discover installed commands. Missing supported packages are proposed as a batch; nothing is installed without approval.

The Android host is generated in CI with `flutter create`; `tool/patch_android.sh` installs the native `omni/termux` MethodChannel bridge and receiver into that generated host. The CI workflow analyzes Dart, runs tests, and compiles a debug APK so Kotlin bridge errors are caught before merge.

**Security note:** Termux is the user's real device shell, not an app sandbox. Scope parsing is intentionally conservative and only accepts explicitly listed hostnames; it does not infer related APIs, IPs, mobile backends, or sibling domains. A scope confirmation does not override the program's other rules or authorize destructive tests.
