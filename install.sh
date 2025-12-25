#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "请以 root 权限运行此脚本"
  exit 1
fi

echo "正在开始安装 OCI 多网卡自启动配置..."

# 1. 创建脚本存储目录
mkdir -p /usr/local/bin/oci-scripts

# 2. 创建执行脚本
# 注意：这里直接将脚本写入本地，避免每次启动都依赖 GitHub 网络
cat <<'EOF' > /usr/local/bin/oci-scripts/setup_vnic.sh
#!/bin/bash
# 下载 Oracle 官方配置脚本（如果本地不存在则下载）
URL="https://raw.githubusercontent.com/oracle/terraform-examples/master/examples/oci/connect_vcns_using_multiple_vnics/scripts/secondary_vnic_all_configure.sh"
DEST="/usr/local/bin/oci-scripts/secondary_vnic_all_configure.sh"

# 尝试更新脚本，如果失败则使用旧版本
wget -qO $DEST.tmp $URL && mv $DEST.tmp $DEST
chmod +x $DEST

# 执行配置命令
bash $DEST -c
EOF

chmod +x /usr/local/bin/oci-scripts/setup_vnic.sh

# 3. 创建 Systemd 服务
cat <<'EOF' > /etc/systemd/system/oci-vnic-config.service
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

# 4. 启用服务
systemctl daemon-reload
systemctl enable oci-vnic-config.service
systemctl start oci-vnic-config.service

echo "------------------------------------------------"
echo "安装完成！"
echo "辅助网卡已配置，且已设置为开机自启。"
echo "你可以使用 'ip addr' 查看网络状态。"
echo "------------------------------------------------"