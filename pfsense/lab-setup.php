<?php
/* Lab config for a fresh pfSense 2.7 install (em0 WAN, em1 OPT1, em2 LAN). Run: php /root/lab-setup.php */
require_once("config.inc");
require_once("filter.inc");
require_once("interfaces.inc");
require_once("services.inc");

config_set_path('interfaces/lan/ipaddr', '10.10.10.1');
config_set_path('interfaces/lan/subnet', '24');
config_set_path('interfaces/lan/ipaddrv6', '');
config_set_path('interfaces/opt1/descr', 'HOSTNET');
config_set_path('interfaces/opt1/enable', '');
config_set_path('interfaces/opt1/ipaddr', '192.168.56.10');
config_set_path('interfaces/opt1/subnet', '24');
/* ubuntu is static; no DHCP on LAN */
config_del_path('dhcpd/lan/enable');
config_del_path('dhcpdv6/lan/enable');
config_set_path('system/ssh/enable', 'enabled');
config_set_path('system/timezone', 'Europe/Berlin');

/* HOSTNET is the attacker side: allowed traffic is logged, the rest hits the logged default block */
$rules = config_get_path('filter/rule', []);
$mk = function ($descr, $proto, $dst, $port) {
	$r = ['type' => 'pass', 'interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => $proto,
	      'source' => ['network' => 'opt1'], 'destination' => $dst, 'log' => '', 'descr' => $descr,
	      'tracker' => (string)(time() . rand(100, 999))];
	if ($port) $r['destination']['port'] = $port;
	if ($proto == 'icmp') $r['icmptype'] = 'any';
	return $r;
};
$rules[] = $mk('Host to pfSense GUI', 'tcp', ['network' => '(self)'], '443');
$rules[] = $mk('Host to pfSense SSH', 'tcp', ['network' => '(self)'], '22');
$rules[] = $mk('Host to ubuntu HTTP (DVWA)', 'tcp', ['address' => '10.10.10.20'], '80');
$rules[] = $mk('Host to ubuntu SSH (vagrant)', 'tcp', ['address' => '10.10.10.20'], '22');
$rules[] = $mk('Host ping ubuntu', 'icmp', ['address' => '10.10.10.20'], '');
config_set_path('filter/rule', $rules);

write_config("pfsense-lab: interfaces, ssh, HOSTNET rules");
echo "done, rebooting\n";
