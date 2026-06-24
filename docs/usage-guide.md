# 当前版本使用指南

本文补充 README 中没有展开的安装、运行托管模式、订阅、代理、项目更新和迁移说明。

真实机器上的运行托管切换会启动或停止内核进程，不适合在自动测试里默认执行。需要实机验证时，可以按 [手工端到端检查清单](manual-e2e-checklist.md) 执行。

## 快速选择

如果是在共享机、没有 sudo、希望容易查看进程：

```bash
bash install.sh
```

这会把默认运行托管模式设为 `tmux`。

如果没有 tmux，且只需要一个简单后台进程，安装时就选择 nohup：

```bash
bash install.sh --init nohup
```

如果机器允许 sudo，并且需要 Tun：

```bash
sudo bash install.sh --init systemd
```

## 安装前配置

安装前可以先编辑源码目录里的 `.env`。它只表示这次安装的默认值，不是安装后的主配置中心：

```bash
CLASH_BASE_DIR="$HOME/clashctl"
INIT_TYPE=tmux
CLASH_CONFIG_URL=""
```

常用配置：

- `CLASH_BASE_DIR`：安装目录。必须是绝对路径，默认 `~/clashctl`。
- `INIT_TYPE`：默认运行托管模式，可选 `tmux`、`nohup`、`systemd`。
- `CLASH_CONFIG_URL`：订阅链接。可以留空，安装末尾会交互输入。
- `URL_GH_PROXY`：GitHub 下载代理前缀。默认留空，表示直连 GitHub；安装时推荐用 `--gh-proxy <url>` 设置，而不是手工改 `.env`。
- `SUBCONVERTER_REPO`：subconverter 下载来源，默认 `tindy2013/subconverter`。
- `CLASHCTL_DOWNLOAD_TIMEOUT`：依赖下载超时。
- `CLASHCTL_SUB_TIMEOUT`：订阅下载超时。

安装完成后，本机安装状态会写入 `resources/install-state.yaml`。新版 `clashctl`、`update.sh` 和 `uninstall.sh` 都优先读取这个状态文件；`.env` 仍会保留，用于旧版本兼容和安装前默认值。适合长期维护和版本管理的配置在 `config/mixin.yaml`、`config/clashctl.yaml` 和 `config/subscriptions.yaml`。

订阅链接请始终使用双引号包起来：

```bash
CLASH_CONFIG_URL="https://example.com/sub?clash=3&extend=1"
```

## GitHub 下载代理

默认安装不使用 GitHub 下载代理。网络受限时，可以在安装时显式指定：

```bash
bash install.sh --gh-proxy https://gh-proxy.org
```

这会影响安装阶段从 GitHub 下载 `mihomo`、`yq`、`subconverter` 等依赖，并把 `URL_GH_PROXY` 写入安装目录 `.env`。后续执行 `clashctl update-self` 从 GitHub 下载项目源码时，也会复用这个前缀。

如果希望明确直连 GitHub，可以使用：

```bash
bash install.sh --no-gh-proxy
```

`--gh-proxy` 只处理 GitHub 下载地址前缀，不会开启终端代理变量，也不会修改 `clashproxy`、系统代理或 mihomo 运行时代理设置。

## 运行托管模式说明

### tmux

默认托管模式：

```bash
bash install.sh --init tmux
```

适合共享机普通用户。内核进程运行在带安装路径标识的 tmux 会话中，避免不同安装目录互相冲突。

常用检查方式：

```bash
tmux ls
clashstatus
clashlog
```

### nohup

备用用户态模式可在运行时选择：

```bash
clashon --mode nohup
```

它不依赖 tmux，但只通过 pid / pgrep 管理进程。若机器上有 tmux，优先使用 tmux。

### systemd

sudo 模式：

```bash
sudo bash install.sh --init systemd
```

适合需要 Tun 的机器。通过 sudo 安装时，服务文件由 root 写入系统目录，真实 systemd unit 默认不写 `User=`，因此 mihomo 以 root 身份运行；这能覆盖 Tun、路由、透明代理和 `systemd-resolved` DNS 接管这类整机级网络能力。
默认安装目录仍是 sudo 调用用户的 `~/clashctl`，脚本会把 root 环境下展开出来的 `/root/clashctl` 归一化回普通用户目录。

运行时启动、停止和重启 systemd 服务会走 `sudo -n systemctl`。这意味着执行命令的用户需要是 root，或者已经拥有免密 sudo 权限；脚本不会停下来等待输入 sudo 密码。

因为 systemd/Tun 路线本质上是 root 级整机网络托管，这条路线建议只用于单用户机器、个人虚拟机或明确授权的专用机器。共享机默认仍应使用 `tmux` / `nohup`。

