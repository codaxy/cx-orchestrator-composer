#!/bin/bash

set -e 

HOSTSFILE=/etc/hosts

if [[ $EUID > 0 ]] ; then
	echo Error: You must run this script with sudo.
	exit 1
fi

hosts_add() {
	grep -q $1 $HOSTSFILE || echo $2 $1 >> $HOSTSFILE
}

hosts_add local.keycloak.codaxy-cxo 127.0.0.1
hosts_add local.codaxy-cxo 127.0.0.1
