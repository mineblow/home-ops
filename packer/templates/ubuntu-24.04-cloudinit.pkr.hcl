packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_url"      { type = string }
variable "proxmox_username" { type = string }
variable "proxmox_token"    { type = string }

locals {
  timestamp  = formatdate("2006-01-02", timestamp())
  image_name = "ubuntu-24.04-cloudinit-${local.timestamp}"
}

source "proxmox" "ubuntu_cloudinit" {
  proxmox_url     = var.proxmox_url
  username        = var.proxmox_username
  token           = var.proxmox_token
  insecure_skip_tls_verify = true

  node            = "proxmox"
  template_name   = local.image_name

  iso_url         = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  iso_checksum    = "auto"

  cloud_init      = true
  http_directory  = "http"
  ssh_username    = "ubuntu"
  ssh_password    = "changeme"
  ssh_wait_timeout = "10m"

  disks = [{
    storage_pool = "local-zfs"
    disk_size    = "10G"
    format       = "raw"
  }]
}

build {
  sources = ["source.proxmox.ubuntu_cloudinit"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y qemu-guest-agent cloud-init curl wget ca-certificates sudo htop net-tools nano openssh-server",
      "sudo systemctl enable qemu-guest-agent"
    ]
  }
}
