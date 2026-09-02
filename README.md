# luci-app-adguardhome

`luci-app-adguardhome` 2.4.0-r3，兼容基线为 ImmortalWrt 25.12.1。

本项目是去 Lua、去 CBI 的纯 LuCI JavaScript + ucode RPC 实现。AdGuard Home 核心、二进制、官方小写服务和官方 UCI 主配置均由 ImmortalWrt 的 `adguardhome` 软件包提供，本插件只负责 LuCI 管理、DNS 集成、配置协调和可选的内存数据运行。

## 唯一 UCI 配置

2.4.0-r3 的活动配置只使用一个 UCI 文件：`/etc/config/adguardhome`。运行时不创建或使用 `/etc/config/AdGuardHome`，也不存在第二个 `enabled` 或第二个 `work_dir`。

标准配置格式如下：

```uci
config adguardhome 'config'
	option enabled '1'
	option config_file '/etc/AdGuardHome/AdGuardHome.yaml'
	option work_dir '/etc/AdGuardHome'
	option verbose '0'

config luci 'luci'
	option redirect 'dnsmasq-upstream'
	option run_from_memory '0'
	option memory_writeback_interval '60'
```

`config` 是官方核心配置段：

- `enabled` 是唯一的服务启用开关。
- `work_dir` 是唯一的官方工作目录。
- `config_file` 始终为 `<work_dir>/AdGuardHome.yaml`；修改工作目录时由插件同步更新，不需要再单独指定 YAML 路径。
- `verbose` 直接控制官方服务的详细日志选项。

`luci` 段只保存插件自己的 DNS 模式、内存模式和回写周期。插件会保留官方配置中不属于它管理范围的选项。

默认工作目录为 `/etc/AdGuardHome`。自定义工作目录仅允许使用 `/etc/AdGuardHome-*`，或 `/mnt` 挂载盘下以 `AdGuardHome`/`AdGuardHome-*` 命名的专用叶目录，以免官方服务改动系统目录的所有权。

## 核心与内存模式

- 核心由官方 `/etc/init.d/adguardhome` 服务管理，并以官方 `adguardhome` 用户和组运行（ImmortalWrt 25.12.1 默认 UID/GID 853）。插件不会替换 `/usr/bin/AdGuardHome` 或官方服务文件。
- 开启“从内存运行”后，只把持久工作目录中的 `data` 内容载入 RAM，并将 RAM 中的 `data` 绑定到 `<work_dir>/data`。
- 官方 `work_dir` 及 UCI 中的 `work_dir` 始终保持持久路径；`AdGuardHome.yaml` 始终从 `<work_dir>/AdGuardHome.yaml` 读取和修改；主程序、YAML 和整个官方工作目录均不会复制到内存。
- 默认每 60 分钟回写一次，可设置为 1–10080 分钟；设置为 `0` 可关闭周期回写。
- 手动和周期回写直接用 `cp` 把 RAM 中 `data` 的内容写回持久 `data`，同名对象直接覆盖，不先清空目标目录，也不停止或重启核心、插件服务或 DNS 服务。
- 内存模式不建立持久事务日志或回写快照，也不承诺并发快照一致性或极端断电可靠性；断电时可能丢失上次成功回写后的数据。启动准备若在发布活动状态前中断，下次启动只丢弃经过校验的插件专用临时目录并从持久 `data` 重新载入。
- 内存模式使用系统已有的 tmpfs、挂载能力和 BusyBox 基础工具，不新增 `rsync`、cron、`coreutils-stat` 或 `coreutils-timeout` 等依赖。有界操作由插件自身的 shell 监控完成，不需要任何替代的 timeout 软件包。

## DNS 集成模式

插件支持三种模式，实际 AdGuard Home DNS 端口始终从当前 YAML 的 `dns.port` 动态读取；`53335` 只是默认模板值。

- `none`：不修改 dnsmasq 或防火墙。AdGuard Home 可以直接监听 53 端口。
- `redirect`：使用 fw4 将路由器收到的 53 端口 DNS 请求重定向到 YAML 中的实际 AdGuard Home DNS 端口。
- `dnsmasq-upstream`：保留 dnsmasq 的 53 端口监听，并把 dnsmasq 上游指向 YAML 中的实际 AdGuard Home DNS 端口。此模式要求系统只有一个 dnsmasq UCI 实例；进入模式时保留条件转发，只添加精确的 `127.0.0.1#<dns.port>` 上游并设置 `noresolv=1`。检测到多个 dnsmasq 实例、既有普通上游或 `/#/` 通配上游时会拒绝接管。

