#!/bin/sh
# Packages the Ubuntu VM needs before `make up`, plus log rotation.
# This does not open the firewall. That is scripts/harden-vm.sh.
#
#   sudo sh scripts/bootstrap-vm.sh
#   sudo sh scripts/bootstrap-vm.sh --enable-cert-renew
#   sudo sh scripts/bootstrap-vm.sh --with-cron
#
# --enable-cert-renew installs the systemd timer that renews Let's Encrypt.
# --with-cron installs the cron example instead of, or in addition to, the timer.
# Pick one of those two on a public VM. Both call scripts/tls-renew.sh.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root on the Ubuntu VM: sudo sh scripts/bootstrap-vm.sh" >&2
    exit 1
fi

enable_timer=0
with_cron=0
for arg in "$@"; do
    case "$arg" in
        --enable-cert-renew) enable_timer=1 ;;
        --with-cron) with_cron=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y make jq python3 openssl gdal-bin ca-certificates curl logrotate

root_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
install_template() {
    src="$1"
    dest="$2"
    sed "s#__ROOT__#${root_dir}#g" "$src" > "$dest"
}

mkdir -p /etc/logrotate.d
install_template "$root_dir/hardening/logrotate/geoknight-nginx" /etc/logrotate.d/geoknight-nginx
echo "Installed /etc/logrotate.d/geoknight-nginx"

if [ "$enable_timer" -eq 1 ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "systemd is not available, so the timer was not installed." >&2
        exit 1
    fi
    install_template "$root_dir/hardening/systemd/geoknight-cert-renew.service" \
        /etc/systemd/system/geoknight-cert-renew.service
    install_template "$root_dir/hardening/systemd/geoknight-cert-renew.timer" \
        /etc/systemd/system/geoknight-cert-renew.timer
    systemctl daemon-reload
    systemctl enable --now geoknight-cert-renew.timer
    echo "Enabled geoknight-cert-renew.timer"
fi

if [ "$with_cron" -eq 1 ]; then
    install_template "$root_dir/hardening/cron/geoknight-cert-renew" /etc/cron.d/geoknight-cert-renew
    chmod 644 /etc/cron.d/geoknight-cert-renew
    echo "Installed /etc/cron.d/geoknight-cert-renew"
fi

echo "Packages are installed: make, jq, python3, openssl, gdal-bin."
