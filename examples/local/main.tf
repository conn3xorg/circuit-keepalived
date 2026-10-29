# up.sh writes these to up.auto.tfvars: the two SSH ports, and each
# container's address on the Podman network they share.
variable "port" {
  type    = number
  default = 2222
}

variable "port_b" {
  type    = number
  default = 2223
}

variable "a_ip" {
  type = string
}

variable "b_ip" {
  type = string
}

variable "nopreempt" {
  type    = bool
  default = false
}

module "keepalived" {
  source = "../.."

  # Conn3x logs in through Podman's port forwards on 127.0.0.1, so each
  # host names the address the other sends VRRP adverts to. a sorts first,
  # so it gets priority 200 and b 190.
  hosts = {
    a = { address = "127.0.0.1", port = var.port, vrrp_address = var.a_ip }
    b = { address = "127.0.0.1", port = var.port_b, vrrp_address = var.b_ip }
  }
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  virtual_ips = ["10.226.61.100/24"]
  auth_pass   = "c0nn3x"
  nopreempt   = var.nopreempt

  # Touching /etc/keepalived/maintenance on the master hands the address to
  # the backup, which is how you'd drain it before working on it.
  track_script = {
    script = "/usr/bin/test ! -e /etc/keepalived/maintenance"
    fall   = 1
  }
}

output "master" {
  value = module.keepalived.master
}

output "priorities" {
  value = module.keepalived.priorities
}
