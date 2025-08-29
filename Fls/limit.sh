#!/bin/bash
REPOSLIM="https://raw.githubusercontent.com/Diah082/vip/main/"
wget -q -O /usr/bin/limit-ip "${REPOSLIM}install/limit-ip"
chmod +x /usr/bin/*
cd /usr/bin
sed -i 's/\r//' limit-ip
cd
systemctl daemon-reload
wget -q -O /etc/systemd/system/limitvmess.service "${REPOSLIM}install/limitvmess.service" && chmod +x limitvmess.service >/dev/null 2>&1
wget -q -O /etc/systemd/system/limitvless.service "${REPOSLIM}install/limitvless.service" && chmod +x limitvless.service >/dev/null 2>&1
wget -q -O /etc/systemd/system/limittrojan.service "${REPOSLIM}install/limittrojan.service" && chmod +x limittrojan.service >/dev/null 2>&1
wget -q -O /etc/systemd/system/limitshadowsocks.service "${REPOSLIM}install/limitshadowsocks.service" && chmod +x limitshadowsocks.service >/dev/null 2>&1
wget -q -O /etc/xray/limit.vmess "${REPOSLIM}install/vmess" >/dev/null 2>&1
wget -q -O /etc/xray/limit.vless "${REPOSLIM}install/vless" >/dev/null 2>&1
wget -q -O /etc/xray/limit.trojan "${REPOSLIM}install/trojan" >/dev/null 2>&1
wget -q -O /etc/xray/limit.shadowsocks "${REPOSLIM}install/shadowsocks" >/dev/null 2>&1
chmod +x /etc/xray/limit.vmess
chmod +x /etc/xray/limit.vless
chmod +x /etc/xray/limit.trojan
chmod +x /etc/xray/limit.shadowsocks
systemctl daemon-reload
systemctl enable --now limitvmess
systemctl enable --now limitvless
systemctl enable --now limittrojan
systemctl enable --now limitshadowsocks
systemctl start limitvmess
systemctl start limitvless
systemctl start limittrojan
systemctl start limitshadowsocks