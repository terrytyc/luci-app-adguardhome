# luci-app-adguardhome

本项目是去 Lua、去 CBI 的纯 LuCI JavaScript + ucode RPC 实现。AdGuard Home 核心、二进制、官方小写服务和官方 UCI 主配置均由固件官方的 `adguardhome` 软件包提供，本插件只负责 LuCI 管理、DNS 集成、配置协调和可选的内存数据运行。

兼容基线为 OpenWrt/ImmortalWrt 25.12（APK），LuCI ≥ 23.05，fw4。

## 唯一 UCI 配置

活动配置只使用一个 UCI 文件：`/etc/config/adguardhome`。

标准配置格式如下：

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

`config` 是官方核心配置段：

- `enabled` 是唯一的服务启用开关。
- `work_dir` 是唯一的官方工作目录。
- `config_file` 始终为 `<work_dir>/AdGuardHome.yaml`；修改工作目录时由插件同步更新，不需要再单独指定 YAML 路径。
- `verbose` 直接控制官方服务的详细日志选项。

`luci` 段只保存插件自己的 DNS 模式、内存模式和回写周期。插件会保留官方配置中不属于它管理范围的选项。

默认工作目录为 `/etc/AdGuardHome`。自定义目录不限名称和存放位置，按实际挂载文件系统检查，不能位于 tmpfs、ramfs 等内存文件系统。使用绝对路径、避免符号链接，并选择专用目录：官方服务会递归调整工作目录的属主，`/`、`/etc` 等系统目录不能直接作为工作目录。目录须能实际写入并允许核心用户访问；插件不额外限制已有目录的属主或权限位，也不会自动放宽共享父目录的权限。

## 核心与内存模式

- 核心由官方 `/etc/init.d/adguardhome` 服务管理，并以官方 `adguardhome` 用户和组运行（ImmortalWrt 25.12.1 默认 UID/GID 853）。插件不会替换 `/usr/bin/AdGuardHome` 或官方服务文件。
- 开启“从内存运行”后，只把持久工作目录中的 `data` 内容载入 RAM，并将 RAM 中的 `data` 绑定到 `<work_dir>/data`。
- 官方 `work_dir` 及 UCI 中的 `work_dir` 始终保持持久路径；`AdGuardHome.yaml` 始终从 `<work_dir>/AdGuardHome.yaml` 读取和修改；主程序、YAML 和整个官方工作目录均不会复制到内存。
- 默认每 60 分钟回写一次，可设置为 1–10080 分钟；设置为 `0` 可关闭周期回写。
- 手动和周期回写直接用 `cp` 把 RAM 中 `data` 的内容写回持久 `data`，同名对象直接覆盖，不先清空目标目录，也不停止或重启核心、插件服务或 DNS 服务。
- RAM 数据运行时，可在设置页点击“立即回写”；只回写当前运行数据，不应用尚未保存的设置，回写周期为 `0` 时也可使用。
- 内存模式不建立持久事务日志或回写快照，也不承诺并发快照一致性或极端断电可靠性；断电时可能丢失上次成功回写后的数据。启动准备若在发布活动状态前中断，下次启动只丢弃经过校验的插件专用临时目录并从持久 `data` 重新载入。
- 内存模式使用系统已有的 tmpfs、挂载能力和 BusyBox 基础工具，不新增 `rsync`、cron、`coreutils-stat` 或 `coreutils-timeout` 等依赖。有界操作由插件自身的 shell 监控完成，不需要任何替代的 timeout 软件包。

## DNS 集成模式

插件支持三种模式，实际 AdGuard Home DNS 端口始终从当前 YAML 的 `dns.port` 动态读取；`53335` 只是默认模板值。

- `none`：不修改 dnsmasq 或防火墙。AdGuard Home 可以直接监听 53 端口。
- `redirect`：使用 fw4 将路由器收到的 53 端口 DNS 请求重定向到 YAML 中的实际 AdGuard Home DNS 端口。
- `dnsmasq-upstream`：保留 dnsmasq 的 53 端口监听，并把 dnsmasq 上游指向 YAML 中的实际 AdGuard Home DNS 端口。此模式要求系统只有一个 dnsmasq UCI 实例；进入模式时保留条件转发，只添加精确的 `127.0.0.1#<dns.port>` 上游并设置 `noresolv=1`。检测到多个 dnsmasq 实例、既有普通上游或 `/#/` 通配上游时会拒绝接管。

`redirect` 和 `dnsmasq-upstream` 要求 YAML 的 `dns.port` 不是 53；`none` 模式可使用 53。停用插件或离开 `dnsmasq-upstream` 时会删除插件记录的精确上游并取消 `noresolv`，不修改 `resolvfile`；切换其他模式时只撤销插件自己创建的 DNS 或防火墙项。

