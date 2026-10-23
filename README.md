# Adaptive Proxy/AutoSwitchProxy

一个为 Git、npm 等命令行工具设计的轻量级本地 HTTP 代理，支持上游自动故障切换与可选直连回退。

## 功能特性

- 固定本地入口：`127.0.0.1:32333`
- 自动选择上游代理，连接失败时尝试其他上游
- 支持 HTTP 和 SOCKS5 上游
- 可选直连回退
- 后台健康检查与可配置超时
- 通过 CONNECT 隧道转发 HTTPS

## 运行环境

- Windows
- Windows PowerShell 5.1 或更高版本

## 快速开始

### 1. 配置上游代理

修改 `adaptive-proxy.ps1` 中的配置：

```powershell
$ListenPort        = 32333
$Upstreams         = @()
$ProxyPorts        = @(31323, 1080, 8443)
$AllowDirect       = $true
```

当 `$Upstreams` 为空时，`$ProxyPorts` 中的端口全部按 HTTP 代理处理。如果需要使用 SOCKS5，请显式指定协议：

```powershell
$Upstreams = @(
    'http://127.0.0.1:31323',
    'socks5://127.0.0.1:1080'
)
```

### 2. 启动脚本

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\adaptive-proxy.ps1
```

### 3. 配置 Git 和 npm

```powershell
git config --global http.proxy http://127.0.0.1:32333

npm config set proxy http://127.0.0.1:32333
npm config set https-proxy http://127.0.0.1:32333
```

取消配置：

```powershell
git config --global --unset http.proxy
npm config delete proxy
npm config delete https-proxy
```

## 开机自动启动

### 方案 A：Windows 任务计划程序（推荐）

Windows 自带任务计划程序，无需安装其他软件。

1. 将 `adaptive-proxy.ps1` 放到固定目录，例如 `C:\AdaptiveProxy\adaptive-proxy.ps1`。
2. 以管理员身份打开 PowerShell，执行以下命令。如脚本路径不同，请修改 `$Script`：

```powershell
$Script = "C:\AdaptiveProxy\adaptive-proxy.ps1"
$PowerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

$Action = New-ScheduledTaskAction `
    -Execute $PowerShell `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Script`""

$Trigger = New-ScheduledTaskTrigger -AtLogOn

$Principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName "AdaptiveProxy" `
    -Action $Action `
    -Trigger $Trigger `
    -Principal $Principal `
    -Description "Local adaptive proxy for command-line tools"
```

3. 启动任务：

```powershell
Start-ScheduledTask -TaskName "AdaptiveProxy"
```

此后，每次登录 Windows 时，脚本都会在后台启动。

停止任务：

```powershell
Stop-ScheduledTask -TaskName "AdaptiveProxy"
```

删除任务：

```powershell
Unregister-ScheduledTask -TaskName "AdaptiveProxy" -Confirm:$false
```

### 方案 B：NSSM（可选）

如果希望将脚本作为 Windows 服务管理，可以使用 [NSSM](https://nssm.cc/) 托管，无须修改脚本的代理核心。

1. 下载 NSSM，以管理员身份运行 `nssm install AdaptiveProxy`。
2. 在配置窗口中填写：

   - **Path：** `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
   - **Startup directory：** 脚本所在目录
   - **Arguments：**

     ```text
     -NoProfile -ExecutionPolicy Bypass -File "C:\AdaptiveProxy\adaptive-proxy.ps1"
     ```

3. 保存后启动服务：

```powershell
nssm start AdaptiveProxy
```

请将示例路径替换为脚本的实际路径。

## 注意事项

- 故障切换主要发生在连接建立阶段，已建立的连接中断后无法迁移。
- 直连回退可能绕过代理路由，并暴露真实的网络出口地址。
- 当前 SOCKS5 上游仅支持无需认证的连接。
- 代理仅监听 `127.0.0.1`，供本机应用程序使用。

## 开源协议

本项目采用 [MIT License](LICENSE)。
