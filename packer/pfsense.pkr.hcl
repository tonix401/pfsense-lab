# Builds the Vagrant box "pfsense-lab" from the pfSense CE ISO with no manual steps:
# the installer is driven by boot_command, then the lab config (http/config.xml) is fetched
# over Packer's HTTP server, Suricata is installed and its rules downloaded.
#
#   packer init . && packer build .      (scripts/build-box.sh does this and adds the box)

packer {
  required_plugins {
    virtualbox = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/virtualbox"
    }
    vagrant = {
      version = ">= 1.1.5"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

variable "iso" {
  type    = string
  default = "../iso/pfSense-CE-2.7.2-RELEASE-amd64.iso"
}

source "virtualbox-iso" "pfsense" {
  iso_url       = var.iso
  iso_checksum  = "sha256:441005f79ea0c155bc4b830a2b4207f8c0804cf7b075d2a6489c0a136cbc5d51"
  iso_interface = "sata"

  vm_name              = "pfsense-lab-build"
  guest_os_type        = "FreeBSD_64"
  headless             = true
  cpus                 = 1
  memory               = 1024
  disk_size            = 8192
  hard_drive_interface = "sata"
  guest_additions_mode = "disable"
  # No login, so Packer cannot upload the VirtualBox version file
  virtualbox_version_file = ""

  # NIC order is pfSense's interface order: em0 WAN (NAT), em1 HOSTNET, em2 LAN. The inner two
  # only need to exist during the build; Vagrant attaches them to the real networks later.
  vboxmanage = [
    ["modifyvm", "{{ .Name }}", "--audio-enabled", "off", "--boot1", "disk", "--boot2", "dvd",
      # VirtualBox 7 blocks guest access to the host's localhost via 10.0.2.2 by default;
      # Packer's HTTP server (config.xml) is reached exactly that way
      "--nictype1", "82540EM", "--nat-localhostreachable1", "on",
      "--nic2", "intnet", "--intnet2", "pfsense-build-hostnet", "--nictype2", "82540EM",
    "--nic3", "intnet", "--intnet3", "pfsense-build-lan", "--nictype3", "82540EM"],
  ]

  # pfSense has no login Packer could use. Everything is typed on the console, and the last
  # command powers the VM off, which is what Packer waits for.
  communicator     = "none"
  disable_shutdown = true
  shutdown_timeout = "30m"
  http_directory   = "http"

  boot_wait = "45s"
  boot_command = [
    # Installer: accept notice, Install, Auto (UFS), Entire Disk, MBR, Finish, Commit
    "<enter><wait3>",
    "<enter><wait3>",
    "<down><enter><wait3>",
    "<enter><wait3>",
    "<enter><wait3>",
    "<enter><wait3>",
    "<enter><wait120>",
    # Reboot into the installed system and wait for the console menu
    "<enter><wait180>",
    # Menu option 8 = shell. Keys typed while pfSense is still booting are dropped, so "8" is
    # sent twice: if the first one already opened the shell, the second is a harmless
    # "8: Command not found". In the shell, typed input is buffered, so the chain runs in order
    # however long each step takes; any failure skips the poweroff and the build times out.
    "8<enter><wait90>",
    "8<enter><wait5>",
    "fetch -o /cf/conf/config.xml http://{{ .HTTPIP }}:{{ .HTTPPort }}/config.xml && ",
    "rm -f /tmp/config.cache && ",
    "pkg-static install -y pfSense-pkg-suricata && ",
    "php /usr/local/pkg/suricata/suricata_check_for_rule_updates.php && ",
    "shutdown -p now<enter>",
  ]
}

build {
  sources = ["source.virtualbox-iso.pfsense"]

  post-processor "vagrant" {
    output = "../pfsense-lab.box"
  }
}
