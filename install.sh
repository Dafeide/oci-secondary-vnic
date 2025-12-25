curl -sSL https://raw.githubusercontent.com/oracle/terraform-examples/master/examples/oci/connect_vcns_using_multiple_vnics/scripts/secondary_vnic_all_configure.sh -o /tmp/vnic_test.sh && \
sudo mkdir -p /usr/local/bin/oci-scripts && \
cat <<EOF | sudo tee /usr/local/bin/oci-scripts/setup_vnic.sh > /dev/null
#!/bin/bash
# 自动下载并执行 Oracle 官方 VNIC 配置脚本
wget -qO /tmp/secondary_vnic_all_configure.sh https://raw.githubusercontent.com/oracle/terraform-examples/master/examples/oci/connect_vcns_using_multiple_vnics/scripts/secondary_vnic_all_configure.sh
bash /tmp/secondary_vnic_all_configure.sh -c
EOF
sudo chmod +x /usr/local/bin/oci-scripts/setup_vnic.sh && \
cat <<EOF | sudo tee /etc/systemd/system/oci-vnic-config.service > /dev/null
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
sudo systemctl daemon-reload && sudo systemctl enable oci-vnic-config.service && sudo systemctl start oci-vnic-config.service && echo "--- 配置完成！辅助网卡已激活，且下次重启会自动运行 ---"
