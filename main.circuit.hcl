locals {
  # Hosts sorted by name: without a priority of its own, the first gets 200,
  # the next 190, and so on, so the first is master while it's up.
  names    = sort(keys(var.hosts))
  priority = { for i, name in local.names : name => try(var.hosts[name].priority, max(1, 200 - 10 * i)) }

  # Where the other hosts send this one's VRRP adverts: its vrrp_address,
  # else the address Conn3x logs in on.
  vrrp_address = { for name, h in var.hosts : name => try(h.vrrp_address, h.address, h) }

  config    = "/etc/keepalived/keepalived.conf"
  candidate = "/etc/keepalived/keepalived.conf.conn3x"

  has_secret = nonsensitive(var.auth_pass != null)

  # A host's interface comes from its host object, then the interface
  # input, then the interface its default route goes out of.
  interface = {
    for name, h in var.hosts : name => coalesce(
      try(h.interface, null),
      var.interface,
      try(trimspace(nonsensitive(conn3x_command.keepalived_interface__default[name].stdout)), null),
    )
  }

  detect_hosts = { for name, h in var.hosts : name => h if try(h.interface, var.interface) == null }

  # Every host starts as BACKUP and the highest priority takes over, which
  # is what nopreempt needs and works the same without it.
  keepalived_conf = {
    for me in local.names : me => join("\n", concat(
      [
        <<-EOT
        # Written by Conn3x. Changes here are overwritten on the next apply.
        global_defs {
            router_id ${me}
            script_user root
            enable_script_security
        }
        EOT
      ],
      var.track_script == null ? [] : [<<-EOT
        vrrp_script conn3x_check {
            script "${var.track_script.script}"
            interval ${var.track_script.interval}
            fall ${var.track_script.fall}
            rise ${var.track_script.rise}
        ${var.track_script.weight == 0 ? "" : "    weight ${var.track_script.weight}\n"}}
        EOT
      ],
      ["${join("\n", compact(concat(
        [
          "vrrp_instance conn3x {",
          "    state BACKUP",
          "    interface ${local.interface[me]}",
          "    virtual_router_id ${var.virtual_router_id}",
          "    priority ${local.priority[me]}",
          "    advert_int ${var.advert_int}",
          var.nopreempt ? "    nopreempt" : "",
        ],
        local.has_secret ? [
          "    authentication {",
          "        auth_type PASS",
          "        auth_pass ${var.auth_pass}",
          "    }",
        ] : [],
        length(local.names) < 2 ? [] : concat(
          ["    unicast_peer {"],
          [for name in local.names : "        ${local.vrrp_address[name]}" if name != me],
          ["    }"],
        ),
        ["    virtual_ipaddress {"],
        [for ip in var.virtual_ips : "        ${ip}"],
        ["    }"],
        var.track_script == null ? [] : ["    track_script {", "        conn3x_check", "    }"],
        var.notify_script == null ? [] : ["    notify \"${var.notify_script}\""],
        ["}"],
      )))}\n"],
    ))
  }
}

# Reads the default route's interface once, from the kernel's routing
# table, so it needs no ip command. Hosts that name an interface skip it.
circuit "keepalived_interface" {
  hosts = local.detect_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "default" {
    command {
      command = "awk '$2 == \"00000000\" { print $1; exit }' /proc/net/route | grep ."
    }
  }
}

circuit "keepalived" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "package" {
    package {
      name = "keepalived"
    }
  }

  # Lets a service on a backup bind the floating address before it arrives,
  # so it's already listening when the address moves over.
  step "nonlocal_bind" {
    sysctl {
      name  = "net.ipv4.ip_nonlocal_bind"
      value = "1"
    }
  }

  # The rendered config lands beside the live one first. With an auth_pass
  # in it, it goes through content_wo, which keeps it out of state and out
  # of the plan; without one, the plan shows the diff.
  step "candidate" {
    for_each = local.has_secret ? [] : ["config"]
    file {
      path    = local.candidate
      content = local.keepalived_conf[each.key]
      mode    = "0600"
    }
  }

  step "candidate_secret" {
    for_each = local.has_secret ? ["config"] : []
    file {
      path       = local.candidate
      content_wo = local.keepalived_conf[each.key]
      mode       = "0600"
    }
  }

  # Copies the candidate over the live config only once keepalived -t
  # accepts it, so a typo never reaches the running keepalived. Also puts
  # it back after a hand edit to the live file.
  step "config" {
    command {
      command  = "keepalived -t -f ${local.candidate} && install -m 600 ${local.candidate} ${local.config}"
      unless   = "[ \"$(sha256sum < ${local.candidate})\" = \"$(sha256sum < ${local.config})\" ]"
      triggers = { candidate = try(conn3x_file.keepalived__candidate["${each.key}/config"].revision, conn3x_file.keepalived__candidate_secret["${each.key}/config"].revision) }
    }
    notify = [handler.reload]
  }

  step "running" {
    service {
      name    = "keepalived"
      state   = "started"
      enabled = true
    }
  }

  # A reload rereads the config without restarting keepalived.
  handler "reload" {
    service {
      name   = "keepalived"
      action = "reload"
    }
  }
}
