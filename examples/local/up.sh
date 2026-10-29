#!/usr/bin/env sh
# Starts two throwaway hosts, a on 127.0.0.1:$PORT (default 2222) and b on
# $PORT_B (default the port after it), that Conn3x can configure, with a
# fresh SSH key and their host keys in ./known_hosts. They share a Podman
# network of their own, 10.226.61.0/24, where VRRP runs and the example's
# floating address lives. It writes the ports and each host's address on
# that network to up.auto.tfvars.
# CONTAINERFILE picks another image, such as one of Conn3x's test images.
# Needs Podman, since the hosts run systemd. keepalived adds addresses to
# the network interface, so the containers are privileged. Rootful Podman
# is simplest: CONTAINER_CONNECTION=podman-machine-default-root on a Mac,
# or PODMAN="sudo podman" on Linux.
set -eu
cd "$(dirname "$0")"
port=${PORT:-2222}
port_b=${PORT_B:-$((port + 1))}
containerfile=${CONTAINERFILE:-Containerfile}
name=${NAME:-circuit-keepalived}

podman=${PODMAN:-podman}
[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "$name" -f id_ed25519
$podman build -q -f "$containerfile" -t "$name" "$(dirname "$containerfile")" >/dev/null
$podman network exists "$name" || $podman network create --subnet 10.226.61.0/24 "$name" >/dev/null
: > known_hosts
printf 'port = %s\nport_b = %s\n' "$port" "$port_b" > up.auto.tfvars

# Fedora's image ships a fixed machine-id, and systemd derives eth0's MAC
# address from it, so two containers from it get the same one and can't
# reach each other. This keeps the address Podman gave each.
link=$(mktemp)
trap 'rm -f "$link"' EXIT
printf '[Match]\nOriginalName=*\n\n[Link]\nMACAddressPolicy=none\n' > "$link"

for host in a b; do
  p=$port
  [ "$host" = a ] || p=$port_b
  $podman rm -f -v "$name-$host" >/dev/null 2>&1 || true
  $podman create --name "$name-$host" --systemd=always --privileged \
    --network "$name" -p "127.0.0.1:$p:22" "$name" >/dev/null
  $podman cp "$link" "$name-$host:/etc/systemd/network/99-default.link"
  $podman start "$name-$host" >/dev/null
  $podman exec -i "$name-$host" sh -c 'cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' < id_ed25519.pub
  $podman exec "$name-$host" timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true
  echo "${host}_ip = \"$($podman inspect -f "{{(index .NetworkSettings.Networks \"$name\").IPAddress}}" "$name-$host")\"" >> up.auto.tfvars

  ok=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ssh-keyscan -p "$p" 127.0.0.1 > keyscan 2>/dev/null && [ -s keyscan ]; then
      cat keyscan >> known_hosts
      ok=1
      break
    fi
    sleep 1
  done
  rm -f keyscan
  if [ -z "$ok" ]; then
    echo "The container $name-$host started, but SSH didn't answer on 127.0.0.1:$p." >&2
    exit 1
  fi
done
echo "Ready on 127.0.0.1:$port and :$port_b. Now run: conn3x init && conn3x apply"
