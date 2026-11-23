#!/usr/bin/env bash
# ISO → Packer build → Vagrant box "pfsense-lab". Takes about 10 minutes, all unattended.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
"$here/scripts/get-iso.sh"

cd "$here/packer"
packer init .
packer build -force .
vagrant box add --force pfsense-lab "$here/pfsense-lab.box"