接管后新增 dnsmasq 实例时，退出清理只处理唯一包含已记录上游的实例，不修改其他实例；无法唯一定位时停止清理并报错。新接管仍要求只有一个实例。

## LuCI 页面

LuCI 菜单入口统一为小写 `/admin/services/adguardhome`，包含三个页签：

- “设置”：显示运行状态，控制启停，修改 DNS 模式、官方工作目录、详细日志选项、内存模式及回写周期，并可修改 YAML 中唯一管理账号的用户名、密码或两者。密码在浏览器端以 BCrypt cost 10 生成哈希，路由器不会收到密码明文。
- “运行日志”：分别显示官方核心日志和插件协调器日志，均按时间倒序排列，最新记录位于最上方。两个区域可折叠，支持自动换行；只在打开页面或手动刷新时读取。
- “YAML 配置”：编辑、校验、保存并应用 `<work_dir>/AdGuardHome.yaml`。读取完整 YAML 需要插件写权限，避免只读账号取得密码哈希或内嵌私钥；只有校验成功并安全落盘后才应用，失败不会留下半写入的活动配置。

“载入模板”只把软件包模板载入 YAML 编辑框，既不会立即写入文件，也不会立即应用或重启服务。编辑内容变化后显示“未保存”；有未保存内容时，重新载入、载入模板以及离开或刷新页面会提示确认。草稿只保留在当前页面，不写入浏览器存储。只有点击“校验、保存并应用”才会生效。默认模板不启用 HTTPS，管理页面为 HTTP 3000，DNS 端口为 53335，用户名和密码均为 `admin`。

概览显示插件和核心版本，以及 DNS 集成状态。“就绪”表示接管配置与核心监听匹配，不代表已验证外部 DNS 查询或实时防火墙规则；状态随原有概览请求读取，不增加后台定时任务。

管理界面跳转地址由当前 YAML 动态决定：HTTP 使用当前 LuCI 页面 URL 的 IP 或域名，并采用 YAML 中的 HTTP 端口；HTTPS 使用 YAML 中配置的 TLS 域名和 HTTPS 端口。

## HTTPS 与 ACME 证书

文件证书路径应写入 YAML 的 `tls.certificate_path` 和 `tls.private_key_path`。`tls.certificate_chain` 与 `tls.private_key` 用于直接内嵌 PEM 内容，不能填写文件路径。

每次通过插件的 `/etc/init.d/AdGuardHome` 启动或重启服务时，插件都会在启动核心前重新读取当前 `config_file` 指向的 YAML，并确保其中配置的证书、私钥及必要父目录可被官方 UID/GID 853 沙箱读取。以后修改 YAML 中的证书路径，也会在下一次启动或重启时按新路径处理。插件只检查可读性，不判断证书是否过期。

ACME 的 `issued`/`renewed` 事件会触发安全重载，使续期证书生效。直接绕过插件调用官方小写 `/etc/init.d/adguardhome`，不会执行插件的启动前证书权限准备。

## 安装与升级

- 全新安装默认不启用服务（`enabled '0'`），在设置页启用并应用后才启动核心和 DNS 集成。默认工作目录缺少 YAML 时安装默认模板；导入已存在的官方实例时保留其启用状态。使用模板时默认选择 `dnsmasq-upstream`；导入既有官方 YAML 时初始使用 `none`，不改变原 DNS 策略。
- 通过 APK 直接覆盖更新。安装前停止插件和核心，完成后按当前 `enabled` 设置启动；保留现有格式的 UCI、YAML 和 data。不再识别旧插件版本、迁移历史格式或清理旧版本遗留文件。
- 主包或中文翻译包安装、更新前，会检查系统是否存在尚未提交的 UCI 改动；若有则先停止安装，请自行保存或撤销后重试。安装脚本不会替用户提交或撤销其他插件的设置。
- 安装或升级完成、服务状态恢复后，插件通过 `rpcd reload` 加载新模块，不重启共享 `rpcd` 进程。设置与 YAML 任务会清理无关的继承文件描述符，保留必要的任务锁，不依赖旧进程恰好留有空闲描述符。
- 配置格式与当前版本不同的旧安装，需要手动整理配置，或卸载 LuCI 插件后重新安装；官方 `adguardhome` 核心无需卸载。
- 导入既有官方配置时，持久工作目录保持原位置；若官方使用 `/var/*` 或 `/tmp/*` 下的易失目录，则把 YAML 和现有 `data` 导入 `/etc/AdGuardHome`，原目录保留。实际挂载磁盘的子目录不受路径前缀影响。
- 普通情况下更换已受管的持久工作目录不会搬移旧目录内容：新目录已有 YAML 时直接使用，没有 YAML 时写入默认模板，旧目录保持不动。
- 更换工作目录时同步更新固件升级保留清单，保留当前 YAML 与插件 UCI 快照；不会因为清单仍指向旧目录而漏掉新 YAML。该清单不包含整个 `data`。

