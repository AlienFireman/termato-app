<div align="center">

# Termato

## The full power of Claude Code — in your pocket.

Vibe-code from anywhere. Run real terminals and chat with Claude on your laptop,
your phone, or both at once — and pick up exactly where you left off on whatever
device is in your hand.

```bash
git clone https://github.com/AlienFireman/termato-app.git ~/.axios && bash ~/.axios/install.sh
```

<sub>Free. Up and running on macOS or Linux.</sub>

</div>

<!--
  TODO (Dan): drop hero media here — ideally a short GIF (or side-by-side stills) of
  Termato running the SAME session on desktop and on a phone, the magic terminal, and
  the chat view. Replace this comment with the image(s), e.g.:
  <p align="center"><img src="docs/hero.gif" alt="Termato on desktop and phone" width="860"></p>
-->

---

## Your whole workflow, on your phone

This is the heart of Termato: **everything you can do at your desk, you can do from
your phone** — with no setup and nothing to think about.

- **Hand off mid-thought.** Start a prompt in a chat on your desktop, get up to leave,
  and carry on writing that same prompt from your phone. Your place is waiting for you.
- **Queue and walk away.** Line up follow-up messages from your phone, close the app,
  and put it in your pocket. Termato holds your queue **server-side** and fires each
  message automatically as the current turn finishes — your work keeps moving while
  you don’t have to.
- **One workspace, every device.** Desktop and mobile are both first-class and always
  in sync. There is no “mobile version” with less in it — it’s the whole thing.

## A terminal that finally works everywhere

Termato’s terminal is the **smartest, fastest, most user-friendly terminal across
every device** — and it’s genuinely usable on a phone.

- **Desktop and phone, at the same time, perfectly in sync.**
- **No mangled wrapping. No reflow chaos.** A modern rendering engine keeps every
  line crisp and readable at any width, on any screen — the cross-device problems
  you’re used to simply aren’t there.
- **Resume in one tap, with full context.** Reopen any session and it comes back
  exactly as you left it, even days later.
- **New sessions on the fly.** Spin up another terminal whenever you need one — there’s
  no ceremony.

## Hundreds of sessions, beautifully organized

Work across as many terminals and chats as you like, grouped by project and instantly
findable. Jump between **hundreds of sessions** without losing track of a single one —
from any device, all kept tidy and in order.

## Terminal *or* chat — your choice

Use Claude Code exactly the way you do today, in **real terminals**. Or use Termato’s
clean, friendly **chat interface**, which talks to your Claude Code subscription
underneath. Some people love the terminal; some love the chat. Termato gives you both,
side by side, and lets you switch freely.

## An agent that can drive the interface

Termato gives your agent a way to **control the workspace itself**. When Claude finishes
a task, it can open the built-in browser and **show you the result the moment you return
to the chat** — so your agent doesn’t just describe what it built, it puts it in front
of you.

## It fits your workflow — and changes nothing about it

Termato slips in **alongside** your existing Claude Code setup. Use Claude Code inside
Termato or outside it; Termato never touches, reconfigures, or interferes with your
configuration. There’s nothing to migrate and nothing to undo — your setup stays
exactly as it is. (Context compaction and management are handled by Claude Code itself;
Termato stays out of the way.)

---

## Security & privacy, at the core

Privacy and security aren’t a feature in Termato — they’re the foundation. The
architecture is built so your code never has to be trusted to anyone but you.

- **No middleman. No Termato server.** Your code, prompts, and history never pass
  through us — there is nothing in the middle to intercept, log, or breach. We
  couldn’t see your data if we wanted to, because it never reaches us.
- **Straight to the source.** AI requests go directly to Anthropic under *your own*
  Claude subscription — no extra hop, no broker, no copy kept anywhere.
- **Invisible to the internet.** Remote access runs over an **outbound-only encrypted
  tunnel**. Your machine opens no inbound ports and can’t be discovered, scanned, or
  reached from the public internet.
- **Authenticated end to end.** Every request — the app and your live previews alike —
  is gated behind hardened, cryptographically signed sessions.
- **Runs only on hardware you control.** No cloud, no telemetry, no analytics — ever.

---

## More that makes it a joy to use

- **Live previews** of the apps you build, right next to your chat — in a built-in
  browser, on any device.
- **A fast, polished editor** with tabs and a markdown toolbar.
- **Voice input**, **usage at a glance**, and **skills + scheduled agents**.
- **Start any project in seconds** — import a folder, clone a repo, or scaffold a new
  one, and Termato figures out how to run it for you.
- A UI that’s quick, fluid, and a genuine pleasure to use on every screen.

---

## Install

One line — it’ll ask for a username and password, then set itself up:

```bash
git clone https://github.com/AlienFireman/termato-app.git ~/.axios && bash ~/.axios/install.sh
```

Termato is **self-hosted** and self-contained: it bundles its own runtime, picks free
ports, configures a private reverse proxy and the encrypted tunnel, and runs under pm2
with start-on-boot — all without touching the rest of your system. Works on
**Debian/Ubuntu** and **macOS**.

**You’ll need:** the **Claude Code** CLI and an Anthropic account (Termato drives Claude
under your own subscription). Everything else is set up for you.

See **[INSTALL.md](INSTALL.md)** for details.

## Updating

Termato checks for new versions on startup and from **Settings → Server**. Click
**Update & Restart** — no terminal required.

---

<div align="center">
<sub>This repository contains the production build of Termato, ready to install.
The application source is maintained privately.</sub>
</div>