`redirect` 和 `dnsmasq-upstream` 要求 YAML 的 `dns.port` 不是 53；`none` 模式可使用 53。停用插件或离开 `dnsmasq-upstream` 时会删除插件记录的精确上游并取消 `noresolv`，不修改 `resolvfile`；切换其他模式时只撤销插件自己创建的 DNS 或防火墙项。

## LuCI 页面

LuCI 菜单入口统一为小写 `/admin/services/adguardhome`，包含三个页签：

- “设置”：显示运行状态，控制启停，修改 DNS 模式、官方工作目录、详细日志选项、内存模式及回写周期，并可修改 YAML 中唯一管理账号的用户名、密码或两者。密码在浏览器端以 BCrypt cost 10 生成哈希，路由器不会收到密码明文。
- “运行日志”：分别显示官方核心日志和插件协调器日志，均按时间倒序排列，最新记录位于最上方。
- “YAML 配置”：编辑、校验、保存并应用 `<work_dir>/AdGuardHome.yaml`。读取完整 YAML 需要插件写权限，避免只读账号取得密码哈希或内嵌私钥；只有校验成功并安全落盘后才应用，失败不会留下半写入的活动配置。

“恢复模板”只把软件包模板载入 YAML 编辑框，既不会立即写入文件，也不会立即应用或重启服务。用户仍停留在编辑流程中，可继续修改；只有随后点击“校验、保存并应用”才会生效。默认模板不启用 HTTPS，管理页面为 HTTP 3000，DNS 端口为 53335，用户名和密码均为 `admin`。

管理界面跳转地址由当前 YAML 动态决定：HTTP 使用当前 LuCI 页面 URL 的 IP 或域名，并采用 YAML 中的 HTTP 端口；HTTPS 使用 YAML 中配置的 TLS 域名和 HTTPS 端口。

## HTTPS 与 ACME 证书

文件证书路径应写入 YAML 的 `tls.certificate_path` 和 `tls.private_key_path`。`tls.certificate_chain` 与 `tls.private_key` 用于直接内嵌 PEM 内容，不能填写文件路径。

每次通过插件的 `/etc/init.d/AdGuardHome` 启动或重启服务时，插件都会在启动核心前重新读取当前 `config_file` 指向的 YAML，并确保其中配置的证书、私钥及必要父目录可被官方 UID/GID 853 沙箱读取。以后修改 YAML 中的证书路径，也会在下一次启动或重启时按新路径处理。插件只检查可读性，不判断证书是否过期。

ACME 的 `issued`/`renewed` 事件会触发安全重载，使续期证书生效。直接绕过插件调用官方小写 `/etc/init.d/adguardhome`，不会执行插件的启动前证书权限准备。

## 安装与升级

- 没有既有 AdGuard Home 状态的洁净安装会创建上述唯一 UCI 布局，按样例默认启用服务，并在默认工作目录缺少 YAML 时安装默认模板；导入已存在的官方实例时会保留其启用和运行状态。若该官方状态尚未生成 YAML，插件会连同模板采用默认 `dnsmasq-upstream` 模式；若导入的是既有官方 YAML，则初始使用 `none`，避免擅自改变原 DNS 策略。
- `2.4.0-r1` 和已发布的 `2.4.0-r2` 均支持原位升级到 `2.4.0-r3`。升级保留当前 UCI、YAML、HTTPS 配置、运行数据和内存模式设置；升级脚本不迁移或删除 2.4 基线以前的历史配置项。
- 从 2.3 及更早版本或未知开发版升级不受支持；应先完整卸载旧 LuCI 插件，再安装 2.4.0-r3。官方 `adguardhome` 核心软件包无需卸载。
- 导入既有官方配置时，如果官方 `work_dir` 位于 `/var/*` 或 `/tmp/*`，插件会把 YAML 和现有 `data` 迁移到持久的 `/etc/AdGuardHome`，并把官方 `config_file` 统一为 `/etc/AdGuardHome/AdGuardHome.yaml`；原易失目录保留，便于人工恢复。
- 普通情况下更换已受管的持久工作目录不会搬移旧目录内容：新目录已有 YAML 时直接使用，没有 YAML 时写入默认模板，旧目录保持不动。

核心更新完全交由 ImmortalWrt APK 软件包管理。插件不包含核心下载或更新功能，也不修改官方 APK 的二进制、服务名、UCI 主配置名和包载荷。旧版核心更新器、UPX 与 GFW 列表相关功能均已移除。
