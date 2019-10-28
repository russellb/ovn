#!/bin/bash

cleanup() {
    if ! which ovn-nbctl 2>&1 > /dev/null ; then
        # OVN not yet installed, nothing to cleanup
        return
    fi
    sudo ovs-vsctl del-port foo1
    sudo ovs-vsctl del-port foo2
    sudo ovs-vsctl del-port bar1
    sudo ovs-vsctl del-port alice1
    sudo ip netns delete foo1
    sudo ip netns delete foo2
    sudo ip netns delete bar1
    sudo ip netns delete alice1
    sudo ovn-nbctl lsp-del foo1
    sudo ovn-nbctl lsp-del foo2
    sudo ovn-nbctl lsp-del bar1
    sudo ovn-nbctl lsp-del rp-foo
    sudo ovn-nbctl lsp-del alice1
    sudo ovn-nbctl ls-del foo
    sudo ovn-nbctl ls-del bar
    sudo ovn-nbctl ls-del alice
    sudo ovn-nbctl lr-del R1
}
if [ "$1" = "cleanup" ] ; then
    cleanup
    exit 0
fi

sudo ovs-vsctl set open . external-ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock
sudo ovs-vsctl set open . external-ids:ovn-encap-type=geneve
sudo ovs-vsctl set open . external-ids:ovn-encap-ip=127.0.0.1

sudo setenforce 0

ovn-nbctl lr-add R1

ovn-nbctl ls-add foo
ovn-nbctl ls-add bar
ovn-nbctl ls-add alice

ovn-nbctl lrp-add R1 foo 00:00:01:01:02:03 fd11::1/64
ovn-nbctl lrp-add R1 bar 00:00:01:01:02:04 fd12::1/64
ovn-nbctl lrp-add R1 alice 00:00:02:01:02:03 fd20::1/64 \
    -- set Logical_Router_Port alice options:redirect-chassis=29215964-81ac-428c-9639-632c7c9d64be

# Connect foo to R1
ovn-nbctl lsp-add foo rp-foo -- set Logical_Switch_Port rp-foo \
    type=router options:router-port=foo \
    -- lsp-set-addresses rp-foo router

# Connect bar to R1
ovn-nbctl lsp-add bar rp-bar -- set Logical_Switch_Port rp-bar \
    type=router options:router-port=bar \
    -- lsp-set-addresses rp-bar router

# Connect alice to R1
ovn-nbctl lsp-add alice rp-alice -- set Logical_Switch_Port rp-alice \
    type=router options:router-port=alice \
    -- lsp-set-addresses rp-alice router


add_phys_port() {
    name=$1
    mac=$2
    ip=$3
    mask=$4
    gw=$5
    iface_id=$6
    sudo ip netns add $name
    sudo ovs-vsctl add-port br-int $name -- set interface $name type=internal
    sudo ip link set $name netns $name 
    sudo ip netns exec $name ip link set $name address $mac
    sudo ip netns exec $name ip addr add $ip/$mask dev $name 
    sudo ip netns exec $name ip link set $name up
    sudo ip netns exec $name ip route add default via $gw
    sudo ovs-vsctl set Interface $name external_ids:iface-id=$iface_id
}

add_phys_port foo1 f0:00:00:01:02:03 fd11::2 64 fd11::1 foo1
while test "$(sudo ip netns exec foo1 ip a | grep fd11::2 | grep tentative)" = "" ; do : ; done
ovn-nbctl lsp-add foo foo1 \
-- lsp-set-addresses foo1 "f0:00:00:01:02:03 fd11::2"

add_phys_port foo2 f0:00:00:01:02:06 fd11::3 64 fd11::1 foo2
while test "$(sudo ip netns exec foo2 ip a | grep fd11::3 | grep tentative)" = "" ; do : ; done
ovn-nbctl lsp-add foo foo2 \
-- lsp-set-addresses foo2 "f0:00:00:01:02:06 fd11::3"

add_phys_port bar1 f0:00:00:01:02:04 fd12::2 64 fd12::1 bar1
while test "$(sudo ip netns exec bar1 ip a | grep fd12::2 | grep tentative)" = "" ; do : ; done
ovn-nbctl lsp-add bar bar1 \
-- lsp-set-addresses bar1 "f0:00:00:01:02:04 fd12::2"

add_phys_port alice1 f0:00:00:01:02:05 fd20::2 64 fd20::1 alice1
while test "$(sudo ip netns exec alice1 ip a | grep fd20::2 | grep tentative)" = "" ; do : ; done
ovn-nbctl lsp-add alice alice1 \
-- lsp-set-addresses alice1 "f0:00:00:01:02:05 fd20::2"

ovn-nbctl --wait=hv sync

# Add DNAT rules
ovn-nbctl lr-nat-add R1 dnat_and_snat fd20::3 fd11::2 foo1 00:00:02:02:03:04
ovn-nbctl lr-nat-add R1 dnat_and_snat fd20::4 fd12::2 bar1 00:00:02:02:03:05

# Add a SNAT rule
ovn-nbctl lr-nat-add R1 snat fd20::1 fd11::/64
ovn-nbctl lr-nat-add R1 snat fd20::1 fd12::/64

ovn-nbctl --wait=hv sync

msg() {
    echo
    echo "***"
    echo "*** $1" 
    echo "***"
    echo
}
