# Local example

Applies circuit-keepalived to two throwaway Rocky Linux 10 containers with systemd, `a` and `b`, which share the floating address `10.226.61.100`. You need Conn3x and Podman.

keepalived adds and removes addresses on the containers' network interface, so they run privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` `a` sorts first, so it gets priority 200 to `b`'s 190 and holds the address. To watch it move:

```sh
podman exec circuit-keepalived-a systemctl stop keepalived
podman exec circuit-keepalived-b grep -w 10.226.61.100 /proc/net/fib_trie
podman exec circuit-keepalived-a systemctl start keepalived
```

Within a few seconds of the stop, the address is on `b`; after the start it goes back to `a`. Touching `/etc/keepalived/maintenance` on `a` does the same through the example's track script, without stopping anything. To keep the address on `b` when `a` comes back, apply with `-var nopreempt=true`.

`up.sh` puts both containers on a Podman network of their own, `10.226.61.0/24`, and writes each one's address there to `up.auto.tfvars`. Conn3x logs in through port forwards on `127.0.0.1`, which the containers can't use to reach each other, so `main.tf` passes those addresses as each host's `vrrp_address`.

`up.sh` listens on `127.0.0.1:2222` for `a` and `2223` for `b`. Set `PORT` and `PORT_B` to use other ports, and `NAME` to change the containers' and network's name from `circuit-keepalived`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the containers, their volumes and network, the key and the state.
