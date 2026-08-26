#!/bin/bash

{

NS=ns2
IF=eno2
IP=172.27.27.17/16
GW=172.27.16.254

sudo ip netns add $NS

sudo ip link set $IF netns $NS

sudo ip netns exec $NS ip link set lo up
sudo ip netns exec $NS ip link set $IF up

sudo ip netns exec $NS ip addr add $IP dev $IF
sudo ip netns exec $NS ip route add default via $GW

sudo ip netns exec $NS /usr/sbin/sshd

}
