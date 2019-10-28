#!/bin/bash

cleanup() {
    if ! which ovn-nbctl 2>&1 > /dev/null ; then
        # OVN not yet installed, nothing to cleanup
        return
    fi
    sudo ovs-vsctl del-port foo1
    sudo ovs-vsctl del-port alice1
    sudo ip netns delete foo1
    sudo ip netns delete alice1
    sudo ovn-nbctl lsp-del foo1
    sudo ovn-nbctl lsp-del rp-foo
    sudo ovn-nbctl lsp-del alice1
    sudo ovn-nbctl ls-del foo
    sudo ovn-nbctl ls-del alice
    sudo ovn-nbctl ls-del join
    sudo ovn-nbctl lr-del R1
    sudo ovn-nbctl lr-del R2
}
if [ "$1" = "cleanup" ] ; then
    cleanup
    exit 0
fi

sudo ovs-vsctl set open . external-ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock
sudo ovs-vsctl set open . external-ids:ovn-encap-type=geneve
sudo ovs-vsctl set open . external-ids:ovn-encap-ip=127.0.0.1

sudo setenforce 0

# Logical network:
# Two LRs - R1 and R2 that are connected to each other via LS "join"
# in fd20::/64 network. R1 has switchess foo (fd10::/64) connected
# to it.  R2 has alice (fd30::/64) connected to it.
# R2 is a gateway router on which we add NAT rules.
#
#    foo -- R1 -- join - R2 -- alice

ovn-nbctl lr-add R1
ovn-nbctl lr-add R2 -- set Logical_Router R2 options:chassis=29215964-81ac-428c-9639-632c7c9d64be

ovn-nbctl ls-add foo
ovn-nbctl ls-add alice
ovn-nbctl ls-add join

ovn-nbctl lrp-add R1 foo 00:00:01:01:02:03 fd10::1/64
ovn-nbctl lrp-add R2 alice 00:00:02:01:02:03 fd30::1/64
ovn-nbctl lrp-add R1 R1_join 00:00:04:01:02:03 fd20::1/64
ovn-nbctl lrp-add R2 R2_join 00:00:04:01:02:04 fd20::2/64

# Connect foo to R1
ovn-nbctl lsp-add foo rp-foo -- set Logical_Switch_Port rp-foo \
    type=router options:router-port=foo addresses='"00:00:01:01:02:03"'

# Connect alice to R2
ovn-nbctl lsp-add alice rp-alice -- set Logical_Switch_Port rp-alice \
    type=router options:router-port=alice addresses='"00:00:02:01:02:03"'

# Connect R1 to join
ovn-nbctl lsp-add join r1-join -- set Logical_Switch_Port r1-join \
    type=router options:router-port=R1_join addresses='"00:00:04:01:02:03"'

# Connect R2 to join
ovn-nbctl lsp-add join r2-join -- set Logical_Switch_Port r2-join \
    type=router options:router-port=R2_join addresses='"00:00:04:01:02:04"'

# Static routes.
ovn-nbctl lr-route-add R1 fd30::/64 fd20::2
ovn-nbctl lr-route-add R2 fd10::/64 fd20::1

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

add_phys_port foo1 f0:00:00:01:02:03 fd10::2 64 fd10::1 foo1
while test "$(sudo ip netns exec foo1 ip a | grep fd10::2 | grep tentative)" = "" ; do : ; done
ovn-nbctl lsp-add foo foo1 \
-- lsp-set-addresses foo1 "f0:00:00:01:02:03 fd10::2"

add_phys_port alice1 f0:00:00:01:02:04 fd30::2 64 fd30::1 alice1
while test "$(sudo ip netns exec alice1 ip a | grep fd30::2 | grep tentative)" = "" ; do : ; done
ovn-nbctl lsp-add alice alice1 \
-- lsp-set-addresses alice1 "f0:00:00:01:02:04 fd30::2"

# Add a SNAT rule
ovn-nbctl -- --id=@nat create nat type="snat" logical_ip=\"fd10::2\" \
    external_ip=\"fd30::1\" -- add logical_router R2 nat @nat

ovn-nbctl --wait=hv sync

msg() {
    echo
    echo "***"
    echo "*** $1" 
    echo "***"
    echo
}
