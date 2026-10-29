variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts, vrrp_address, interface or priority."

  validation {
    condition     = length(var.hosts) >= 1
    error_message = "hosts needs at least one host, and a floating address wants two or more."
  }

  validation {
    condition     = alltrue([for h in var.hosts : try(h.priority, null) == null || try(h.priority >= 1 && h.priority <= 254 && floor(h.priority) == h.priority, false)])
    error_message = "A host's priority must be a whole number from 1 to 254."
  }

  validation {
    condition     = alltrue([for h in var.hosts : try(h.vrrp_address, null) == null || can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", h.vrrp_address))])
    error_message = "A host's vrrp_address must be an IPv4 address, such as \"10.0.0.11\"."
  }

  validation {
    condition     = alltrue([for h in var.hosts : try(h.interface, null) == null || can(regex("^[A-Za-z0-9_.@-]{1,15}$", h.interface))])
    error_message = "A host's interface must be a network interface name, such as \"eth1\"."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "virtual_ips" {
  type        = list(string)
  description = "Floating IPv4 addresses with their prefix length, such as [\"10.0.0.100/24\"]. The master holds all of them."

  validation {
    condition     = length(var.virtual_ips) >= 1
    error_message = "virtual_ips needs at least one address."
  }

  validation {
    condition     = alltrue([for ip in var.virtual_ips : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", ip)) && can(cidrhost(ip, 0))])
    error_message = "Each of virtual_ips must be an IPv4 address with a prefix length, such as \"10.0.0.100/24\"."
  }
}

variable "interface" {
  type        = string
  default     = null
  description = "Network interface the floating addresses go on and VRRP adverts go out of, such as \"eth1\". When null, each host's default route interface. A host object's interface overrides it."

  validation {
    condition     = var.interface == null || can(regex("^[A-Za-z0-9_.@-]{1,15}$", coalesce(var.interface, "-")))
    error_message = "interface must be a network interface name, such as \"eth1\"."
  }
}

variable "virtual_router_id" {
  type        = number
  default     = 51
  description = "VRRP router ID, 1 to 255. Every keepalived group on the same network needs its own."

  validation {
    condition     = var.virtual_router_id >= 1 && var.virtual_router_id <= 255 && floor(var.virtual_router_id) == var.virtual_router_id
    error_message = "virtual_router_id must be a whole number from 1 to 255."
  }
}

variable "advert_int" {
  type        = number
  default     = 1
  description = "Seconds between the master's adverts. A backup takes over after about three missed ones."

  validation {
    condition     = var.advert_int >= 1 && var.advert_int <= 255 && floor(var.advert_int) == var.advert_int
    error_message = "advert_int must be a whole number of seconds from 1 to 255."
  }
}

variable "nopreempt" {
  type        = bool
  default     = false
  description = "Keep the floating addresses where they are when a higher-priority host comes back, instead of moving them back to it."
}

variable "auth_pass" {
  type        = string
  default     = null
  sensitive   = true
  description = "VRRP password, up to 8 characters, the same on every host. It keeps strays out rather than attackers: VRRP sends it in the clear. When null, no authentication."

  validation {
    condition     = var.auth_pass == null || try(length(var.auth_pass) >= 1 && length(var.auth_pass) <= 8 && can(regex("^[!-~]+$", var.auth_pass)), false)
    error_message = "auth_pass must be 1 to 8 printable characters with no spaces. keepalived cuts anything longer down to 8."
  }
}

variable "track_script" {
  type = object({
    script   = string
    interval = optional(number, 2)
    fall     = optional(number, 2)
    rise     = optional(number, 2)
    weight   = optional(number, 0)
  })
  default     = null
  description = "A command keepalived runs every interval seconds, such as \"/usr/bin/systemctl is-active --quiet haproxy\". After fall failures in a row, a weight of 0 puts the host in FAULT so it gives up the addresses; another weight adds to its priority instead. rise passes in a row bring it back."

  validation {
    condition     = var.track_script == null || try(startswith(var.track_script.script, "/") && !strcontains(var.track_script.script, "\"") && !strcontains(var.track_script.script, "\n"), false)
    error_message = "track_script's script must start with an absolute path, such as /usr/bin/systemctl, and can't contain double quotes or newlines."
  }

  validation {
    condition     = var.track_script == null || try(alltrue([for n in [var.track_script.interval, var.track_script.fall, var.track_script.rise] : n >= 1 && floor(n) == n]), false)
    error_message = "track_script's interval, fall and rise must be whole numbers, 1 or more."
  }

  validation {
    condition     = var.track_script == null || try(var.track_script.weight >= -253 && var.track_script.weight <= 253 && floor(var.track_script.weight) == var.track_script.weight, false)
    error_message = "track_script's weight must be a whole number from -253 to 253."
  }
}

variable "notify_script" {
  type        = string
  default     = null
  description = "Absolute path of a script on each host that keepalived runs on every state change, with the arguments INSTANCE, the instance name, conn3x, the new state, MASTER, BACKUP or FAULT, and the priority. The circuit doesn't write it."

  validation {
    condition     = var.notify_script == null || can(regex("^/[^\\s\"]+$", coalesce(var.notify_script, "-")))
    error_message = "notify_script must be an absolute path with no spaces or quotes."
  }
}
