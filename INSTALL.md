# Installing Termato

Termato is a **personal** workspace: it runs as your normal user account (no root, no
service user) inside your home directory, where it manages your git repos, creates
task branches under `$HOME/.worktrees`, and uses your `~/.claude` config. The
recommended location is **`~/.axios`**, but it works at any path.

> **Run it where it belongs.** Termato gives Claude shell and filesystem access **as
> the user that runs it** — anything that user can read or change, Claude can too.
> Install it on your own machine or a dedicated box, not on a server holding other
> people’s sites, production data, or secrets.

## Requirements

- **macOS** or **Debian/Ubuntu Linux** (other distros work if you install the few
  base tools yourself; you’ll get a clear message if something’s missing).
- The **Claude Code** CLI and an Anthropic account — Termato drives Claude under your
  own subscription.

Everything else — a pinned Node runtime, the reverse proxy, and the secure tunnel —
is set up for you and kept inside `~/.axios`, never touching your system.

## Install

```bash
git clone https://github.com/AlienFireman/termato-app.git ~/.axios
bash ~/.axios/install.sh
```

The installer prompts for a **username** and a **password** — nothing else to
configure. (For an unattended install, pre-set `AXIOS_USERNAME` and `TERMATO_PASSWORD`
to skip the prompts.) It then:

- sets up a private **Node 22** runtime in `~/.axios/.node` (your system Node is
  never used or modified),
- installs anything missing (pm2, plus the Caddy + cloudflared **binaries** — no
  system services),
- configures a private reverse proxy and an encrypted **Cloudflare Tunnel**,
- starts everything under pm2 (`axios`, `axios-caddy`, `axios-tunnel`) and enables
  start-on-boot.

When it finishes, open `https://termato-<username>.fordweb.io` — try it from your phone
over cellular to confirm remote access works.

## How remote access works

Most people run Termato on a home machine or laptop **behind NAT** (no public IP). The
default install uses a **Cloudflare Tunnel** so the machine is reachable from anywhere
— including your phone — with **no inbound ports opened** and nothing exposed to the
public internet. You don’t register a domain or configure DNS: the installer requests
a set of subdomains and a tunnel for you during setup.

You get:
- the app at **`https://termato-<username>.fordweb.io`**
- live app previews at **`https://<animal>-<username>.fordweb.io`** (e.g.
  `beaver-dan.fordweb.io`) — memorable animal names instead of port numbers.

The install is deliberately **non-invasive**: it never touches the system Caddy /
nginx or ports 80/443 (it runs its own private proxy on a high localhost port), and
it auto-picks every local port so it won’t clash with anything else on the box.

## Updating

Termato checks for new builds on startup and from **Settings → Server**. Click
**Update & Restart** to pull the latest version and restart — no terminal needed.

## Changing your login password

Your password is stored only as a one-way **scrypt** hash, so there’s nothing to read
back. To change it:

```bash
cd ~/.axios && npm run set-password      # hidden prompt, updates your config
pm2 restart axios --update-env
```

Add `-- --rotate-sessions` to also log out every device. If the brute-force throttle
ever locks you out, delete `data/auth-throttle.json` and try again.

## Where your data lives

Everything stays on your machine, as plain files inside the install directory:

- **`data/`** — your chats, history, and app state (no database, nothing in the cloud).
- **`projects.json`** — your project list (created when you add your first project).
- **`.env.local`** — your config: the scrypt password hash, the session-signing
  secret, and your port/subdomain settings. Never leaves the box.
- **`.cloudflared/`** — your tunnel credentials (scoped to your tunnel only).

None of these are uploaded anywhere. Termato has no backend that sees your code or data;
the only outbound traffic is the AI requests Claude makes to Anthropic under your own
account, and your own encrypted access tunnel.

## Advanced: install on a public server (your own domain)

If you run on a **publicly reachable server with its own domain** and don’t want the
tunnel, set `TERMATO_INSTALL_TYPE=server`. This prompts for an app host, a
`{port}.domain` preview pattern, and a port range, and integrates with the system
Caddy. You’re responsible for pointing wildcard DNS at the box. This path is kept for
flexibility and isn’t offered interactively.
