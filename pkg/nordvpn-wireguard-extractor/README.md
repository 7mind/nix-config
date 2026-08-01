# NordVPN WireGuard Extractor

Extract NordVPN WireGuard configurations, or list recommended peer endpoints.

```bash
# Full .conf files (requires access token)
export NORDVPN_ACCESS_TOKEN="..."
nordvpn-wireguard-extractor --country nl --count 5 --output ./configs

# Peer endpoints only (no token, no files) — paste into peerEndpoint
nordvpn-wireguard-extractor --endpoints --country nl --count 10
```
