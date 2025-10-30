#!/bin/bash
# Auto setup 3proxy with IPv6 local fake (NAT v6 -> v4)
# Author: ChatGPT mod

echo "=== Installing 3proxy & dependencies ==="
apt update -y || yum update -y
apt install gcc make git curl net-tools wget unzip -y 2>/dev/null || yum install gcc make git curl net-tools wget unzip -y -q

WORKDIR="/home/cloudfly"
mkdir -p $WORKDIR && cd $WORKDIR

echo "=== Downloading 3proxy ==="
rm -rf 3proxy
git clone https://github.com/z3APA3A/3proxy.git
cd 3proxy
make -f Makefile.Linux

mkdir -p /usr/local/etc/3proxy/bin
cp src/3proxy /usr/local/etc/3proxy/bin/
cd /usr/local/etc/3proxy

# Generate config folder
mkdir -p /usr/local/etc/3proxy/{logs,conf,bin,stat}

echo "=== Configuring IPv6 NAT ==="
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.default.disable_ipv6=0
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -p

# Create fake IPv6 network
ip -6 addr add fd00::1/64 dev eth0

# Generate proxy config
BASE_PORT=10000
USER="user"
PASS="pass"
COUNT=5  # số lượng proxy muốn tạo

echo "=== Generating proxy list ($COUNT proxies) ==="
> /usr/local/etc/3proxy/conf/3proxy.cfg
for i in $(seq 1 $COUNT); do
  IPV6="fd00::$i"
  PORT=$((BASE_PORT + i))
  echo "proxy -6 -n -a -p$PORT -i$(hostname -I | awk '{print $1}') -e$IPV6" >> /usr/local/etc/3proxy/conf/3proxy.cfg
done

cat <<EOF >> /usr/local/etc/3proxy/conf/3proxy.cfg
auth strong
users $USER:CL:$PASS
allow $USER
maxconn 200
flush
setgid 65535
setuid 65535
nserver 1.1.1.1
nserver 8.8.8.8
log /usr/local/etc/3proxy/logs/3proxy.log D
logformat "L%t %E %U %C:%c %R:%r %O %I %h %T"
rotate 30
EOF

# Create systemd service
cat <<EOF >/etc/systemd/system/3proxy.service
[Unit]
Description=3proxy proxy server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/conf/3proxy.cfg
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy
systemctl restart 3proxy

echo "=== Proxy installed successfully ==="
echo "Your proxy list:"
for i in $(seq 1 $COUNT); do
  PORT=$((BASE_PORT + i))
  echo "http://$USER:$PASS@$(hostname -I | awk '{print $1}'):$PORT"
done

echo "=== Done ==="
