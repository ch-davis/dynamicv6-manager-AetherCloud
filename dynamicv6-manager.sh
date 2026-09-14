# DynamicV6 Manager

`dynamicv6-manager.sh` 是一个专为 Linux 环境打造的 **AetherCloud DynamicV6 动态 IPv6 管理与路由守护脚本**。

它可以帮助你非常方便地在服务器上进行交互式的 IPv6 下发、网关切换，并通过强大的路由策略（Source 地址路由 + Metric 优先级）和后台守护进程，确保你的服务器永远不会因为 IPv6 下发失败或租约到期而“失联”。

## ✨ 核心特性

- 🛡️ **防失联设计 (安全路由)**：通过 `src` 源地址控制和 `metric` 优先级配置路由，**绝不删除机房原生路由**，**绝不触碰 IPv4**。确保即使动态 IPv6 发生故障，也能无缝回退到原生 IPv6。
- 🤖 **全自动守护与恢复**：内置自动监控逻辑（支持 Cron），能够每 3 分钟检测一次连通性；一旦发现宕机或动态 IP 丢失，自动尝试重新下发，多次失败后安全切回原生网络。
- 🖥️ **跨发行版兼容**：底层完全使用 `iproute2`，并在缺少依赖时自动通过 `apt/yum/dnf/apk/zypper` 安装 `jq`，完美适配 Debian, Ubuntu, CentOS, RHEL, Alpine, openSUSE 等所有主流系统。
- 📜 **全链路日志审计**：所有的操作步骤、报错信息和 Cron 守护日志都会双向输出并持久化存储至 `/var/log/dynamicv6-manager.log`，方便问题追踪。

---

## 🚀 快速开始

### 1. 运行要求
- 任何现代 Linux 发行版（带有 `bash` 和 `iproute2`）。
- **必须以 `root` 权限执行。**

### 2. 下载与准备
如果你的服务器上还没有此脚本，可以使用以下命令下载并赋予权限：
```bash
wget -O dynamicv6-manager.sh https://raw.githubusercontent.com/ch-davis/dynamicv6-manager-AetherCloud/refs/heads/main/dynamicv6-manager.sh
chmod +x dynamicv6-manager.sh
```

*(如果你只是一次性调试，不想在硬盘中保存文件，也可以使用一键内存执行：)*
```bash
bash <(curl -sL https://raw.githubusercontent.com/ch-davis/dynamicv6-manager-AetherCloud/refs/heads/main/dynamicv6-manager.sh)
```

### 3. 交互式运行 (推荐)
直接运行脚本即可进入可视化交互菜单：
```bash
./dynamicv6-manager.sh
```
在菜单中，你可以执行以下操作：
1. **重新下发 IPv6**：向 AetherCloud 申请刷新或下发新的动态 IPv6。
2. **切换默认 IPv6 出口**：在原生的 IPv6 和获取到的多个动态 IPv6 之间自由切换出站身份。
3. **还原所有变更**：一键清除脚本创建的所有路由表、配置文件和 Cron 任务，将网卡恢复到最原始的清爽状态。
4. **查看状态**：显示当前路由表走向、选中出口、监控状态等。
5. **开启/关闭自动恢复**：控制是否允许后台 Cron 在检测到网络中断时自动重置网络。

---

## ⚙️ 进阶：命令行与自动化

如果你需要将此脚本结合到其他自动化流程（如 Ansible, Terraform 后置脚本），你可以使用以下参数。

### 自动化无头下发
```bash
# 全自动下发，并默认使用第 1 个动态 IPv6 作为主出口
./dynamicv6-manager.sh --auto 

# 全自动下发，但保留使用机房“原生 IPv6”作为主出口（动态 IP 仅作为备用或入站使用）
./dynamicv6-manager.sh --auto --egress=native

# 全自动下发，使用第 2 个动态 IPv6 作为主出口，并同时开启后台“自动恢复”守护
./dynamicv6-manager.sh --auto --egress=dynamic:2 --auto-recovery
```

### 状态查询与运维
```bash
# 仅打印当前网络配置与出口状态
./dynamicv6-manager.sh --status

# 一键卸载所有动态路由并还原网卡
./dynamicv6-manager.sh --restore
```

### 全局参数选项
| 选项 | 说明 |
| :--- | :--- |
| `--auto-recovery` | 在自动下发时同时启用崩溃自动恢复守护进程。 |
| `--no-monitor` | 部署完成后，不自动安装 Cron 监控任务。 |
| `--iface=<name>` | 强制指定操作的网卡名称（例如 `eth0`）。默认会自动探测有默认路由的网卡。 |
| `--verbose` | 开启 Debug 详细输出，方便排查路由表的具体变化逻辑。 |
| `-h, --help` | 显示帮助菜单。 |

---

## 📂 文件与目录约定

脚本在运行中会自动生成以下状态目录和文件：

- **日志文件**：`/var/log/dynamicv6-manager.log`
  - *排查故障首选，如果你遇到疑难杂症，请追加 `--verbose` 运行脚本并将日志截取。*
- **状态存储目录**：`/var/lib/dynamicv6-manager/`
  - `config.json`: 持久化保存当前选中的出口策略和守护进程状态。
  - `RECOVERY.md`: 每次变更路由前都会生成该文档。如果在极端情况下你的服务器完全断网，可以通过 VNC 登录，按照此文件中的命令手动将路由切回原生状态。

---

## ⚠️ 注意事项

1. **多网卡环境**：脚本默认会自动推断具有出站能力的主网卡。如果你的服务器有多张网卡（如内网和外网分离），请务必在运行时使用 `--iface=网卡名` 手动指定。
2. **Cron 环境变量**：脚本已针对 Cron 极简的环境变量（PATH）做了深度优化并做了兼容后备处理，无需额外干预。
3. **请勿使用 `ip -6 route flush table main`**：在手动排障时请一定要小心，直接 flush 会把机房底层的静态路由清空，导致彻底断网，请参考脚本生成的 `RECOVERY.md` 逐条删除 `default`。
