<div align="center">

# تصميم SOLIMAN &nbsp;·&nbsp; Designed by SOLIMAN

<img src="docs/icon.png" width="150" alt="Omni Chat icon"/>

# Omni Chat

**One chat for every AI model — and an assistant that can actually *do* things on your phone.**
<br/>
**شات واحد لكل موديلات الذكاء الاصطناعي، ومساعد بيشتغل فعلاً على موبايلك.**

Flutter · Android · Bring your own API keys · Private by design

[Download the latest APK](../../releases/latest) &nbsp;·&nbsp; [What it can do](#what-it-can-do) &nbsp;·&nbsp; [How to use each plugin](#how-to-use-each-plugin) &nbsp;·&nbsp; [FAQ](#troubleshooting)

</div>

---

## نبذة سريعة (بالعربي)

Omni Chat تطبيق أندرويد شخصي بيجمع كل مزودي الذكاء الاصطناعي في شات واحد (OpenAI وClaude وGemini وOpenRouter
وGroq وDeepSeek وOllama وغيرهم). مش مجرد شات: المساعد ممكن يفتح المتصفح ويتصفح مواقع بحسابك، ويشغّل أوامر على
موبايلك أو على سيرفراتك عن طريق SSH، ويبني مشاريع كاملة، ويعدّل مستودعات GitHub، ويكمل مهمة طويلة من غير ما
تقوله "كمل". مفاتيحك ومحادثاتك فاضلة على موبايلك ومبتتبعتش لأي مكان غير المزود اللي إنت اخترته.

## What it can do

| | |
|---|---|
| 🧠 **Any model** | 12+ providers or any OpenAI-compatible URL; switch model per chat; thinking effort control |
| 🩺 **Self-healing** | Health check at every launch; automatic fallback when a model is out of tokens or silent |
| 📎 **Any file** | Upload anything, any size — text is read, binaries are described, archives are listed |
| 🖼️ **Rich answers** | Swipeable image slideshows, video link cards, colored code with line numbers |
| 🌐 **A real browser** | Desktop-mode browser the assistant drives, with a DevTools panel you and the model both read |
| 🛠️ **Real tools** | Termux shell, SSH hosts, sandboxed Python, FTP server, GitHub, file projects |
| 🔁 **Long tasks** | One switch and the assistant keeps going until the whole job is finished |
| 🧩 **Skills & memory** | Loadable instruction packs, lasting memory, and lessons that survive a model change |

---

## Contents

1. [Install and first run](#install-and-first-run)
2. [Chat](#chat)
3. [How to use each plugin](#how-to-use-each-plugin)
   - [Web search and pages](#web-search-and-pages) · [Built-in browser and DevTools](#built-in-browser-and-devtools) · [Termux shell](#termux-shell) · [SSH hosts](#ssh-hosts-and-the-setupguides) · [FTP server](#ftp-server) · [Python](#python-sandbox) · [GitHub](#github) · [Gmail, Canva, Facebook, Instagram, YouTube](#gmail-canva-facebook-instagram-youtube) · [Custom sites](#custom-sites) · [Assistant model](#assistant-model-second-opinion) · [Image helper](#image-helper-for-text-only-models) · [Projects](#projects) · [Skills](#skills) · [Memory and lessons](#memory-and-lessons) · [Add other plugins (MCP)](#other-plugins-mcp-and-web-apis)
4. [Proxy and Tor](#proxy-and-tor)
5. [Privacy](#privacy-and-security)
6. [Troubleshooting](#troubleshooting)
7. [Build and contribute](#build-from-source)

---

## Install and first run

1. Open the **Releases** page and download `omni-chat.apk` from the newest `build-N`.
2. Open the file and allow *Install unknown apps* for your browser or file manager when Android asks.
   Each build is signed with the same key, so a new build installs **over** the old one and keeps your chats.
3. Open the side menu (☰) → **Providers → Add**, pick a provider, paste its API key, and tap
   *Fetch models from the provider*.
4. In the model list tap **Test N models** and wait for the HTTP 200 marks (use *Working only* to filter) —
   those are the models the app may switch to automatically if your chosen one fails. From then on the test
   re-runs by itself every time the app opens.
5. Start chatting. Everything below is optional and **off by default** where it touches your device or accounts.

> If Android says *“App not installed as package appears to be invalid”*: re-download the file on a stable
> connection (a partial download is the usual cause), and check *Settings → Apps → Omni Chat* — you cannot
> install a build whose number is lower than the one already on the phone.

## Chat

- **Providers**: OpenAI, Anthropic, Google Gemini, OpenRouter, Groq, DeepSeek, Mistral, Together, NVIDIA,
  xAI, Perplexity, Ollama, LM Studio, or any OpenAI-compatible base URL. Pick provider and model per chat.
- **Thinking effort**: off / low / high / max per model — sent as `reasoning_effort` (OpenAI-compatible),
  an extended-thinking budget (Anthropic) or `thinkingConfig` (Gemini).
- **Model health and automatic fallback**
  - Every time the app opens (and when it returns from the background after 10 minutes) it re-tests the
    models you use and shows HTTP status per model.
  - If a model runs out of tokens, is rate limited, rejects the key, is gone, or returns **no response**,
    the turn continues on another healthy model and a small note above the answer says what happened.
  - A dropped connection or a timeout **never** triggers a switch. Turn the whole thing off in
    *Plugins → Switch model automatically*.
- **Files and images** (up to 50 per message): photos, camera, PDF, Word, Excel, PowerPoint, OpenDocument,
  EPUB, ZIP projects, text and code — **any other file too, at any size**:
  - Text of any kind is read, whatever its extension. A multi-gigabyte log is trimmed to its beginning and
    end with a line count.
  - Binaries (video, audio, APK, EXE, databases…) are attached as a report: detected type, size, first
    bytes, an archive's file list and the readable strings inside.
- **Rich answers**
  - Several pictures in a row become **one slideshow card** — swipe right/left, tap for full screen.
  - A YouTube/Vimeo link on its own line becomes a **video card** with thumbnail and title.
  - Code blocks are colored per language (Python, JS/TS, Dart, Java, Kotlin, Swift, C/C++/C#, Go, Rust,
    PHP, Ruby, Bash, SQL, CSS, HTML, JSON, YAML, TOML…) with line numbers and a monospace font. The same
    look is used in the project file editor.
- **Long tasks**: open the chat’s **⋮ menu → Long tasks**. The assistant keeps working until the *whole*
  job is done (every comment replied to, every file fixed) instead of stopping after one or two and waiting
  for “continue”. A small circular arrow marks the automatic nudges. Toggle it off any time.
- **Plan card**: for multi-step work a small badge shows the real plan and the current step. A resumed task
  continues the same plan instead of restarting.
- **Edit, regenerate, continue**: edit your message, regenerate the last answer, or resume an interrupted
  one (dropped connection, closed app) exactly where it stopped.
- **Also**: streaming Markdown, searchable history, temporary chats, custom instructions, dark / light /
  glass “emerald” themes, and the SOLIMAN icon on your home screen.

---

## How to use each plugin

Everything lives in **side menu → Settings → Plugins**. Switch a plugin on, then simply *ask for the outcome in plain
language* — the assistant chooses the tools.

### Web search and pages

*Tools: `web_search`, `image_search`, `fetch_page`.*

- **Turn on**: Plugins → Web. “Search before answering” makes new chats start with the Search switch on.
- **Use it**: ask anything current — *“What’s the latest on …?”*, *“Compare these two phones”*, or paste a
  link and say *“summarize this page”*.
- **Pictures**: *“Find pictures of the Pyramids at sunset.”* The result arrives as a swipeable slideshow.
- **Videos**: *“Find a tutorial video on …”* — links appear as cards with thumbnails.

### Built-in browser and DevTools

*Tools: `browser_open`, `browser_read`, `browser_click`, `browser_type`, `browser_drag`, `browser_scroll`,
`browser_back`, `browser_devtools`.*

- **Turn on**: Plugins → Built-in browser. *Show it while it works* docks the browser above the chat so you
  can watch; off = it works in the background.
- **Desktop mode, always**: the browser identifies as desktop Chrome with a wide viewport, so Facebook,
  WhatsApp Web, Gmail and similar sites show their full computer version.
- **Change local browser** (Settings): lists the browsers on your phone (Chrome, Firefox, Tor Browser, Edge…)
  plus the built-in one at the top. Pick one and every plugin task still runs **inside Omni Chat** — the
  assistant keeps reading and driving the page — but sites now see that browser's name and version. Pick
  *Built-in browser* to go back. The engine is always Android's web view, so this changes the identity, not
  the engine, cookies or add-ons of the other app, and the other app is never opened. For Tor, also turn on
  *Proxy & Tor*, since the identity alone does not hide your address.
- **Use it**: *“Open Facebook, go to my page’s comments and reply to each customer politely.”* Combine
  with **Long tasks** so it doesn’t stop after the first reply. Sign in once by hand in the browser — the
  session is kept.
- **DevTools (hammer button on the browser bar)**
  - **Network**: every request with status, time, method and address; tap one for headers, request body and
    response body; filter by address or show only failures; copy it all.
  - **Console**: logs, warnings and errors, color-coded.
  - The assistant reads the same data with `browser_devtools` — ask *“why did that button do nothing?”*
    and it checks failed requests and console errors itself.
- **Safety**: it asks before anything irreversible (sending, buying, deleting, publishing).

### Termux shell

*Tools: `termux_run`, `termux_list_files`.*  **Off by default; reaches a real Linux shell on your phone.**

1. Install **Termux from F-Droid** (the Play Store build is too old for this).
2. In Termux run: `echo "allow-external-apps = true" >> ~/.termux/termux.properties` and restart Termux.
3. Plugins → Shell (Termux): turn on *Real shell commands*, then tap **Grant permission** (if nothing
   appears, use *Open the permission by hand in system settings* and enable “Run commands in Termux
   environment”).
4. The status row turns green: **Termux is ready**.
5. **Use it**: *“Write a Python script that renames these files and run it.”* The assistant writes, runs,
   reads the real output and fixes errors in a loop. `pkg install python git` in Termux first for more tools.

### SSH hosts and the setup guides

Let the assistant work on your servers or PC (needs the Termux shell above).

1. **Plugins → Add SSH host**: name, host/IP, port (22), username.
2. Choose **Key** (the app generates the key pair in Termux and shows you the public half to put in the
   server’s `authorized_keys`) or **Password** (with a one-tap `sshpass` install).
3. Ask: *“On my-server, check disk space and restart nginx.”*
4. **Not sure how to enable SSH on the other side?** Open **Plugins → SSH & FTP setup guides** — step-by-step
   guides with a **copy button on every command** for:
   **Windows PowerShell · Windows CMD · macOS Terminal · Linux Terminal · Ubuntu · Kali Linux.**
   Each covers: turning the server on → firewall → finding your IP/username → key login → SFTP/FTP file
   transfer → what to do if it fails.

### FTP server

Edit your phone’s Projects files from a PC or another device on the same Wi-Fi.

1. Plugins → FTP: switch it on, optionally set a port (default 2121), username and password.
2. Note the address shown, like `ftp://192.168.1.20:2121`.
3. On Windows: paste it in File Explorer, or use FileZilla / WinSCP. On macOS/Linux: `curl` or any FTP client
   (the guides above show the commands).
4. **Switch it off when you’re done** — it exposes your Projects folder to the whole network.

### Python sandbox

*Tool: `python_run`.* Python compiled to WebAssembly (Pyodide) — safe, offline-capable, no setup.
Ask for calculations, data cleaning, parsing or quick scripts: *“Parse this CSV and give me totals by month.”*
For packages and files on the device itself, use the Termux shell instead.

### GitHub

*Tools: search, repo, file, tree, commits, branches, Actions runs, issues/PRs — and, with edits on,
commit, pull request, merge, new issue, comment, new repository.*

1. Plugins → GitHub: switch on. Without a token it reads **public** repos only.
2. For your own repos create a **fine-grained personal access token** (GitHub → Settings → Developer
   settings) with *Contents* and *Pull requests/Issues* access, paste it in *Personal access token*.
3. Switch on **Allow edits** if you want it to change things. Merging and creating repos still **ask first**.
4. Ask: *“Read my repo `me/app`, find why login fails, fix it on a branch and open a pull request.”*

### Gmail, Canva, Facebook, Instagram, YouTube

Each works through the built-in browser with **your own signed-in account** (nothing is stored by the app
beyond the browser session).

1. Plugins → the service: switch it on, tap **Sign in to …** and log in once in the browser.
2. Ask in plain language:
   - **Gmail** — *“Find the invoice emails from last week and draft a reply to the first.”*
   - **Canva** — *“Create an Instagram post with this text and my brand colors.”*
   - **Facebook** — pages, posts, groups, Marketplace: *“Reply to every new comment on my latest post.”*
   - **Instagram** — posts, stories, DMs, profiles: *“Reply to the new DMs about prices.”*
   - **YouTube** — search, watch, manage your channel/Studio: *“Open Studio and list the comments waiting.”*
3. The assistant asks before anything that is not just reading (posting, sending, deleting).

### Custom sites

Plugins → **Custom sites → Add a site**: paste any link and write what it’s for (*“my store admin — orders
and stock”*). It gets the same treatment as the named plugins: sign in once, then ask.

### Assistant model (second opinion)

Pick a second model (any provider) under **Plugins → Assistant model**. When the main model is stuck — a
command keeps failing, an error is confusing, a decision is uncertain — it can hand over the real context,
read the advice and continue. Use a stronger or differently-trained model here.

### Image helper for text-only models

If your chat model cannot see pictures, set a **Helper provider/model** (one with vision). Attached images
are described by the helper and the text is given to the chat model.

### Projects

A real file workspace for building something to hand back — a website, a script bundle, an app.
Tools: create, list, read, write, edit, search, move, delete, download/export as ZIP, import/push to GitHub,
`project_serve` (live preview on the phone) and `project_check` (looks at the page like a phone and reports
console errors).

- **Use it**: *“Build a landing page for my bakery, put it in a project, and show me a preview.”*
- **Import**: attach a `.zip` or a folder — it is unpacked into a project the assistant can work on.
- **Edit by hand**: open a file in the project screen (colored code with line numbers), or edit remotely over FTP.

### Skills

Instruction packs the assistant can load, with the tools they may use. Open **Skills** from the side menu,
switch one on for a chat, or let the assistant load it when it fits. Install from a GitHub repo, a
`SKILL.md` link or a `.zip`, or write your own. Skills are grouped by origin (one folder per repo, *Manual*,
*Built-in*).

### Memory and lessons

- **Memory** (side menu → Memory): lasting facts about *you* — name, job, preferences, projects — saved by the
  assistant as they come up and used in every future chat. Review or delete any item.
- **Self-improvement / Lessons** (side menu → Lessons; the switch is in Settings → Self-improvement): operational lessons the assistant records about *itself* (a mistake and its
  real fix, a device constraint). They are fed into every chat regardless of the model, so experience survives
  a model change.

### Other plugins (MCP and web APIs)

**Plugins → Add plugin or skill**: paste the URL of a remote **MCP server** (with a token if it needs one) or
a `plugin.json` that describes a simple web API. Its tools appear to the assistant immediately and can be
turned on/off under *Installed plugins*.

---

## Design: Midnight Glass

The whole app uses one frosted-glass design system. **Settings → Appearance** picks *Dark* (deep midnight navy),
*Light* (pale frosted glass), *System* or *Emerald*.

- **Surfaces** are translucent with a thin bright rim, a soft top-left sheen and a gentle shadow, over a static
  scene (a deep gradient with two soft light pools) that gives the glass something to refract. Blur is used only
  on a few large surfaces — the top bar, dialogs, bottom sheets and the side drawer — never per list row, so
  scrolling stays light on the GPU.
- **Components** (`lib/ui/glass/`): `FrostedGlassCard`, `GlassButton`, `GlassIconButton`, `GlassInput`,
  `GlassNavigation`, `GlassDialog`, `GlassBottomSheet` (`showGlassSheet`), `GlassStatusIndicator`, `GlassToggle`
  and `NeonProgressTimeline`. Buttons and controls have pressed, disabled, loading, selected and focus states.
- **Neon progress timeline.** Every multi-step run (the assistant's tool steps, and the plan popup) is drawn as a
  vertical timeline: a glowing electric-blue ring on the active step, a luminous line that fills in as each step
  finishes, and clear completed / failed / cancelled / waiting states with real start times and durations.
  It shows only what the app is really doing: the active ring follows the engine's current tool call, a step turns
  red when the tool actually failed, and calls that never ran after a stop are marked cancelled.
- **Icons** are one outline set (Cupertino) at three sizes, with electric blue for active controls.

---

## Proxy and Tor

**Settings → Proxy & Tor** sends the app's traffic through a proxy or through Tor. Everything the app does on
the network — AI providers, web search and pages, GitHub, downloads and the image helper — goes through it;
the built-in browser is pointed at it too (switch it off with *Use for the built-in browser*).

| Mode | What it does |
|---|---|
| **Off** | Direct connection (default). |
| **Proxy** | An HTTP or SOCKS5 proxy: host, port and an optional username and password. |
| **Tor** | A SOCKS5 connection to Tor, on `127.0.0.1:9050` by default. Names are resolved by Tor, so `.onion` addresses work and DNS does not leak. |

**Running Tor on the phone.** Tor is a separate program; the app only connects to it. Either:

- start **Orbot** and use its SOCKS port (9050 unless you changed it), or
- use **Start Tor in Termux** on the Tor screen (needs the Termux plugin allowed), or run it by hand in Termux:
  `pkg install tor`, then `tor`.

Wait about a minute for Tor to connect, then tap **Test connection** — it asks check.torproject.org which
address it sees and tells you whether the traffic really came out of Tor.

**Good to know**

- **No leaks.** While a proxy or Tor is on and it is not reachable, requests fail; they never fall back to a
  direct connection.
- **Local network stays direct** (default): Ollama, LM Studio, a PC's FTP and other `192.168.x.x`/`10.x.x.x`
  addresses skip the proxy, because a remote proxy cannot reach them. Turn it off to route those too. The
  phone itself (`localhost`) is always direct.
- **Browser coverage.** Android's web view can only be redirected on phones with a recent WebView. If yours
  cannot, the screen says so and the built-in browser connects directly.
- **Not a VPN.** Only Omni Chat's own traffic is covered, not other apps, and Termux commands run by the agent
  use their own network unless you set a proxy there.
- Tor is slow; long AI answers still work but expect a delay on the first byte.

---

## Privacy and security

- API keys, chats, memory, lessons and settings stay on the phone (Android’s private app storage).
- Each message goes **directly to the provider you chose** — there is no Omni Chat server.
- Device-touching features (Termux, SSH, FTP, browser accounts, GitHub edits) are **off by default** and ask
  before irreversible actions.
- FTP is unencrypted and open to your Wi-Fi while on — use it briefly on networks you trust.
- Keep tokens narrow: a fine-grained GitHub token limited to the repositories you want it to touch.

## Troubleshooting

| Problem | What to do |
|---|---|
| *App not installed as package appears to be invalid* | Re-download on a stable connection; make sure the installed build isn’t newer than the one you’re installing. |
| A model says it is out of tokens | If **Switch model automatically** is on and another model has a green mark, it moves there by itself. |
| The assistant stops after one or two items | Turn on **⋮ → Long tasks** for that chat. |
| A website behaves oddly | Open the browser’s **DevTools**, check Network (failed requests) and Console (errors), or ask the assistant to. |
| Termux says “not ready” | Use Termux from F-Droid, add `allow-external-apps = true`, then grant the permission. |
| An answer was cut off | Tap **Continue** — it resumes from the exact point. |

## Build from source

Push to `main`: GitHub Actions analyzes, tests and builds the APK and publishes `omni-chat.apk` as release
`build-N` (the build number always increases, so builds install as updates). The Android project is generated
in CI (`flutter create`, then `tool/patch_android.sh`) — only `lib/`, `assets/`, `test/` and the config files
are committed. Original recon notes and feature list: `replica/`.

---

<div align="center">

**تصميم SOLIMAN · Designed by SOLIMAN**

</div>

## Downloads (parallel, resumable)

Tapping a file link in the built-in browser opens a prompt (name, size, number of connections) and then Android's save
picker, so you choose the folder and file name. The file is cut into many 1–16 MB parts that are fetched over up to 32
connections at once, then joined in order into the file you chose. Pause and resume at any time: every part keeps its
own file, so nothing starts over, even after the app is closed. Servers without byte-range support are downloaded as one
plain stream. Open **Settings → Downloads** (or the ⋯ menu of the browser) to see speed, per-part progress and to paste
a link by hand. Browser fixes: desktop mode is scaled to the screen width, and the web view stops sending the
`X-Requested-With` header and accepts third-party cookies, which helps with sites that refuse embedded browsers.
Google may still refuse sign-in in any embedded browser; that is Google's policy and cannot be guaranteed.

## AI execution experience: streaming, Thinking panel, workers

**Real-time streaming.** Every provider streams (SSE for OpenAI-compatible APIs including NVIDIA, Anthropic and Gemini).
Text is shown as it arrives and in order, Markdown and code blocks included; redraws are batched (less often as a reply
grows) so long replies never freeze the UI. **Stop** ends the stream at once. If the connection drops or goes silent the
app reconnects (up to 3 times), asks the model to continue from the text received and removes any repeated text, so there
is one unbroken reply. A server that refuses `stream=true` is asked for the whole reply instead. Live numbers — time to
first token, tokens/second, total tokens (provider-reported when available, otherwise estimated), connection state — show
under the reply and in the Thinking panel; a finished reply keeps a one-line summary.

**Thinking panel** (chat menu → *Thinking panel*, or Settings → Plugins). Built from the real events of the task, not a
script: an *Execution Overview* bar (elapsed time, steps done/running, agents, workers, tokens, tokens/s, status), a
vertical *Thinking Timeline* of stages (Analyzing Request, Understanding Requirements, Planning, Researching, Analyzing
Files, Delegating Tasks, Executing Commands, Reviewing Results, Testing, Finalizing — each with time, status and its
events), and a *Step Inspector* (task, events, tools used, terminal commands and output, results, modified files, errors
and warnings, stage summary). It shows what the app recorded; it does not claim to reveal the model's hidden reasoning.
Drag the handles to resize, hide it entirely with ✕, and switch auto-scroll on or off.

**Agents & Workers** (Settings → Agents & Workers). For jobs with independent parts the assistant can call
`run_parallel`: the orchestrator splits the job into tasks, runs independent ones on worker agents side by side (default
2 at a time; up to your limits for workers and active agents), waits for dependencies, never runs two tasks that change the
same file together, queues file writes per file and reports files two workers both wrote, retries failures, times out
stuck workers, and returns every result in one report for the assistant to check and combine. Workers can search the web,
read pages and read/write project files; the browser, terminal and Python stay with the main assistant. Stop cancels all
workers. The Multi-Agent Monitor in the Thinking panel shows one card per worker.
