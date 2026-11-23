#!/usr/bin/env bash
# Routes everything through pfSense (10.10.10.1) and runs DVWA on :80.
# The NAT adapter only keeps carrying Vagrant's SSH until the after-up trigger unplugs it.
set -euo pipefail

lab_if=$(ip -o -4 addr show | awk '$4 ~ /^10\.10\.10\.20\// {print $2}')
nat_if=$(ip -o -4 addr show | awk '$4 ~ /^10\.0\.2\./ {print $2}')
[[ -n "$lab_if" ]] || { echo "no interface with 10.10.10.20" >&2; exit 1; }

# Default route and DNS via pfSense; the NAT DHCP lease no longer installs either
cat > /etc/netplan/60-lab.yaml <<EOF
network:
  version: 2
  ethernets:
    ${lab_if}:
      routes:
        - to: default
          via: 10.10.10.1
      nameservers:
        addresses: [10.10.10.1]
EOF
if [[ -n "$nat_if" ]]; then
  cat >> /etc/netplan/60-lab.yaml <<EOF
    ${nat_if}:
      dhcp4: true
      dhcp4-overrides: { use-routes: false, use-dns: false }
      optional: true
EOF
fi
chmod 600 /etc/netplan/60-lab.yaml
netplan apply
ip route

# Proves egress works through pfSense before installing anything. pfSense may still be booting
# (Vagrant cannot wait for it), so allow a few minutes on slow hosts.
for i in $(seq 1 60); do
  curl -sfI -m 5 https://deb.debian.org >/dev/null && break
  [[ $i == 60 ]] && { echo "no internet through pfSense (10.10.10.1)" >&2; exit 1; }
  sleep 2
done

if ! command -v docker >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -yq docker.io
fi

docker rm -f dvwa 2>/dev/null || true
docker run -d --name dvwa --restart unless-stopped -p 80:80 vulnerables/web-dvwa
