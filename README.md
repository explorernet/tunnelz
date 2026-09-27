# Tunnelz

Expose local ports to the internet from your Mac and inspect every request that goes through them.

Tunnelz is a native macOS app (SwiftUI, macOS 26+) that runs tunnels in two ways:

- **Quick Tunnels**: random `*.trycloudflare.com` URLs through [cloudflared](https://github.com/cloudflare/cloudflared). There is nothing to configure.
- **Relay tunnels** (optional): permanent URLs like `myapp.your-domain.com` through your own self-hosted [zrok](https://zrok.io) relay.

Traffic passes through a local inspecting proxy, so you can see, filter, save and replay requests.

## Features

- **Request inspector**:
  - see the method, path, status, timing, headers and body of every request;
  - filter requests and save the important ones;
  - replay requests;
  - preview images.
- **Path routes**: send `/api` to one port and everything else to another.
  - The longest matching prefix wins.
  - Each route can strip its prefix, and capture can be turned off per route.
- **Streaming**: Server-Sent Events and WebSockets pass through without buffering.
- **Settings**:
  - Limits: maximum request size, how many requests are kept, how much of each body is captured.
  - Privacy: an option to hide `Authorization`, `Cookie` and API key headers.
- **Managed tools**: install and update cloudflared and the zrok client from inside the app.

## Install

1. Download the latest `Tunnelz-<version>.dmg` from [Releases](https://github.com/explorernet/tunnelz/releases/latest).
2. Drag **Tunnelz** into **Applications**, then open it.
3. Onboarding has two optional steps; you can skip both:
   - **Cloudflare**: installs `cloudflared` with Homebrew so you can use Quick Tunnels.
   - **Relay**: connects the app to your own relay (see below).

You can change both later in **Settings**.

## Relay (optional)

A relay gives you **stable, named URLs** (`https://<name>.<your-domain>`) instead of random Quick Tunnel addresses. It is completely optional: without one, Tunnelz works with Quick Tunnels only.

The relay is a self-hosted **zrok v2** server that you run on your own infrastructure. Tunnelz is the client: it does not host a relay for you.

### 1. Run the server

Follow zrok's [self-hosting guide](https://docs.zrok.io/docs/category/self-hosting/) to deploy zrok v2 (controller, frontend and the OpenZiti network) on a VPS. Tunnelz expects this layout:

| Host | Purpose |
|---|---|
| `zrok2.<your-domain>` | zrok API (controller) |
| `*.<your-domain>` | Public shares, one subdomain per tunnel |

Requirements:

- **DNS**:
  - an `A`/`AAAA` record for `zrok2.<your-domain>`;
  - a **wildcard** record for `*.<your-domain>`.
  - Both must point to the server.
- **TLS**:
  - valid certificates for `zrok2.<your-domain>` and for `*.<your-domain>`;
  - the wildcard certificate needs a DNS-01 challenge, for example Caddy or certbot with your DNS provider's plugin.
- **Admin token**:
  - the zrok controller's admin secret;
  - Tunnelz uses it only to manage accounts.

> [!IMPORTANT]
> Tunnelz uses the **zrok2 v2** client and API. A zrok v1 server will not work.

### 2. Create accounts

Each person who uses the relay needs a zrok account. You can create accounts in either of two ways:

- **In Tunnelz**:
  1. Connect as an admin: add the admin token in **Settings → Relay**.
  2. Use **Settings → Users** to create or delete accounts.
  3. When you create an account, Tunnelz shows a **setup link** to send to that person:

     ```
     tunnelz://relay?domain=<your-domain>&token=<account-token>
     ```

- **On the server**:

  ```bash
  zrok2 admin create account <email> <password>
  ```

  The command prints the account token.

Treat setup links and account tokens as secrets: anyone who has one can open tunnels on your relay.

### 3. Connect a Mac

Use any of these:

- **Open the setup link.** Tunnelz opens and fills in the domain and token. If the Mac is already connected to a different domain, Tunnelz asks before it replaces that domain.
- **Onboarding.** In the *Relay* step, enter the domain and token, or paste the setup link.
- **Settings → Relay.** Enter the domain and token.

When it connects, Tunnelz does the following:

1. It downloads the latest zrok2 **2.x** client from GitHub.
2. It checks the download's SHA-256.
3. It installs the client into `~/Library/Application Support/Tunnelz/bin`. Your system is left untouched.
4. It enables a zrok environment for that Mac, stored in `~/.zrok2`.

After that, choose **Relay** when you create a tunnel and pick a name. The tunnel is served at `https://<name>.<your-domain>`, and the name stays reserved for you.

To update the client, open **Settings → Relay**. To disconnect, use the same pane: disconnecting releases the environment.

## Building from source

Requires Xcode 26 or later.

```bash
git clone https://github.com/explorernet/tunnelz.git
cd tunnelz
xcodebuild -scheme Tunnelz -destination 'platform=macOS' build
```

Or open `Tunnelz.xcodeproj` and run the **Tunnelz** scheme.

Local builds have no Sparkle key, so "Check for Updates…" is disabled.

## Releasing

Push a `v*` tag. GitHub Actions then builds, signs, notarizes and publishes the DMG and the Sparkle appcast.

See [RELEASING.md](RELEASING.md) for the one-time secrets setup.

## Data and privacy

**Tunnelz collects nothing**: it has no analytics, no telemetry, no crash reporting and no account. Captured requests never leave your Mac. The only connections the app makes on its own are update checks to GitHub (Sparkle, with system profiling off) and downloads of cloudflared or the zrok client when you ask for them.

| What | Where |
|---|---|
| Tunnels, routes, request history | `~/Library/Application Support/Tunnelz/Tunnelz.store` |
| Managed zrok client | `~/Library/Application Support/Tunnelz/bin` |
| zrok environment (relay identity) | `~/.zrok2` |
| Preferences | `defaults read dev.tunnelz.app` |

Captured bodies can contain credentials and personal data. Lower the capture limits or turn on **Hide credentials** in **Settings → General** when you need to.

## Uninstall

Quit Tunnelz. If you use a relay, disconnect in **Settings → Relay** first. Then run:

```bash
rm -rf /Applications/Tunnelz.app
```

```bash
rm -rf ~/Library/Application\ Support/Tunnelz ~/.zrok2
```

```bash
defaults delete dev.tunnelz.app
```

If you installed cloudflared through Tunnelz and no longer need it:

```bash
brew uninstall cloudflared
```
