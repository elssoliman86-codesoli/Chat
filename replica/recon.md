# Recon: ChatGPT for Android (com.openai.chatgpt)

Purpose of the clone: a personal-use Android chat app that keeps the core ChatGPT experience and adds
(1) many model providers, (2) user-defined skills, (3) more files and images per message.

## Rules in force
Public sources only. I did not use the real app, so screens and flows below come from the Play listing, OpenAI's
help center and press articles. Anything not confirmed by a source is marked as inferred. Nothing of the original is
copied: no name, logo, copy, code or private API. Personal use only, no store release planned.

## Sources read (all public)
| source | URL | read |
| --- | --- | --- |
| Play Store listing | https://play.google.com/store/apps/details?id=com.openai.chatgpt | 2026-11-03 |
| File uploads FAQ | https://help.openai.com/en/articles/8555545-file-uploads-faq | 2026-11-03 |
| Feature overview | https://chatai.guide/features/ | 2026-11-03 |
| Mobile tips | https://www.tomsguide.com/ai/4-hidden-chatgpt-mobile-tricks-that-make-it-way-more-useful | 2026-11-03 |

## Core loop
Open app -> type, speak or attach -> streaming answer -> continue in the same conversation -> find it later in history.

## Screens (S IDs). Confidence: H = from a source, M = inferred from sources, L = guess
| ID | screen | purpose | key components | states | conf |
| --- | --- | --- | --- | --- | --- |
| S01 | Chat | converse with the model | message list, streaming text, composer, "+" attach menu (camera, photos, files), mic, send/stop | empty, streaming, error, offline, long answer | H |
| S02 | Conversation list / sidebar | find and manage chats | list, search, swipe left to rename or delete, new chat | empty, many, search no result | H |
| S03 | Voice conversation | real-time spoken chat (long-press the mic) | waveform/orb, mute, end, voice picker | listening, thinking, speaking, no permission | H |
| S04 | Image generation / edit | create and edit images from text | prompt, result grid, save/share | generating, failed, limit reached | H |
| S05 | Photo input | camera or gallery photo to analyse (handwriting, landmarks, menus) | picker, preview, remove | permission denied, too large | H |
| S06 | Memory | what the assistant remembers, view and delete, temporary chat to skip | list, delete, toggle | empty, many | M |
| S07 | Projects | group chats and files under one topic | project list, project files, instructions | empty, many | M |
| S08 | Custom instructions / personalisation | tone and facts applied to every chat | text fields, toggles | empty, filled | M |
| S09 | Settings | account, theme, voice, data controls, export, delete | rows, toggles | | M |
| S10 | Share / export conversation | shareable snapshot | share sheet | | M |
| S11 | Model picker | choose the model | list | paywall state (original only) | M |
| S12 | Onboarding / sign in | login | buttons | | L (skipped: not needed for a local app) |

## Flows
- F01 Ask a question: S01 compose -> send -> stream -> follow-up. Edge: offline, API error mid-stream, stop generation, regenerate.
- F02 Ask about a photo: S01 "+" -> Camera or Photos -> S05 -> send. Edge: permission denied, image over size limit.
- F03 Ask about a file: S01 "+" -> Files -> pick -> send. Original limits (public): 512 MB per file, 20 MB per image, 2M tokens per text file, ~50 MB per spreadsheet; text-only PDFs fully read, image-only PDFs not supported.
- F04 Talk: long-press mic -> S03 -> spoken back-and-forth -> end.
- F05 Generate an image: prompt -> S04 -> save/share.
- F06 Manage history: S02 swipe left -> rename/delete; search.
- F07 Memory: S06 view, delete; temporary chat to skip memory.
- F08 Group work: S07 create project -> add files and instructions -> chats inherit them.

## Components
Message bubble (user/assistant, markdown, code block with copy, table), composer with attachment chips, attachment menu,
conversation row with swipe actions, model picker sheet, voice orb, toast/snackbar, settings row, empty states.

## Inferred data model (guesses marked)
- Conversation(id, title, project_id?, model, created_at, updated_at, temporary:bool)  conf M
- Message(id, conversation_id, role, content, created_at, status)  conf H
- Attachment(id, message_id, kind image|file, name, mime, size, local_path)  conf M
- Memory(id, text, created_at)  conf M
- Project(id, name, instructions)  conf M
- Settings(theme, voice, custom_instructions)  conf M

## Cannot be cloned (skip)
The OpenAI models and their servers, accounts and sync across devices, the GPT Store and other users' content,
OpenAI's voice models and image models, subscription billing, Agent mode's cloud virtual computer, Atlas browser.
The clone talks to providers the user chooses with the user's own API keys.

## Requested additions (not in the original)
1. Many providers: OpenAI-compatible endpoints (OpenAI, OpenRouter, Groq, Together, DeepSeek, Mistral, NVIDIA, local LM Studio/Ollama or any custom base URL), Anthropic, Google Gemini.
2. Skills: user-defined reusable capabilities the assistant can use.
3. More files and images per message, more file types, with on-device text extraction.

## Size
M (a few weeks of normal work). With Flutter, local storage and a provider layer, the vertical slice (S01 + two providers) is the first milestone.
Hardest parts: streaming for three provider protocols, reading files on the phone (PDF, Office, CSV) within model context limits,
safe local storage of API keys, long conversations and token limits.
