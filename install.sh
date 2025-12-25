#!/bin/bash

# 强制转换当前脚本为 Unix 格式（防止执行时报错）
# 如果你是直接粘贴到 GitHub 网页编辑器里的，这一部分是双重保险
export LC_ALL=C

# 1. 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as root."
  exit 1
fi

echo "Starting OCI Secondary VNIC configuration setup..."

# 2. 安装必要工具
apt-get update && apt-get install -y wget curl

# 3. 创建本地执行脚本
mkdir -p /usr/local/bin/oci-scripts
cat << 'EOF' > /usr/local/bin/oci-scripts/setup_vnic.sh
#!/bin/bash
# 下载 Oracle 官方脚本并执行
RAW_URL="https://raw.githubusercontent.com/oracle/terraform-examples/master/examples/oci/connect_vcns_using_multiple_vnics/scripts/secondary_vnic_all_configure.sh"
LOCAL_SCRIPT="/usr/local/bin/oci-scripts/secondary_vnic_all_configure.sh"

wget -qO $LOCAL_SCRIPT $RAW_URL || curl -sL $RAW_URL -o $LOCAL_SCRIPT
chmod +x $LOCAL_SCRIPT
bash $LOCAL_SCRIPT -c
EOF

chmod +x /usr/local/bin/oci-scripts/setup_vnic.sh

# 4. 创建 Systemd 服务（开机自启）
cat << 'EOF' > /etc/systemd/system/oci-vnic-config.service
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

# 5. 启用并立即运行
systemctl daemon-reload
systemctl enable oci-vnic-config.service
systemctl start oci-vnic-config.service

echo "Done! Secondary VNIC is configured and will persist after reboot."
