# Simple Matrix + Element Home Server for Debian 13

Self-host a private [Matrix](https://matrix.org) + [Element](https://element.io) chat server on your own Debian 13 (Trixie) machine. No cloud required. Full end-to-end encrypted messaging, voice/video calls, and multi-party video conferencing – all under your own domain.

---

## What you get

| Feature | Dev (localhost) | Prod (Docker) |
|---|---|---|
| Matrix Synapse homeserver | ✅ native packages | ✅ Docker |
| Element Web client | ✅ nginx static | ✅ Docker |
| PostgreSQL database | — SQLite | ✅ Docker |
| HTTPS / Let's Encrypt SSL | — | ✅ |
| Matrix federation | — | ✅ |
| coturn STUN/TURN (1:1 video) | — | ✅ |
| LiveKit SFU (group video) | — | ✅ |
| lk-jwt-service (Matrix→LiveKit) | — | ✅ |
| Screen sharing | — | ✅ |
| Data preserved on update | ✅ | ✅ |

---

## Architecture

### Dev environment (localhost)

```
Browser
  └── http://localhost:8080 ──→ nginx ──→ /var/www/element (Element Web)
                                      └──→ http://localhost:8008 (Synapse)
```

Synapse runs as a native Debian service, writing to a local SQLite database.
No SSL, no Docker, no external dependencies. Perfect for testing your config
before going to production.

### Production environment (Docker)

```
Internet
  ├── :80  / :443  ──→ nginx ──→ Element Web  (Docker)
  │                         └──→ Synapse      (Docker, port 8008)
  │                         └──→ lk-jwt-svc   (Docker, port 8080)
  ├── :8448          ──→ nginx ──→ Synapse (federation)
  ├── :3478 / :5349  ──→ coturn STUN/TURN  (host networking)
  └── :7882 UDP      ──→ LiveKit SFU       (Docker)

Internal only:
  Synapse ←→ PostgreSQL
  lk-jwt  ←→ Synapse (auth check)
  lk-jwt  ←→ LiveKit (JWT issue)
  Element Call ←→ lk-jwt → LiveKit (group video)
```

### Video calling stack

```
1:1 calls:     Element → WebRTC (coturn for NAT traversal)
Group calls:   Element → Element Call widget
                          → lk-jwt-service (Matrix auth → LiveKit JWT)
                          → LiveKit SFU (efficient multi-party video)
                          ↑ coturn handles STUN/TURN relay for all ICE
```

---

## Prerequisites

### Dev (localhost)
- Debian 13 (Trixie) – fresh install or existing
- `sudo` access
- Outbound internet access (to download packages and Element Web)

### Production (Docker)
- Debian 13 (Trixie)
- [Docker Engine](https://docs.docker.com/engine/install/debian/) with Compose plugin
- A registered domain name (e.g., `matrix.example.com`)
- Your machine's public IP reachable from the internet
- Ports 80, 443, 8448, 3478, 5349, 7882 forwarded on your router

#### Recommended hardware
| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 1 core | 2+ cores |
| RAM | 1 GB | 2 GB+ |
| Disk | 10 GB | 20 GB+ (media files grow over time) |

> Actual requirements depend on number of users, media uploads, and group-call usage. A small family/team server (5–10 users) runs comfortably on 1 CPU / 1 GB RAM.

---

## Quick Start

### Phase 1 – Local testing

```bash
# 1. Clone this repository
git clone https://github.com/papaknee/simple-matrix-element-home-server.git
cd simple-matrix-element-home-server

# 2. Run the localhost setup (installs Synapse + Element natively)
cd localhost
sudo bash setup.sh

# 3. Open Element in your browser
xdg-open http://localhost:8080
```

The setup script will:
- Add the Matrix.org apt repository and install Synapse
- Download Element Web and configure nginx to serve it on port 8080
- Patch the Synapse config for local dev (open registration, SQLite)
- Prompt you to create an admin user

**Test everything you want** – create rooms, send messages, try voice/video calls (basic 1:1 with your browser's built-in WebRTC). When you are happy, proceed to Phase 2.

To stop / start the local services:
```bash
sudo bash stop.sh
sudo bash start.sh
```

To tear down completely and remove all local data:
```bash
sudo bash teardown.sh
```

---

### Phase 2 – Production deployment

> **Prerequisites**: Install Docker first:
> ```bash
> curl -fsSL https://get.docker.com | sudo sh
> sudo usermod -aG docker $USER
> newgrp docker   # or log out and back in
> ```

```bash
cd docker/

# 1. Copy and fill in the environment file
cp .env.example .env
nano .env    # Set DOMAIN, LETSENCRYPT_EMAIL, POSTGRES_PASSWORD, etc.
```

**Minimum required settings in `.env`:**
```env
DOMAIN=matrix.example.com
LETSENCRYPT_EMAIL=admin@example.com
POSTGRES_PASSWORD=choose_a_strong_password
```

> All other secrets (COTURN_SECRET, MACAROON_SECRET_KEY, etc.) are
> **auto-generated** by `deploy.sh` on first run if left as placeholders.

```bash
# 2. Run the first deployment (HTTP only – no SSL yet)
bash deploy.sh
```

The deploy script will:
1. Validate your `.env`
2. Generate strong random secrets (if not already set)
3. Render all config templates into `./data/`
4. Pull Docker images and start all services
5. **Pause and ask you to verify** the server is working before SSL

**Verify everything works** over HTTP:
```bash
# API responds correctly?
curl http://matrix.example.com/_matrix/client/versions

# Element loads in browser?
xdg-open http://matrix.example.com
```

See [`docs/domain-setup.md`](docs/domain-setup.md) and [`docs/router-setup.md`](docs/router-setup.md) to configure DNS and router port forwarding.

---

### Phase 3 – Enable SSL (Let's Encrypt)

> ⚠️ **Rate limit warning**: Let's Encrypt allows only **5 certificate requests per registered domain per week**. Test with `STAGING=1` first.

**Only run this once you have confirmed:**
1. DNS A record for `matrix.example.com` resolves to your public IP ✅
2. Port 80 is reachable from the internet ✅
3. The server works in HTTP mode ✅

```bash
cd docker/

# Optional: test with staging (no rate limits, cert not browser-trusted)
# STAGING=1 bash init-letsencrypt.sh

# Request real certificate
bash init-letsencrypt.sh
```

This will:
1. Run certbot with the webroot challenge
2. Store the certificate in a Docker volume
3. Set `SSL_ENABLED=true` in `.env`
4. Restart nginx with the HTTPS configuration
5. Set up a daily cron job for automatic renewal

After this, your Matrix server is accessible at `https://matrix.example.com`.

---

## Updating to a new version

All configuration files and data are stored in `docker/data/` and Docker volumes. Updates only pull new images – **your data is never touched.**

```bash
cd docker/
bash update.sh
```

This runs `docker compose pull` + `docker compose up -d --remove-orphans`. The `./data/` directory and all named volumes are preserved.

---

## Backing up your data

Your server stores data in two places. Back both up regularly:

1. **`docker/data/`** – rendered config files and signing keys.
2. **Docker named volumes** – the PostgreSQL database, Synapse media store, and Let's Encrypt certificates.

### Quick backup

```bash
cd docker/

# 1. Dump the PostgreSQL database
docker compose exec -T postgres pg_dumpall -U synapse > backup-db-$(date +%F).sql

# 2. Copy config / keys / media
tar czf backup-data-$(date +%F).tar.gz data/

# 3. Back up Docker volumes (optional but recommended)
docker run --rm \
    -v simple-matrix-element-home-server_synapse_data:/source:ro \
    -v "$(pwd)":/backup \
    alpine tar czf /backup/backup-synapse-volume-$(date +%F).tar.gz -C /source .
```

Store the resulting files somewhere safe (external drive, remote server, etc.). To restore, reverse the process: load the SQL dump with `psql`, extract the tarball back to `data/`, and recreate volumes from the archives.

---

## Managing users

### Create a user (admin)
```bash
cd docker/
docker compose exec synapse register_new_matrix_user \
    -c /data/homeserver.yaml \
    -u USERNAME \
    -p PASSWORD \
    -a \
    http://localhost:8008
```

### Create a user (regular)
```bash
docker compose exec synapse register_new_matrix_user \
    -c /data/homeserver.yaml \
    -u USERNAME \
    -p PASSWORD \
    --no-admin \
    http://localhost:8008
```

### Enable open registration (allows anyone to sign up)
Edit `docker/data/synapse/homeserver.yaml`:
```yaml
enable_registration: true
enable_registration_without_verification: true
```
Then: `docker compose restart synapse`

> See the [Configuration Guide → Registration options](#registration-options)
> for captcha, email verification, and invite-token variants.

### Synapse Admin API
The [Synapse Admin API](https://element-hq.github.io/synapse/latest/admin_api/) is available at `https://matrix.example.com/_synapse/admin/`. You need an admin access token.

---

## Video calling details

### 1:1 calls (coturn)

coturn provides STUN/TURN servers so WebRTC calls can traverse NAT and firewalls. Synapse automatically issues time-limited TURN credentials to clients via `/_matrix/client/v3/voip/turnServer`.

Required ports (on router + firewall):
- `3478` UDP+TCP (STUN / TURN)
- `5349` TCP (TURNS over TLS)
- `49152–65535` UDP (TURN relay range)

### Group video / screen sharing (LiveKit + lk-jwt-service)

[LiveKit](https://livekit.io) is a Selective Forwarding Unit (SFU). In a peer-to-peer (P2P) mesh call, each participant sends their video to every other participant. With an SFU, each participant sends **once** to LiveKit, which then forwards it to others. This scales much better for group calls.

Flow:
1. User starts or joins a group call in Element
2. Element opens the **Element Call** widget
3. Element Call requests a LiveKit JWT from `lk-jwt-service`
4. `lk-jwt-service` validates the Matrix auth token with Synapse
5. `lk-jwt-service` returns a signed LiveKit JWT
6. Element Call connects to LiveKit using the JWT
7. All media (audio, video, screen share) flows through LiveKit

Required ports: `7882` UDP (LiveKit media)

**Note on Element Call**: By default, Element is configured to use the hosted `call.element.io` for the Element Call widget. If you want full self-hosting, you can deploy the [Element Call](https://github.com/element-hq/element-call) app and update `element_call.url` in `docker/data/element/config.json`.

---

## Directory structure

```
simple-matrix-element-home-server/
├── README.md                        ← You are here
├── .gitignore
│
├── localhost/                       ← Dev environment (native Debian packages)
│   ├── setup.sh                     ← One-time setup
│   ├── start.sh                     ← Start local services
│   ├── stop.sh                      ← Stop local services
│   ├── teardown.sh                  ← Full removal
│   └── config/
│       ├── homeserver.yaml.template ← Reference Synapse config
│       └── element-config.json      ← Element config for localhost
│
├── docker/                          ← Production Docker environment
│   ├── docker-compose.yml           ← All services
│   ├── .env.example                 ← Copy to .env and fill in
│   ├── deploy.sh                    ← First deploy + update-aware
│   ├── update.sh                    ← Pull new images, preserve data
│   ├── init-letsencrypt.sh          ← One-time SSL cert request
│   ├── nginx/                       ← Custom nginx image
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh            ← Auto-selects HTTP or HTTPS config
│   │   ├── nginx.conf
│   │   └── templates/               ← nginx server block templates
│   │       ├── matrix-http.conf.template
│   │       ├── matrix-ssl.conf.template
│   │       ├── element-http.conf.template
│   │       ├── element-ssl.conf.template
│   │       ├── livekit-http.conf.template
│   │       └── livekit-ssl.conf.template
│   └── config/                      ← Service config templates
│       ├── synapse/
│       │   ├── homeserver.yaml.template
│       │   └── log.config.template
│       ├── element/
│       │   └── config.json.template
│       ├── coturn/
│       │   └── turnserver.conf.template
│       ├── livekit/
│       │   └── livekit.yaml.template
│       └── lk-jwt/
│           └── config.yaml.template
│
└── docs/
    ├── domain-setup.md              ← DNS / registrar instructions
    ├── router-setup.md              ← Port forwarding guide
    └── troubleshooting.md           ← Debug and fix common issues
```

---

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for a full guide.

Quick checks:

```bash
# Are services running?
cd docker && docker compose ps

# Synapse logs
docker compose logs synapse --tail=50

# nginx config valid?
docker compose exec nginx nginx -t

# TURN server working?
curl -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \
     https://matrix.example.com/_matrix/client/v3/voip/turnServer

# Federation OK?
# https://federationtester.matrix.org/?server=matrix.example.com
```

---

## Security notes

- The `.env` file contains secrets. It is in `.gitignore` and must never be committed.
- `REGISTRATION_SHARED_SECRET` is used to create users via the command line. Keep it secret.
- The Synapse admin API (`/_synapse/admin/`) is exposed only to admin users.
- coturn is configured with `no-loopback-peers` and `denied-peer-ip` rules to prevent SSRF attacks via TURN relay.
- All HTTPS traffic uses TLS 1.2+ with the Mozilla Intermediate cipher list.

---

## Configuration Guide

After first deployment, the rendered config lives at `docker/data/synapse/homeserver.yaml`.
Edit that file directly for quick changes (remember to `docker compose restart synapse`).
For permanent changes that survive `deploy.sh` re-runs, edit the **template** at
`docker/config/synapse/homeserver.yaml.template` and delete the rendered file so
it is re-generated on the next `deploy.sh` run.

### Private server – disable federation

By default your server federates with the rest of the Matrix network. To make it
completely private (users can only talk to other users on **your** server):

**Step 1** – in `docker/data/synapse/homeserver.yaml`, set:
```yaml
federation_domain_whitelist: []          # empty list = block all servers
allow_public_rooms_over_federation: false
```

**Step 2** – Change the listener resources so the federation port is never served:
```yaml
listeners:
  - port: 8008
    ...
    resources:
      - names: [client]    # remove 'federation' from this list
        compress: false
```

**Step 3** – In `docker/nginx/templates/matrix-ssl.conf.template` (and the HTTP
variant), remove or comment out the `server { listen 8448 ... }` block so the
federation port is not exposed at all.

Then restart Synapse:
```bash
cd docker && docker compose restart synapse
```

> **Whitelist mode**: Instead of blocking everything, you can allow only specific
> trusted servers:
> ```yaml
> federation_domain_whitelist:
>   - "trusted-partner.example.com"
>   - "family-server.example.net"
> ```

---

### Registration options

Edit `docker/data/synapse/homeserver.yaml` and `docker compose restart synapse` after any change.

#### Option A – Closed registration (default, most secure)
Only admins can create accounts via the command line. No self-service signup.
```yaml
enable_registration: false
enable_registration_without_verification: false
```
Create accounts manually:
```bash
cd docker/
docker compose exec synapse register_new_matrix_user \
    -c /data/homeserver.yaml \
    -u USERNAME -p PASSWORD --no-admin \
    http://localhost:8008
```

#### Option B – Open registration (anyone can sign up)
```yaml
enable_registration: true
enable_registration_without_verification: true
```
> ⚠️ Only use this if you intend to run a public server. Anyone who can reach your
> URL can create an account.

#### Option C – Registration with email verification
Users must confirm a valid email address before their account is activated.
Requires [email/SMTP to be configured](#email--smtp-setup).
```yaml
enable_registration: true
enable_registration_without_verification: false
```

#### Option D – Registration with CAPTCHA
Adds a reCAPTCHA v2 challenge to the signup form, deterring bots.
Get keys at <https://www.google.com/recaptcha/admin/create> (choose v2 "I'm not a robot").
```yaml
enable_registration: true
enable_captcha: true
recaptcha_public_key: "YOUR_RECAPTCHA_SITE_KEY"
recaptcha_private_key: "YOUR_RECAPTCHA_SECRET_KEY"
```
CAPTCHA can be combined with email verification for two layers of protection.

#### Option E – Invite tokens (controlled open registration)
Generate single-use or limited-use invite codes so only invited people can register.
```yaml
enable_registration: true
registration_requires_token: true
```
Create a token via the Admin API:
```bash
curl -X POST https://matrix.example.com/_synapse/admin/v1/registration_tokens/new \
    -H "Authorization: Bearer YOUR_ADMIN_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"uses_allowed": 1}'
```
Share the returned token with the person you want to invite. They enter it during
signup. See the [Synapse docs](https://element-hq.github.io/synapse/latest/usage/administration/admin_api/registration_tokens.html) for managing tokens.

---

### Email / SMTP setup

Email is needed for:
- **Password resets** (users who forget their password)
- **Email verification** (Option C registration above)
- **Push notification emails** (missed message digests)

Without email, users cannot reset forgotten passwords.

Edit `docker/data/synapse/homeserver.yaml` and uncomment/fill in the `email:` block:

```yaml
email:
  smtp_host: smtp.example.com
  smtp_port: 587
  smtp_user: noreply@example.com
  smtp_pass: "your_smtp_password"
  require_transport_security: true   # enforce STARTTLS (recommended)
  notif_from: "Matrix <noreply@matrix.example.com>"
  enable_notifs: true                # missed-message digest emails
```

Then restart Synapse:
```bash
cd docker && docker compose restart synapse
```

#### Gmail / Google Workspace
```yaml
email:
  smtp_host: smtp.gmail.com
  smtp_port: 587
  smtp_user: youraddress@gmail.com
  smtp_pass: "your_app_password"   # NOT your account password; generate at myaccount.google.com/apppasswords
  require_transport_security: true
  notif_from: "Matrix <youraddress@gmail.com>"
  enable_notifs: true
```
> Generate an App Password at <https://myaccount.google.com/apppasswords>
> (requires 2-Step Verification enabled on the Google account).

#### Mailgun / SendGrid / Brevo (transactional email services)
These services give you a reliable sending IP and good deliverability:
```yaml
email:
  smtp_host: smtp.mailgun.org       # or smtp.sendgrid.net / smtp-relay.brevo.com
  smtp_port: 587
  smtp_user: postmaster@mg.yourdomain.com
  smtp_pass: "your_api_key_or_smtp_password"
  require_transport_security: true
  notif_from: "Matrix <noreply@yourdomain.com>"
  enable_notifs: true
```

#### Self-hosted relay (Postfix, Mailcow, etc.)
```yaml
email:
  smtp_host: mail.yourdomain.com
  smtp_port: 587
  smtp_user: noreply@yourdomain.com
  smtp_pass: "mailbox_password"
  require_transport_security: true
  notif_from: "Matrix <noreply@yourdomain.com>"
  enable_notifs: true
```

---

## License

MIT – see [LICENSE](LICENSE).