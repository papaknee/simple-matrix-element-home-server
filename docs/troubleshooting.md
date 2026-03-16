# Troubleshooting Guide

Quick reference for diagnosing common issues with your Matrix home server.

---

## Table of Contents

1. [Synapse won't start](#1-synapse-wont-start)
2. [Can't log in to Element](#2-cant-log-in-to-element)
3. [Federation not working](#3-federation-not-working)
4. [SSL certificate issues](#4-ssl-certificate-issues)
5. [Video calls fail](#5-video-calls-fail)
6. [LiveKit group calls fail](#6-livekit-group-calls-fail)
7. [coturn TURN not working](#7-coturn-turn-not-working)
8. [Database errors](#8-database-errors)
9. [nginx errors](#9-nginx-errors)
10. [Port connectivity issues](#10-port-connectivity-issues)
11. [Checking all service logs](#11-checking-all-service-logs)

---

## 1. Synapse won't start

### Localhost mode
```bash
# Check Synapse status
sudo systemctl status matrix-synapse

# View recent logs
sudo journalctl -u matrix-synapse -n 100 --no-pager

# Validate the config file
python3 -m synapse.app.homeserver --config-path /etc/matrix-synapse/homeserver.yaml --check-config
```

### Docker mode
```bash
cd docker/
docker compose logs synapse --tail=100
docker compose exec synapse python -m synapse.app.homeserver \
    --config-path /data/homeserver.yaml --check-config
```

**Common causes:**
- YAML indentation error in `homeserver.yaml` (use a YAML linter)
- PostgreSQL not running or wrong password (`docker compose logs postgres`)
- Port 8008 already in use (`sudo ss -tlnp | grep 8008`)
- Missing signing key (delete `data/synapse/*.signing.key` and redeploy)

---

## 2. Can't log in to Element

**Symptom**: Element says "Homeserver not found" or login fails.

```bash
# Test the homeserver URL directly
curl http://localhost:8008/_matrix/client/versions    # localhost mode
curl https://matrix.example.com/_matrix/client/versions  # docker mode

# Expected response (example):
# {"versions":["r0.0.1","r0.1.0",...], "unstable_features":{...}}
```

**Common causes:**
- Wrong homeserver URL in Element config (`config.json`)
    - Localhost: `base_url` should be `http://localhost:8080`
  - Docker: `base_url` should be `https://matrix.example.com`
- nginx not running (`docker compose ps` or `sudo systemctl status nginx`)
- CORS error: check browser DevTools (F12) → Console for CORS errors

Quick UI check:
```bash
xdg-open https://element.example.com
```

---

## 3. Federation not working

```bash
# Check federation from matrix.org's tester
# https://federationtester.matrix.org/?server=matrix.example.com

# Manually test federation port
curl https://matrix.example.com:8448/_matrix/client/versions

# Check .well-known delegation
curl https://example.com/.well-known/matrix/server
# Expected: {"m.server":"matrix.example.com:443"}

# Test with federation tester tool
curl https://federationtester.matrix.org/api/report?server_name=matrix.example.com
```

**Common causes:**
- Port 8448 not forwarded (see `docs/router-setup.md`)
- Missing `.well-known/matrix/server` response (check nginx config)
- DNS not propagated yet (wait 5–30 minutes after DNS changes)
- SSL cert doesn't match domain (check with `openssl s_client -connect matrix.example.com:8448`)

---

## 4. SSL certificate issues

### Check certificate status
```bash
# Verify certificate is valid
openssl s_client -connect matrix.example.com:443 -servername matrix.example.com \
    </dev/null 2>/dev/null | openssl x509 -noout -dates

# Verify Element and LiveKit hostnames are covered by the SAN certificate
openssl s_client -connect element.example.com:443 -servername element.example.com \
    </dev/null 2>/dev/null | openssl x509 -noout -dates
openssl s_client -connect livekit.example.com:443 -servername livekit.example.com \
    </dev/null 2>/dev/null | openssl x509 -noout -dates

# Check certificate chain
curl -v https://matrix.example.com/_matrix/client/versions 2>&1 | grep -A5 "SSL"
```

### Certificate not found / expired
```bash
cd docker/

# List existing certificates (from the Docker volume)
docker run --rm \
    -v simple-matrix-element-home-server_letsencrypt_data:/etc/letsencrypt \
    alpine:latest \
    ls /etc/letsencrypt/live/

# Renew manually
docker compose --profile certbot run --rm certbot renew --force-renewal
docker compose exec nginx nginx -s reload
```

### Rate limit hit
Let's Encrypt allows **5 certificates per registered domain per week**.
If you've hit the limit, wait until the rate limit resets (check at
https://crt.sh/?q=matrix.example.com to see when your last cert was issued).

**Always test with staging first:**
```bash
STAGING=1 ./init-letsencrypt.sh
```

---

## 5. Video calls fail

### 1:1 calls (WebRTC / coturn)

Element uses STUN/TURN for 1:1 voice/video calls.

```bash
# Check coturn is running
docker compose ps coturn
docker compose logs coturn --tail=50

# Test STUN reachability (from a different machine)
# Install: apt install stun-client
stun -v turn.example.com 3478

# Check that Synapse is sending TURN credentials
# (Replace YOUR_ACCESS_TOKEN with a real token – see below for how to obtain one)
curl -H "Authorization: Bearer YOUR_ACCESS_TOKEN" \
    https://matrix.example.com/_matrix/client/v3/voip/turnServer
# Expected: {"uris": [...], "username": "...", "password": "..."}
```

> **Getting an access token**: In Element, go to **Settings → Help & About → scroll down → Access Token**.
> Alternatively, use the login API:
> ```bash
> curl -X POST https://matrix.example.com/_matrix/client/v3/login \
>   -H "Content-Type: application/json" \
>   -d '{"type":"m.login.password","user":"YOUR_USER","password":"YOUR_PASS"}'
> # The response contains "access_token"
> ```

**Common causes:**
- coturn TURN port range not open in firewall/router (`49152–65535 UDP`)
- `COTURN_SECRET` mismatch between Synapse and coturn config
- coturn bound to wrong IP (check `external-ip` setting if needed)

### Browser console inspection
Open browser DevTools (F12) → Console during a call attempt. Look for:
- `ICE connection failed` → TURN relay not working
- `TURN server unavailable` → coturn not reachable

---

## 6. LiveKit group calls fail

LiveKit powers multi-party video calls and screen sharing.

```bash
# Check LiveKit and lk-jwt service
docker compose logs livekit --tail=50
docker compose logs lk-jwt --tail=50

# Test LiveKit health
curl http://localhost:7880/      # Should return LiveKit info (internal)
```

**Verify lk-jwt-service is accessible**:
```bash
curl https://matrix.example.com/_matrix/client/unstable/com.element.msc3401/
```

**Verify LiveKit signaling hostname**:
```bash
curl -I https://livekit.example.com/
```

**Common causes:**
- LiveKit UDP port 7882 not open in firewall/router
- `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` mismatch between livekit and lk-jwt configs
  (re-run `./deploy.sh` if these were auto-generated and got out of sync)
- Element still using stale config from before migration (regenerate `docker/data/element/config.json`)
- Group call feature flags not enabled in Element config (`feature_group_calls`)

### Checking LiveKit room status
```bash
# Use the LiveKit CLI (install from https://github.com/livekit/livekit-cli)
livekit-cli list-rooms \
    --url ws://localhost:7880 \
    --api-key "${LIVEKIT_API_KEY}" \
    --api-secret "${LIVEKIT_API_SECRET}"
```

---

## 7. coturn TURN not working

### Test TURN relay with a tool
```bash
# Install turnutils
apt install coturn

# Test UDP relay
turnutils_uclient -v \
    -u $(openssl rand -hex 8) \
    -w $(openssl rand -hex 8) \
    turn.example.com

# Test via docker
docker compose exec coturn turnadmin -l
```

### Diagnose with Trickle ICE
Use the online tool https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/
to test your STUN/TURN servers directly from a browser.

Enter:
- STUN/TURN URL: `turn:turn.example.com:3478`
- Username and password from the Synapse TURN API (see step 5 above)
- Click "Gather Candidates" – look for `relay` type candidates

If relay candidates appear, coturn is working.

---

## 8. Database errors

```bash
# Check PostgreSQL logs
docker compose logs postgres --tail=100

# Connect to the database for inspection
docker compose exec postgres psql -U synapse -d synapse

# Check Synapse database connectivity
docker compose exec synapse python -c "
import synapse.storage.databases.main
print('DB import OK')
"
```

### Synapse schema out of date
After upgrading Synapse, the database schema may need to be updated:
```bash
docker compose up -d synapse   # Synapse auto-migrates on startup
docker compose logs synapse -f  # Watch for migration messages
```

---

## 9. nginx errors

```bash
# Check nginx config syntax
docker compose exec nginx nginx -t

# View nginx error log
docker compose logs nginx --tail=100

# Test connectivity to upstream services
docker compose exec nginx wget -q -O- http://synapse:8008/health
docker compose exec nginx wget -q -O- http://element:80
```

**Common causes:**
- SSL certificate path wrong (nginx fails to start if cert doesn't exist)
- Upstream service not running (nginx returns 502 Bad Gateway)
- Config template not rendered (check `docker/data/nginx/` isn't being used)

---

## 10. Port connectivity issues

```bash
# Check what ports are listening on the Debian host
sudo ss -tlnp
sudo ss -ulnp

# Check firewall rules
sudo ufw status verbose
sudo iptables -L -n -v

# Test from outside (replace with your public IP / domain)
nc -zv matrix.example.com 80
nc -zv matrix.example.com 443
nc -zv matrix.example.com 8448
nc -zv element.example.com 80
nc -zv element.example.com 443
nc -zv livekit.example.com 80
nc -zv livekit.example.com 443
nc -zuv turn.example.com 3478
nc -zv turn.example.com 5349
```

---

## 11. Checking all service logs

```bash
cd docker/

# All services at once
docker compose logs --tail=50

# Single service with follow
docker compose logs -f synapse
docker compose logs -f nginx
docker compose logs -f coturn
docker compose logs -f livekit
docker compose logs -f lk-jwt
docker compose logs -f postgres

# Service status overview
docker compose ps
```

### Localhost mode
```bash
# Synapse
sudo journalctl -u matrix-synapse -n 100 --no-pager
tail -f /var/lib/matrix-synapse/homeserver.log

# nginx
sudo journalctl -u nginx -n 50 --no-pager
tail -f /var/log/nginx/error.log
tail -f /var/log/nginx/access.log
```

---

## Useful diagnostic commands

```bash
# Matrix server version
curl -s https://matrix.example.com/_matrix/client/versions | python3 -m json.tool

# Synapse process info
docker compose exec synapse ps aux

# Disk usage
docker system df
du -sh docker/data/

# Network connectivity from inside Docker
docker compose exec synapse curl -sv http://postgres:5432 2>&1 | head -20
docker compose exec synapse curl -s http://localhost:8008/health
```
