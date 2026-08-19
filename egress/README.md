# Telegram egress proxy

The Telegram Bot API is not reachable directly from the Yandex Cloud network
used by the central monitoring host. A minimal Tinyproxy service on the EU
relay provides HTTPS egress over the existing private `wg-monitor` tunnel.

Security boundaries:

- listens only on `10.78.0.3:8888`;
- accepts only the central monitoring client `10.78.0.1`;
- permits only the HTTP CONNECT method destination port `443`;
- whitelists only `api.telegram.org`;
- remains protected by the EU host UFW policy.

Install from the repository root on the EU host:

```sh
sudo ./egress/ops/install.sh
```
