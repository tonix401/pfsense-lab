#!/usr/bin/env bash
# Installs what the lab needs on a Debian host (bookworm or trixie, amd64):
# VirtualBox 7.2 from Oracle's repo, Vagrant and Packer from HashiCorp's repo.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then sudo=(); else sudo=(sudo); fi
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
[[ "$(dpkg --print-architecture)" == amd64 ]] || { echo "pfSense needs an amd64 host" >&2; exit 1; }

"${sudo[@]}" apt-get update
"${sudo[@]}" apt-get install -y curl gpg ca-certificates
# VirtualBox builds its kernel modules on install, so it needs the running kernel's headers
"${sudo[@]}" apt-get install -y "linux-headers-$(uname -r)" \
  || echo "warning: no linux-headers-$(uname -r); update the kernel and reboot if vboxdrv fails" >&2

curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc \
  | "${sudo[@]}" gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $codename contrib" \
  | "${sudo[@]}" tee /etc/apt/sources.list.d/virtualbox.list >/dev/null

curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | "${sudo[@]}" gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $codename main" \
  | "${sudo[@]}" tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

"${sudo[@]}" apt-get update
"${sudo[@]}" apt-get install -y virtualbox-7.2 vagrant packer

user=${SUDO_USER:-${USER:-}}
if [[ -n "$user" && "$user" != root ]]; then
  "${sudo[@]}" usermod -aG vboxusers "$user"
  echo "added $user to vboxusers: log out and in again"
fi

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
  echo "Secure Boot is on: the unsigned VirtualBox modules won't load until you sign them or turn it off" >&2
fi
lsmod | grep -q vboxdrv && echo "vboxdrv loaded" \
  || echo "vboxdrv not loaded yet: run 'sudo /sbin/vboxconfig' and read its log" >&2
