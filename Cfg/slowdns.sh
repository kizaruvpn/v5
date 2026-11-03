#!/bin/bash
# ============================================================
#  slowdns.sh (versi perbaikan) - menu 8.) Install SlowDns
#  Meminta domain NS saat dijalankan. Tanpa verifikasi password,
#  tanpa API Cloudflare pihak lain, tanpa reboot.
# ============================================================
BLUE="\033[36m"; GREEN="\e[92;1m"; NC='\e[0m'
clear
echo ""
echo -e "   ${BLUE}_______________________________${NC}"
echo -e "   ${GREEN}    WELCOME TO SLOWDNS SETUP ${NC}"
echo -e "   ${BLUE}_______________________________${NC}"
echo ""

REPO="${REPO:-https://raw.githubusercontent.com/kizaruvpn/v5/main/}"
SD="${SD:-/etc/systemd/system}"          # folder unit systemd
SLOW="${SLOW:-/etc/slowdns}"             # folder dnstt + key
XRAY="${XRAY:-/etc/xray}"                # folder domain/dns
BACKEND="${BACKEND:-127.0.0.1:143}"      # tujuan tunnel: dropbear (SSH polos)
CLIENT_RESOLVER="${CLIENT_RESOLVER:-1.1.1.1:53}"

G="\e[92;1m"; Y="\033[33m"; B="\033[36m"; R="\033[1;31m"; N="\e[0m"

mkdir -p "$SLOW" "$XRAY"

# ---------- tentukan NS domain ----------
MAIN_DOMAIN=$(cat "$XRAY/domain" 2>/dev/null)
OLD_NS=$(cat "$XRAY/dns" 2>/dev/null)

SUG=""
if [[ -n "$MAIN_DOMAIN" ]]; then
	SUG="ns-${MAIN_DOMAIN%%.*}.${MAIN_DOMAIN#*.}"
fi

if [[ -n "${NS_DOMAIN:-}" ]]; then
	: # diberikan lewat environment
elif [[ -n "$1" ]]; then
	NS_DOMAIN="$1"
else
	echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
	echo -e "   ${G}SETUP SLOWDNS - MASUKKAN DOMAIN NS${N}"
	echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
	[[ -n "$MAIN_DOMAIN" ]] && echo -e " Domain VPS      : ${Y}${MAIN_DOMAIN}${N}"
	[[ -n "$OLD_NS" ]]      && echo -e " NS saat ini     : ${Y}${OLD_NS}${N}"
	echo ""
	echo -e " Buat dulu record di Cloudflare/DNS provider:"
	echo -e "   Type NS | Name <nama-ns> | Nameserver ${Y}${MAIN_DOMAIN:-domain-vps-anda}${N}"
	echo ""
	read -r -p " Domain NS [${SUG}] : " NS_DOMAIN </dev/tty
	NS_DOMAIN=${NS_DOMAIN:-$SUG}
fi

NS_DOMAIN=$(echo "$NS_DOMAIN" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
if ! [[ "$NS_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
	echo -e "${R} Domain NS tidak valid: '${NS_DOMAIN}'${N}"
	exit 1
fi

# peringatan saja (tidak membatalkan): NS belum terbaca di DNS
if command -v dig >/dev/null 2>&1; then
	if [[ -z "$(dig +short NS "$NS_DOMAIN" @1.1.1.1 2>/dev/null)" ]]; then
		echo -e "${Y} Peringatan: record NS untuk ${NS_DOMAIN} belum terbaca (mungkin belum propagasi).${N}"
	fi
fi

# ---------- pasang dnstt ----------
if [[ ! -x "$SLOW/dnstt-server" ]]; then
	wget -q -O "$SLOW/dnstt-server" "${REPO}Fls/dnstt-server" || { echo -e "${R} Gagal unduh dnstt-server${N}"; exit 1; }
	chmod +x "$SLOW/dnstt-server"
fi
if [[ ! -x "$SLOW/dnstt-client" ]]; then
	wget -q -O "$SLOW/dnstt-client" "${REPO}Fls/dnstt-client" || { echo -e "${R} Gagal unduh dnstt-client${N}"; exit 1; }
	chmod +x "$SLOW/dnstt-client"
fi

# key lama dipertahankan supaya public key client tidak berubah
if [[ ! -s "$SLOW/server.key" || ! -s "$SLOW/server.pub" ]]; then
	"$SLOW/dnstt-server" -gen-key -privkey-file "$SLOW/server.key" -pubkey-file "$SLOW/server.pub"
fi

# ---------- unit systemd ----------
cat > "$SD/server.service" <<EOF
[Unit]
Description=Server SlowDNS
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$SLOW/dnstt-server -udp :5300 -privkey-file $SLOW/server.key $NS_DOMAIN $BACKEND
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat > "$SD/client.service" <<EOF
[Unit]
Description=Client SlowDNS
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$SLOW/dnstt-client -udp $CLIENT_RESOLVER --pubkey-file $SLOW/server.pub $NS_DOMAIN 127.0.0.1:88
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

echo "$NS_DOMAIN" > "$XRAY/dns"

# ---------- firewall: UDP 53 -> 5300 (tidak dobel) ----------
if command -v iptables >/dev/null 2>&1 && [[ -z "${SKIP_FW:-}" ]]; then
	iptables -C INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 5300 -j ACCEPT
	iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null   || iptables -I INPUT -p udp --dport 53 -j ACCEPT
	iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null \
		|| iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300
	command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
fi

# ---------- jalankan ----------
if [[ -z "${SKIP_SYSTEMCTL:-}" ]]; then
	systemctl daemon-reload
	systemctl enable server client >/dev/null 2>&1
	systemctl restart server client
	sleep 1
	if systemctl is-active --quiet server; then
		STATUS="${G}AKTIF${N}"
	else
		STATUS="${R}TIDAK AKTIF (cek: journalctl -u server -n 20 --no-pager)${N}"
	fi
fi

echo ""
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e " NS Domain  : ${G}${NS_DOMAIN}${N}"
echo -e " Public Key : ${G}$(cat "$SLOW/server.pub")${N}"
echo -e " Tujuan     : ${BACKEND}"
[[ -n "${STATUS:-}" ]] && echo -e " Service    : ${STATUS}"
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"

echo ""
read -r -p " Tekan Enter untuk kembali ke menu..." _ </dev/tty
command -v menu >/dev/null 2>&1 && menu
