#!/bin/bash
# =====================================================================
#  SlowDNS (dnstt) manager  -  install / ganti domain / info
#
#  Pemakaian:
#     slowdns            -> menu (install bila belum terpasang)
#     slowdns install    -> pasang / pasang ulang
#     slowdns domain     -> ganti domain NS (custom domain)
#     slowdns info       -> tampilkan domain, public key & record DNS
#
#  Non-interaktif (opsional, lewat environment):
#     SLOWDNS_NS=sl.domainku.com          domain tunnel (wajib utk non-interaktif)
#     SLOWDNS_TARGET=vps.domainku.com     host NS target (default: /etc/xray/domain)
#     CF_TOKEN=xxxx                       API Token Cloudflare milik sendiri
#                                         (bila diisi, record NS dibuat otomatis)
#     SLOWDNS_UPSTREAM=127.0.0.1:22       tujuan forward (default SSH 22)
# =====================================================================

REPO="${REPO:-https://raw.githubusercontent.com/kizaruvpn/v5/main/}"
case "$REPO" in */) ;; *) REPO="${REPO}/" ;; esac

DIR=/etc/slowdns
SERVICE=/etc/systemd/system/server.service
UPSTREAM="${SLOWDNS_UPSTREAM:-127.0.0.1:22}"
LISTEN_PORT=5300

G="\e[92;1m"; R="\033[1;31m"; Y="\033[33m"; B="\033[36m"; N="\e[0m"
line() { echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }
ok()   { echo -e "${G}[ OK ]${N} $*"; }
warn() { echo -e "${Y}[ !! ]${N} $*"; }
err()  { echo -e "${R}[ERR ]${N} $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Jalankan sebagai root."; exit 1; }

# --------------------------------------------------------------------
#  Helper
# --------------------------------------------------------------------
need_pkg() {
	command -v "$1" >/dev/null 2>&1 && return 0
	apt-get install -y "${2:-$1}" >/dev/null 2>&1
}

