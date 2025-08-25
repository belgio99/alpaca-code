DIR="`pwd`/`dirname "$0"`/"
GREEN="\033[0;32m"
NC="\033[0m"

cat << "EOF"
    _     _      ____    _     ____     _
   / \   | |    |  _ \  / \   / ___|   / \
  / _ \  | |    | |_) |/ _ \ | |      / _ \
 / ___ \ | |___ |  __// ___ \| |___  / ___ \
/_/   \_\|_____||_|  /_/   \_\\____|/_/   \_\

USE WITH CAUTION!

EOF

OS=`uname`

echo -e "${GREEN}Building docker images (THIS WILL TAKE A WHILE!)${NC}"
docker-compose -f servers/docker-compose.yml build --pull -q
docker-compose -f servers/docker-compose.yml pull -q 2> /dev/null

echo -e "${GREEN}Adding additional loopback IP${NC}"
if [ "$OS" = "Darwin" ]; then
   ifconfig lo0 alias 127.0.0.2/8 up
else
   ip addr add 127.0.0.2/8 dev lo
fi

echo -e "${GREEN}Installing dependencies${NC}"

if [ "$OS" = "Darwin" ]; then
   brew install easy-rsa
else
   apt-get install -y easy-rsa
fi

path="/usr/share/easy-rsa/"
if [ "$OS" = "Darwin" ]; then
   path=""
fi
# Always use a local PKI in the repo
PKI_DIR="$DIR/pki"
echo -e "${GREEN}[CERT] Creating PKI${NC}"
${path}easyrsa --pki-dir="$PKI_DIR" init-pki
cat << EOF > "$DIR/pki/vars"
set_var EASYRSA_DN     "cn_only"
set_var EASYRSA_DIGEST "sha512"
set_var EASYRSA_BATCH    "1"
set_var EASYRSA_REQ_CN "alpaca.poc"
EOF
dd if=/dev/urandom of="$DIR/pki/.rnd" bs=256 count=1 2> /dev/null
echo -e "${GREEN}[CERT] Build CA${NC}"
${path}easyrsa --pki-dir="$PKI_DIR" build-ca nopass

#echo -e "${GREEN}[CERT] If you proceed, the generated CA will be added to your trusted CAs. Press any key to proceed${NC}"
#read
#cp "$DIR/pki/ca.crt" /usr/local/share/ca-certificates/alpaca.crt
#update-ca-certificates

echo -e "${GREEN}[CERT] Generating Certificates${NC}"
${path}easyrsa --pki-dir="$PKI_DIR" --req-cn="attacker.com" gen-req attacker.com nopass
${path}easyrsa --pki-dir="$PKI_DIR" sign-req server attacker.com

mkdir -p "$DIR/servers/files/cert/" 2> /dev/null
cp "$PKI_DIR/issued/attacker.com.crt" "$DIR/servers/files/cert/"
cp "$PKI_DIR/private/attacker.com.key" "$DIR/servers/files/cert/"

${path}easyrsa --pki-dir="$PKI_DIR" --req-cn="target.local" gen-req target.local nopass
${path}easyrsa --pki-dir="$PKI_DIR" sign-req server target.local

cp "$PKI_DIR/issued/target.local.crt" "$DIR/servers/files/cert/"
cp "$PKI_DIR/private/target.local.key" "$DIR/servers/files/cert/"

if ! grep ALPACA /etc/hosts >/dev/null 2>&1; then
   echo -e "${GREEN}[HOST] Alter host file${NC}"
   if [ "$OS" = "Darwin" ]; then
      # BSD sed requires a (blank) backup extension
      sed -i '' '/# ALPACA/,/# END ALPACA/d' /etc/hosts
   else
      sed -i '/# ALPACA/,/# END ALPACA/d' /etc/hosts
   fi
   echo "# ALPACA" >> /etc/hosts
   echo "127.0.0.1    attacker.com" >> /etc/hosts
   echo "127.0.0.2    target.local" >> /etc/hosts
   echo "# END ALPACA" >> /etc/hosts
fi
