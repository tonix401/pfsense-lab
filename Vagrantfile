# pfSense lab: pfSense is the only path between the host, the internet and the Ubuntu web VM.
#
#   internet ── NAT ── em0 WAN  pfSense  em1 HOSTNET 192.168.56.10 ── host-only ── host 192.168.56.1
#                                 em2 LAN 10.10.10.1
#                                    │ internal network "lab"
#                                 ubuntu 10.10.10.20 (DVWA on :80)
#
# The host reaches 10.10.10.0/24 through a route via 192.168.56.10, which the pfsense machine's
# triggers add and remove (sudo, or an admin shell on Windows).

UBUNTU_ISOLATED = File.join(__dir__, ".vagrant", "machines", "ubuntu", "isolated")
LAB_NET, LAB_GW = "10.10.10.0/24", "192.168.56.10"

# pfSense uses the "none" communicator, which Vagrant 2.4 only loads behind the experimental
# flag. Plugins are loaded before this file, so set the flag, clear Vagrant's cached reading of
# it and load the plugin again.
unless Vagrant::Util::Experimental.feature_enabled?("none_communicator")
  ENV["VAGRANT_EXPERIMENTAL"] = [ENV["VAGRANT_EXPERIMENTAL"], "none_communicator"].compact.reject(&:empty?).join(",")
  Vagrant::Util::Experimental.reset!
  load File.join(Vagrant.source_root, "plugins", "communicators", "none", "plugin.rb")
end

# Adds (:add) or removes (:del) the host route to the lab network
def lab_route(action)
  sudo = ENV["SUDO_ASKPASS"] ? %w[sudo -A] : %w[sudo]
  if Vagrant::Util::Platform.windows?
    return if action == :add && `route print`.include?("10.10.10.0")
    system("route", action == :add ? "add" : "delete", "10.10.10.0", "mask", "255.255.255.0", LAB_GW)
  elsif Vagrant::Util::Platform.darwin?
    system(*sudo, "route", "-n", action == :add ? "add" : "delete", "-net", LAB_NET, LAB_GW)
  else
    return if action == :add && `ip route show #{LAB_NET}`.include?("via #{LAB_GW}")
    return if action == :del && `ip route show #{LAB_NET}`.empty?
    system(*sudo, "ip", "route", action == :add ? "replace" : "del", LAB_NET, "via", LAB_GW)
  end or warn "could not #{action} the route #{LAB_NET} via #{LAB_GW}; add it by hand"
end

Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define "pfsense", primary: true do |fw|
    # Built from the ISO by scripts/build-box.sh (Packer)
    fw.vm.box = "pfsense-lab"
    # pfSense is configured by its own config.xml, not by Vagrant, so Vagrant never logs in
    fw.vm.communicator = "none"
    fw.vm.guest = :freebsd
    fw.vm.network "private_network", ip: LAB_GW, auto_config: false
    fw.vm.network "private_network", ip: "10.10.10.1", virtualbox__intnet: "lab", auto_config: false

    fw.vm.provider "virtualbox" do |vb|
      vb.name = "pfsense-lab"
      vb.memory = 1024
      vb.cpus = 1
      # Lets pfSense's packet capture and Suricata see every frame on both inner networks
      vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all", "--nicpromisc3", "allow-all"]
    end

    fw.trigger.after :up, :reload, :resume do |t|
      t.info = "Routing #{LAB_NET} via pfSense (#{LAB_GW})"
      t.ruby { lab_route(:add) }
    end
    fw.trigger.after :destroy do |t|
      t.ruby { lab_route(:del) }
    end
  end

  config.vm.define "ubuntu" do |web|
    web.vm.box = "bento/ubuntu-24.04"
    web.vm.hostname = "ubuntu-web"
    web.vm.network "private_network", ip: "10.10.10.20", virtualbox__intnet: "lab"

    isolated = File.exist?(UBUNTU_ISOLATED)
    web.vm.provider "virtualbox" do |vb|
      vb.name = "ubuntu-web"
      vb.memory = 2048
      vb.cpus = 2
      # Vagrant always makes NIC1 a NAT adapter. It is only needed for the first provisioning
      # (Vagrant configures 10.10.10.20 over it); afterwards it stays unplugged.
      vb.customize ["modifyvm", :id, "--cableconnected1", isolated ? "off" : "on"]
    end

    if isolated
      # NIC1 is unplugged, so SSH goes host → pfSense → ubuntu
      web.vm.network "forwarded_port", guest: 22, host: 2222, id: "ssh", disabled: true
      web.ssh.host = "10.10.10.20"
      web.ssh.port = 22
    end

    web.vm.provision "shell", path: "provision/ubuntu.sh"

    web.trigger.after :up, :provision do |t|
      t.info = "Unplugging ubuntu's NAT adapter: pfSense is now its only network path"
      t.ruby do |env, machine|
        system("VBoxManage", "controlvm", machine.id, "setlinkstate1", "off") or raise "setlinkstate1 failed"
        File.write(UBUNTU_ISOLATED, "")
      end
    end
    web.trigger.after :destroy do |t|
      t.ruby { |env, machine| File.delete(UBUNTU_ISOLATED) if File.exist?(UBUNTU_ISOLATED) }
    end
  end
end
