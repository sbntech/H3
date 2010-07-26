#!/bin/bash

# used by w2 when it needs to act as a router/NAT server
# ./firewall.sh UNDO to undo

# variables
LAN="85.159.114.0/28"
LAN_IP="85.159.114.1/28"
INET_IFACE="eth0"
LAN_IFACE="eth1"

## === clear the tables flush,delete,zero ===
iptables -t filter -F
iptables -t filter -X
iptables -t filter -Z
iptables -t nat -F
iptables -t nat -X
iptables -t nat -Z
iptables -t mangle -F
iptables -t mangle -X
iptables -t mangle -Z

if [ "x$1x" == "xUNDOx" ]
then
	echo 0 > /proc/sys/net/ipv4/ip_forward
	ip a del $LAN_IP dev $LAN_IFACE
	echo "Undo..."
	exit
fi

ip a add $LAN_IP dev $LAN_IFACE

# SNAT the LAN on the internet
iptables -t nat -A POSTROUTING -s $LAN -o $INET_IFACE -j MASQUERADE

echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv4/conf/all/rp_filter
