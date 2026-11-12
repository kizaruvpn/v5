#!/bin/bash
REPOSLIM="https://raw.githubusercontent.com/kizaruvpn/v5/main/Fls/"
W="wget --timeout=15 --tries=2 -q"

# unduh ke file sementara; file lama hanya diganti kalau unduhan berhasil & tidak kosong
get() {
    local tmp; tmp=$(mktemp)
    if $W -O "$tmp" "${REPOSLIM}$1" && [[ -s "$tmp" ]]; then
        sed -i 's/\r//' "$tmp"
        mv -f "$tmp" "$2"; chmod "$3" "$2"
        echo "   - $1 -> $2 OK"
    else
        rm -f "$tmp"
        echo "   ! gagal unduh $1, file lama dipertahankan"
    fi
}

echo "   - hentikan daemon limit"
systemctl stop limitvmess limitvless limittrojan limitshadowsocks >/dev/null 2>&1
mkdir -p /etc/xray /etc/limit/vmess /etc/limit/vless /etc/limit/trojan /etc/limit/shadowsocks

get limit-ip /usr/bin/limit-ip 755
for p in vmess vless trojan shadowsocks; do
    get limit${p}.service /etc/systemd/system/limit${p}.service 644
    get ${p} /etc/xray/limit.${p} 755
done

systemctl daemon-reload
for p in vmess vless trojan shadowsocks; do
    systemctl enable limit${p} >/dev/null 2>&1
    systemctl restart limit${p}
    echo "   - limit${p}: $(systemctl is-active limit${p})"
done
