#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

WORKDIR="/home/cloudfly"
mkdir -p $WORKDIR
cd $WORKDIR

# -------------------------------
# Cài đặt 3proxy
install_3proxy() {
    echo "Installing 3proxy..."
    yum -y install wget gcc make bsdtar zip >/dev/null
    wget -qO- https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz | bsdtar -xvf-
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
}

install_3proxy

# -------------------------------
# Thông số proxy
IP4=$(curl -4 -s icanhazip.com)
IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')  # subnet /64
FIRST_PORT=21000
LAST_PORT=$((FIRST_PORT + 1999))  # 2000 proxy
DATA_FILE="$WORKDIR/data.txt"

# -------------------------------
# Tạo file data.txt: port/IPv6
gen_data() {
  > $DATA_FILE
  for port in $(seq $FIRST_PORT $LAST_PORT); do
      ipv6="$IP6_PREFIX:$(printf '%x%x:%x%x:%x%x:%x%x\n' $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)"
      echo "$port/$IP4/$ipv6" >> $DATA_FILE
  done
}

gen_data

# -------------------------------
# Tạo 3proxy.cfg không user/pass
PROXY_CFG="/usr/local/etc/3proxy/3proxy.cfg"
cat > $PROXY_CFG <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
auth none

$(awk -F "/" '{print "proxy -6 -n -a -p"$1" -i"$2" -e"$3}' $DATA_FILE)
EOF

# -------------------------------
# Script thêm IPv6
BOOT_IFCONFIG="$WORKDIR/boot_ifconfig.sh"
cat > $BOOT_IFCONFIG <<'EOF'
#!/bin/bash
WORKDIR="/home/cloudfly"
DATA_FILE="$WORKDIR/data.txt"
# Xóa IPv6 cũ trước khi thêm
ip -6 addr flush dev eth0
for ip in $(awk -F "/" '{print $3}' $DATA_FILE); do
    ip -6 addr add $ip/64 dev eth0
done
EOF
chmod +x $BOOT_IFCONFIG

# -------------------------------
# Mở port iptables
BOOT_IPTABLES="$WORKDIR/boot_iptables.sh"
cat > $BOOT_IPTABLES <<'EOF'
#!/bin/bash
WORKDIR="/home/cloudfly"
DATA_FILE="$WORKDIR/data.txt"
for port in $(awk -F "/" '{print $1}' $DATA_FILE); do
    iptables -I INPUT -p tcp --dport $port -j ACCEPT
done
EOF
chmod +x $BOOT_IPTABLES

# -------------------------------
# Chạy proxy lần đầu
bash $BOOT_IFCONFIG
bash $BOOT_IPTABLES
ulimit -n 2000048
/usr/local/etc/3proxy/bin/3proxy $PROXY_CFG &

# -------------------------------
# Xuất danh sách proxy
awk -F "/" '{print "http://"$2":"$1}' $DATA_FILE > $WORKDIR/proxy.txt
echo "✅ 2000 Proxy created!"
echo "Sample proxies:"
head -n 20 $WORKDIR/proxy.txt

# -------------------------------
# Script xoay IPv6 mỗi phút
ROTATE_SCRIPT="/root/auto_rotate_ipv6.sh"
cat > $ROTATE_SCRIPT <<'EOF'
#!/bin/bash
WORKDIR="/home/cloudfly"
DATA_FILE="$WORKDIR/data.txt"
PROXY_CFG="/usr/local/etc/3proxy/3proxy.cfg"
IP4=$(curl -4 -s icanhazip.com)
IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

# Tạo dữ liệu mới
> $DATA_FILE
FIRST_PORT=21000
LAST_PORT=$((FIRST_PORT + 1999))
for port in $(seq $FIRST_PORT $LAST_PORT); do
    ipv6="$IP6_PREFIX:$(printf '%x%x:%x%x:%x%x:%x%x\n' $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)"
    echo "$port/$IP4/$ipv6" >> $DATA_FILE
done

# Flush IPv6 cũ + thêm IPv6 mới
ip -6 addr flush dev eth0
for ip in $(awk -F "/" '{print $3}' $DATA_FILE); do
    ip -6 addr add $ip/64 dev eth0
done

# Reload 3proxy
pkill -TERM -f 3proxy
sleep 1
/usr/local/etc/3proxy/bin/3proxy $PROXY_CFG &>/dev/null &
echo "$(date) -> IPv6 rotated" >> /var/log/ipv6-rotate.log
EOF
chmod +x $ROTATE_SCRIPT

# -------------------------------
# Thêm cron xoay IPv6 mỗi phút
(crontab -l 2>/dev/null; echo "*/1 * * * * bash /root/auto_rotate_ipv6.sh >/dev/null 2>&1") | crontab -
echo "✅ IPv6 auto-rotation enabled (every 1 minute)"
