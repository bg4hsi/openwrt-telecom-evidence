# OpenWrt Telecom Evidence Community

[中文](#中文说明) | [English](#english)

## 中文说明

一套适用于 OpenWrt 与 iStoreOS 的 Shell 网络测速和留证工具。它会保留原始测试结果，生成 SHA-256 清单和跨次运行的证据链，并提供每日采集、封存、校验、归档整理以及可选 SSH 备份功能。

### 安全默认设置

- 默认不配置测速 VPS、上传地址、远程备份主机或 Ookla 服务器。
- 默认关闭抓包功能。
- 安装程序不会自动安装软件包，也不会修改防火墙、接口、路由、DNS、代理或其他网络配置。
- 安装时保留已有配置文件。
- 定时任务需要通过 `--enable-cron` 显式启用。
- 卸载时保留配置和已采集的证据。

使用前请审阅脚本。测速可能消耗带宽、存储空间和运营商流量额度。抓包及证据输出可能包含公网/内网 IP、路由、接口状态和其他敏感网络信息。

### 安装

将仓库复制或克隆到路由器，然后执行：

```sh
chmod +x *.sh
./install.sh
```

如需同时添加每日采集和归档整理定时任务：

```sh
./install.sh --enable-cron
```

安装程序会报告缺失的命令。必需依赖需要由管理员自行安装；缺少可选命令时，只会跳过对应功能。OpenWrt 不同版本和架构的软件包名称可能不同。

### 配置

编辑 `/etc/telecom-evidence.conf`。在填写相应配置前，所有外部测速功能均保持关闭。

```sh
TEST_SERVER_IP="203.0.113.10"
IPERF_HOST="203.0.113.10"
SPEEDTEST_SERVER_IDS="3633"
```

Ookla 服务器 ID `3633` 只是过去与中国电信上海节点相关的示例，并非必需或官方推荐，也不保证长期可用。请根据所在地和测试目的自行选择服务器；将 `SPEEDTEST_SERVER_IDS` 留空即可关闭 Ookla 测试。

HTTP/HTTPS 上传地址必须属于你控制或获准测试的服务器。使用 HTTPS 时，请将 `HTTPS_CA_FILE` 指向用于验证接收服务器的 CA 证书。不要在 URL 或公开仓库中写入账号、密码、Token 或 Cookie。

可选远程备份通过 `/etc/telecom-evidence-organizer.conf` 单独配置。只有 `VPS_HOST` 非空且指定的免密 SSH 密钥可读时，远程备份才会启用。

### 使用

```sh
telecom-evidence.sh --check
telecom-evidence.sh
telecom-evidence-seal.sh
telecom-evidence-verify.sh
telecom-evidence-organize.sh
```

证据默认保存在 `/root/telecom-evidence`，整理后的导出文件默认保存在 `/root/telecom-evidence-export`。定期调用 daily 脚本时，每个上海日期在 20:30 之后最多执行一次采集。

### 卸载

```sh
./uninstall.sh
```

卸载程序会删除已安装的脚本和对应定时任务，但会有意保留配置及证据文件，避免误删已采集材料。

### 隐私与完整性限制

SHA-256 清单可以发现文件事后发生的变化，但本身不能证明材料由谁生成，也不能保证其法律可采性。网络、路由和防火墙快照可能暴露敏感基础设施信息；对外分享前请先检查导出内容。

### 许可证

采用 MIT 许可证，详见 [LICENSE](LICENSE)。

---

## English

A shell-based network measurement and evidence collector for OpenWrt and iStoreOS. It preserves raw results, creates SHA-256 manifests and run-to-run chain links, and supports daily collection, sealing, verification, export organization, and optional SSH backup.

### Safety defaults

- No test VPS, upload URL, remote backup host, or Ookla server is configured by default.
- Packet capture is disabled by default.
- Installation does not install packages or change firewall, interfaces, routes, DNS, proxy, or other network settings.
- Existing configuration files are preserved.
- Cron is opt-in with `--enable-cron`.
- Evidence and configuration are preserved during uninstall.

Review the scripts before use. Measurements can consume bandwidth, storage, and ISP quota. Packet captures and evidence outputs may include public/private IP addresses, routes, interface details, and other sensitive network metadata.

### Install

Copy or clone the repository onto the router, then run:

```sh
chmod +x *.sh
./install.sh
```

To also add the daily collector and organizer cron entries:

```sh
./install.sh --enable-cron
```

The installer reports missing commands. Required commands must be installed by the administrator; optional features are skipped when their commands are unavailable. Package names vary by OpenWrt release and architecture.

### Configure

Edit `/etc/telecom-evidence.conf`. External tests remain disabled until their values are configured.

```sh
TEST_SERVER_IP="203.0.113.10"
IPERF_HOST="203.0.113.10"
SPEEDTEST_SERVER_IDS="3633"
```

Ookla server ID `3633` is only a historical example associated with a China Telecom Shanghai endpoint. It is not required, endorsed, or guaranteed to remain available. Select servers appropriate for your location and purpose. Leaving `SPEEDTEST_SERVER_IDS` blank disables Ookla tests.

HTTP/HTTPS upload endpoints must be servers you control or are authorized to test. For HTTPS, point `HTTPS_CA_FILE` to the CA certificate used to verify the receiver. Do not embed accounts, passwords, tokens, or cookies in URLs or public commits.

Optional remote backup is configured separately in `/etc/telecom-evidence-organizer.conf`. It is enabled only when `VPS_HOST` is non-empty and the configured passwordless SSH key is readable.

### Use

```sh
telecom-evidence.sh --check
telecom-evidence.sh
telecom-evidence-seal.sh
telecom-evidence-verify.sh
telecom-evidence-organize.sh
```

Evidence is stored under `/root/telecom-evidence` by default, with organized exports under `/root/telecom-evidence-export`. When invoked periodically, the daily wrapper collects at most once per Shanghai calendar day after 20:30.

### Uninstall

```sh
./uninstall.sh
```

The uninstaller removes installed programs and matching cron entries. It intentionally preserves configuration and collected evidence.

### Privacy and integrity limits

SHA-256 manifests can detect later file changes; they do not prove who created the evidence or guarantee legal admissibility. Network, routing, and firewall snapshots may expose sensitive infrastructure details. Inspect exports before sharing them.

### License

MIT. See [LICENSE](LICENSE).
