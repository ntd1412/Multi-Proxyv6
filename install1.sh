#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# === RANDOM STRING ===
random() {
  tr </dev/urandom -dc A-Za-z0-9 | head -c12
  echo
}

# === RANDOM IPv6 GENERATOR ===
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
  ip64() {
    echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
  }
  echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# === INSTALL 3PROXY ===
install_3proxy() {
  echo "Installing 3proxy..."
  URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
  wget -qO- $URL | bsdtar -xvf- >/dev/null
  cd 3proxy-3proxy-0.8.6
  make -f Makefile.Linux >/dev/null
  mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
  cp src/3proxy /usr/local/etc/3proxy/bin/
  cd $WORKDIR
}

# === GENERATE 3PROXY CONFIG ===
gen_3proxy() {
  cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456 
flush
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\nflush\n"}' ${WORKDATA})
EOF
}

# === CREATE USER PROXY FILE ===
gen_proxy_file_for_user() {
  cat >proxy.txt <<EOF
$(awk -F "/" '{print "http://"$1":"$2"@"$3":"$4}' ${WORKDATA})
EOF
}

# === GENERATE INITIAL DATA ===
gen_data() {
  seq $FIRST_PORT $LAST_PORT | while read port; do
    echo "user$port/$(random)/$IP4/$port/$(gen64 $IP6)"
  done
}

# === IPTABLES + IFCONFIG ===
gen_iptables() {
  awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -j ACCEPT"}' ${WORKDATA}
}
gen_ifconfig() {
  awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA}
}

# === MAIN SCRIPT ===
echo "Installing dependencies..."
yum -y install wget gcc net-tools bsdtar zip >/dev/null

WORKDIR="/home/cloudfly"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

install_3proxy

IP4=$(curl -4 -s icanhazip.com)
IP6="2001:df7:c600:ee23"   # Fixed subnet for your VPS

FIRST_PORT=21000
LAST_PORT=$(($FIRST_PORT + 2000))

gen_data >$WORKDATA
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x boot_*.sh

bash $WORKDIR/boot_iptables.sh
bash $WORKDIR/boot_ifconfig.sh

ulimit -n 1000048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &

gen_proxy_file_for_user
echo "=== Proxy installed successfully ==="
cat proxy.txt

# === AUTO ROTATE IPV6 EACH 1 MINUTE ===
cat <<'AUTOSCRIPT' >/root/auto_rotate_ipv6.sh
#!/bin/bash
WORKDIR="/home/cloudfly"
WORKDATA="${WORKDIR}/data.txt"
CONFIG="/usr/local/etc/3proxy/3proxy.cfg"
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
  ip64() {
    echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
  }
  echo "2001:df7:c600:ee23:$(ip64):$(ip64):$(ip64):$(ip64)"
}
> $WORKDATA
IP4=$(curl -4 -s icanhazip.com)
seq 21000 21050 | while read port; do
  echo "user$port/$(tr </dev/urandom -dc A-Za-z0-9 | head -c12)/$IP4/$port/$(gen64)" >> $WORKDATA
done

bash /home/cloudfly/boot_ifconfig.sh
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
echo "$(date) -> IPv6 rotated" >> /var/log/ipv6-rotate.log
AUTOSCRIPT

chmod +x /root/auto_rotate_ipv6.sh
(crontab -l 2>/dev/null; echo "*/1 * * * * bash /root/auto_rotate_ipv6.sh >/dev/null 2>&1") | crontab -
echo "✅ IPv6 auto-rotation enabled (every 1 minute)"
