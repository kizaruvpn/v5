#!/bin/bash
# UPDATE SCRIPT - versi verbose: tiap langkah tampil + lama waktunya
REPO="https://raw.githubusercontent.com/kizaruvpn/v5/main"
PASS="HeyHeyMauDecryptYaAwokawok"
WGET="wget --timeout=20 --tries=3 -q --show-progress"
WORK="/tmp/upd"
SUM=()
T_ALL=$(date +%s)

step() {
    local title="$1" fn="$2" t0 rc dt
    t0=$(date +%s)
    echo -e "\n\033[1;33m[$(date +%H:%M:%S)] ▶ ${title}\033[0m"
    "$fn"; rc=$?
    dt=$(( $(date +%s) - t0 ))
    if [[ $rc -eq 0 ]]; then
        echo -e "\033[1;32m   ✔ OK (${dt}s)\033[0m"
        SUM+=("$(printf '%-44s %5ss  OK' "$title" "$dt")")
    else
        echo -e "\033[1;31m   ✘ GAGAL kode ${rc} (${dt}s)\033[0m"
        SUM+=("$(printf '%-44s %5ss  GAGAL' "$title" "$dt")")
    fi
    return $rc
}

cek_awal() {
    local n
    n=$(grep -cE '^(###|#&|#!) ' /etc/xray/config.json 2>/dev/null)
    echo "   Akun xray terdaftar : ${n:-0}"
    echo "   Load average        : $(cut -d' ' -f1-3 /proc/loadavg)  (CPU: $(nproc) core)"
    echo "   Disk / bebas        : $(df -h / | awk 'NR==2{print $4}')"
}

stop_limit() {
    systemctl stop limitvmess limitvless limittrojan limitshadowsocks >/dev/null 2>&1
    echo "   daemon kuota dihentikan sementara (counter xray tetap tersimpan, akan dinyalakan lagi di langkah akhir)"
}

unduh_menu() {
    rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK" || return 1
    $WGET -O menu.zip "$REPO/Cdy/menu.zip" || return 1
    [[ -s menu.zip ]] || { echo "   menu.zip kosong"; return 1; }
    echo "   ukuran menu.zip: $(du -h menu.zip | cut -f1)"
}

ekstrak_menu() {
    cd "$WORK" || return 1
    7z x -y -bd -p"$PASS" menu.zip >/dev/null 2>&1 || { echo "   gagal ekstrak menu.zip (7z)"; return 1; }
    [[ -d menu ]] || { echo "   folder menu tidak ditemukan"; return 1; }
    echo "   $(ls menu | wc -l) file menu akan diperbarui:"
    ls -1 menu | paste -sd' ' | fold -s -w 76 | sed 's/^/     /'
}

pasang_menu() {
    cd "$WORK" || return 1
    chmod +x menu/*
    rm -rf /usr/local/sbin && mkdir -p /usr/local/sbin
    mv menu/* /usr/local/sbin/ || return 1
    echo "   terpasang di /usr/local/sbin"
}

cek_slowdns() {
    if [ -f "/etc/slowdns/install.sh" ] && [ -f "/etc/slowdns/slowdns.env" ]; then
        echo "   SlowDNS sudah terpasang, dilewati"
    else
        echo "   SlowDNS belum terpasang, memasang (bagian ini bisa lama)..."
        $WGET -O /tmp/nameserver "$REPO/Cfg/slowdns.sh" || return 1
        chmod +x /tmp/nameserver
        /tmp/nameserver
    fi
}

update_limit() {
    $WGET -O /tmp/limit.sh "$REPO/Fls/limit.sh" || return 1
    chmod +x /tmp/limit.sh
    /tmp/limit.sh
    local rc=$?
    rm -f /tmp/limit.sh
    return $rc
}

netfilter-persistent >/dev/null 2>&1
clear
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e " \e[1;97;101m          UPDATE SCRIPT        \e[0m"
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

step "Cek kondisi VPS" cek_awal
step "Hentikan daemon kuota sementara" stop_limit
if step "Unduh menu.zip" unduh_menu; then
    if step "Ekstrak menu.zip" ekstrak_menu; then
        step "Pasang menu ke /usr/local/sbin" pasang_menu
    fi
else
    echo -e "\033[1;31m   menu lama TIDAK diubah karena unduhan gagal\033[0m"
fi
step "Cek / pasang SlowDNS" cek_slowdns
step "Perbarui daemon kuota & service limit" update_limit

rm -rf "$WORK"
cd ~ 2>/dev/null
echo -e "\n\033[1;36m━━━━━━━━━━━━━━ RINGKASAN WAKTU ━━━━━━━━━━━━━━\033[0m"
for s in "${SUM[@]}"; do echo "  $s"; done
echo "  Total: $(( $(date +%s) - T_ALL ))s | Load sekarang: $(cut -d' ' -f1-3 /proc/loadavg)"
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo ""
read -n 1 -s -r -p "Press [ Enter ] to back on menu"
rm -f "$0"
menu
