# OpenWrt Telecom Evidence Community

A shell-based network measurement and evidence collector for OpenWrt and iStoreOS. It preserves raw results, creates SHA-256 manifests and run-to-run chain links, supports daily collection, sealing, verification, export organization, and optional SSH backup.

## Safety defaults

- No test VPS, upload URL, remote backup host, or Ookla server is configured by default.
- Packet capture is disabled by default.
- Installation does not install packages and does not change firewall, interfaces, routes, DNS, proxy, or other network settings.
- Existing configuration files are preserved.
- Cron is opt-in with `--enable-cron`.
- Evidence and configuration are preserved during uninstall.

Review the scripts before use. Measurements can consume bandwidth, storage, and ISP quota. Packet captures and evidence outputs may include public/local IP addresses, routes, interface details, and other sensitive network metadata.

## Install

Copy or clone the repository onto the router, then:

```sh
chmod +x *.sh
./install.sh
```

To also add the daily collector and organizer cron entries:

```sh
./install.sh --enable-cron
```

The installer reports missing commands. Required commands must be installed by the administrator; optional features are skipped when their command is unavailable. Package names vary by OpenWrt release and architecture.

## Configure

Edit `/etc/telecom-evidence.conf`. External tests stay disabled until you fill their values.

```sh
TEST_SERVER_IP="203.0.113.10"
IPERF_HOST="203.0.113.10"
SPEEDTEST_SERVER_IDS="3633"
```

`3633` is only a historical example associated with a China Telecom Shanghai Ookla endpoint. It is not required, endorsed, or guaranteed to remain available. Find and configure server IDs suitable for your own location and test purpose. Leaving `SPEEDTEST_SERVER_IDS` blank disables Ookla tests.

HTTP/HTTPS upload endpoints must be servers you control or are authorized to test. For HTTPS, point `HTTPS_CA_FILE` at the CA certificate used to verify that receiver. Credentials, tokens, and cookies should not be embedded in URLs or committed.

Optional remote backup is configured separately in `/etc/telecom-evidence-organizer.conf`. It is disabled unless `VPS_HOST` is non-empty and a readable passwordless SSH key is provided.

## Use

```sh
telecom-evidence.sh --check
telecom-evidence.sh
telecom-evidence-seal.sh
telecom-evidence-verify.sh
telecom-evidence-organize.sh
```

By default, evidence is stored under `/root/telecom-evidence` and organized exports under `/root/telecom-evidence-export`. The daily wrapper runs at most once per Shanghai calendar day after 20:30 when invoked periodically.

## Uninstall

```sh
./uninstall.sh
```

This removes installed programs and matching cron lines. It intentionally keeps evidence and configuration so uninstall cannot destroy collected material.

## Privacy and integrity limits

SHA-256 manifests detect later file changes; they do not by themselves prove who created the evidence or guarantee legal admissibility. The active network/routing/firewall snapshots may expose sensitive infrastructure details. Inspect exports before sharing them.

## License

MIT. See [LICENSE](LICENSE).
