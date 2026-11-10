#!/bin/bash
# Pasang reseller-api di VPS (script v5).
# Satu perintah:
#   wget -qO- https://raw.githubusercontent.com/kizaruvpn/v5/main/Bot/install-reseller-api.sh | bash -s -- <AUTH_KEY> [PORT] [IP_BOT]
# Pemakaian: bash install-reseller-api.sh <AUTH_KEY> [PORT=5889] [IP_BOT]
#   AUTH_KEY : harus SAMA dengan kolom "auth" server tsb. di database bot
#   IP_BOT   : (disarankan) IP VPS tempat bot berjalan, supaya port hanya bisa diakses bot
set -e
KEY="$1"; PORT="${2:-5889}"; BOT_IP="$3"
REPO_RAW="https://raw.githubusercontent.com/kizaruvpn/v5/main/Bot"
[ -z "$KEY" ] && { echo "Pemakaian: bash install-reseller-api.sh <AUTH_KEY> [PORT] [IP_BOT]"; exit 1; }
[ "$(id -u)" -ne 0 ] && { echo "Jalankan sebagai root."; exit 1; }
command -v python3 >/dev/null || apt-get install -y python3

mkdir -p /etc/kyt
umask 077
printf '%s' "$KEY" > /etc/kyt/reseller-api.key
chmod 600 /etc/kyt/reseller-api.key
umask 022

# Pakai file lokal kalau ada di folder yang sama, kalau tidak unduh dari repo
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp)"
if [ -f "$DIR/reseller-api.py" ]; then
  cp "$DIR/reseller-api.py" "$TMP"
else
  command -v wget >/dev/null || apt-get install -y wget
  wget -qO "$TMP" "$REPO_RAW/reseller-api.py" || { echo "Gagal mengunduh reseller-api.py dari repo."; rm -f "$TMP"; exit 1; }
fi
python3 -m py_compile "$TMP" || { echo "reseller-api.py tidak valid, instalasi dibatalkan."; rm -f "$TMP"; exit 1; }
install -m 755 "$TMP" /usr/local/bin/reseller-api.py
rm -f "$TMP" "${TMP}c"

cat > /etc/systemd/system/reseller-api.service <<UNIT
[Unit]
Description=Reseller API (lock/unlock/tambah IP)
After=network.target xray.service

[Service]
Environment=RESELLER_API_PORT=$PORT
ExecStart=/usr/bin/python3 /usr/local/bin/reseller-api.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable reseller-api >/dev/null 2>&1
systemctl restart reseller-api

# Firewall: hanya IP bot jika diberikan, kalau tidak buka untuk semua
if command -v iptables >/dev/null; then
  while iptables -D INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null; do :; done
  if [ -n "$BOT_IP" ]; then
    iptables -C INPUT -s "$BOT_IP" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -s "$BOT_IP" -p tcp --dport "$PORT" -j ACCEPT
    iptables -A INPUT -p tcp --dport "$PORT" -j DROP
    echo "Port $PORT hanya dibuka untuk $BOT_IP"
  else
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    echo "PERINGATAN: port $PORT terbuka untuk semua IP (hanya dilindungi auth key)."
  fi
  if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4
  fi
fi

sleep 1
if systemctl is-active --quiet reseller-api; then
  echo "reseller-api AKTIF di port $PORT"
else
  echo "Gagal start, cek: journalctl -u reseller-api"
  exit 1
fi