`clashstatus` 在 systemd 路线下会展示 `systemctl --no-pager --full status <内核名>`，便于直接看到 systemd 视角的 active / failed / inactive 状态；`tmux` / `nohup` 路线仍以托管进程和本机 API 健康检查为主。启动、重启、面板地址和内核升级这些内部流程会单独检查 `/version` API，不把 systemd 的 active 状态当作 API 可用。

注册完成后，运行时切到 systemd：

```bash
clashrestart --mode systemd
clashtun on
```

卸载也需要 sudo：

```bash
sudo bash ~/clashctl/uninstall.sh
```

## 权限边界

### root shell 使用建议

默认安装实例属于执行安装的普通用户，项目不会主动修改 `/root/.bashrc`。root shell 可以使用这个实例，但建议把它当成代理使用者，而不是日常配置维护入口。

推荐的 root 用法分三类：

- 查看状态和地址：`clashstatus`、`clashlog`、`clashui`、`clashsecret`（不带参数）这类查看命令适合在 root shell 里使用。
- 当前会话代理：root shell 已经加载 `clashctl` 入口时，直接执行 `clashproxy on`。它只修改当前 shell 的代理环境变量，不会改订阅、mixin 或运行模式。
- 自动代理偏好：单用户机器上，如果希望新开的 root shell 静默继承代理，可以先在安装用户侧执行 `clashproxy on -g`，再同步 root rc。同步后，root shell 会复用同一套 `clashctl` 入口和自动代理偏好。

同步 root rc：

```bash
sudo "$HOME/clashctl/scripts/tools/sync-root-rc.sh"
```

删除同步块：

```bash
sudo "$HOME/clashctl/scripts/tools/unsync-root-rc.sh"
```

共享机不建议同步 root rc，也不建议 root source 某个普通用户的 `clashctl.sh` 后执行写操作。`clashsub`、`clashmixin -e/-m`、`clashsecret <secret>`、`clashrestart --mode ...`、`clashtun on/off` 这类命令会修改用户配置或运行状态，应优先回到安装用户 shell 操作。脚本会尽量把 root 生成的运行时文件归还给安装目录 owner（属主），但这是兜底保护，不是推荐 root 日常改配置。

