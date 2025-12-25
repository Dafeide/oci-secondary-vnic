#!/bin/bash
set -e

echo "[+] Installing OCI Secondary VNIC auto-run service..."

cat >/usr/local/bin/secondary-vnic.sh <<'EOF'
#!/bin/bash
set -e

URL="https://raw.githubusercontent.com/oracle/terraform-examples/master/examples/oci/connect_vcns_using_multiple_vnics/scripts/secondary_vnic_all_configure.sh"
DIR="/root/secondary_vnic"

mkdir -p "$DIR"
cd "$DIR"

wget -qO secondary_vnic_all_configure.sh "$URL"
chmod +x secondary_vnic_all_configure.sh
bash secondary_vnic_all_configure.sh -c
EOF

chmod +x /usr/local/bin/secondary-vnic.sh

cat >/etc/systemd/system/secondary-vnic.service <<'EOF'
[Unit]
Description=Configure Oracle Secondary VNIC on Boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/secondary-vnic.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable secondary-vnic.service

echo "[✓] Done.
Secondary VNIC will be configured on every boot."
