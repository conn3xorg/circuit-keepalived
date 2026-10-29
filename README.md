# circuit-keepalived

A Conn3x circuit that runs keepalived on two or more hosts so they share a floating IP address. One host holds it; when that host goes down, or its load balancer stops, another picks the address up within a few seconds, and clients pointed at it never have to know.

The usual case is a pair of HAProxy or nginx boxes in front of everything else. You give the circuit the address and the hosts, and it writes the same VRRP setup on Debian, Ubuntu, Fedora and Rocky Linux: priorities from the order of your hosts, unicast adverts to the other hosts, since most clouds and plenty of switches drop multicast, and a check that hands the address over when the service behind it dies.

## Usage

```hcl
module "keepalived" {
  source = "github.com/conn3xorg/circuit-keepalived?ref=v0.1.0"

  hosts = {
    lb1 = { address = "203.0.113.10", vrrp_address = "10.0.0.11" }
    lb2 = { address = "203.0.113.11", vrrp_address = "10.0.0.12" }
  }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  interface   = "eth1"
  virtual_ips = ["10.0.0.100/24"]
  auth_pass   = var.vrrp_password

  track_script = {
    script = "/usr/bin/systemctl is-active --quiet haproxy"
  }
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

`lb1` sorts first, so it gets priority 200 and holds `10.0.0.100`; `lb2` gets 190. If HAProxy stops on `lb1`, the track script fails and `lb1` gives the address up. When HAProxy is back, the address moves back. Set `nopreempt = true` if you'd rather it stayed where it is until the next failure, which saves a second blip.

Hosts send their adverts to each other's `vrrp_address`, or to the address Conn3x logs in on when there isn't one. Set it when that isn't the address on `interface`, as with a public address for SSH and a private network for VRRP.

The circuit pairs with [circuit-haproxy](https://github.com/conn3xorg/circuit-haproxy). Bind its frontends to the floating address, such as `bind = "10.0.0.100:80"`: the circuit sets `net.ipv4.ip_nonlocal_bind`, so HAProxy on the backup starts and listens on an address it doesn't hold yet.

To try it on two throwaway containers first, see [examples/local](examples/local).

### Priorities

Without a `priority` in its host object, each host gets one from its place in the hosts sorted by name: 200, 190, 180 and so on. Give a host object `priority`, from 1 to 254, to pick your own. The host with the highest priority that's up and passing its track script holds the addresses.

A `track_script` with the default `weight = 0` puts a host whose check fails into the FAULT state, where it holds nothing, whatever the priorities. A non-zero `weight` adds to the host's priority instead, positive while the check passes or negative while it fails; make a negative one bigger than the gap between the priorities, or nothing moves.

### Cloud floating IPs

keepalived moves an address by adding it to the new master's interface and announcing it with gratuitous ARP. That works on a LAN, a homelab or a VLAN you control. Cloud networks mostly ignore it: they only deliver traffic for addresses the provider assigned to a machine, so other hosts can't reach a floating address that keepalived added on its own. A DigitalOcean reserved IP, an AWS Elastic IP or a Hetzner floating IP moves through the provider's API instead.

For those, point `notify_script` at a script of your own that calls the API when the host becomes MASTER. keepalived runs it with the instance name and the new state, `MASTER`, `BACKUP` or `FAULT`. The circuit doesn't write or install that script. `virtual_ips` is still required, and the address it adds stays local to the host.

## What it does

On each host, in order:

1. Installs `keepalived` from the distribution's own repositories.
2. Sets `net.ipv4.ip_nonlocal_bind = 1`, now and at boot.
3. Unless the host has an `interface`, reads the interface its default route goes out of, once.
4. Writes `/etc/keepalived/keepalived.conf.conn3x`, checks it with `keepalived -t`, and copies it over `/etc/keepalived/keepalived.conf` only if keepalived accepts it. A config with a mistake fails the apply and leaves the running one alone. A hand edit to the live file is put back on the next apply.
5. Starts keepalived now and at boot, and reloads it when the config changes.

The config has one VRRP instance, `conn3x`, with every host starting as `BACKUP` so the priorities decide the master. Track scripts run as root, with keepalived's script security on, so a script has to be somewhere only root can write to.

With `auth_pass` set, the config goes through `content_wo`, which keeps it out of the plan and out of state. Without one, the plan shows the config's diff.

### What it doesn't do

- It doesn't open VRRP in a firewall. VRRP is IP protocol 112, not TCP or UDP, and every host has to receive it from the others. firewalld blocks it by default; ufw on Ubuntu is off by default but blocks it when on. With firewalld, `firewall-cmd --permanent --add-rich-rule='rule protocol value="vrrp" accept'` lets it in.
- It doesn't do IPv6 floating addresses, which need a VRRP instance of their own.
- It doesn't set up LVS virtual servers, keepalived's other half.
- It doesn't install what the track script checks.
- Deleting the module leaves keepalived installed and running with the last config.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`, and `vrrp_address`, `interface` and `priority` for that host. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `virtual_ips` | list(string) | Required | Floating IPv4 addresses with their prefix length, such as `["10.0.0.100/24"]`. The master holds all of them. |
| `interface` | string | `null` | Interface the addresses go on and adverts go out of, such as `"eth1"`. When null, each host's default route interface. A host object's `interface` overrides it. |
| `virtual_router_id` | number | `51` | VRRP router ID, 1 to 255. Two keepalived groups on one network need different IDs. |
| `advert_int` | number | `1` | Seconds between the master's adverts. A backup takes over after about three missed ones. |
| `nopreempt` | bool | `false` | Leave the addresses where they are when a higher-priority host comes back. |
| `auth_pass` | string | `null` | VRRP password, 1 to 8 printable characters, the same on every host. Sensitive. VRRP sends it in the clear, so it keeps out a neighbouring group with the same router ID rather than an attacker. When null, no authentication. |
| `track_script` | object | `null` | A check keepalived runs: `script`, a command starting with an absolute path, and optional `interval` (default `2` seconds), `fall` and `rise` (default `2` each) and `weight` (default `0`). See [Priorities](#priorities). |
| `notify_script` | string | `null` | Absolute path of a script on each host that keepalived runs on every state change. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the config the circuit writes, `/etc/keepalived/keepalived.conf`. |
| `priorities` | Each host's VRRP priority, such as `{ lb1 = 200, lb2 = 190 }`. |
| `master` | The host with the highest priority, which holds the addresses while it's up. |

## Requirements

Requires Conn3x v0.6.7 or later and systemd on each host, with a package mirror the host can reach. Every host needs to receive VRRP, IP protocol 112, from the others' `vrrp_address`.

## Tested on

Rocky Linux 10 (keepalived 2.2.8), Fedora 45 (2.3.4), Ubuntu 24.04 (2.2.8) and Debian 13 (2.3.3). CI applies [examples/local](examples/local) to two hosts of each on amd64, checks that the second plan has no changes, checks the floating address is on the first host, moves to the second when keepalived stops and when the track script fails, and comes back each time. It then applies with `nopreempt` and checks the address stays put when the first host returns.

On two Ubuntu 24.04 droplets in one DigitalOcean VPC, VRRP ran between their private addresses on `eth1` with an unused VPC address as the floating one: the first droplet held it, it moved to the second when keepalived stopped and when the track script failed, and it came back each time. After both rebooted, the first held it again and the plan had no changes. Other machines couldn't reach the floating address there, as [Cloud floating IPs](#cloud-floating-ips) describes.

## License

MPL-2.0. See [LICENSE](LICENSE). keepalived itself is GPL-2.0.
