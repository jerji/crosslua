#!/bin/bash
# Joins the X4 hotspot from this host's USB WiFi adapter WITHOUT touching the VM's routing, fetches the page, then leaves.
# usage: ap_client.sh <ssid> <password> <url> [url ...]
IF=wlx04421a527590
SSID="$1"; PASS="$2"; shift 2
cat > /tmp/dhcp_noroute.sh <<'EOS'
#!/bin/sh
# dhclient script: set the leased address only. No default route, no resolv.conf: this host stays on its own network.
case "$reason" in
  BOUND|RENEW|REBIND|REBOOT)
    ip addr flush dev "$interface" 2>/dev/null
    ip addr add "$new_ip_address/$new_subnet_mask" dev "$interface" 2>>/tmp/dh_err.txt; env | grep -E "^(new_|reason|interface)" >> /tmp/dh_env.txt
    echo "dhcp: $interface got $new_ip_address/$new_subnet_mask from $new_dhcp_server_identifier"
    ;;
esac
exit 0
EOS
chmod +x /tmp/dhcp_noroute.sh
cat > /tmp/x4ap.conf <<EOC
ctrl_interface=/var/run/wpa_supplicant_x4
network={
  ssid="$SSID"
  psk="$PASS"
  key_mgmt=WPA-PSK
}
EOC
rm -f /tmp/dh_x4.leases; pkill -f "wpa_supplicant.*$IF" 2>/dev/null; pkill -f "dhclient.*$IF" 2>/dev/null
ip link set "$IF" up
wpa_supplicant -B -i "$IF" -c /tmp/x4ap.conf -P /tmp/wpa_x4.pid > /tmp/wpa_x4.log 2>&1
for i in $(seq 1 30); do
  st=$(iw dev "$IF" link 2>/dev/null | head -1)
  case "$st" in Connected*) echo "associated: $st"; break;; esac
  sleep 1
done
iw dev "$IF" link | head -6
OUT=$(dhclient -1 -v -sf /bin/true -pf /tmp/dh_x4.pid -lf /tmp/dh_x4.leases "$IF" 2>&1)
echo "$OUT" | grep -E 'DHCP|bound|No DHCPOFFERS' | head -6
# dhclient's own script is replaced by /bin/true (the real one would install a default route): apply the lease by hand, address only
ADDR=$(echo "$OUT" | grep -oE 'bound to [0-9.]+' | awk '{print $3}')
echo "lease: addr=$ADDR (mask /24: the X4 reports 255.255.255.0)"
[ -n "$ADDR" ] && ip addr add "$ADDR/24" dev "$IF" 2>&1
ip -4 -br addr show "$IF"; ping -c2 -W1 -I "$IF" 192.168.4.1 2>&1 | tail -3
for u in "$@"; do
  echo "--- GET $u"
  curl -sv -m 8 --interface "$ADDR" "$u" 2>&1 | head -24
  echo
done
echo "--- leaving"
kill "$(cat /tmp/wpa_x4.pid 2>/dev/null)" 2>/dev/null
pkill -f "dhclient.*$IF" 2>/dev/null
ip addr flush dev "$IF" 2>/dev/null
ip link set "$IF" down