valid_domain() {
	[[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

get_ip() {
	local ip
	for u in https://ipinfo.io/ip https://api.ipify.org https://ifconfig.me; do
		ip=$(curl -fsS --max-time 8 "$u" 2>/dev/null) && [[ "$ip" =~ ^[0-9.]+$ ]] && { echo "$ip"; return; }
	done
}

# --------------------------------------------------------------------
#  Binary + key
# --------------------------------------------------------------------
fetch_binary() {
	local name="$1" tmp
	tmp=$(mktemp)
	if wget -q -O "$tmp" "${REPO}Fls/${name}" && [[ $(head -c4 "$tmp" | tail -c3) == "ELF" ]]; then
		install -m 755 "$tmp" "$DIR/$name"
		rm -f "$tmp"
		return 0
	fi
	rm -f "$tmp"
	# pakai binary lama bila sudah ada
	[[ -x "$DIR/$name" ]] && { warn "Gagal download $name, memakai binary yang sudah ada."; return 0; }
	err "Gagal download $name dari ${REPO}Fls/${name}"
	return 1
}

install_files() {
	mkdir -p "$DIR" /etc/xray
	fetch_binary dnstt-server || return 1
	fetch_binary dnstt-client || true
	# key hanya dibuat sekali. Jangan ditimpa agar client lama tetap jalan.
	if [[ ! -s "$DIR/server.key" || ! -s "$DIR/server.pub" ]]; then
		"$DIR/dnstt-server" -gen-key -privkey-file "$DIR/server.key" -pubkey-file "$DIR/server.pub" >/dev/null 2>&1
	fi
	[[ -s "$DIR/server.pub" ]] || { err "Gagal membuat key SlowDNS."; return 1; }
	chmod 600 "$DIR/server.key"
	chmod 644 "$DIR/server.pub"
}

# --------------------------------------------------------------------
#  Cloudflare (opsional, pakai API Token milik user sendiri)
# --------------------------------------------------------------------
cf_api() { # method path [json]
	curl -fsS -X "$1" "https://api.cloudflare.com/client/v4$2" \
		-H "Authorization: Bearer ${CF_TOKEN}" \
		-H "Content-Type: application/json" ${3:+--data "$3"}
}

cf_set_ns_record() { # name content
	local name="$1" content="$2" zone="" probe="$1" rec body res
	need_pkg jq || { err "jq tidak terpasang."; return 1; }
	while [[ "$probe" == *.* ]]; do
		zone=$(cf_api GET "/zones?name=${probe}&status=active" 2>/dev/null | jq -r '.result[0].id // empty')
		[[ -n "$zone" ]] && break
		probe="${probe#*.}"
	done
	[[ -z "$zone" ]] && { err "Zone Cloudflare untuk ${name} tidak ditemukan / token tidak punya akses."; return 1; }

	body=$(jq -nc --arg n "$name" --arg c "$content" '{type:"NS",name:$n,content:$c,ttl:1}')
	rec=$(cf_api GET "/zones/${zone}/dns_records?type=NS&name=${name}" | jq -r '.result[0].id // empty')
	if [[ -n "$rec" ]]; then
		res=$(cf_api PUT "/zones/${zone}/dns_records/${rec}" "$body")
	else
		res=$(cf_api POST "/zones/${zone}/dns_records" "$body")
	fi
	if [[ $(echo "$res" | jq -r '.success') == "true" ]]; then
		ok "Record NS ${name} -> ${content} tersimpan di Cloudflare (zone ${probe})."
	else
		err "Cloudflare menolak: $(echo "$res" | jq -r '.errors[0].message // "unknown"')"
		return 1
	fi
}

# --------------------------------------------------------------------
#  Input domain
# --------------------------------------------------------------------
ask_domain() {
	local cur xdom mode
	cur=$(cat /etc/xray/dns 2>/dev/null)
	xdom=$(cat /etc/xray/domain 2>/dev/null)
	TARGET="${SLOWDNS_TARGET:-$xdom}"

	if [[ -n "$SLOWDNS_NS" ]]; then
		NS_DOMAIN="${SLOWDNS_NS,,}"
		[[ -n "$CF_TOKEN" ]] && mode=2 || mode=1
	else
		line
		echo -e "              ${G}DOMAIN SLOWDNS${N}"
		line
		[[ -n "$cur" ]] && echo -e " Domain sekarang : ${Y}${cur}${N}\n"
		echo " 1) Domain sendiri  (record NS dibuat manual di DNS)"
		echo " 2) Domain sendiri  (record NS dibuat otomatis via Cloudflare)"
		echo ""
		read -rp " Pilih [1-2] (default 1) : " mode
		[[ "$mode" != "2" ]] && mode=1
		echo ""
		echo -e " Masukkan domain tunnel SlowDNS, contoh: ${Y}sl.domainku.com${N}"
		echo -e " (bukan domain utama, pakai subdomain khusus)"
		read -rp " Domain NS : " NS_DOMAIN
		NS_DOMAIN="${NS_DOMAIN,,}"
		if [[ -z "$TARGET" ]]; then
			read -rp " Host target NS (A record ke IP VPS ini) : " TARGET
		fi
		if [[ "$mode" == "2" ]]; then
			read -rsp " Cloudflare API Token (izin Zone:DNS:Edit) : " CF_TOKEN
			echo ""
		fi
	fi

	TARGET="${TARGET,,}"
	if ! valid_domain "$NS_DOMAIN"; then
		err "Domain NS tidak valid: '${NS_DOMAIN}'"
		return 1
	fi
	if ! valid_domain "$TARGET"; then
		err "Host target NS tidak valid: '${TARGET}'. Isi /etc/xray/domain atau set SLOWDNS_TARGET."
		return 1
	fi
	if [[ "$NS_DOMAIN" == "$TARGET" ]]; then
		err "Domain NS tidak boleh sama dengan host target. Gunakan subdomain khusus, mis. sl.${TARGET#*.}"
		return 1
	fi

	if [[ "$mode" == "2" ]]; then
		cf_set_ns_record "$NS_DOMAIN" "$TARGET" || warn "Buat record NS secara manual (lihat info di bawah)."
	fi
	mkdir -p /etc/xray
	echo "$NS_DOMAIN" > /etc/xray/dns
	echo "$TARGET" > "$DIR/target"
}

# --------------------------------------------------------------------
#  Service + firewall
# --------------------------------------------------------------------
write_service() {
	local ns; ns=$(cat /etc/xray/dns)
	cat > "$SERVICE" <<EOF
[Unit]
Description=Server SlowDNS (dnstt)
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=65535
ExecStart=${DIR}/dnstt-server -udp :${LISTEN_PORT} -privkey-file ${DIR}/server.key ${ns} ${UPSTREAM}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
	# client.service lama memakai resolver pihak ketiga yang di-hardcode, tidak dipakai di server
	if [[ -f /etc/systemd/system/client.service ]]; then
		systemctl disable --now client >/dev/null 2>&1
		rm -f /etc/systemd/system/client.service
	fi
	systemctl daemon-reload
	systemctl enable server >/dev/null 2>&1
	systemctl restart server
}

fw_rule() { # table chain args...
	local t="$1"; shift
	iptables -t "$t" -C "$@" 2>/dev/null || iptables -t "$t" -I "$@"
}

setup_firewall() {
	fw_rule filter INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT
	fw_rule filter INPUT -p udp --dport 53 -j ACCEPT
	fw_rule nat PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$LISTEN_PORT"
	command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
}

# --------------------------------------------------------------------
#  Info
# --------------------------------------------------------------------
show_info() {
	local ns pub target ip
	ns=$(cat /etc/xray/dns 2>/dev/null)
	pub=$(cat "$DIR/server.pub" 2>/dev/null)
	target=$(cat "$DIR/target" 2>/dev/null || cat /etc/xray/domain 2>/dev/null)
	ip=$(get_ip)
	line
	echo -e "                ${G}INFO SLOWDNS${N}"
	line
	echo -e " NS Domain  : ${Y}${ns}${N}"
	echo -e " Public Key : ${Y}${pub}${N}"
	echo -e " Port UDP   : 53 (redirect ke ${LISTEN_PORT})"
	echo -e " Forward ke : ${UPSTREAM}"
	line
	echo -e " Record DNS yang harus ada (DNS only / awan abu-abu):"
	echo -e "   ${Y}A    ${target}  ->  ${ip:-IP_VPS}${N}"
	echo -e "   ${Y}NS   ${ns}  ->  ${target}${N}"
	line
	if systemctl is-active --quiet server; then
		ok "service server : aktif"
	else
		err "service server : TIDAK aktif (cek: journalctl -u server -n 30)"
	fi
	if ss -lunp 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
		ok "UDP ${LISTEN_PORT} : listening"
	else
		err "UDP ${LISTEN_PORT} : tidak listening"
	fi
	if command -v dig >/dev/null 2>&1; then
		local got; got=$(dig +short NS "$ns" @1.1.1.1 2>/dev/null | head -1)
		if [[ "${got%.}" == "$target" ]]; then ok "DNS NS ${ns} sudah mengarah ke ${target}"
		else warn "DNS NS ${ns} belum terdeteksi (hasil: ${got:-kosong}). Propagasi bisa butuh beberapa menit."; fi
	fi
	line
}

# --------------------------------------------------------------------
#  Aksi
# --------------------------------------------------------------------
do_install() {
	need_pkg wget; need_pkg curl; need_pkg jq
	install_files || return 1
	ask_domain    || return 1
	write_service
	setup_firewall
	install_self
	sleep 1
	show_info
}

do_domain() {
	[[ -x "$DIR/dnstt-server" ]] || { warn "SlowDNS belum terpasang, menjalankan install..."; do_install; return; }
	ask_domain || return 1
	write_service
	setup_firewall
	sleep 1
	show_info
}

install_self() {
	# pasang perintah `slowdns` agar bisa ganti domain kapan saja
	local me; me=$(readlink -f "$0" 2>/dev/null)
	if [[ -n "$me" && -f "$me" && "$me" != /usr/local/sbin/slowdns ]]; then
		install -m 755 "$me" /usr/local/sbin/slowdns 2>/dev/null
	fi
}

menu() {
	clear
	line
	echo -e "               ${G}SLOWDNS MANAGER${N}"
	line
	echo " 1) Install / pasang ulang SlowDNS"
	echo " 2) Ganti domain SlowDNS (custom domain)"
	echo " 3) Info & cek status"
	echo " 4) Restart service"
	echo " 0) Keluar"
	line
	read -rp " Pilih : " c
	case "$c" in
		1) do_install ;;
		2) do_domain ;;
		3) show_info ;;
		4) systemctl restart server && ok "server direstart"; show_info ;;
		*) exit 0 ;;
	esac
}

case "${1:-}" in
	install) do_install ;;
	domain)  do_domain ;;
	info)    show_info ;;
	restart) systemctl restart server && show_info ;;
	"")      if [[ -x "$DIR/dnstt-server" && -s /etc/xray/dns ]]; then menu; else do_install; fi ;;
	*)       echo "Pemakaian: slowdns [install|domain|info|restart]"; exit 1 ;;
esac
