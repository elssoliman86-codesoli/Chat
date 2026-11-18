# Omni Chat

A personal, agentic Android chat app in the style of the big AI assistants — built clean-room with
Flutter. Bring your own provider API keys; everything runs from your own phone.

## Chat

- **Many providers**: OpenAI, Anthropic, Google Gemini, OpenRouter, Groq, DeepSeek, Mistral, Together,
  NVIDIA, xAI, Perplexity, Ollama, LM Studio, or any OpenAI-compatible URL. Switch provider and model
  per chat, with a health check that tests each model and flags which ones actually answer.
- **Thinking effort**: pick off/low/high/max per model — sent as `reasoning_effort` for
  OpenAI-compatible providers, an extended-thinking token budget for Anthropic, or `thinkingConfig`
  for Gemini.
- **Many files and images per message**: up to 50 (default 20) — photos, camera, PDF, Word, Excel,
  PowerPoint, OpenDocument, EPUB, text and code. A text-only model can be given a helper model to describe
  images for it.
- **Any file, any size**: nothing is refused. Text of any kind (whatever the extension) is read — a huge log
  is trimmed to its start and end with a line count; anything else (video, audio, APK, EXE, databases,
  unknown binaries) is attached as a report: type from its magic bytes, size, first bytes, an archive's
  file list and the readable strings inside.
- **Pictures and videos in answers**: pictures found by the image search show as one slideshow card you
  swipe left and right (tap one for full screen); a YouTube/Vimeo link shows as a card with its thumbnail
  and title.
- **Long tasks**: a toggle in the chat's menu. The model keeps going until the whole job is done (every
  comment replied to, every file fixed) instead of stopping after one or two and waiting for "continue".
- **Automatic model health and fallback**: the HTTP-200 check re-runs by itself every time the app opens.
  If a model runs out of tokens, is rate limited, rejects the key or returns no response, the turn moves to
  another model that passed the check — but never just because the connection dropped (can be switched off).
- Streaming Markdown answers, chat history with search, temporary chats, custom instructions, and
  several themes including a dark glass/"emerald" look.
- **Edit, regenerate, or continue**: edit your own message and re-send, regenerate the last answer, or
  resume one that was cut off (a dropped connection, a timeout, or the app itself being closed
  mid-turn) from exactly where it stopped rather than starting over.
- **Plan card**: for a multi-step task, a small card above the chat shows the real steps and which one
  is in progress — tap to expand. A resumed task continues the same plan instead of restarting it.

## Skills

Instruction packs the assistant can load, plus the tools they're allowed to use. Switch one on for a
chat, or let the assistant load it itself when it fits (`/skills`). Install from a GitHub repo, a
`SKILL.md` link, or a `.zip`, or write one by hand — skills are grouped into folders by where they
came from (one per repo, plus "Manual" and "Built-in").

## Memory and self-improvement

- **Memory**: lasting facts about *you* (name, job, preferences, recurring projects) that the
  assistant saves on its own as they come up, and uses in every future chat.
- **Lessons**: operational lessons the assistant records about *itself* — a mistake and its real fix,
  a constraint of this app or a device it discovered, an approach that works — kept by the app and fed
  into every future chat regardless of which model is answering it, so experience survives a model
  change instead of starting from zero.

## Device access (all off by default)

- **Shell (Termux)**: real commands on your own device through the [Termux](https://termux.com) app —
  not a sandbox. The assistant treats it as its default way to actually build and run something (a
  script, a scraper), looping write → run → read the real output → decide the next step, instead of
  just handing back source code. A built-in diagnosis tells an old/Play-Store Termux build apart from
  one that just hasn't granted permission yet.
- **SSH hosts**: add a server's host/user/port and either generate a real key pair (Termux creates it,
  you copy the public half to the server) or a password (with a one-tap sshpass install) — the
  assistant then reaches that host directly, Linux, Kali or a Windows PC's Command Prompt/PowerShell
  over its OpenSSH Server. Built-in **SSH & FTP setup guides** (Plugins) walk through turning the servers
  on, finding the address, key login and file transfer on PowerShell, CMD, macOS, Linux, Ubuntu and Kali,
  with a copy button on every command.
- **FTP server**: turn on a local FTP server over the Projects folder (below) to edit those files
  directly from a PC or another device on the same Wi-Fi — Windows Explorer, FileZilla, WinSCP, or any
  FTP client.

## Browser and plugins

A built-in browser the assistant can open, read, click, type into, drag within and scroll — visible so
you can watch it work. It always shows the **desktop** version of sites (desktop Chrome user agent and a
wide viewport — Facebook, WhatsApp Web and the like), and has a **DevTools** panel (hammer button) with
every network request (status, timing, headers, request and response bodies) and the console. The
assistant reads the same data with `browser_devtools`. On top of that:

- **Named plugins**: Gmail, Canva, Facebook, Instagram, YouTube, GitHub (search, read, and — with your
  own token — open PRs/issues, comment, create a repo). Each signs in once and stays signed in.
- **Custom sites**: paste a link to any other website and say what it's for, and it gets the same
  treatment — sign in once, ask before anything that isn't just reading.

## Projects

A real, separate file workspace for building something self-contained to hand back — a website, an
app, a bundle of code. The assistant creates, edits, searches, moves, downloads, and can push it to or
import it from GitHub; a project can be served locally for a live preview, or reached over FTP (above)
to edit from another device.

## Assistant model (second opinion)

Pick a second model — any provider, your own account — that the assistant can consult mid-task when
its own judgement feels weak: a command that keeps failing, a confusing error, a decision it's unsure
about. It hands over the real context, reads the advice back, and acts on it the same way it would act
on its own plan.

---

Keys, chats, memory, lessons and settings stay on the phone (app-private storage, no extra
encryption layer beyond Android's own app sandbox). Each message goes directly to the provider you
choose; nothing is sent anywhere else.

Build: push to `main`; GitHub Actions publishes `omni-chat.apk` as release `build-N`.
See `replica/` for the original recon notes and feature list.
