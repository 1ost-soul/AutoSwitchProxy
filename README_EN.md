# Adaptive Proxy/AutoSwitchProxy

A lightweight local HTTP proxy with automatic upstream failover for command-line tools.

## Features

- Stable local endpoint: `127.0.0.1:32333`
- Automatic upstream selection and failover
- HTTP and SOCKS5 upstream support
- Optional direct connection fallback
- Background health checks and configurable timeouts
- HTTPS tunneling via CONNECT

## Requirements

- Windows
- Windows PowerShell 5.1+

## Quick Start

### 1. Configure upstreams

Edit the configuration section in `adaptive-proxy.ps1`:

```powershell
$ListenPort        = 32333
$Upstreams         = @()
$ProxyPorts        = @(31323, 1080, 8443)
$AllowDirect       = $true
```

When `$Upstreams` is empty, `$ProxyPorts` treats all entries as HTTP proxy ports. To configure SOCKS5, specify the protocol explicitly:

```powershell
$Upstreams = @(
    'http://127.0.0.1:31323',
    'socks5://127.0.0.1:1080'
)
```

### 2. Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\adaptive-proxy.ps1
```

### 3. Configure Git and npm

```powershell
git config --global http.proxy http://127.0.0.1:32333

npm config set proxy http://127.0.0.1:32333
npm config set https-proxy http://127.0.0.1:32333
```

To remove the settings:

```powershell
git config --global --unset http.proxy
npm config delete proxy
npm config delete https-proxy
```

## Start Automatically with Windows

### Option A: Task Scheduler (Recommended)

Task Scheduler is built into Windows; no additional software is required.

1. Save `adaptive-proxy.ps1` to a permanent location, such as `C:\AdaptiveProxy\adaptive-proxy.ps1`.
2. Open PowerShell as Administrator and run the following, updating the script path if necessary:

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

3. Start the task:

```powershell
Start-ScheduledTask -TaskName "AdaptiveProxy"
```

The task starts when you log in and runs in the background. To stop it:

```powershell
Stop-ScheduledTask -TaskName "AdaptiveProxy"
```

To remove it:

```powershell
Unregister-ScheduledTask -TaskName "AdaptiveProxy" -Confirm:$false
```

### Option B: NSSM (Optional)

If you prefer to manage Adaptive Proxy as a Windows service, you can use [NSSM](https://nssm.cc/).

1. Download NSSM and run `nssm install AdaptiveProxy` as Administrator.
2. Configure the application:

   - **Path:** `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
   - **Startup directory:** the script's directory
   - **Arguments:**
     ```text
     -NoProfile -ExecutionPolicy Bypass -File "C:\AdaptiveProxy\adaptive-proxy.ps1"
     ```

3. Save the configuration and start the service:

```powershell
nssm start AdaptiveProxy
```

Replace the example path with your actual script location.

## Notes

- Failover primarily applies during connection establishment; existing connections cannot be migrated after they break.
- Direct fallback may bypass proxy routing and expose your real network address.
- SOCKS5 upstreams currently support unauthenticated connections only.
- The proxy listens on `127.0.0.1` for local applications.

## License

[MIT License](LICENSE)
