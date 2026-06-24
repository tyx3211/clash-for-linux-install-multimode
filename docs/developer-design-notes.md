# 开发者设计说明

本文面向维护者，解释本项目相对上游 `nelvko/clash-for-linux-install` 的实现取舍。用户只想安装和使用时，优先看 [快速上手教程](quickstart.md) 和 [当前版本使用指南](usage-guide.md)。

更完整的致谢、分支策略和用户可见差异见 [上游致谢与项目差异](upstream-and-differences.md)。本文只记录维护时容易误改的不变量。

## 总体取舍

上游项目的核心价值是：用 shell 完成 mihomo / clash 内核下载、订阅管理、配置合并和服务管理，并尽量兼容多种 Linux init（初始化/服务管理）系统。本项目继续保留这个基础，但维护目标不同：

- 默认场景是共享机和普通用户环境，不能假设用户有 root 或可用的 `systemd --user`。
- 默认托管模式是 `tmux`，`nohup` 是普通用户备用模式，`systemd` 只在需要 Tun 时显式启用。
- 安装和更新尽量不覆盖用户长期维护的配置，`config/` 保存用户偏好，`resources/` 保存运行状态和生成物。
- 命令行行为尽量可解释：启动内核不自动注入代理变量，Tun 不静默切换托管模式，端口冲突只提示建议端口。

同步上游时，可以吸收订阅、下载、配置合并、Tun 默认配置和错误处理机制；但不能直接照搬上游的单一 service 管理心智模型。

## 托管模式不变量

上游当前主线会在运行时检测服务管理器。非 root 情况下会退回 `nohup`；root 情况下更偏向系统服务。这个模型适合“安装者就是系统管理员”的机器。

本项目把托管模式拆成运行时 adapter（适配器）：

- `tmux`：默认用户态，session 名包含安装路径标识，只管理当前安装实例。
- `nohup`：用户态备用，写 pid 文件，停止前校验 pid 对应当前内核和当前安装目录。
- `systemd`：系统级 service（系统服务），只操作属于当前安装目录的 unit（服务单元）。

`INIT_TYPE` 只表示默认托管模式，不表示安装后唯一模式。运行时必须允许：

```bash
clashon --mode tmux
clashrestart --mode nohup
clashrestart --mode systemd
```

维护相关代码时，要保留这几个边界：

- `clashon --mode <另一个模式>` 遇到已有模式运行时应拒绝，提示使用 `clashrestart --mode ...`。
- `clashoff` 默认只关闭当前活跃模式；探测到多个模式同时运行时应拒绝自动清理。
- `clashstatus --all` 展示三种 adapter 探测结果，状态文件只能作为线索，真实状态以 adapter 探测为准。

核心文件：

- `scripts/lib/service-runtime.sh`
- `scripts/cmd/clashctl.sh`
- `scripts/install/service-render.sh`

## systemd 设计

这是本项目和上游差异最大的地方。

上游 systemd 模板不写 `User=`，系统服务默认以 root 身份运行内核进程。上游还支持 OpenRC、SysVinit、runit 等服务管理器，并在普通用户场景退回 `nohup`。它的设计心智更接近：

```text
root 安装 + 系统服务 = root 运行代理内核
普通用户运行 = nohup
```

本项目的 systemd 路线是：

```text
sudo 注册系统级 service（系统服务）
/etc/systemd/system/<kernel>.service
不写 User=，系统服务默认以 root 运行 mihomo / clash
安装目录仍归属 sudo 调用用户
```

也就是说，本项目没有使用 `systemd --user`。service（系统服务）仍然由系统级 systemd 管理，mihomo / clash 进程也按系统服务默认行为以 root 身份运行。默认安装目录仍是 sudo 调用用户的 `~/clashctl`，不是 `/root/clashctl`。

这是一个有意的整机级运行模型，不是安全沙箱，也不是严格降权边界。之前版本曾尝试 `User=<安装用户>` 加完整 capability（Linux 能力）运行 mihomo；这个模型能覆盖 TUN、路由和透明代理等内核网络能力，但不能覆盖 `systemd-resolved` 的 D-Bus/Polkit 授权。实际问题是 `resolvectl dns/domain/default-route` 会被策略拒绝，而 mihomo / sing-tun 可能静默吞掉错误，最终系统 resolver 没有切到 Tun 链路。维护时不要把 full capability 当作 root 或 Polkit 授权的等价替代。

这个设计的收益：

- 运行时可以在 `tmux`、`nohup`、`systemd` 之间切换，三种模式共享同一个普通用户安装目录。
- systemd/Tun 场景下，root 运行的服务读取同一个安装目录；脚本生成的长期配置和运行时配置仍应归还给安装用户，避免切回用户态时权限失败。
- 不依赖共享机上经常不可用的 `systemd --user`。

这个设计的代价：