核心更新完全交由系统 APK 软件包管理。插件不包含核心下载或更新功能，也不修改官方 APK 的二进制、服务名、UCI 主配置名和包载荷。

## APK 软件源

软件源仅发布本插件及中文翻译，核心和依赖继续从固件官方源安装。主包和翻译包均为 `noarch`，使用同一个源地址。

首次添加公钥和软件源：

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

后续更新：

```sh
apk update
apk add --upgrade luci-app-adguardhome@terrytyc luci-i18n-adguardhome-zh-cn@terrytyc
```

`@terrytyc` 用于选择本项目的同名软件包，避免被官方 LuCI 插件替换。公钥安装后正常校验签名，无需在路由器使用 `--allow-untrusted`。将 `/etc/apk/keys/terrytyc-adguardhome.pem` 加入 `/etc/sysupgrade.conf`，可在保留配置升级固件时同时保留公钥。

## 3.0.0-r5

- YAML 在修改运行状态前校验失败时，可保留编辑内容继续修正；中断或结果未知时仍要求重新载入。
- 为载入模板、刷新和离页补上未保存提醒，关闭移动端输入框自动大写与自动纠正。
- 设置页新增立即回写、DNS 集成状态和插件版本；复用现有任务与概览请求，不增加后台进程。
- 主包与中文包在安装前检查全局 UCI 待提交改动，避免安装时意外提交其他设置。
- 将现有轻量回归接入 GitHub Actions。

## 3.0.0-r4

- 修复 YAML 编辑器横向滚动时配置文字与行号重叠的问题，行号栏使用不透明的主题背景。
- 保留语法高亮、光标和原有滚动方式，不增加依赖。

## 3.0.0-r3

- 修复 YAML 编辑器处理长空白行时的卡顿，以及特殊换行字符引起的高亮报错。
- 修复 YAML 编辑区光标透明不可见的问题，光标随主题配色显示。
- 修复日志超过读取上限时遗漏最新记录的问题，仍限制返回大小。
- 减少磁盘模式概览轮询中的重复路径检查，监控间隔保持 5 秒。
- 删除目录校验的转发函数，复用已有测试辅助代码；不增加依赖或后台进程。

## 3.0.0-r2

- 修复新增 dnsmasq 实例后无法撤销原有 DNS 接管的问题。
- 修改账号时，连接中断或缺少任务状态令牌会明确提示结果未知。
- 减少 YAML 编辑时的重复扫描和行号刷新，合并同帧输入更新。
- 合并安装快照辅助代码，删除闲置 RPC 和同轮重复的工作目录检查；监控间隔仍为 5 秒。
- 发布构建只使用已提交源码，固定 APK 来源路径；旧发布任务不再覆盖新版软件源。

## 3.0.0-r1

- 仅发布 APK，要求 LuCI 23.05 及以上，默认支持 OpenWrt / ImmortalWrt 25.12 起的 APK 固件，不设置系统版本拦截。
- 删除旧插件版本白名单和专用升级恢复流程，使用 APK 直接覆盖更新。
- 自定义工作目录取消命名和位置限制，按实际文件系统检查是否为持久存储。
- 提供带签名的 APK 软件源，包含主包和中文翻译。

## 2.6.0-r4

- 忽略 ImmortalWrt 更新证书链接前的 ACME 内部续期通知，避免恢复系统后出现无效的证书访问错误。
- 证书内容没有变化时不再重启 AdGuard Home。

## 2.6.0-r3

- 不再校验工作目录和 YAML 的属主、属组或权限位，恢复配置后可直接启用。目录、文件类型、符号链接和工作目录范围检查保持不变。

## 2.6.0-r2

- 运行日志的“自动换行”勾选框移到文字右侧，并修正 Argon 主题下的垂直偏移。
- YAML 编辑器高度随浏览器窗口调整，仍可手动纵向缩放。

## 2.6.0-r1

- 设置页改为居中的单列布局，概览与表单统一对齐；DNS 与内存选项合并到同一设置区域，底层 UCI 配置结构保持不变。
- YAML 编辑器增加行号、当前行提示和轻量语法着色；继续使用原生输入框，不引入前端库，模板、校验和冲突保护流程不变。
- 插件日志补充启停、设置及 YAML 应用、DNS 模式变化和内存载入、回写等关键事件；健康监控保持静默，不增加日志文件或后台进程。
