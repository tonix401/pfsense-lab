# pfSense lab

pfSense is the only path between the host, the internet and an Ubuntu VM running DVWA (a
deliberately vulnerable web app). Attacks from the host on DVWA show up in pfSense's firewall
log, in Suricata alerts and in packet captures.

```
            internet
               │  VirtualBox NAT
        em0 WAN│ 10.0.2.15 (DHCP)
        ┌──────┴──────┐
        │   pfSense   │  em1 HOSTNET 192.168.56.10 ── host-only ── host 192.168.56.1
        └──────┬──────┘
        em2 LAN│ 10.10.10.1/24   VirtualBox internal network "lab"
        ┌──────┴──────┐
        │ ubuntu-web  │  10.10.10.20, gateway 10.10.10.1, DVWA on :80
        └─────────────┘
```

- The host reaches 10.10.10.0/24 by a **route** via pfSense, not a port forward. So pfSense sees and logs the real attacker address, 192.168.56.1.
- Ubuntu's only gateway and DNS is pfSense. Vagrant forces a NAT adapter onto every VM; Ubuntu's is used once for the first provisioning and then unplugged (`isolated` marker in `.vagrant/machines/ubuntu/`).
- Suricata runs on HOSTNET (em1), the attacker side, in alert-only mode with ET Open rules.

> [!warning] Lab-only credentials
> pfSense web GUI and SSH: `admin` / `pfsense` (root uses the same password). DVWA: `admin` / `password`. Never expose these VMs beyond the host.

## Requirements

An **amd64** host (pfSense and the DVWA image don't run on ARM) with about 4 GB of free RAM, and
`sudo`. The subnets 192.168.56.0/24 and 10.10.10.0/24 must not already be in use on the host.

### Debian 12 (bookworm) / 13 (trixie)

```sh
scripts/setup-debian.sh   # VirtualBox 7.2 (Oracle repo), Vagrant + Packer (HashiCorp repo), vboxusers
```

Then log out and in again so the `vboxusers` group applies. With Secure Boot on, the VirtualBox
kernel modules must be signed or Secure Boot turned off; the script warns about it.

### NixOS

- `virtualisation.virtualbox.host.enable = true;` and the user in `vboxusers` (in `~/nix-dots/nixos/common.nix`). Until the next login, run VirtualBox/Vagrant commands through `sg vboxusers -c "…"`.
- nixpkgs' Vagrant pulls a broken libguestfs, so install it without libvirt:
  `nix profile install --impure --expr '((builtins.getFlake "nixpkgs").legacyPackages.x86_64-linux.vagrant.override { withLibvirt = false; })'`
- `nix profile install nixpkgs#packer`

## Build the pfSense box (once, unattended, ~10 minutes)

```sh
scripts/build-box.sh
```

1. `scripts/get-iso.sh` downloads the pfSense CE 2.7.2 ISO from Netgate's mirror (or a second mirror) and checks it against SHA256 hashes pinned in the script.
2. Packer (`packer/pfsense.pkr.hcl`) boots the ISO headless and types the installer answers. It then loads `packer/http/config.xml` (interfaces, firewall rules, Suricata settings), installs Suricata, downloads the ET Open rules and powers off.
3. The result is added to Vagrant as box `pfsense-lab`. To share it without rebuilding, export it with `vagrant box repackage pfsense-lab virtualbox 0` (writes `package.box`) and run `vagrant box add pfsense-lab package.box` on the other machine.

## Bring-up

```sh
vagrant up
```

1. `pfsense` comes up first. Its trigger adds the host route `10.10.10.0/24 via 192.168.56.10` (asks for the sudo password).
2. `ubuntu` provisions Docker + DVWA through pfSense, then unplugs its NAT adapter.
3. Open `http://10.10.10.20`, log in (`admin` / `password`), click **Create / Reset Database**, log in again, set **DVWA Security** to *Low*.

`vagrant ssh ubuntu` keeps working afterwards; it goes host → pfSense → ubuntu. `vagrant destroy`
removes the route again.

## Changing the pfSense config

`packer/http/config.xml` is the source of truth. Change things in the web GUI, export with
*Diagnostics → Backup & Restore*, replace that file, delete any `<authorizedkeys>` you added,
and run `scripts/build-box.sh` again.

## Firewall rules on HOSTNET

| # | Rule | Logged |
|---|------|--------|
| 1 | host → pfSense tcp/443 (GUI) | yes |
| 2 | host → pfSense tcp/22 | yes |
| 3 | host → 10.10.10.20 tcp/80 (DVWA) | yes |
| 4 | host → 10.10.10.20 tcp/22 (vagrant ssh) | yes |
| 5 | host → 10.10.10.20 ICMP | yes |
| – | everything else: default deny | yes |

LAN keeps pfSense's default "allow LAN to any", which with automatic outbound NAT gives Ubuntu internet access. WAN allows nothing in.

## Attack and trace

Run from the host (tools: `nix shell nixpkgs#nmap nixpkgs#sqlmap`).

1. **Recon.** `nmap -sS -sV -p- 10.10.10.20` (needs root) or `nmap -sV 10.10.10.20`.
   - Firewall log (*Status → System Logs → Firewall*): passes to :80/:22 and a wall of default-deny blocks from 192.168.56.1 on every other port.
   - Suricata (*Services → Suricata → Alerts*, interface HOSTNET): `ET SCAN` alerts, e.g. Nmap scripting engine user agent.
2. **SQL injection.** In DVWA → *SQL Injection*, enter `1' OR '1'='1' -- `. Or automated, with the session cookie from the browser:
   `sqlmap -u "http://10.10.10.20/vulnerabilities/sqli/?id=1&Submit=Submit" --cookie "PHPSESSID=…; security=low" --batch --dbs`
   - Suricata: `ET WEB_SERVER` / SQL injection alerts (`UNION SELECT`, `OR 1=1`), plus `ET SCAN Sqlmap SQL Injection Scan`.
3. **Command injection.** DVWA → *Command Injection*: `127.0.0.1; cat /etc/passwd`.
   - Suricata: `ET ATTACK_RESPONSE` / `ET WEB_SERVER` alerts for `/etc/passwd` in the request or response.
4. **Packet capture.** *Diagnostics → Packet Capture*, interface HOSTNET, host 10.10.10.20, port 80, full packets, start, repeat an attack, stop and download. Open it in Wireshark and *Follow HTTP stream* to read the payload and the leaked data.
5. **Response (optional).** In the Suricata interface settings tick **Block Offenders**, save, restart, repeat step 2. The attacker IP lands in *Blocks* and further requests time out. Untick it afterwards, otherwise the host stays blocked.

Over SSH the same evidence is in:

- `/var/log/filter.log` (raw pf log; `clog`-free plain text on 2.7),
- `/var/log/suricata/suricata_em1*/alerts.log` and `eve.json`,
- `/var/log/suricata/suricata_em1*/http.log` (every HTTP request with URI and user agent).

## Checks

```sh
VBoxManage list hostonlyifs | grep 192.168.56.1          # host side of HOSTNET
vagrant ssh ubuntu -c 'ip route; curl -sI https://example.com | head -1'   # default via 10.10.10.1, 200
curl -s http://10.10.10.20/login.php | grep -o 'DVWA'     # app reachable through pfSense
ssh root@192.168.56.10 'tail -3 /var/log/suricata/suricata_em1*/alerts.log'   # password pfsense
```

Isolation check: `VBoxManage controlvm pfsense-lab setlinkstate1 off` (pfSense WAN) and Ubuntu loses the internet, which shows it has no other way out. `setlinkstate1 on` to restore.