- systemd/Tun 是 root 级整机网络托管，不是最小权限模型。它只适合单用户机器、个人虚拟机或明确授权的专用机器；共享机默认仍应使用 `tmux` / `nohup`。
- systemd unit 会让 root 执行安装目录里的 `bin/mihomo` / `bin/clash` 和 `resources/runtime.yaml`。因此安装目录 owner（属主）在 systemd/Tun 场景下等价于这个 root 服务的管理员；不要把普通不可信用户的可写目录注册成 systemd/Tun 安装目录。
- sudo 安装或 root 排障过程中生成的运行时文件，必须保证安装用户可读写。
- 不能让 root 环境下的 `~` 漂移到 `/root/clashctl`；sudo 安装默认仍应落到 sudo 调用用户的安装目录。
- 运行时 systemd 操作使用 `sudo -n systemctl`，没有免密 sudo 时必须明确失败，不能卡住等待密码。
- 公开的 `clashstatus` 在 systemd 模式下应展示 `systemctl status`，和上游的状态命令心智保持一致；内部启动、重启、UI 和升级流程需要确认本机控制口可用时，应调用 `_clash_api_health_check`，不要复用 public status。
- systemd unit 不应设置 `LimitNPROC`、`LimitNOFILE` 等项目级资源限制。资源上限交给系统默认、发行版策略和宿主机 cgroup；本项目不额外压低或固定这些限制。

因此维护时必须保留这些权限修复点：

- 安装收尾可以递归修复安装目录 owner（属主），确保安装用户后续能继续维护配置、订阅和用户态托管模式。
- 运行时配置合并只修复新生成的 `resources/runtime.yaml`，不要在普通命令里递归 `chown` 整个安装目录。
- root shell 可以使用只读命令和代理入口；不推荐 root 日常执行订阅、mixin、secret、运行模式切换等持久可写操作。

相关文件：

- `install.sh`
- `scripts/lib/common.sh`
- `scripts/lib/config.sh`
- `scripts/install/service-render.sh`
- `scripts/tools/sync-root-rc.sh`
- `scripts/tools/unsync-root-rc.sh`

## Tun 边界

Tun 只在已注册且属于当前安装的 systemd service（系统服务）下开放。`clashtun on` 不应该帮用户静默切到 systemd，也不应该在 `tmux` / `nohup` 下尝试绕过权限限制。

原因是 Tun 会影响整机网络路径。共享机上，这不是一个普通用户进程内部的小开关；它应该要求明确授权和明确托管模式。

维护 `scripts/lib/tun.sh` 时要保留：

- 当前活跃模式不是 `systemd` 时拒绝开启 Tun，并提示 `clashrestart --mode systemd`。
- 未注册 systemd service 时拒绝开启 Tun，并提示先执行 `sudo bash install.sh --init systemd`。
- Tun 配置写入或重启失败时回滚，不要把不可用配置留给下一次启动。
- Tun 网卡存在不等于 DNS 已接管；如果本机 DNS 确实由 `systemd-resolved` 接管，`tunstatus` 和 `clashtun on` 必须检查 DNS scope、DNS server 和 `~.` 路由域是否切到 Tun 链路。仅安装了 `resolvectl` 但未使用 `systemd-resolved` 的系统不应被这个检查误判失败。
- shell wrapper（外层脚本）只做诊断，不调用 `resolvectl dns` / `resolvectl domain` / `resolvectl default-route` / `resolvectl revert` 接管 DNS 生命周期。DNS 接管和清理应由 root 模式运行的 mihomo / sing-tun 自己处理。

## 配置和状态边界

本项目把用户长期配置和本机运行状态分开：

- `config/mixin.yaml`：用户维护的 mihomo / clash mixin。
- `config/clashctl.yaml`：`clashctl` 自身行为，例如新 shell 自动代理。
- `config/subscriptions.yaml`：订阅元信息。
- `resources/install-state.yaml`：本机安装状态。
- `resources/service-state.yaml`：运行时托管线索。
- `.env`：安装默认值和旧版本兼容入口，短期保留，但不应继续扩大为持久配置中心。

开发新功能时，优先把用户愿意长期维护的偏好放进 `config/`；把安装路径、默认模式、已注册服务等本机状态放进 `resources/install-state.yaml` 或同类状态文件；临时覆盖继续使用命令行参数或环境变量。

## 和上游同步时要注意

可以直接比较和吸收的上游改动：

- 下载失败处理、超时、代理前缀、订阅转换等边界。
- mihomo / clash 配置模板更新。
- Tun 默认配置中和 mihomo 当前版本匹配的字段。
- 帮助输出、错误信息和配置校验。

需要重新适配的上游改动：

- 任何假设“当前只有一个 service manager”的逻辑。
- 任何在 `clashon` / `clashoff` 中同时修改代理环境变量和内核状态的逻辑。
- 任何默认 root systemd 运行、默认写 `/var/log` / `/run`、或把普通用户强制退回 `nohup` 的逻辑。
- 任何 `rm -rf`、`cp -rf`、递归覆盖安装目录的更新流程。

代码审查时优先看这些问题：

- 是否会误操作另一个安装目录的 tmux session、pid 或 systemd unit。
- 是否会在 root 下生成普通用户不可写的 runtime / profile / log 文件。
- 是否把用户配置、运行状态和安装状态混在同一个文件里。
- 是否在 shell 字符串拼接里遗漏 quoting（转义）。
- 是否在失败路径留下半写入配置，或吞掉了原始错误信息。

## 测试要求

普通单元测试不应触碰真实 `~/clashctl`、真实 `tmux` 会话、真实 mihomo 进程或真实 systemd。测试默认应在 `/tmp/tyx/clash-test-run.*` 下创建临时安装目录，并在退出时清理。

需要人工端到端验证时，按 [手工端到端检查清单](manual-e2e-checklist.md) 执行。systemd/Tun 用例属于高风险项，只应在单用户虚拟机或明确授权机器上跑。
