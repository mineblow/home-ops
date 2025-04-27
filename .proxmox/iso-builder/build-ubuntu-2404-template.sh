#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────
# ⚙️ CONFIGURATION
# ─────────────────────────────────────────
VMID_START=9010
VMID_END=9015
TEMPLATE_PREFIX="ubuntu-24.04-cloudinit"
ISO_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
ISO_NAME="ubuntu-24.04-cloudimg-amd64.img"
ISO_PATH="/var/lib/vz/template/iso/${ISO_NAME}"
STORAGE_POOL="local-zfs"
CI_DISK="scsi0"
TODAY=$(date +%Y-%m-%d)

# VM name includes the date
VMNAME="${TEMPLATE_PREFIX}-${TODAY}"

# Metadata filename does NOT have date
SHORT_VERSION=$(echo "$TEMPLATE_PREFIX" | grep -oP '[0-9]{2}\.[0-9]{2}' || echo "unknown")
STRIPPED_VERSION=$(echo "$SHORT_VERSION" | tr -d '.')
META_OUT="/var/lib/vz/template/ubuntu-${STRIPPED_VERSION}.meta.json"

# ─────────────────────────────────────────
# 🔒 PRECHECKS
# ─────────────────────────────────────────
command -v qm >/dev/null || { echo "❌ qm not found (Proxmox CLI required)"; exit 1; }
command -v curl >/dev/null || { echo "❌ curl not found"; exit 1; }

# ─────────────────────────────────────────
# 📥 ISO DOWNLOAD
# ─────────────────────────────────────────
echo "📥 Downloading latest ISO..."
curl -fLo "$ISO_PATH" "$ISO_URL"

# ─────────────────────────────────────────
# 🔢 DYNAMIC VMID ALLOCATION (Auto-delete oldest if needed)
# ─────────────────────────────────────────
echo "🎲 Finding available VMID..."
VMID=""
for ((i=VMID_START; i<=VMID_END; i++)); do
  if ! qm status "$i" &>/dev/null; then
    VMID="$i"
    break
  fi
done

if [[ -z "$VMID" ]]; then
  echo "⚠️ No free VMID found. Deleting oldest template to reclaim ID..."
  OLDEST=$(qm list | awk '$2 ~ /^'"$TEMPLATE_PREFIX"'/ { print $1","$2 }' | sort -t, -k2 | cut -d, -f1 | head -n1)
  if [[ -n "$OLDEST" ]]; then
    echo "🔥 Destroying oldest template VMID $OLDEST"
    qm destroy "$OLDEST" --purge
    VMID="$OLDEST"
  else
    echo "❌ Could not reclaim a VMID. No matching templates to delete."
    exit 1
  fi
fi

# ─────────────────────────────────────────
# 🧱 CREATE BASE VM
# ─────────────────────────────────────────
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

# ─────────────────────────────────────────
# 💽 IMPORT DISK
# ─────────────────────────────────────────
echo "💽 Importing disk..."
qm importdisk "$VMID" "$ISO_PATH" "$STORAGE_POOL" --format raw
qm set "$VMID" \
  --$CI_DISK "$STORAGE_POOL:vm-${VMID}-disk-0,cache=writeback" \
  --ide2 "$STORAGE_POOL:cloudinit" \
  --ciuser ubuntu \
  --cipassword changeme \
  --ipconfig0 ip=dhcp

# ─────────────────────────────────────────
# 🪄 FINALIZE TEMPLATE
# ─────────────────────────────────────────
qm set "$VMID" --autostart off
qm template "$VMID"
qm set "$VMID" --tags "cloudinit,ubuntu,auto-built"

# ─────────────────────────────────────────
# 🏷️ RETAG SURVIVING TEMPLATES
# ─────────────────────────────────────────
echo "🏷️ Retagging templates..."
mapfile -t SURVIVING < <(qm list | awk '$2 ~ /^'"$TEMPLATE_PREFIX"'/ { print $1","$2 }' | sort -t, -k2 -r | cut -d, -f1)
for i in "${!SURVIVING[@]}"; do
  tag="retired"
  [[ $i -eq 0 ]] && tag="active"
  qm set "${SURVIVING[$i]}" --tags "cloudinit,ubuntu,auto-built,$tag"
done

# ─────────────────────────────────────────
# 🧾 BUILD METADATA
# ─────────────────────────────────────────
echo "🧾 Building metadata..."
ISO_HASH=$(sha256sum "$ISO_PATH" | awk '{print $1}')
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_HASH=$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')
CENTRAL_TIMESTAMP=$(TZ="America/Chicago" date '+%Y-%m-%dT%H:%M:%S%z')

cat <<EOF > "$META_OUT"
{
  "iso_hash": "${ISO_HASH}",
  "script_hash": "${SCRIPT_HASH}",
  "template_id": "${VMID}",
  "timestamp": "${CENTRAL_TIMESTAMP}",
  "os_version": "ubuntu-${SHORT_VERSION}",
  "template_name": "${VMNAME}"
}
EOF

echo "📦 Metadata saved to: $META_OUT"
