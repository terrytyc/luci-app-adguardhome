# AdGuard Home for LuCI

觉得好用点个小星星吧！

DNS、配置、日志，在路由器里一处管理。

给官方 AdGuard Home 配上顺手的 LuCI 界面：切换 DNS 模式、编辑 YAML、查看运行日志，也能把 data 放进内存，减少持久存储写入。核心仍用官方包，插件通过 APK 软件源更新。

[下载安装](#-安装) · [版本记录](https://github.com/terrytyc/luci-app-adguardhome/releases) · [反馈问题](https://github.com/terrytyc/luci-app-adguardhome/issues)

## ✨ 主要功能

- **三种 DNS 模式**：不接管、作为 dnsmasq 上游、重定向 53 端口。监听端口从 YAML 读取，改端口不用再改一遍插件设置。
- **data 可选内存运行**：主程序和 YAML 留在持久目录，只有 data 进入内存。支持定时、手动回写，回写不重启服务。
- **直接编辑 YAML**：语法高亮、行号、未保存提醒，保存前校验。大文件自动使用轻量文本显示。“载入模板”只替换编辑内容，确认保存后才生效。
- **日志分开看**：核心日志和插件日志独立展示，最新记录在上，支持折叠和换行。插件只记录启停、配置应用、回写等关键事件。
- **管理入口更省事**：按 YAML 生成 HTTP / HTTPS 管理地址，也能直接修改 AdGuard Home 登录账号或密码。

纯 LuCI JavaScript + ucode RPC，无 Lua、无 CBI。不替换官方核心或服务文件，也不另做核心更新器。

## 🚀 安装

适用于使用 **APK 的 OpenWrt / ImmortalWrt 25.12 及以上固件**，要求 LuCI ≥ 23.05、fw4。不提供 IPK。

软件源只提供本插件和中文翻译，均为 `noarch`；核心及依赖仍从固件官方源安装。

通过 SSH 执行一次，添加签名公钥、软件源并安装：

```sh
mkdir -p /etc/apk/keys /etc/apk/repositories.d
wget -O /etc/apk/keys/terrytyc-adguardhome.pem \
  https://terrytyc.github.io/luci-app-adguardhome/public-key.pem
feed='@terrytyc https://terrytyc.github.io/luci-app-adguardhome/packages/packages.adb'
grep -qxF "$feed" /etc/apk/repositories.d/customfeeds.list 2>/dev/null || \
  printf '%s\n' "$feed" >> /etc/apk/repositories.d/customfeeds.list
apk update
apk add luci-app-adguardhome@terrytyc luci-i18n-adguardhome-zh-cn@terrytyc
```

打开 LuCI → **服务 → AdGuard Home**，勾选启用并保存应用。全新安装默认关闭，不会立即接管 DNS。

默认管理账号为 `admin / admin`，管理端口为 HTTP `3000`，DNS 端口为 `53335`，HTTPS 默认关闭。可在设置页修改 AdGuard Home 登录账号或密码。

后续更新只需：

```sh
apk update
apk add --upgrade luci-app-adguardhome@terrytyc luci-i18n-adguardhome-zh-cn@terrytyc
```

`@terrytyc` 指定使用本项目软件源，避免同名包被其他源替换。正常校验签名，无需 `--allow-untrusted`。保留配置升级固件时，请将 `/etc/apk/keys/terrytyc-adguardhome.pem` 加入 `/etc/sysupgrade.conf`，一并保留公钥。

## 🧭 DNS 模式

| 模式 | 工作方式 |
| --- | --- |
| 无（`none`） | 不接管 dnsmasq 或防火墙，适合自行安排 DNS 流程；AdGuard Home 可直接监听 53。 |
| 作为 dnsmasq 上游（`dnsmasq-upstream`） | dnsmasq 保留 53 端口，将请求交给 AdGuard Home。新模板默认使用此模式。 |
| 重定向 53 端口（`redirect`） | 使用 fw4，把路由器收到的 53 端口 DNS 请求转到 AdGuard Home。 |

后两种模式要求 AdGuard Home 监听端口不是 53；`53335` 只是模板默认值，实际以 YAML 为准。

上游模式要求只有一个 dnsmasq 实例，保留条件转发；已有普通上游或匹配所有域名的转发规则时会拒绝接管。启用后添加 `127.0.0.1#<DNS 端口>` 并临时设置 `noresolv=1`。停用或离开此模式时，删除插件记录的上游，并把 `noresolv` 恢复为接管前的存在状态和原值，不改 `resolvfile`。其他模式切换也只撤销插件创建的接管项；无法确定归属时会报错，不猜测清理目标。

概览中的 DNS“就绪”表示接管配置与核心监听匹配，不等同于外网解析测试或实时防火墙检查。

选择“无”且关闭内存运行时，不启动插件监控进程，核心仍由官方服务管理。通过 SSH 修改 UCI 后，请执行 `/etc/init.d/AdGuardHome reload` 应用设置。

防火墙接管撤销失败时会保留可重试状态，确认重载成功后才完成清理。无法确认撤销成功时不会继续停止核心。

## 💾 内存运行

开启后，插件把持久目录中的 data 载入 RAM，再挂载到原来的 `<工作目录>/data`。**主程序、YAML 和 UCI 工作目录路径都不变。** 不需要额外安装 rsync、cron 或 timeout 软件包。

- 默认每 **60 分钟**回写，可设为 1–10080 分钟；`0` 关闭定时回写。
- “立即回写”只处理当前运行的 data，不应用页面中尚未保存的设置。
- 定时和手动回写直接复制、覆盖同名内容，不删除持久 data 中的额外文件，也不重启核心或 DNS 服务。正常停止、重启时会在核心退出后回写，并删除 RAM 中已经不存在的持久文件，使两边最终一致。

这不是实时备份：断电可能丢失上次回写后的数据，复制过程也不保证快照一致性。需要更稳妥的数据持久性时，保持默认的磁盘模式即可。

## ⚙️ 配置与管理

日常操作都在“设置、运行日志、YAML 配置”三个页签中，入口为 `/admin/services/adguardhome`。

工作目录默认是 `/etc/AdGuardHome`，YAML 固定为目录下的 `AdGuardHome.yaml`，修改工作目录时自动同步配置路径。可选择其他持久目录，但须使用可写、核心用户可访问的专用绝对路径；不能用 tmpfs / ramfs、符号链接或 `/`、`/etc` 等系统目录，也不会自动放宽共享父目录权限。

使用外部磁盘时，请在 `/etc/config/fstab` 声明挂载目标及设备、UUID 或 LABEL。启动和配置写入前会检查对应目标已可写挂载，并在启动端核对设备身份；缺盘时不会改用挂载点下面的闪存目录。禁用的 fstab 挂载条目仍保留这项依赖。没有 fstab 条目的路径按普通持久目录处理，插件无法推测它原来属于哪块外盘。缺盘时仍可在设置页停用服务或选择其他目录。

保存应用会先核对核心进程、官方参数、YAML、证书及核心文件是否与已应用状态一致。确认一致时，仅调整回写间隔或 DNS 接管，不重启核心；设置无变化也会检查运行状态。状态记录缺失或发现变化时执行完整启动协调，保留“再次应用以修复运行状态”的用途。

YAML／密码保存、证书续期重启和故障恢复重新启动核心后，会在验证成功时更新运行记录，后续仅调整周期或 DNS 不会因为旧进程记录再次重启。恢复 DNS 时如果原核心仍在运行，会保留它原有的运行记录。

设置比较和应用结果确认只核对 RAM 状态、目录及挂载身份，不重复遍历 data；实际启动、复制、切换和清理仍执行完整检查。原始设置已规范且完全相同时，跳过 UCI 写事务，继续检查恢复快照和运行状态。

更换工作目录不会搬移旧数据：新目录有 YAML 就使用现有文件，没有则写入模板，旧目录保留。需要沿用配置与 data 时，请先自行复制。

YAML 草稿只保留在当前页面。未保存时，重新载入、载入模板及离页会提示确认；只有“校验、保存并应用”才写入配置。读取完整 YAML 需要插件写权限，避免只读账号取得密码哈希或内嵌私钥。

管理按钮使用 YAML 中的端口：HTTP 沿用访问 LuCI 时的 IP 或域名；HTTPS 使用 YAML 配置的 TLS 域名。

只有一个管理账号时，可修改用户名和密码；多账号时禁止改名，但存在唯一的 `admin` 时仍可单独修改其密码。其他多账号调整请使用 YAML 编辑器。

<details>
<summary>手动配置：一个 UCI 文件，一个启用开关</summary>

活动配置统一使用 `/etc/config/adguardhome`：

```uci
config adguardhome 'config'
	option enabled '0'
	option config_file '/etc/AdGuardHome/AdGuardHome.yaml'
	option work_dir '/etc/AdGuardHome'
	option verbose '0'

config luci 'luci'
	option redirect 'dnsmasq-upstream'
	option run_from_memory '0'
	option memory_writeback_interval '60'
```

`config` 管理官方核心，`luci` 只保存插件的 DNS、内存及回写选项。`enabled` 是唯一启用开关，`config_file` 由 `work_dir` 同步生成，其他官方选项会保留。

核心由官方 `/etc/init.d/adguardhome` 管理，以官方 `adguardhome` 用户和组运行；通过插件协调启停时使用 `/etc/init.d/AdGuardHome`。两者不是同一个脚本，插件不会替换官方文件。

开机、关机由插件统一协调，官方服务不再独立自启动。网络接口就绪后，插件会按需补启尚未运行的核心，不会因网络变化重启正常运行的核心。卸载插件不恢复官方自启动。

如果官方服务被重新勾选自启动，插件会在下次启动、应用配置、网络接口就绪或 APK 事务结束时取消它；运行状态正常时只纠正自启动，不额外重启核心。不做定时扫描，因此不会在勾选后立即撤销。

</details>

### 🔒 HTTPS 与证书续期

如果配置了 HTTPS，通过插件启动或重启时，会重新读取证书路径，确保官方核心沙箱可读取证书、私钥及必要父目录。之后更换路径也按新配置处理，不判断证书是否过期。ACME 签发、续期后会同步证书访问权限，内容变化时重启核心加载；手动停止插件后只同步权限，不会被续期事件重新启动。

直接调用官方小写 `/etc/init.d/adguardhome` 会绕过插件的启动前权限准备，请使用 LuCI 或 `/etc/init.d/AdGuardHome`。

目录所属组和读写权限决定能否访问文件；沙箱挂载决定文件是否可见，内存挂载决定 data 的实际存储位置。调整组权限不能替代这些挂载。

### 📦 更新前知道这些

- 支持 APK 覆盖更新，保留当前格式的 UCI、YAML 和 data。安装前停止服务，完成后按现有启用状态恢复；不会重启共享的 rpcd 进程。
- 卸载只停止核心、移除插件接管并关闭官方自启动，保留当前 UCI、YAML 和 data，不恢复首次安装前的配置。首次安装失败仍会尝试恢复当次安装前的 UCI；覆盖更新不依赖原始快照。
- 官方核心通过 APK 更新后，插件会检查运行状态：启用时按需重启到新核心，关闭时停止被安装脚本拉起的核心。检查由 APK 触发，插件关闭时也有效；无关软件更新不会重启状态正常的核心。
- 此检查在整个 APK 事务结束后执行，不阻止官方安装脚本在升级期间启动核心。事务中断、跳过安装脚本或钩子失败时，不保证自动恢复，应检查服务状态和系统日志。
- 升级前无法安全记录核心状态时，会报错并中止本次 APK 事务，包括无关软件安装；不会忽略损坏的插件运行目录继续更新。核心文件缺失本身不会阻止修复安装。
- 安装、更新前，请先提交或撤销默认 UCI 工作区中的待提交设置。固件的安装脚本会执行全局 `uci commit`，因此主包和中文包均在安装前一次性检查全部默认 UCI 改动，存在改动即中止，避免替你提交尚未确认的配置。
- 不迁移旧插件格式或清理历史遗留文件。配置格式不同的旧安装，请手动整理，或卸载 LuCI 插件后重装，无需卸载官方核心。
- 导入已有官方实例时保留启用状态，以 `none` 模式开始，不接管原 DNS 流程；易失目录中的 YAML 和 data 会导入 `/etc/AdGuardHome`，原目录保留。
- 固件升级保留清单随工作目录同步，包含当前 YAML 和插件 UCI 快照，**不包含整个 data**。

历史改动见 [Releases](https://github.com/terrytyc/luci-app-adguardhome/releases)。

## 开发与验证

所有流程和异常分支均以单用户、管理操作串行为使用场景。优化优先复用本次操作已确认且未改变的信息；实际写入、挂载切换或核心启动后，再检查受影响的部分。

配置读取、运行身份核对、DNS 接管、存储准备和启停编排分别由专用方法负责。`scripts/` 下共享 Shell 模块在构建期展开为独立可执行的安装脚本，不增加运行时子服务。状态查询使用只读加载和非阻塞共享锁；配置修复、写入和启停使用协调锁。所有核心启动入口共用挂载依赖检查。

`scripts/test.sh --light` 执行主机回归；`--full` 另使用 OpenWrt UCI/ucode 和隔离 APK 事务环境。测试读取构建期展开后的核心协调脚本，覆盖挂载缺失、失败重试、只读状态、按变更应用及启动复制次数。
