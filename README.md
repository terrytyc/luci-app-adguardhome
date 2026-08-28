# luci-app-adguardhome

luci-app-adguardhome v2.1.0 for ImmortalWrt 25.12.1

去 Lua、去 CBI、纯 LuCI JS + ucode RPC。自用修改版，支持 fw4 和 HTTP/HTTPS 管理入口自适应，不支持旧版 Lua LuCI。

## 特性

- 使用 ImmortalWrt 官方 `adguardhome` 软件包提供和更新核心
- 使用现代 LuCI JavaScript 页面和专用 ucode RPC 后端，不依赖 Lua、CBI 或 `luci-compat`
- 通过官方 `/etc/init.d/adguardhome` 管理核心进程
- 保留旧版 `AdGuardHome` UCI 配置兼容层和 DNS 重定向模式
- 默认 YAML 的 Web 管理端口为 `3000`，默认用户名和密码均为 `admin`
- 默认 YAML 的 DNS 监听端口为 `53335`；运行时会动态读取实际的 `dns.port`
- 只需配置工作目录；配置文件固定为 `<工作目录>/AdGuardHome.yaml`
- 默认工作目录为 `/etc/AdGuardHome`
- 自定义工作目录仅允许使用 `/etc/AdGuardHome-*`，或 `/mnt` 挂载盘下以 `AdGuardHome`/`AdGuardHome-*` 命名的专用叶目录，防止官方服务误改系统目录所有权
- 洁净安装默认停用；默认目录权限为 `0700`，YAML 权限为 `0600`
- 核心由官方服务使用 `adguardhome` 系统用户和组运行（ImmortalWrt 默认 UID/GID 853）
- LuCI 前端分为“设置”、“运行日志”和“YAML 配置”三个页签；状态概览与启停、详细日志、DNS 模式、工作目录在“设置”页扁平显示
- “运行日志”页可直接查看插件与 AdGuard Home 的运行日志
- “YAML 配置”页提供事务式编辑：新配置通过校验并安全落盘后才会生效，失败时不会留下半写入的活动配置
- LuCI 入口统一为小写 `/admin/services/adguardhome`，三个子页分别为 `/settings`、`/log` 和 `/yaml`
- v2.1 升级会刷新 LuCI 运行缓存并重建旧版启动优先级链接，同时保留原有的启用或禁用状态
- 更换工作目录时会安全复制现有 `data` 运行数据并保留原目录作为回退
- 导入官方默认的易失 `/var/lib/adguardhome` 时，会把 YAML 与现有 `data` 迁移到持久目录；新的工作目录不允许位于 `/tmp` 或 `/var`
- Web 跳转按钮从 YAML 读取管理端点：HTTP 沿用当前 LuCI 的 IP/域名并使用 `http.address` 的端口，HTTPS 使用 `tls.server_name` 和 `tls.port_https`

## HTTPS 与 ACME 证书

AdGuard Home 的 HTTPS 文件证书应在 YAML 中使用 `tls.certificate_path` 和 `tls.private_key_path`。`tls.certificate_chain` 与 `tls.private_key` 仅用于直接内嵌 PEM 内容，不能填写文件路径。

官方核心运行在 UID/GID 853 的沙箱中，证书及其父目录必须对该沙箱可读。每次通过插件的 `/etc/init.d/AdGuardHome` 启动或重启核心，以及安装过程中恢复官方服务之前，v2.1 都会重新读取当前工作目录下的 YAML，并把 `/etc/ssl/certs`、`/etc/ssl/acme` 到 `/etc/acme` 的受控外部证书文件修复为 `root:853`、`0640`，再实际验证 UID 853 可读；不要通过放宽整个证书目录权限来绕过沙箱。

插件不会在后台轮询证书路径。官方小写 `/etc/init.d/adguardhome` 保持原样；直接绕过插件调用该服务，不会执行上述启动前准备。

已支持 ACME 自动续期：ACME 的 `issued`/`renewed` 事件会触发安全重载，使续期证书生效，无需手工重启路由器。

插件只校验证书文件能否被官方核心安全读取，不解析或判断证书有效期；签发与到期续期由 ACME 管理。

核心升级请使用 ImmortalWrt 的 APK 软件包管理，不再由 LuCI 插件自行下载或替换二进制。
官方 `adguardhome` APK 的文件、服务名、UCI 配置名和 `/usr/bin/AdGuardHome` 二进制名称保持原样；本插件仅通过官方服务与 UCI 接口集成，不覆盖官方包载荷。
旧版核心更新器、UPX 和 GFW 列表功能已经移除。

`dnsmasq-upstream` 模式要求系统只有一个 dnsmasq UCI 实例；检测到多个实例时会拒绝接管，避免误改非 LAN 实例。此类系统可选择 `redirect` 或 `none` 模式。

`dnsmasq-upstream` 与 `redirect` 模式要求 YAML 的 `dns.port` 不是 53；`none` 模式可保留官方已有的 53 端口配置。DNS 与 Web 端口、HTTP/HTTPS 协议及 TLS 域名均由 AdGuard Home YAML 管理，不再在 UCI 中保存重复副本。