如果只是临时让 root 里的 `curl`、`apt` 等命令走代理，也可以不用 `clashctl`，直接手工设置当前会话变量：

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export all_proxy=socks5h://127.0.0.1:7891
export no_proxy=localhost,127.0.0.1,::1
```

如果一开始就是 root 执行安装，那就是 root 自己的安装实例，不需要把普通用户 rc 同步到 root。

## 常用命令

启动和关闭：

```bash
clashon
clashon --mode tmux
clashrestart --mode nohup
clashoff
clashstatus
clashstatus --all
clashhealth
clashctl health-check
clashdoctor
```

代理环境变量：

```bash
clashproxy on
clashproxy off
clashproxy status
clashproxy on -g
clashproxy mode silent
```

`clashhealth` / `clashctl health-check` 始终请求本机 `/version` API；在 systemd/Tun 路线下，它和 `tmux` / `nohup` 一样看 API 健康，而不是展示 `systemctl status`。`clashdoctor` / `clashctl doctor` 会聚合展示 `clashstatus --all`、API 健康、`clashproxy status`、`clashproxy mode status` 和 `clashtun status`，适合排障前先看全局状态。

`clashon` / `clashrestart` 只启动或切换内核托管模式，不会自动写入当前终端代理变量。需要当前终端走代理时，执行 `clashproxy on`。`clashproxy status` 中只有 `no_proxy` / `NO_PROXY` 时，不视为代理开启。`clashoff` 只关闭内核，不改当前终端代理变量；需要关闭当前终端代理时，执行 `clashproxy off`。如果曾经执行过 `clashproxy on -g`，关闭内核后建议再执行 `clashproxy off -g`，避免新终端自动写入已经不可用的代理地址。

Web 面板：

```bash
clashui
clashsecret
clashsecret "new-secret"
```

订阅：

```bash
clashsub add "https://example.com/sub?clash=3&extend=1"
clashsub ls
clashsub use 1
clashsub update 1
clashsub update 1 --convert
clashsub delete 1
clashsub log
```

Mixin：

```bash
clashmixin
clashmixin -e
clashmixin -m
clashmixin -r
```

Tun：

```bash
clashtun
clashtun on
clashtun status
clashtun off
```

Tun 需要 systemd 服务已注册，并且当前内核以 `systemd` 模式运行。`clashtun status` 会同时检查 Tun 网卡和 `systemd-resolved` DNS 接管状态；如果 DNS 未接管，需要刷新真实 systemd unit 后重新切到 systemd 模式：

```bash
sudo "$HOME/clashctl/scripts/tools/refresh-systemd-service.sh"
clashrestart --mode systemd
clashtun on
```

## 更新项目脚本

更新类型需要分开理解：

- `clashsub update`：更新订阅。
- `clashupgrade`：升级 mihomo/clash 内核。
- `bash update.sh --target <安装目录>` 或 `clashctl update-self --source <源码目录>`：更新本项目 shell 脚本和文档资产。
- `clashctl update-self`：直接从 GitHub 下载本项目的 `main` 分支并无损更新当前安装目录。

### 更新命令和 GitHub 代理范围

`--gh-proxy` / `--no-gh-proxy` 只服务于 GitHub 下载链路，不是通用网络代理开关。

| 命令或链路 | 是否支持 `--gh-proxy` | 说明 |
| --- | --- | --- |
| `bash install.sh --gh-proxy <url>` | 支持 | 持久写入安装目录 `.env`，安装阶段下载 GitHub release 资产时使用 |
| 安装时空版本号 latest release 查询 | 支持 | 如果 `.env` 里把 `VERSION_MIHOMO` / `VERSION_YQ` / `VERSION_SUBCONVERTER` 留空，查询 GitHub `releases/latest` API 时也使用该代理前缀 |
| `clashctl update-self --gh-proxy <url>` | 支持 | 只影响本次从 GitHub 下载项目源码，不改写 `.env` |
| `bash update.sh --gh-proxy <url>` | 支持 | 等价于项目自更新脚本的一次性 GitHub 下载代理 |
| `clashctl update-self --source <dir>` | 不需要 | 使用本地源码目录刷新安装目录，不访问 GitHub |
| `clashsub update` | 不支持 | 更新用户订阅 URL，订阅源不一定是 GitHub；应使用当前终端或系统网络环境处理订阅访问 |
| `clashupgrade` | 不支持 | shell 端只请求本机 mihomo API 的 `/upgrade`，实际下载由 mihomo 内核处理 |
| `migrate.sh` | 不需要 | 迁移从本地新源码目录刷新旧安装，不做远程 GitHub 下载 |

日常使用时，直接执行：

```bash
clashctl update-self
```

该命令默认从 GitHub 获取本项目的 `main`，不会使用本机源码目录里的未提交改动。如果安装目录 `.env` 中有 `URL_GH_PROXY`，下载项目源码时会复用该代理前缀。正在本地调试修复时，必须使用下面的 `--source` 路线，或者直接在源码仓库中执行 `bash update.sh --target "$HOME/clashctl"`。

指定分支或 tag：

```bash
clashctl update-self --ref main
```

指定 GitHub 仓库和分支：

```bash
clashctl update-self --repo tyx3211/clash-for-linux-install-multimode --ref main
```

临时覆盖本次 GitHub 下载代理：

```bash
clashctl update-self --gh-proxy https://gh-proxy.org
clashctl update-self --no-gh-proxy
```

这两个参数只影响本次项目更新，不会改写安装目录 `.env`。持久默认值仍建议在安装时通过 `bash install.sh --gh-proxy <url>` 写入。

从源码仓库 pull 新版本后，在源码仓库执行：

```bash
bash update.sh --target "$HOME/clashctl"
```

在已安装环境中也可以显式指定刚 pull 过的源码仓库：

```bash
clashctl update-self --source "<源码目录>"
```

项目脚本更新会保留 `config/`、`resources/install-state.yaml`、`resources/config.yaml`、`resources/runtime.yaml`、`resources/profiles/`、日志和 pid 状态。旧安装目录如果已有 `.env`，会继续保留；旧安装目录如果还在使用 `resources/mixin.yaml`、`resources/clashctl.yaml`、`resources/profiles.yaml`，这些文件也会原样保留。

如果当前安装注册过 systemd 服务，项目更新只会刷新安装目录里的 service 模板，不会自动改真实 `/etc/systemd/system/mihomo.service` 或 `/etc/systemd/system/clash.service`。需要让 systemd/Tun 路线使用新 unit 时执行：

```bash
sudo "$HOME/clashctl/scripts/tools/refresh-systemd-service.sh"
clashrestart --mode systemd
```

不要用 `sudo bash install.sh --init systemd` 刷新已有安装；`install.sh` 是初装入口，安装目录已存在时会拒绝继续。

更新完成后，当前 shell 里已经加载过的函数不会自动替换。立刻使用新版命令：

```bash
source "$HOME/clashctl/scripts/cmd/clashctl.sh"
```

如果需要让运行中的内核也按新版脚本重新拉起：

```bash
clashctl off && clashctl on
```

## 配置目录与 git

`git clone` 得到的是源码目录，用来执行初装或本地 `--source` 更新。默认安装目录 `~/clashctl` 是运行时目录，不是项目 git 仓库；初装不会复制源码目录里的 `.git`，`clashctl update-self` 也不依赖安装目录中的 git 状态。

适合人工维护的源配置集中在：

```text
~/clashctl/config/
  mixin.yaml
  clashctl.yaml
  subscriptions.yaml
