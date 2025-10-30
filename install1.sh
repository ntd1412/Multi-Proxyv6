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
FIRST_PORT=21000
LAST_PORT=22999   # 2000 proxy
DATA_FILE="$WORKDIR/data.txt"
PROXY_CFG="/usr/local/etc/3proxy/3proxy.cfg"

ARRAY=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
IP4=$(curl -4 -s icanhazip.com)

# -------------------------------
# Hàm sinh IPv6 ngẫu nhiên
gen64() {
    ip64() {
        echo "${ARRAY[$RANDOM % 16]}${ARRAY[$RANDOM % 16]}${ARRAY[$RANDOM % 16]}${ARRAY[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# -------------------------------
# Tạo dữ liệu proxy IPv6
gen_ipv6_data() {
    IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
    > $DATA_FILE
    for port in $(seq $FIRST_PORT $LAST_PORT); do
        ipv6=$(gen64 $IP6_PREFIX)
        echo "$port/$ipv6" >> $DATA_FILE
    done
}

# -------------------------------
# Tạo 3proxy.cfg
gen_3proxy_cfg() {
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

$(awk -F "/" -v ip4=$IP4 '{print "proxy -6 -n -a -p"$1" -i"ip4" -e"$2}' $DATA_FILE)
EOF
}

# -------------------------------
# Thêm IPv6 vào eth0
BOOT_IFCONFIG="$WORKDIR/boot_ifconfig.sh"
cat > $BOOT_IFCONFIG <<'EOF'
#!/bin/bash
WORKDIR="/home/cloudfly"
DATA_FILE="$WORKDIR/data.txt"
for ip in $(awk -F "/" '{print $2}' $DATA_FILE); do
    ip -6 addr add $ip/64 dev eth0 2>/dev/null || true
done
EOF
chmod +x $BOOT_IFCONFIG

# -------------------------------
# Mở port bằng ip6tables
BOOT_IPTABLES="$WORKDIR/boot_iptables.sh"
cat > $BOOT_IPTABLES <<'EOF'
#!/bin/bash
WORKDIR="/home/cloudfly"
DATA_FILE="$WORKDIR/data.txt"
for port in $(awk -F "/" '{print $1}' $DATA_FILE); do
    ip6tables -I INPUT -p tcp --dport $port -j ACCEPT
done
EOF
chmod +x $BOOT_IPTABLES

# -------------------------------
# Chạy proxy lần đầu
gen_ipv6_data
gen_3proxy_cfg
bash $BOOT_IFCONFIG
bash $BOOT_IPTABLES
ulimit -n 1000048
/usr/local/etc/3proxy/bin/3proxy $PROXY_CFG &

# Xuất danh sách proxy IPv4:PORT
awk -F "/" -v ip=$IP4 '{print ip ":" $1}' $DATA_FILE > $WORKDIR/proxy.txt
echo "✅ 2000 IPv4:PORT proxies created!"
cat $WORKDIR/proxy.txt

# -------------------------------
# Script xoay IPv6 mà không restart 3proxy
ROTATE_SCRIPT="$WORKDIR/auto_rotate_ipv6.sh"
cat > $ROTATE_SCRIPT <<'EOF'
#!/bin/bash
WORKDIR="/home/cloudfly"
DATA_FILE="$WORKDIR/data.txt"
PROXY_CFG="/usr/local/etc/3proxy/3proxy.cfg"
FIRST_PORT=21000
LAST_PORT=22999

ARRAY=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
IP4=$(curl -4 -s icanhazip.com)

gen64() {
    ip64() {
        echo "${ARRAY[$RANDOM % 16]}${ARRAY[$RANDOM % 16]}${ARRAY[$RANDOM % 16]}${ARRAY[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Lấy prefix IPv6 mới
IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

# Tạo dữ liệu mới
> $DATA_FILE
for port in $(seq $FIRST_PORT $LAST_PORT); do
    ipv6=$(gen64 $IP6_PREFIX)
    echo "$port/$ipv6" >> $DATA_FILE
done

# Xóa IPv6 cũ khỏi eth0
OLD_IPS=$(ip -6 addr show dev eth0 | grep global | awk '{print $2}' | cut -d'/' -f1)
for ip in $OLD_IPS; do
    ip -6 addr del $ip/64 dev eth0 2>/dev/null || true
done

# Thêm IPv6 mới
for ip in $(awk -F "/" '{print $2}' $DATA_FILE); do
    ip -6 addr add $ip/64 dev eth0 2>/dev/null || true
done

# Reload 3proxy config mà không kill process
kill -HUP $(pidof 3proxy)

# Cập nhật proxy.txt với IP4:PORT
awk -F "/" -v ip=$IP4 '{print ip ":" $1}' $DATA_FILE > $WORKDIR/proxy.txt
echo "$(date) -> IPv6 rotated without restarting 3proxy" >> /var/log/ipv6-rotate.log
EOF
chmod +x $ROTATE_SCRIPT

# -------------------------------
# Thêm cron xoay IPv6 mỗi phút
(crontab -l 2>/dev/null; echo "*/1 * * * * bash $ROTATE_SCRIPT >/dev/null 2>&1") | crontab -
echo "✅ IPv6 auto-rotation enabled (every 1 minute without restarting 3proxy)"
