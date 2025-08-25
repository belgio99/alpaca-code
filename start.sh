#!/usr/bin/env bash
set -euo pipefail

# One-click launcher for the ALPACA lab with selectable target protocol (ftp|imap).
# - Sets loopback alias (127.0.0.2)
# - Ensures /etc/hosts for attacker.com / target.local
# - Generates CA and server certs via Docker (openssl)
# - Starts compose services for web + selected server
# - Runs the MITM proxy inside the compose network (press any key to arm)

MODE="${1:-ftp}"  # ftp (vsftpd) | imap (cyrus)

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVERS_DIR="$REPO_DIR/testlab/servers"
CERT_DIR="$SERVERS_DIR/files/cert"
PKI_DIR="$REPO_DIR/testlab/pki"
MITM_DIR="$REPO_DIR/testlab/mitmproxy"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}ALPACA lab bootstrap (mode: ${MODE})${NC}"

detect_compose() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		echo "docker compose"
	elif command -v docker-compose >/dev/null 2>&1; then
		echo "docker-compose"
	else
		return 1
	fi
}

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo -e "${RED}Missing required command: $1${NC}" >&2
		exit 1
	fi
}

require_cmd docker
COMPOSE_CMD="$(detect_compose)" || { echo -e "${RED}Neither 'docker compose' nor 'docker-compose' found.${NC}"; exit 1; }

# Ask sudo once (needed for loopback alias and /etc/hosts) and keep alive
OS="$(uname -s)"
if [[ "$OS" == "Darwin" || "$OS" == "Linux" ]]; then
	echo -e "${GREEN}Acquiring sudo for network and hosts changes...${NC}"
	sudo -v || true
	while true; do sudo -n true; sleep 60; kill -0 "$" 2>/dev/null || exit; done 2>/dev/null &
fi

echo -e "${GREEN}Step 1/5: Configure loopback alias (127.0.0.2)${NC}"
if [[ "$OS" == "Darwin" ]]; then
	if ifconfig lo0 | grep -q "127.0.0.2"; then
		echo "lo0 already has 127.0.0.2"
	else
		sudo ifconfig lo0 alias 127.0.0.2/8 up
	fi
else
	if ip addr show dev lo | grep -q "127.0.0.2"; then
		echo "lo already has 127.0.0.2"
	else
		sudo ip addr add 127.0.0.2/8 dev lo || true
	fi
fi

echo -e "${GREEN}Step 2/5: Ensure /etc/hosts entries${NC}"
if ! grep -q "attacker.com" /etc/hosts || ! grep -q "target.local" /etc/hosts; then
	echo -e "${YELLOW}Adding ALPACA hosts block to /etc/hosts${NC}"
	sudo sh -c 'printf "\n# ALPACA\n127.0.0.1    attacker.com\n127.0.0.2    target.local\n# END ALPACA\n" >> /etc/hosts'
else
	echo "Entries for attacker.com and target.local already present."
fi

echo -e "${GREEN}Step 3/5: Generate CA and server certificates (in Docker)${NC}"
mkdir -p "$PKI_DIR" "$CERT_DIR"
docker run --rm \
	-v "$REPO_DIR":/work -w /work \
	alpine:3.19 sh -euxc '
		apk add --no-cache openssl
		mkdir -p testlab/pki testlab/servers/files/cert

		if [ ! -f testlab/pki/ca.crt ] || [ ! -f testlab/pki/ca.key ]; then
			openssl genrsa -out testlab/pki/ca.key 4096
			openssl req -x509 -new -nodes -key testlab/pki/ca.key -sha256 -days 3650 \
				-out testlab/pki/ca.crt -subj "/CN=ALPACA Test CA"
		fi

		cat > testlab/pki/target.local.ext <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = target.local
