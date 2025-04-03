#!/bin/bash
set -euo pipefail

# ----------- [⚙️ SETTINGS] -----------
VMID_START=9000
VMID_END=9005
TEMPLATE_PREFIX="ubuntu-24.04-cloudinit"
ISO_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
ISO_NAME="ubuntu-24.04-cloudimg-amd64.img"
STORAGE_POOL="local-zfs"
CI_DISK="scsi0"
NODE="proxmox"
ENABLE_DISCORD_WEBHOOK=true
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
GIT_COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || true)

# ----------- [⏱️ TIMESTAMP] -----------
TODAY=$(date +%Y-%m-%d)
VMNAME="${TEMPLATE_PREFIX}-${TODAY}"
ISO_PATH="/var/lib/vz/template/iso/${ISO_NAME}"
ISO_META_PATH="/var/lib/vz/template/iso/${ISO_NAME}.meta"
MAX_TEMPLATES=5

# ----------- [📥 ISO CHECK + METADATA] -----------
echo "📦 Checking ISO version..."

LATEST_SHA256=$(curl -sI "${ISO_URL}" | grep -i 'etag:' | cut -d '"' -f2 || true)
if [[ -f "$ISO_META_PATH" ]] && grep -q "$LATEST_SHA256" "$ISO_META_PATH"; then
  echo "✅ ISO is up to date."
else
  echo "📥 Downloading latest ISO..."
  curl -Lo "$ISO_PATH" "$ISO_URL"
  echo "$LATEST_SHA256" > "$ISO_META_PATH"

  echo "🧹 Cleaning up old ISO files..."
  find /var/lib/vz/template/iso/ -type f -name "${TEMPLATE_PREFIX}*.img" ! -newer "$ISO_META_PATH" -delete
  find /var/lib/vz/template/iso/ -type f -name "${TEMPLATE_PREFIX}*.meta" ! -newer "$ISO_META_PATH" -delete
fi

# ----------- [🔢 Assign Dynamic VMID] -----------
echo "🎲 Finding next available VMID..."
for ((i=VMID_START; i<=VMID_END; i++)); do
  if ! qm status "$i" &>/dev/null; then
    VMID="$i"
    break
  fi
done

if [[ -z "${VMID:-}" ]]; then
  echo "❌ No free VMID between $VMID_START and $VMID_END."
  exit 1
fi

# ----------- [🧱 CREATE VM] -----------
echo "🧱 Creating VM $VMID..."
qm create "$VMID" \
  --name "$VMNAME" \
  --memory 2048 \
  --cores 2 \
  --cpu cputype=kvm64 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single \
  --boot c \
  --bootdisk "$CI_DISK" \
  --ostype l26 \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

# ----------- [💽 IMPORT DISK] -----------
echo "💽 Importing disk..."
qm importdisk "$VMID" "$ISO_PATH" "$STORAGE_POOL" --format raw

qm set "$VMID" \
  --$CI_DISK "$STORAGE_POOL:vm-$VMID-disk-0,cache=writeback" \
  --ide2 "$STORAGE_POOL:cloudinit" \
  --ciuser ubuntu \
  --cipassword changeme \
  --ipconfig0 ip=dhcp

# ----------- [📄 CLOUD-INIT YAML] -----------
mkdir -p /var/lib/vz/snippets
cat > /var/lib/vz/snippets/${VMNAME}-defaults.yaml <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - cloud-init
  - curl
  - wget
  - ca-certificates
  - htop
  - net-tools
  - nano
  - openssh-server

users:
  - name: ubuntu
    plain_text_passwd: "changeme"
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

chpasswd:
  expire: false

ssh_pwauth: true

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF

qm set "$VMID" --cicustom "user=local:snippets/${VMNAME}-defaults.yaml"

# ----------- [🧠 Skipping cloud-init boot check] -----------
echo "⚠️ Skipping VM boot to preserve clean cloud-init state."
echo "ℹ️ Validate cloud-init success by cloning and testing the template manually."

# ----------- [🪄 FINALIZE] -----------
qm set "$VMID" --autostart off
qm resize "$VMID" "$CI_DISK" +10G || true
qm template "$VMID"
qm set "$VMID" --tags "cloudinit,ubuntu,auto-built"

# ----------- [🧹 CLEANUP OLD TEMPLATES] -----------
echo "🧹 Cleaning up old templates..."
TEMPLATES=$(qm list | grep "${TEMPLATE_PREFIX}" | awk '{print $1,$2,$3}' | sort -k3 -r)
TEMPLATE_IDS=($(echo "$TEMPLATES" | awk '{print $1}'))

for ((i=MAX_TEMPLATES; i<${#TEMPLATE_IDS[@]}; i++)); do
  OLD_VMID="${TEMPLATE_IDS[$i]}"
  echo "🔥 Deleting old template $OLD_VMID"
  qm destroy "$OLD_VMID"
done

# ----------- [🏷️ RETAG OLD + NEW] -----------
ALL_VMS=($(qm list | grep "${TEMPLATE_PREFIX}" | sort -k3 -r | awk '{print $1}'))
for i in "${!ALL_VMS[@]}"; do
  tag="retired"
  [[ $i -eq 0 ]] && tag="active"
  qm set "${ALL_VMS[$i]}" --tags "cloudinit,ubuntu,auto-built,$tag"
done

# ----------- [📎 SYMLINK TO LATEST] -----------
ln -sf "/var/lib/vz/snippets/${VMNAME}-defaults.yaml" "/var/lib/vz/snippets/${TEMPLATE_PREFIX}-latest.yaml"

# ----------- [📤 DISCORD NOTIFICATION] -----------
if [[ "$ENABLE_DISCORD_WEBHOOK" == "true" ]]; then
  echo "📢 Sending Discord notification..."

  BUILT_TIME=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  VERSION="v1.0.0"
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

  curl -s -X POST "$DISCORD_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "embeds": [
    {
      "title": "✅ Proxmox Template Created",
      "color": 65280,
      "fields": [
        { "name": "🆔 VMID", "value": "$VMID", "inline": true },
        { "name": "🏷️ Name", "value": "$VMNAME", "inline": true },
        { "name": "💾 Pool", "value": "$STORAGE_POOL", "inline": true },
        { "name": "📅 Built", "value": "$BUILT_TIME", "inline": false },
        { "name": "🧬 Version", "value": "$VERSION", "inline": true },
        { "name": "🔖 Commit", "value": "$COMMIT", "inline": true }
      ]
    }
  ]
}
EOF
fi

# ----------- [📋 SUMMARY] -----------
echo "✅ Template Created:"
echo "   🆔 VMID: $VMID"
echo "   🏷️ Name: $VMNAME"
echo "   💾 Pool: $STORAGE_POOL"
echo "   📅 Built: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "   🧬 Version: $VERSION"
echo "   🔖 Commit: ${GIT_COMMIT_HASH:-unknown}"


# ----------- [📁 LOGGING] (optional)
# LOGFILE="/var/log/template-builder.log"
# exec > >(tee -a "$LOGFILE") 2>&1
