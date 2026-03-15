# Home Router Setup

This guide explains how to configure your home router to forward internet
traffic to your Debian Matrix server.

---

## Ports that need to be forwarded

| Port    | Protocol  | Service              | Direction     |
|---------|-----------|----------------------|---------------|
| 80      | TCP       | HTTP / ACME challenge | Internet → Debian |
| 443     | TCP       | HTTPS (Element + API)| Internet → Debian |
| 8448    | TCP       | Matrix federation    | Internet → Debian |
| 3478    | UDP + TCP | STUN / TURN (coturn) | Internet → Debian |
| 5349    | TCP       | TURNS over TLS       | Internet → Debian |
| 7882    | UDP       | LiveKit media (WebRTC)| Internet → Debian |
| 49152–65535 | UDP   | coturn relay range   | Internet → Debian |

> **Note:** The large relay port range (49152–65535 UDP) is needed by coturn to
> relay WebRTC media for clients that cannot communicate directly. Without this,
> TURN relay will not work and video calls may fail through restrictive NATs.

---

## Step 1: Assign a static LAN IP to your Debian machine

Router DHCP typically assigns different IPs each time. You need a **fixed
internal IP** so port forwarding rules always work.

### Option A: DHCP reservation (recommended)

1. Find the MAC address of your Debian machine's network interface:
   ```bash
   ip link show | grep ether
   ```
2. Log in to your router admin panel (usually `http://192.168.1.1` or
   `http://192.168.0.1`; check the sticker on your router).
3. Navigate to **DHCP → Static Leases** (or "Address Reservation", "IP Binding").
4. Add a new reservation:
   - MAC Address: your machine's MAC
   - IP Address: choose an address outside the DHCP pool, e.g., `192.168.1.100`
5. Reboot your Debian machine or run `sudo dhclient -r && sudo dhclient` to get
   the new IP.

### Option B: Static IP on Debian

Edit `/etc/network/interfaces` (for a wired connection):

```
auto eth0
iface eth0 inet static
  address 192.168.1.100
  netmask 255.255.255.0
  gateway 192.168.1.1
  dns-nameservers 1.1.1.1 8.8.8.8
```

---

## Step 2: Add port forwarding rules

The exact menu location varies by router brand. Common labels:
- **Netgear**: Advanced → Advanced Setup → Port Forwarding / Port Triggering
- **ASUS**: WAN → Virtual Server / Port Forwarding
- **TP-Link**: Advanced → NAT Forwarding → Virtual Servers
- **Linksys**: Security → Apps and Gaming → Single Port Forwarding
- **Fritz!Box**: Internet → Permit Access → Port Sharing

Add the following rules (replace `192.168.1.100` with your Debian machine's IP):

| Service Name          | External Port     | Internal IP      | Internal Port | Protocol |
|-----------------------|-------------------|------------------|---------------|----------|
| Matrix HTTP           | 80                | 192.168.1.100    | 80            | TCP      |
| Matrix HTTPS          | 443               | 192.168.1.100    | 443           | TCP      |
| Matrix Federation     | 8448              | 192.168.1.100    | 8448          | TCP      |
| coturn STUN/TURN UDP  | 3478              | 192.168.1.100    | 3478          | UDP      |
| coturn STUN/TURN TCP  | 3478              | 192.168.1.100    | 3478          | TCP      |
| coturn TURNS          | 5349              | 192.168.1.100    | 5349          | TCP      |
| LiveKit media         | 7882              | 192.168.1.100    | 7882          | UDP      |
| coturn relay range    | 49152–65535       | 192.168.1.100    | 49152–65535   | UDP      |

> Some consumer routers do not support port ranges as wide as 49152–65535.
> If your router doesn't allow this, use the `min-port` / `max-port` settings
> in `data/coturn/turnserver.conf` to restrict the range to something your
> router supports (e.g., 50000–55000), and forward only that range.

---

## Step 3: Verify connectivity from outside

Use a tool on your phone (on mobile data, NOT your home WiFi) or an online
port checker service:

```bash
# From an external machine or smartphone on mobile data:
curl http://YOUR.PUBLIC.IP/_matrix/client/versions
# Should return a JSON response with Synapse version info.
```

Online tools:
- https://www.yougetsignal.com/tools/open-ports/
- https://portchecker.co/

---

## Firewall on the Debian machine

The Debian machine itself may have a firewall. Allow the required ports:

```bash
# Using ufw (Uncomplicated Firewall)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 8448/tcp
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp
sudo ufw allow 7882/udp
sudo ufw allow 49152:65535/udp
sudo ufw enable
sudo ufw status
```

---

## ISP-level blocking

Some residential ISPs block inbound connections on ports 80 and 443. If you
have confirmed your router forwarding is correct but external connections still
fail:

1. **Check your ISP's terms of service** – some prohibit running servers.
2. **Call your ISP** and ask if they block inbound ports 80/443. Many will
   unblock them on request.
3. **Upgrade to a business plan** – these typically allow inbound server traffic.
4. **Alternative**: Use a VPS (Virtual Private Server) as a reverse proxy / relay
   if your ISP won't cooperate. A small VPS (€3–5/month) can forward traffic to
   your home server via an SSH tunnel or WireGuard VPN.
