# Installing Remnawave X

A practical guide for the [samur005/remnawave-reverse-proxy-X](https://github.com/samur005/remnawave-reverse-proxy-X) installer (`main` branch, script version `3.8.4-x.2`). This is a fork of the eGames installer: it can deploy official Remnawave or the **Remnawave X** edition with qWDTT.

Русская версия: [install.md](./install.md).

## Requirements

- **OS:** Debian 11/12 or Ubuntu 22.04/24.04 (the script checks this on start).
- **Privileges:** root. A fresh machine and KVM virtualization are recommended.
- **Docker and Docker Compose** are installed by the script if missing.
- **Domains:** three distinct names that resolve to this server’s IP:
  - the control panel;
  - the subscription page;
  - selfsteal / node (the camouflage site on the node).
  You can use your own domains or free names such as `panel.<IP>.sslip.io`, `sub.<IP>.sslip.io`, `node.<IP>.sslip.io`, as long as they actually resolve to the server. The selfsteal domain must not sit behind a Cloudflare proxy (DNS Only only). All three names must be unique.
- **Ports** (the script opens them in ufw):
  - SSH (22/tcp, or whatever port `sshd` listens on);
  - 80/tcp (certificate issuance);
  - 443/tcp (HTTPS and Xray);
  - for qWDTT on the node: **56000/tcp and 56000/udp** (peer), **56001/udp** (sidecar WireGuard), **56003/udp** (raw).
  Do not open client port `9000` on the server: it is local to the phone. If you change sidecar ports in the panel, open those instead of the defaults.
- Port 443 must not be taken by another service.

## How to run the installer

On a clean server as root:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/samur005/remnawave-reverse-proxy-X/refs/heads/main/install_remnawave.sh)
```

If GitHub is unreachable, the jsDelivr mirror:

```bash
bash <(curl -Ls https://cdn.jsdelivr.net/gh/samur005/remnawave-reverse-proxy-X@main/install_remnawave.sh)
```

The script fetches the rest of the modules from the same `main` branch. After the first install you can use the short `rr` command (`remnawave_reverse`).

In the menu choose **Install Remnawave X Components**. Options:

1. Panel and node on one server — the simplest path.
2. Panel and subscription page.
3. Panel only.
4. Subscription page only.
5. Add a node to an existing panel.
6. Node only.

The script then asks which web server to use (NGINX or Caddy) and for the domains.

## Official vs Remnawave X

On the first install (if no edition is saved yet) the script asks which images to use:

1. **Official Remnawave** — `remnawave/backend:3` and `remnawave/node:latest`. No qWDTT UI.
2. **Remnawave X with qWDTT** — `ghcr.io/samur005/backend-x:3` and `ghcr.io/samur005/node-x:latest`. The panel gets a qWDTT section; the node runs the sidecar.

The subscription page stays official in both cases: `remnawave/subscription-page:latest`.

The choice is stored in `/usr/local/remnawave_reverse/edition` (`official` or `custom`). You can change it later in the panel management menu: “Switch Official / Remnawave X images”. A plain `docker compose pull` will not replace panel and node images with the other edition: the installer rewrites `image:` lines to match the saved edition. The `:3` tag on `backend-x` tracks the Remnawave X line (including builds such as `3.4.11-x.6`).

qWDTT requires the Remnawave X edition (option 2).

## What to enter for the panel, subscription and node

The script asks for three domains, for example:

- panel: `panel.example.com` or `panel.203.0.113.10.sslip.io`;
- subscription: `sub.example.com` or `sub.203.0.113.10.sslip.io`;
- node selfsteal: `node.example.com` or `node.203.0.113.10.sslip.io`.

They must be different names pointing at this server. The script checks DNS and issues Let’s Encrypt certificates. If a domain’s IP does not match the server, installation stops with a hint.

## After installation

At the end the script prints the administrator **username and password** and (when cookie protection is on) the **login URL** that sets the access cookie. Save them immediately: they are shown in the terminal and are not written to a credentials file. Without that URL the panel hostname may show a camouflage site instead of the login form.

After install:

- panel: `https://<panel-domain>/`;
- subscription: `https://<subscription-domain>/`;
- node / selfsteal: `https://<node-domain>/`;
- panel stack: **`/opt/remnawave`** (`docker-compose.yml`, `.env`, Caddyfile or nginx.conf);
- a standalone node lives in **`/opt/remnanode`**.

Further management is the `rr` command: status, logs, updates, CLI, edition switch.

## qWDTT after install (Remnawave X only)

qWDTT is a sidecar on the node, not an Xray inbound. It does not replace existing Reality hosts.

1. In the panel open **qWDTT**. Enable the integration, save VK cookies, generate hashes (or turn on automatic maintenance). Under “Assigned nodes” select the nodes that should run the sidecar. An empty list means no nodes; new nodes are not added automatically.
2. “Subscription host (fallback)” (`subHost`) is **not** each node’s domain and does not need to be edited when you add nodes. It is only a fallback peer when the host address is empty and the node address is private.
3. For distinct locations in the subscription, create **qWDTT hosts**: Hosts → New host → type **qWDTT**. Set the remark (the name/location the client sees), exactly one node in “Node (location)”, and the address and port (default 56000). The address may be left empty: the node’s public address is used. Private addresses such as `10/8`, `172.16/12`, `192.168/16`, `127/8` are never put in the subscription. If no public peer can be resolved, the host is skipped and the form shows a warning.
4. Enable qWDTT on an internal squad (or grant a user access manually). Members of that squad get separate `qwdtt://` lines in the regular base64 subscription — one per eligible host, with that host’s name and the node’s public peer.

## Updates and images

- Update the installer and the stack from the `rr` menu (panel management / update). For the Remnawave X edition this pulls `ghcr.io/samur005/backend-x` and `ghcr.io/samur005/node-x`; the subscription page stays official `remnawave/subscription-page`.
- Panel images: [ghcr.io/samur005/backend-x](https://github.com/samur005/backend-X/pkgs/container/backend-x). Tags `:3` and `:latest` move with the line; you can pin a specific one such as `3.4.11-x.6`.
- The panel frontend is baked into `backend-x` from [samur005/frontend-X](https://github.com/samur005/frontend-X/releases) releases (`remnawave-frontend.zip`).
- Node image: [ghcr.io/samur005/node-x](https://github.com/samur005/node-X/pkgs/container/node-x), usually the `:latest` tag.
- Before an update the installer copies compose and `.env` to `/opt/remnawave/backup/update-<timestamp>/` and can roll back if the stack fails to come up.

Panel, frontend and node code: [backend-X](https://github.com/samur005/backend-X), [frontend-X](https://github.com/samur005/frontend-X), [node-X](https://github.com/samur005/node-X). Upstream Remnawave docs: [docs.rw](https://docs.rw/).
