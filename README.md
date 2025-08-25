# ALPACA Lab — Quick Start Guide

This repository contains a one‑click test lab to reproduce the ALPACA attack locally using Docker, with improvements from the original demo. The `start.sh` script prepares the environment (hostnames, certificates, Docker services) and starts a TLS MITM that reroutes traffic from the legitimate website to the selected target service (FTP/IMAP/POP3).

> Educational and research use only. Run in an isolated environment. This is a demonstrative setup; some up‑to‑date server images may already be fixed (see notes and limitations).

## Prerequisites

- macOS or Linux with sudo privileges
- Docker Desktop (macOS) or Docker Engine (Linux)
- One of the following:
  - docker compose v2 (recommended)
  - docker‑compose (legacy)
- A desktop browser (Firefox recommended for managing custom CAs) or macOS Keychain (for Safari/Chrome)

## Quick start

- FTP (vsftpd — main working demo):
  - `./start.sh` or `./start.sh ftp`
- IMAP (courier):
  - `./start.sh imap`
- POP3 (courier):
  - `./start.sh pop3`

The script will request sudo in order to:

- add the loopback alias `127.0.0.2`
- write entries to `/etc/hosts`:
  - `attacker.com → 127.0.0.1`
  - `target.local → 127.0.0.2`
- generate and place certificates (inside Docker) under `testlab/pki` and `testlab/servers/files/cert`

Once bootstrap is finished, a TLS MITM will be listening on `127.0.0.2:443`.

## Background

ALPACA (Application Layer Protocol Confusion — Analyzing and mitigating cross‑protocol attacks on TLS) is a class of attacks that exploit the fact that TLS authenticates endpoints by hostname but does not bind the TLS session to a specific application protocol. If multiple TLS‑enabled services (e.g., HTTPS and FTPS/IMAPS/POP3S) share the same certificate/hostname or are considered interchangeable by the client, an active network attacker can redirect a victim’s HTTPS request to a different TLS service that understands the TCP/TLS layer but interprets the application data differently.

Key points:

- Threat model: active MitM with the ability to redirect connections between TLS services that share a certificate/hostname or are otherwise accepted by the client.
- Root cause: lack of protocol channel binding in TLS and weak cross‑protocol separation at the application layer.
- Typical vectors: redirecting HTTPS requests to FTPS/IMAPS/POP3S/SMTPS and leveraging web browser behaviors (cookies, redirects, POST bodies) to cause meaningful actions on the target service.
- Impact examples: cross‑protocol request smuggling, reflected content disclosure, credential or session leakage, unintended file retrieval or upload on FTP, message injection on mail protocols.

Preconditions for a practical exploit (varies by target):

- A browser or client that accepts the certificate for both the web origin and the alternate TLS service (same hostname or a CA trusted for both).
- A reachable alternate TLS service (FTP/IMAP/POP3/SMTP over TLS) that processes the redirected payload in a useful way.
- An attacker‑controlled page capable of triggering cross‑origin requests from the victim (e.g., JavaScript in the attacker origin).

Mitigations (defense in depth):

- Use distinct certificates/hostnames per protocol and avoid sharing wildcard certificates across heterogeneous services.
- Enforce ALPN on clients and servers to ensure protocol agreement; reject connections when the negotiated protocol does not match expectations.
- Implement strict SNI and virtual host mapping so that non‑HTTPS services do not accept certificates/hostnames intended for the web origin.
- On servers: normalize and strictly parse inputs; avoid side effects from arbitrary binary payloads.
- On browsers/clients: use channel binding and bind cookies/sessions to the expected protocol where possible.

References:

- ALPACA website and paper: <https://alpaca-attack.com/>
- Original paper: “ALPACA: Application Layer Protocol Confusion — Analyzing and Mitigating Cross‑Protocol Attacks on TLS” (USENIX Security ’21)

## Detailed attack steps (FTP — recommended)

1. Start the lab: run `./start.sh` (default mode `ftp`) and wait for the message “MITM listening on 127.0.0.2:443 …”.

1. Import the test CA: `testlab/pki/ca.crt` (generated on first run). On macOS (Keychain Access) import it into System certificates and set it to “Always Trust”. In Firefox: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import `ca.crt` → trust for websites.