EOF

		cat > testlab/pki/attacker.com.ext <<EOF
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = attacker.com
EOF

		if [ ! -f testlab/servers/files/cert/target.local.crt ] || [ ! -f testlab/servers/files/cert/target.local.key ]; then
			openssl genrsa -out testlab/pki/target.local.key 2048
			openssl req -new -key testlab/pki/target.local.key -out testlab/pki/target.local.csr -subj "/CN=target.local"
			openssl x509 -req -in testlab/pki/target.local.csr -CA testlab/pki/ca.crt -CAkey testlab/pki/ca.key -CAcreateserial \
				-out testlab/servers/files/cert/target.local.crt -days 825 -sha256 -extfile testlab/pki/target.local.ext
			cp testlab/pki/target.local.key testlab/servers/files/cert/
		fi

		if [ ! -f testlab/servers/files/cert/attacker.com.crt ] || [ ! -f testlab/servers/files/cert/attacker.com.key ]; then
			openssl genrsa -out testlab/pki/attacker.com.key 2048
			openssl req -new -key testlab/pki/attacker.com.key -out testlab/pki/attacker.com.csr -subj "/CN=attacker.com"
			openssl x509 -req -in testlab/pki/attacker.com.csr -CA testlab/pki/ca.crt -CAkey testlab/pki/ca.key -CAcreateserial \
				-out testlab/servers/files/cert/attacker.com.crt -days 825 -sha256 -extfile testlab/pki/attacker.com.ext
			cp testlab/pki/attacker.com.key testlab/servers/files/cert/
		fi
	'

echo -e "${YELLOW}Action required:${NC} import the CA into your browser (Firefox Authorities or macOS Keychain for Safari/Chrome)."

echo -e "${GREEN}Step 4/5: Build and start docker services${NC}"
pushd "$SERVERS_DIR" >/dev/null
$COMPOSE_CMD build --pull -q || true
case "$MODE" in
	ftp)
		$COMPOSE_CMD up -d nginx-proxy nginx-target nginx-attacker vsftp
		TARGET_HOST="alpaca-vsftp"
		TARGET_PORT=21
		PROTOCOL="FTP"
		ATTACK_HINT="https://attacker.com/download/ftps-raw.html (or /download/ftps.html)"
		;;
		imap)
			# Use courier instead of cyrus (cyrus base image is deprecated on Docker Hub)
			$COMPOSE_CMD up -d nginx-proxy nginx-target nginx-attacker courier
			TARGET_HOST="alpaca-courier"
			TARGET_PORT=143
			PROTOCOL="IMAP"
			ATTACK_HINT="https://attacker.com/download/imap.html (click Submit)"
		;;
			pop3)
				$COMPOSE_CMD up -d nginx-proxy nginx-target nginx-attacker courier
				TARGET_HOST="alpaca-courier"
				TARGET_PORT=110
				PROTOCOL="POP3"
				ATTACK_HINT="https://attacker.com/download/pop3.html (click Submit)"
				;;
	*)
		echo -e "${RED}Unknown mode: $MODE (use: ftp | imap)${NC}"
		exit 1
		;;
esac
popd >/dev/null

echo -e "${GREEN}Step 5/5: Start MITM proxy (interactive)${NC}"
COMPOSE_NET="servers_default"
if ! docker network inspect "$COMPOSE_NET" >/dev/null 2>&1; then
	echo -e "${YELLOW}Warning:${NC} docker network $COMPOSE_NET not found. Using default bridge; connectivity may fail."
	COMPOSE_NET="bridge"
fi

echo -e "MITM listening on 127.0.0.2:443; unarmed forward -> alpaca-nginx-proxy:443; armed target -> $TARGET_HOST:$TARGET_PORT ($PROTOCOL)"
echo -e "1) Visit https://target.local (disarmed)\n2) Press any key in the MITM to arm\n3) Open $ATTACK_HINT"

docker run --rm -it \
	--network "$COMPOSE_NET" \
	-p 127.0.0.2:443:443 \
	-v "$MITM_DIR":/app \
	-w /app \
	python:3.11-slim \
	python main.py "$TARGET_HOST" "$TARGET_PORT" --unarmed_ip alpaca-nginx-proxy --unarmed_port 443 --attacker_ip 0.0.0.0 --protocol "$PROTOCOL" --log_level INFO

