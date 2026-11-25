#!/bin/sh
# Firewall and fail2ban for the Ubuntu 24.04 VM.
# This is not part of `make up`. Run it yourself, on the VM, as root.
#
#   sudo sh scripts/harden-vm.sh --yes
#
# What it does:
#   * allows SSH, HTTP, and HTTPS through ufw, then turns the firewall on
#   * installs fail2ban and a jail for repeated 401/403 hits on the admin paths
#
# What it does not do:
#   * It does not publish the database, GeoServer's own port, or Grafana's own port.
#     Those stay on 127.0.0.1 in docker-compose.yml.
#   * It does not restart Docker unless you also pass --restart-docker.
#
# Docker's userland proxy hides the visitor's real IP from Nginx. fail2ban would
# then see every visitor as the Docker gateway and could lock the gateway out.
# Pass --restart-docker to set "userland-proxy": false so Nginx sees real IPs.
# Do that from a console, not from an SSH session you cannot afford to drop.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root on the Ubuntu VM." >&2
    exit 1
fi

yes_flag=""
restart_docker=""
for arg in "$@"; do
    case "$arg" in
        --yes) yes_flag=1 ;;
        --restart-docker) restart_docker=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [ -z "$yes_flag" ]; then
    echo "Refusing to change the firewall without --yes." >&2
    echo "Read the comments at the top of this script first." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ufw fail2ban

ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

root_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d /var/log/geoknight
cp "$root_dir/hardening/fail2ban/filter.d/geoknight-nginx.conf" /etc/fail2ban/filter.d/geoknight-nginx.conf
cp "$root_dir/hardening/fail2ban/jail.d/geoknight.conf" /etc/fail2ban/jail.d/geoknight.conf

# The compose file writes Nginx logs to ./logs/nginx. Point fail2ban at a stable copy.
if [ ! -L /var/log/geoknight/nginx ]; then
    ln -s "$root_dir/logs/nginx" /var/log/geoknight/nginx
fi

systemctl enable fail2ban
systemctl restart fail2ban || service fail2ban restart || true

if [ -n "$restart_docker" ]; then
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        echo "daemon.json already exists. Add \"userland-proxy\": false yourself, then restart Docker." >&2
    else
        printf '%s\n' '{ "userland-proxy": false }' > /etc/docker/daemon.json
        echo "Wrote /etc/docker/daemon.json and restarting Docker."
        systemctl restart docker || service docker restart
    fi
else
    echo
    echo "fail2ban is installed. If Nginx logs show the Docker gateway instead of visitor IPs,"
    echo "re-run with --restart-docker from a console session."
fi

echo "Firewall is on. SSH, port 80, and port 443 are allowed."
