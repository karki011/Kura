# Kura — Product Brief for Marketing

**One-liner:** An invisible AI copilot that listens to your conversations and whispers the answers — visible only to you.

**Tagline options:**
- "Your invisible copilot."
- "Hears everything. Seen by no one."
- "The answer is on your screen — and only your screen."

---

## What is Kura?

Kura is a macOS app that floats a small assistant panel over your screen during calls, meetings, and interviews. It listens to the conversation in real time, transcribes it, and uses AI (Claude, GPT, or any OpenAI-compatible API) to answer questions, suggest what to say next, and generate meeting notes — all inside a window that is **completely invisible to everyone else**.

Share your screen on Zoom, Meet, or Teams, record it, screenshot it — Kura never appears. There is no Dock icon, no menu bar icon, nothing in the app switcher. To everyone else on the call, you're just… remarkably well-prepared.

## The problem it solves

In live conversations — job interviews, sales calls, client meetings, technical deep-dives — the pressure is on *right now*. You can't pause to Google something or open ChatGPT without everyone noticing. Existing AI assistants either join the call as a visible bot, appear in screen shares, or force you to look away and type.

Kura removes the gap between "I should know this" and "I do know this" — invisibly.

## Key features (benefit-first)

**Invisible by design**
- Excluded from screen sharing, screenshots, and recordings at the OS level — works with Zoom, Meet, Teams, Slack, QuickTime, OBS
- No Dock icon, no menu bar icon, not in Cmd+Tab or Force Quit
- No bot ever joins your meeting — there's nothing in the participant list
- Listening produces **no recording indicators** — Kura taps system audio at a level that lights no purple dots (a genuine technical differentiator; most competitors can't avoid this)

**Always-on hearing, two speakers**
- Continuously transcribes the other person ("Them") from system audio, on-device — nothing leaves your Mac for transcription
- Hold-to-talk captures your own voice in short bursts ("You") — so the mic indicator only flashes for seconds
- Real two-person conversation record, speaker-labeled

**Real-time Auto Q&A**
- When someone asks a question, the answer streams into your panel automatically in ~2 seconds — before you've finished saying "good question"
- Smart follow-ups: "go deeper on that" understands what "that" is (full conversation context)

**Your AI, your keys**
- Bring your own API key: Anthropic Claude, OpenAI, or any OpenAI-compatible provider (Groq, OpenRouter, local models)
- Switch models and reasoning effort mid-call from the overlay — fast model for live answers, deep model for hard questions
- No account, no subscription to Kura itself, no data sent anywhere except your chosen AI provider

**A complete meeting workflow**
- **Assist** — instant "what should I say next?"
- **Recap** — structured notes: summary, decisions, open questions
- **To-dos** — checkbox action items with owners and deadlines, extracted from the conversation
- **Follow-ups** — the 3 questions they're likely to ask next, with answers
- **Summarize (⌃⌥E)** — full meeting wrap-up, auto-saved as a Markdown file
- **Meeting context** — attach a PDF brief or notes before a call; the AI uses it for that meeting only
- **Meeting library** — every session saved with a smart title; browse, revisit, delete from a sidebar

**Feels native**
- Translucent, auto light/dark adaptive overlay that never hides what you're looking at
- Global hotkeys for everything — never touch the mouse
- Markdown rendering with proper code blocks and checklists
- Export any meeting as clean Markdown

## Who it's for

- **Job seekers** — live coding and system-design interviews (answer structure, tradeoffs, code on demand)
- **Sales & founders** — discovery calls: instant answers to pricing/objection questions, perfect follow-up emails from auto-generated notes
- **Consultants & freelancers** — sound meticulously prepared with zero prep time
- **Anyone in high-stakes conversations** — students, support leads, technical interviews, investor calls

## Competitive context

| | Kura | Cluely | Granola |
|---|---|---|---|
| Invisible on screen share | ✅ | ✅ | n/a (notes only) |
| No recording indicator while listening | ✅ (audio-level tap) | ✖ (shows purple dot on macOS) | ✖ |
| Real-time answers mid-call | ✅ auto Q&A | ✅ | ✖ (post-meeting) |
| Bring your own API key | ✅ | ✖ (their models, subscription) | ✖ (subscription) |
| No account / no cloud | ✅ | ✖ | ✖ |
| Meeting library + context attach | ✅ | partial | ✅ |

## Privacy story (strong marketing angle)

- Transcription runs **entirely on-device** (Apple's speech engine) — voices never leave the Mac
- Kura has **no servers, no accounts, no analytics**
- The only network calls go directly from your Mac to the AI provider *you* chose, with *your* key
- API keys live in the macOS Keychain
- All meetings stored locally; delete anytime

## Honest notes (for internal awareness, not ads)

- macOS only (Apple Silicon & Intel, macOS 14+)
- BYOK: user needs an API key from Anthropic or OpenAI (or free alternatives via Groq/OpenRouter/local)
- The mic indicator (orange dot) appears for the seconds push-to-talk is held — hardware-enforced by Apple, applies to every app ever made
- Ethical use is the user's responsibility (interview/proctoring rules vary) — position as "preparation & productivity," not "cheating"

## Available assets

- App icon: Dhaka-inspired conversation mark with Himalayan peaks (`assets/kura_1024.png`)
- The app can produce any screenshot/screen-recording you need — ask engineering for staged captures (debug mode makes windows capturable)
- Demo flows that photograph well: Auto Q&A answering live, To-dos checklist generation, sidebar meeting library, light/dark adaptive theme over different backgrounds
