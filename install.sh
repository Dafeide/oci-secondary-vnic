#!/bin/bash
export LC_ALL=C
set -e

[ "$EUID" -eq 0 ] || { echo "Error: Please run as root."; exit 1; }

echo "Starting OCI Secondary VNIC configuration setup..."

# 1. 依赖
apt-get update && apt-get install -y wget curl iproute2

# 2. Debian 12 默认没有 /etc/iproute2/rt_tables，脚本需要往里写路由表
mkdir -p /etc/iproute2
if [ ! -f /etc/iproute2/rt_tables ]; then
  if [ -f /usr/share/iproute2/rt_tables ]; then
    cp /usr/share/iproute2/rt_tables /etc/iproute2/rt_tables
  else
    printf '255\tlocal\n254\tmain\n253\tdefault\n0\tunspec\n' > /etc/iproute2/rt_tables
  fi
fi

# 3. 下载官方脚本
DIR=/usr/local/bin/oci-scripts
LOCAL_SCRIPT=$DIR/secondary_vnic_all_configure.sh
RAW_URL="https://raw.githubusercontent.com/oracle/terraform-examples/master/examples/oci/connect_vcns_using_multiple_vnics/scripts/secondary_vnic_all_configure.sh"
mkdir -p $DIR
wget -qO $LOCAL_SCRIPT $RAW_URL || curl -fsSL $RAW_URL -o $LOCAL_SCRIPT
[ -s $LOCAL_SCRIPT ] || { echo "Error: download failed"; exit 1; }

# 4. 自动探测 IMDS 版本（优先 v2，其次 v1）
if curl -fs --max-time 5 -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics/ >/dev/null 2>&1; then
  MD_VER=v2
  sed -i "s#^declare -r MD_URL=.*#declare -r MD_URL='http://169.254.169.254/opc/v2/vnics/'#" $LOCAL_SCRIPT
  sed -i 's#\$CURL -s \$MD_URL#$CURL -s -H "Authorization: Bearer Oracle" $MD_URL#' $LOCAL_SCRIPT
  grep -q "opc/v2/vnics" $LOCAL_SCRIPT || { echo "Patch failed: MD_URL"; exit 1; }
  grep -q 'Authorization: Bearer Oracle' $LOCAL_SCRIPT || { echo "Patch failed: curl header"; exit 1; }
elif curl -fs --max-time 5 http://169.254.169.254/opc/v1/vnics/ >/dev/null 2>&1; then
  MD_VER=v1   # 原脚本默认就是 v1，无需修改
else
  echo "Error: cannot reach OCI metadata service (v1 or v2)"; exit 1
fi
echo "Using IMDS $MD_VER"

# 5. MTU 改为 1500（与网卡当前 MTU 一致）
sed -i 's#^declare -ir MTU=9000#declare -ir MTU=1500#' $LOCAL_SCRIPT
chmod +x $LOCAL_SCRIPT

# 6. 开机执行脚本（不再联网下载）
cat > $DIR/setup_vnic.sh <<'EOF'
#!/bin/bash
sleep 3
exec bash /usr/local/bin/oci-scripts/secondary_vnic_all_configure.sh -c
EOF
chmod +x $DIR/setup_vnic.sh

# 7. systemd 服务
cat > /etc/systemd/system/oci-vnic-config.service <<'EOF'
[Unit]
Description=Configure OCI Secondary VNICs
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oci-scripts/setup_vnic.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable oci-vnic-config.service
systemctl restart oci-vnic-config.service || true

echo "------ status ------"
systemctl --no-pager status oci-vnic-config.service | head -n 15 || true
echo "------ result ------"
bash $LOCAL_SCRIPT
ip -4 addr show
ip rule
echo "Done! (IMDS $MD_VER)"
