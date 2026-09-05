# Telegram egress proxy

EU Tinyproxy lets central Grafana reach `api.telegram.org` through
`wg-monitor`. It listens only on `10.78.0.3:8888`, accepts only `10.78.0.1` and
permits HTTPS CONNECT to port 443.

```sh
sudo ./egress/ops/install.sh
```
