# https://developer.hashicorp.com/packer/integrations/hashicorp/virtualbox/latest/components/builder/iso
# https://www.packer.io/docs/templates/hcl_templates/blocks/packer for more info
packer {
  required_plugins {
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = "~> 1"
    }
    ansible = {
      version = "~> 1"
      source = "github.com/hashicorp/ansible"
    }
  }
}

# https://developer.hashicorp.com/packer/docs/templates/hcl_templates/blocks/build/source
# https://developer.hashicorp.com/packer/integrations/hashicorp/virtualbox
# https://developer.hashicorp.com/packer/integrations/hashicorp/virtualbox/latest/components/builder/iso
source "virtualbox-iso" "ubuntu_builder" {
  boot_command = [
    "<wait>c",
    "<wait>set gfxpayload=keep",
    "<wait><enter>",
    "<wait>linux /casper/vmlinuz --- autoinstall ds=nocloud;",
    "<wait><enter>",
    "<wait>initrd /casper/initrd",
    "<wait><enter>",
    "<wait>boot",
    "<wait><enter>"
  ]
  cd_files = [
      "http/meta-data",
      "http/user-data"
  ]
  cd_label               = "CIDATA" # https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html#source-2-drive-with-labeled-filesystem
  boot_wait              = "10s"
  disk_size              = "${var.virtualbox_disk_size}"
  rtc_time_base          = "UTC"
  gfx_accelerate_3d      = false
  gfx_controller         = "vmsvga"
  gfx_vram_size          = 128
  guest_additions_mode   = "upload"
  guest_additions_path   = "VBoxGuestAdditions_{{ .Version }}.iso"
  guest_os_type          = "Ubuntu_64"
  headless               = "${var.headless}"
  iso_checksum           = "${var.iso_checksum}"
  iso_url                = "${var.iso_url}"
  shutdown_command       = "echo '${var.ansible_user}' | sudo -S shutdown -P now"
  ssh_handshake_attempts = "9001"
  ssh_password           = "${var.ansible_password}"
  ssh_port               = var.ssh_nat_port
  ssh_host               = "127.0.0.1"
  skip_nat_mapping       = true
  ssh_timeout            = "10000s"
  ssh_username           = "${var.ansible_user}"
  disable_shutdown       = true
  keep_registered        = true
  vboxmanage             = [
    ["modifyvm", "{{ .Name }}", "--memory", "${var.ram}"],
    ["modifyvm", "{{ .Name }}", "--vram", "128"],
    ["modifyvm", "{{ .Name }}", "--cpus", "${var.cpus}"],
    ["modifyvm", "{{ .Name }}", "--natpf1", "guestssh,tcp,127.0.0.1,${var.ssh_nat_port},,22"],  # https://www.virtualbox.org/manual/ch06.html#natforward
    ["modifyvm", "{{ .Name }}", "--nat-localhostreachable1", "on"], # https://github.com/hashicorp/packer/issues/12118
  ]
  vm_name                = "${var.vm_name}"
  export_opts = [
        "--manifest",
        "--vsys", "0",
        "--ovf20",

        #"--description", "${var.vm_description}",
        #"--version", "${var.vm_version}"
  ]
  format = "ova"
}

# https://www.packer.io/docs/templates/hcl_templates/blocks/build
build {
  sources = ["source.virtualbox-iso.ubuntu_builder"]

  provisioner "shell" {
    environment_vars  = ["HOME_DIR=/home/${var.ansible_user}"]
    execute_command   = "echo '${var.ansible_password}' | {{ .Vars }} sudo -S -E sh -eux '{{ .Path }}'"
    scripts           = [
      "scripts/guest_additions.sh",
    ]
  }

  provisioner "ansible" {
    command       = "scripts/ansible.sh"
    playbook_file = "ansible/main.yml"
    user          = "${var.ansible_user}"
    extra_arguments = [
      "--extra-vars",
      "vm_name=${var.vm_name} ansible_user=${var.ansible_user} ansible_password=${var.ansible_password} ansible_sudo_pass=${var.ansible_password}",
    ]
  }

  provisioner "shell" {
    environment_vars  = ["HOME_DIR=/home/${var.ansible_user}"]
    execute_command   = "echo '${var.ansible_password}' | {{ .Vars }} sudo -S -E sh -eux '{{ .Path }}'"
    expect_disconnect = true
    skip_clean        = true
    scripts           = [
      "scripts/obsidian.sh",
    ]
  }

  provisioner "shell" {
    environment_vars  = ["HOME_DIR=/home/${var.ansible_user}"]
    execute_command   = "echo '${var.ansible_password}' | {{ .Vars }} sudo -S -E sh -eux '{{ .Path }}'"
    expect_disconnect = true
    skip_clean        = true
    scripts           = [
      "scripts/cleanup.sh",
    ]
  }

  // not sure how to accomplish this...doesn't work in a local-shell provisioner b/c vbox has lock on vm due to packer...
  // doesn't exist here, b/c it's been exported already...
  // post-processor "shell-local" {
  //   inline            = ["/usr/bin/vboxmanage modifyvm \"${var.vm_name}\" --natpf1 delete \"guestssh\""]
  // }
}
