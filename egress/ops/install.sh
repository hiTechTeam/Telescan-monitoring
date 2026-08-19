#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root" >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
config_source="$repo_dir/egress/tinyproxy.conf"
filter_source="$repo_dir/egress/telegram-filter"

if [[ ! -r "$config_source" || ! -r "$filter_source" ]]; then
  echo "Missing Tinyproxy configuration files" >&2
  exit 1
fi

if ! ip -4 address show dev wg-monitor | grep -qE 'inet 10\.78\.0\.3/'; then
  echo "This installer must run on the EU host with wg-monitor 10.78.0.3" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends tinyproxy

if [[ -f /etc/tinyproxy/tinyproxy.conf && ! -e /etc/tinyproxy/tinyproxy.conf.package-default ]]; then
  install -m 0644 \
    /etc/tinyproxy/tinyproxy.conf \
    /etc/tinyproxy/tinyproxy.conf.package-default
fi

install -m 0644 "$config_source" /etc/tinyproxy/tinyproxy.conf
install -m 0644 "$filter_source" /etc/tinyproxy/telescan-telegram-filter

ufw allow in on wg-monitor \
  from 10.78.0.1 to 10.78.0.3 \
  port 8888 proto tcp \
  comment 'Telescan Telegram egress'

systemctl enable tinyproxy.service
systemctl restart tinyproxy.service

deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  if systemctl is-active --quiet tinyproxy.service && \
     ss -lnt | grep -qE '10\.78\.0\.3:8888[[:space:]]'; then
    systemctl --no-pager --full status tinyproxy.service
    ss -lntp | grep -E '10\.78\.0\.3:8888[[:space:]]'
    exit 0
  fi
  sleep 2
done

systemctl --no-pager --full status tinyproxy.service || true
journalctl --no-pager --unit tinyproxy.service --lines=100
exit 1