```

安装时可以直接初始化这个配置仓库：

```bash
bash install.sh --config-git
# 或
CLASHCTL_CONFIG_GIT=1 bash install.sh
```

如果已经通过环境变量打开，但本次想关闭：

```bash
CLASHCTL_CONFIG_GIT=1 bash install.sh --no-config-git
```

该选项只会在 `~/clashctl/config` 下执行 `git init`，不会自动提交，也不会把 `~/clashctl` 根目录变成 git 仓库。更多说明见 [配置版本管理](config-versioning.md)。

旧版本安装目录如果已经在根目录带有 `.git`，它通常是历史全量复制遗留。为了避免误删用户手工创建的仓库，`update-self` 不会自动删除已有 `.git`。确认没有自定义用途后，可以手工删除：

```bash
rm -rf "$HOME/clashctl/.git"
```

不建议在安装目录根启用 git 管理配置。该目录包含脚本、二进制、订阅展开结果、运行时配置、日志和 pid 状态。真正适合版本管理的是 `config/` 下的源配置；`resources/` 下的 `config.yaml`、`runtime.yaml`、`profiles/`、日志和 pid 都是运行时文件。

## 自动化安装

跳过 shell rc 写入：

```bash
CLASHCTL_NO_RC=1 bash install.sh
```

跳过安装末尾的订阅导入交互：

```bash
CLASHCTL_NO_QUIT=1 bash install.sh
```

同时指定默认托管模式：

```bash
CLASHCTL_NO_RC=1 CLASHCTL_NO_QUIT=1 bash install.sh --init tmux
```

如果没有写入 shell rc，需要手动加载：

```bash
. "$CLASH_BASE_DIR/scripts/cmd/clashctl.sh"
```

## 从 nosudo-tmux 迁移

旧 `nosudo-tmux` 分支已经退役。旧 `nosudo-tmux`、旧 `master`、[`legacy-nosudo-tmux`](https://github.com/tyx3211/clash-for-linux-install-multimode/tree/legacy-nosudo-tmux) 这个 tag 及以前版本，或者还没有执行过 `migrate.sh` 的早期中间版安装，都建议先按 [旧版迁移指南](legacy-migration.md) 原地迁移，不要先卸载旧安装目录。

迁移后的心智变化：

- 默认仍然是 tmux 用户态，不需要 sudo。
- `config/clashctl.yaml` 是新增的 sidecar 配置。
- `config/mixin.yaml` 只放会参与内核运行时合并的配置。
- Tun 不再是 no-sudo 路线的一部分，需要注册 systemd 服务并执行 `clashrestart --mode systemd`。
- 安装路径限制比旧版本更明确，不建议使用带空格或特殊字符的目录。

## 远程访问 Web 面板

新安装默认控制口绑定 `127.0.0.1:9090`，共享机上推荐用 SSH 端口转发：

```bash
ssh -L 9090:127.0.0.1:9090 user@remote-host
```

然后访问：

```text
http://localhost:9090/ui
```

如果使用 VS Code Remote-SSH，也可以直接在 VS Code 里转发远端 `9090` 端口。若希望用独立面板可视化管理 SSH 端口转发，而不是绑定到 VS Code 项目窗口，可以使用 [tyx3211/ssh-tunnel-panel](https://github.com/tyx3211/ssh-tunnel-panel)。

旧安装执行 `clashctl update-self` 后不会自动改已有 `mixin.yaml`，因此旧安装可能仍在使用 `127.0.0.1:23571` 或其他自定义端口。实际地址以 `clashui` 输出或当前 `mixin.yaml` 为准。如需迁移到 9090，手工修改 `external-controller` 后执行 `clashmixin -m` 或 `clashctl mixin -m`。

启动前会检查 `external-controller` 控制端口。如果该端口被其他进程占用，脚本只报错并提示一个空闲端口；不会自动写入 `mixin.yaml`，也不会自动合并配置。我们需要手工改 `~/clashctl/config/mixin.yaml`，旧兼容安装则可能是 `~/clashctl/resources/mixin.yaml`，然后执行 `clashmixin -m` 或 `clashctl mixin -m`。
