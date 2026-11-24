# komari-tcpquality

给 Komari 节点一键安装 Atlas 三网回程附件（TcpQuality）。

## 一键安装

在节点上用 root 跑这一条（把 `<节点UUID>` 换成该节点在 Komari 里的 UUID）：

```bash
curl -fsSL -o /tmp/install-tcpquality.sh "https://raw.githubusercontent.com/4258806/komari-tcpquality/main/install-tcpquality.sh" && nohup bash /tmp/install-tcpquality.sh <节点UUID> > /tmp/tcpquality-install.log 2>&1 & tail -F /tmp/tcpquality-install.log
```

看到 `全部完成` 就按 Ctrl+C 退出。

## 脚本做的事

1. 检查环境：Python ≥ 3.12、`unshare`/`chroot`/`mount`/`ip`、`curl`、磁盘 ≥ 600MB
2. 下载附件包并验 SHA256，解压到 `/opt/komari/attachments/tcpquality/0.4.0`
3. `prepare.py` 准备 rootfs（下载约 100MB，自动校验）
4. 从 systemd 启动参数取 Agent 身份，写 0600 配置（全程不打印 token）；已有标准 Agent 配置文件时直接用它
5. `enroll.py` 登记
6. 跑一次 `collector.py run` 验收（约 15–25 分钟），通过了才开定时

只装附件，不改 Agent 本身，不改代理配置。

## 装完还差一步（网页上，1 分钟）

后台 → 插件 → Atlas Return Route Probe → 配置，把新节点并进 `nodes` 的同一个大括号里（已有节点保留，节点之间用英文逗号隔开；不要把新节点连同大括号粘到原来后面——两个大括号并排是错的，插件会读不懂配置）：

```json
"<节点UUID>": {"enabled": true, "city": "beijing", "periodMinutes": 720, "collector": "tcpquality"}
```

## 要求

- Linux 节点，Python ≥ 3.12，root 身份
- 节点上已装 Komari Agent

## 文件

- `install-tcpquality.sh`：一键安装脚本
- `atlas-komari-tcpquality-0.4.0.zip`：附件包，SHA-256 为 `d8dc2957d8239dbd9774de2ce4a846cbf6874fed62310f02e0fcd680a797ede2`（跑脚本时自动校验）

## 来源

附件包由 [MagnetOscar/Atlas](https://github.com/MagnetOscar/Atlas) 仓库 `companion/tcpquality/` 的官方打包脚本构建，Atlas 遵循 MIT 协议（Copyright (c) 2025 Tony Liu，2026 年新增贡献沿用 MIT）。`install-tcpquality.sh` 是本仓库自写的安装脚本。
