#!/bin/bash
REPOSLIM="https://raw.githubusercontent.com/kizaruvpn/v5/main/Fls/"
systemctl stop limitvmess limitvless limittrojan limitshadowsocks >/dev/null 2>&1
mkdir -p /etc/xray /etc/limit/vmess /etc/limit/vless /etc/limit/trojan /etc/limit/shadowsocks
wget -q -O /usr/bin/limit-ip "${REPOSLIM}limit-ip"
chmod +x /usr/bin/*
sed -i 's/\r//' /usr/bin/limit-ip
for p in vmess vless trojan shadowsocks; do
  wget -q -O /etc/systemd/system/limit${p}.service "${REPOSLIM}limit${p}.service"
  wget -q -O /etc/xray/limit.${p} "${REPOSLIM}${p}"
  sed -i 's/\r//' /etc/xray/limit.${p} /etc/systemd/system/limit${p}.service
  chmod +x /etc/xray/limit.${p}
done
systemctl daemon-reload
for p in vmess vless trojan shadowsocks; do
  systemctl enable limit${p} >/dev/null 2>&1
  systemctl restart limit${p}
done
