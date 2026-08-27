# luci-app-adguardhome

luci-app-adguardhome for ImmortalWrt 25.12.1

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
- 洁净安装默认停用；默认目录权限为 `0700`，YAML 权限为 `0600`
- 核心由官方服务使用 `adguardhome` 系统用户和组运行（ImmortalWrt 默认 UID/GID 853）
- 更换工作目录时会安全复制现有 `data` 运行数据并保留原目录作为回退
- 导入官方默认的易失 `/var/lib/adguardhome` 时，会把 YAML 与现有 `data` 迁移到持久目录；新的工作目录不允许位于 `/tmp` 或 `/var`
- Web 跳转按钮从 YAML 读取管理端点：HTTP 沿用当前 LuCI 的 IP/域名并使用 `http.address` 的端口，HTTPS 使用 `tls.server_name` 和 `tls.port_https`

核心升级请使用 ImmortalWrt 的 APK 软件包管理，不再由 LuCI 插件自行下载或替换二进制。
旧版核心更新器、UPX 和 GFW 列表功能已经移除。

`dnsmasq-upstream` 模式要求系统只有一个 dnsmasq UCI 实例；检测到多个实例时会拒绝接管，避免误改非 LAN 实例。此类系统可选择 `redirect` 或 `none` 模式。

`dnsmasq-upstream` 与 `redirect` 模式要求 YAML 的 `dns.port` 不是 53；`none` 模式可保留官方已有的 53 端口配置。DNS 与 Web 端口、HTTP/HTTPS 协议及 TLS 域名均由 AdGuard Home YAML 管理，不再在 UCI 中保存重复副本。
