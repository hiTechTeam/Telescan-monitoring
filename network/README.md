# Private monitoring network

Monitoring traffic uses a dedicated WireGuard interface and does not modify the
existing production `wg0` relay-to-origin tunnel.

| Role | Address |
| --- | --- |
| Central monitoring | `10.78.0.1/24` |
| Moscow origin | `10.78.0.2/24` |
| EU relay | `10.78.0.3/24` |

The hub listens on UDP `51821` at `84.201.181.214`. Only the two production
public IP addresses should be allowed to reach that port. Prometheus remote
write and Loki push bind only to `10.78.0.1`.

Private keys are generated and retained under `/etc/wireguard`; only public
keys belong in the templates in this repository.

Install a role after its public-key placeholders have been replaced:

```sh
sudo ./network/ops/generate-key.sh
sudo ./network/ops/install.sh monitoring
```