1. Prime the legitimate HTTPS context: visit `https://target.local`. The page sets a session cookie for the legitimate domain (you’ll see a message with the session_id).

1. Arm the MITM: in the MITM terminal window (the one running `python main.py`), press any key when prompted to switch to the armed mode.

1. Launch the attack from the attacker site: visit `https://attacker.com`. For FTP, use `https://attacker.com/download/ftps.html` (or `ftps-raw.html`). After ~5 seconds the browser will redirect to `https://target.local`; on the FTP backend you’ll see cleartext requests correlated with the session.

Tip (vsftpd logs):

- Open a second terminal and, from the repo root, run one of the following to follow FTP logs:

  - docker compose v2:

    ```fish
    cd testlab/servers
    docker compose exec vsftp tail -f /var/log/vsftpd.log /home/vsftpd/bob/leak
    ```

  - docker‑compose (legacy):

    ```fish
    ./testlab/scripts/show_vsftp_log.sh
    ```

## Other protocols (IMAP/POP3)

- Start:
  - IMAP: `./start.sh imap` → attack page: `https://attacker.com/download/imap.html`
  - POP3: `./start.sh pop3` → attack page: `https://attacker.com/download/pop3.html`
- The operational flow is identical to FTP: first visit `https://target.local`, arm the MITM, then open the attack page.
- Note: many recent mail server images include mitigations; the exploit may not complete as in the FTP case, though the cross‑protocol flow will still be visible.

## What exactly `start.sh` does

1. Detects `docker compose`/`docker-compose`
2. Adds the `127.0.0.2` alias to the loopback (macOS: `lo0`; Linux: `lo`)
3. Appends an “ALPACA” block to `/etc/hosts`
4. Generates a CA and two server certificates (for `target.local` and `attacker.com`) in an Alpine container via OpenSSL
5. Builds and starts services with Docker Compose (Nginx reverse proxy, target site, attacker site, and the selected target server)
6. Starts a TLS MITM in a Python container, bound to `127.0.0.2:443`

## Stop and cleanup

- Stop services:

  ```fish
  cd testlab/servers
  docker compose down
  ```

  (or `docker-compose down`)

- Stop the MITM: terminate the process in the terminal (Ctrl+C)

- Remove the loopback alias:

  macOS:

  ```fish
  sudo ifconfig lo0 -alias 127.0.0.2
  ```

  Linux:

  ```fish
  sudo ip addr del 127.0.0.2/8 dev lo
  ```

- Restore `/etc/hosts` (optional): manually remove the “# ALPACA … # END ALPACA” block appended by `start.sh`

## Troubleshooting

- Port 443 in use: close services that bind to 443 on localhost. The MITM uses `127.0.0.2:443`; the Nginx reverse proxy uses `127.0.0.1:443` — they must not overlap.
- CA not trusted / TLS warnings: make sure you imported and trusted `testlab/pki/ca.crt` in the browser you’re using.
- Missing sudo privileges: the script needs sudo for the loopback alias and editing `/etc/hosts`.
- `docker compose` not found: install Docker Desktop (macOS) or Docker Engine + compose plugin, or use legacy `docker-compose`.
- Containers not responding: verify the `servers_default` Docker network exists (`docker network ls`) and that containers are “healthy” (`docker ps`).
- Browser cache: use a private window or clear cache/cookies between attempts.

## Relevant structure

- `start.sh`: full 5‑step bootstrap and MITM startup
- `testlab/servers/docker-compose.yml`: web services and target servers (vsftpd/courier)
- `testlab/servers/files/nginx-attacker/html/`: PoC pages (`download/ftps.html`, `imap.html`, `pop3.html`, etc.)
- `testlab/servers/files/nginx-target/html/index.php`: page that sets the cookie on `target.local`
- `testlab/mitmproxy/main.py`: TLS MITM that forwards to the chosen protocol in clear
- `testlab/pki/`: generated CA and certificates

## Notes and limitations

- In the original testlab the FTP/vsftpd scenario showed the full impact. IMAP/POP3 may already include patches reducing the attack’s effect.
- The provided configurations and certificates are for local testing only.
- https://target.local was used instead of https://target.com to avoid conflicts with real domains.

—
For questions or improvements, please open an issue or submit a PR.
