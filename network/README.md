# Private monitoring network

`wg-monitor` is separate from the production relay tunnel:

- central: `10.78.0.1`
- Moscow: `10.78.0.2`
- EU: `10.78.0.3`

The hub listens on UDP `51821`. Private keys stay in `/etc/wireguard`; Git
contains templates and public keys only.

```sh
sudo ./network/ops/generate-key.sh
sudo ./network/ops/install.sh monitoring
```
