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
