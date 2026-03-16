# Domain Name Setup

This guide explains how to point a domain name you own to your home server.

---

## Overview

When you register a domain name (e.g., `example.com`) with a domain registrar,
you control its **DNS records**. This project expects separate subdomains for
each service by default, so you need to create multiple A records that all
point to your home's public IP address. Then your router needs to forward
incoming traffic to your Debian machine.

```
Internet → DNS lookup "matrix.example.com" / "element.example.com" / ... → Your public IP
         → Your home router → Port forwarding → Your Debian machine
```

---

## Step 1: Find your public IP address

Run this on your Debian machine:

```bash
curl -s https://api4.ipify.org
# or
curl -s ifconfig.me
```

Note this IP. If your ISP gives you a **dynamic IP** (it changes), see the
[Dynamic DNS](#dynamic-dns-ddns-optional-but-recommended) section below.

---

## Step 2: Create DNS records at your registrar

Log in to your domain registrar's DNS management panel (Namecheap, GoDaddy,
Cloudflare, Porkbun, Hover, etc.) and create the following records:

| Type | Host / Name          | Value (your public IP)  | TTL  |
|------|----------------------|-------------------------|------|
| A    | `matrix`             | `YOUR.PUBLIC.IP`        | 300  |
| A    | `element`            | `YOUR.PUBLIC.IP`        | 300  |
| A    | `livekit`            | `YOUR.PUBLIC.IP`        | 300  |
| A    | `turn`               | `YOUR.PUBLIC.IP`        | 300  |

> If you customize hostnames in `.env`, create matching DNS records for your
> custom `MATRIX_DOMAIN`, `ELEMENT_DOMAIN`, `LIVEKIT_DOMAIN`, and `TURN_DOMAIN`.

**Example** (root domain = `example.com`):

| Type | Host     | Value           | TTL  |
|------|----------|-----------------|------|
| A    | `matrix` | `203.0.113.42`  | 300  |
| A    | `element` | `203.0.113.42` | 300  |
| A    | `livekit` | `203.0.113.42` | 300  |
| A    | `turn` | `203.0.113.42` | 300  |

Wait **5–30 minutes** for DNS to propagate (TTL 300 = 5 minutes).

---

## Step 3: Verify DNS propagation

```bash
# Check that the A record resolves to your public IP
dig +short matrix.example.com A
dig +short element.example.com A
dig +short livekit.example.com A
dig +short turn.example.com A

# Or use an online tool:
# https://dnschecker.org/#A/matrix.example.com
```

---

## Step 4: Federation – Matrix SRV or well-known record

For other Matrix servers to find your server, you need one of:

### Option A: well-known delegation (recommended, simpler)

Add a file at `https://example.com/.well-known/matrix/server` that returns:

```json
{"m.server": "matrix.example.com:443"}
```

The nginx config in this project does this automatically via:

```nginx
location /.well-known/matrix/server {
   return 200 '{"m.server": "${MATRIX_DOMAIN}:443"}';
}
```

This is served from the root of your domain (e.g., `example.com`). If your
Matrix domain IS your root domain (not a subdomain), this is handled for you.

### Option B: SRV DNS record

Add this DNS record at your registrar:

| Type | Host                          | Priority | Weight | Port | Value                |
|------|-------------------------------|----------|--------|------|----------------------|
| SRV  | `_matrix._tcp.example.com`   | 10       | 5      | 443  | `matrix.example.com` |

---

## Dynamic DNS (DDNS) – Optional but Recommended

Most residential ISPs assign a **dynamic** public IP that changes periodically.
To handle this automatically, use a DDNS service:

### Option A: Cloudflare + ddclient

1. Transfer your domain to Cloudflare (free DNS + DDNS API)
2. Install ddclient:
   ```bash
   sudo apt install ddclient
   ```
3. Configure `/etc/ddclient.conf`:
   ```
   protocol=cloudflare
   use=web, web=ipify-ipv4
   server=api.cloudflare.com/client/v4
   zone=example.com
   login=your@email.com
   password=YOUR_CF_API_TOKEN
   matrix.example.com
   ```
4. Enable ddclient:
   ```bash
   sudo systemctl enable --now ddclient
   ```

### Option B: Duck DNS (free, easy)

1. Create a free account at https://www.duckdns.org
2. Get a free subdomain (e.g., `yourname.duckdns.org`)
3. Install the updater:
   ```bash
   mkdir ~/duckdns && cd ~/duckdns
   cat > duck.sh << 'EOF'
   echo url="https://www.duckdns.org/update?domains=yourname&token=YOUR_TOKEN&ip=" | curl -k -o ~/duckdns/duck.log -K -
   EOF
   chmod +x duck.sh
   crontab -e
   # Add: */5 * * * * ~/duckdns/duck.sh >/dev/null 2>&1
   ```

---

## Verifying everything before requesting SSL

Before running `./init-letsencrypt.sh`, confirm:

```bash
# 1. DNS resolves to your public IP
dig +short matrix.example.com
dig +short element.example.com
dig +short livekit.example.com
dig +short turn.example.com

# 2. Port 80 is reachable from outside (Matrix server must be running)
curl -v http://matrix.example.com/_matrix/client/versions
curl -I http://element.example.com/

# 3. (Optional) Check federation via matrix.org federation tester
# https://federationtester.matrix.org/?server=matrix.example.com
```

All three should succeed before requesting SSL certificates.
