#Requires -Version 5.1
<#
.SYNOPSIS
    自适应本地代理（带故障转移）：本脚本监听一个固定端口，把流量按优先级转交给上游代理；
    上游代理不可用时自动降级到下一个，最后可回退到直连。

.DESCRIPTION
    用法：把 HTTP_PROXY / HTTPS_PROXY 指向 http://127.0.0.1:<ListenPort> 即可。
    支持 HTTP 明文请求与 HTTPS 的 CONNECT 隧道。
    健康检查在后台周期运行；即使健康检查尚未更新，单条连接也会实时探测并按序降级。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\adaptive-proxy.ps1

.EXAMPLE
    # 临时覆盖端口与上游（命令行优先于下方配置区）
    powershell -NoProfile -ExecutionPolicy Bypass -File .\adaptive-proxy.ps1 -Port 32334 -Ports 65534,31323
#>
[CmdletBinding()]
param(
    # 命令行覆盖项（可选）。不填则使用下方“可修改配置区”的值。
    [int]       $Port,
    [int[]]     $Ports,
    [Alias('Upstreams')]
    [string[]]  $UpstreamsArg,
    [switch]    $NoDirect
)

# ===================================================================
#  可修改配置区 —— 直接改这里即可
# ===================================================================
$ListenPort        = 32333                        # 本脚本监听的端口（其他工具连这个）
$Upstreams         = @()                          # 上游列表，按优先级从高到低
                                                    #   'http://127.0.0.1:31323'   HTTP 代理
                                                    #   'socks5://127.0.0.1:1080'  SOCKS5 代理
                                                    #   '127.0.0.1:7890'            省略协议时按 HTTP 处理
                                                    #   'direct'                    直连
                                                    #   31323（纯数字）             等价于 'http://127.0.0.1:31323'
$ProxyPorts        = @(31323, 33333)              # 简易写法（全部按 HTTP 代理）；$Upstreams 为空时才使用
$AllowDirect       = $true                        # 所有上游代理都不可用时，是否回退到直连
$HealthIntervalSec = 15                           # 后台健康检查间隔（秒）
$ConnectTimeoutMs  = 3000                         # 连接单个上游的超时（毫秒）
$DeepCheck         = $true                        # 深度检测：真实发一次 CONNECT/握手验证链路（不只是探端口）
$ProbeHost         = 'www.gstatic.com'            # 深度检测的目标主机
$ProbePort         = 443                          # 深度检测的目标端口
$Verbose           = $true                        # 打印每条连接的转发详情
# ===================================================================

if ($PSBoundParameters.ContainsKey('Port'))         { $ListenPort = $Port }
if ($PSBoundParameters.ContainsKey('Ports'))        { $ProxyPorts = $Ports }
if ($PSBoundParameters.ContainsKey('UpstreamsArg')) { $Upstreams  = $UpstreamsArg }
if ($PSBoundParameters.ContainsKey('NoDirect'))     { $AllowDirect = $false }

$proxySource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace AdaptiveProxy
{
    public enum UpstreamKind { Direct, Http, Socks5 }

    public class Upstream
    {
        public string Name;
        public string Host;
        public int Port;
        public UpstreamKind Kind;

        public Upstream(string name, string host, int port, UpstreamKind kind)
        {
            Name = name; Host = host; Port = port; Kind = kind;
        }

        public bool IsDirect { get { return Kind == UpstreamKind.Direct; } }
        public bool IsSocks5 { get { return Kind == UpstreamKind.Socks5; } }

        public string Describe()
        {
            if (IsDirect) { return "DIRECT"; }
            return (IsSocks5 ? "socks5://" : "http://") + Host + ":" + Port;
        }
    }

    public class ServerOptions
    {
        public int ListenPort;
        public int ConnectTimeoutMs;
        public int HealthIntervalMs;
        public bool DeepCheck;
        public string ProbeHost;
        public int ProbePort;
        public bool Verbose;
    }

    public class ProxyServer
    {
        private readonly Upstream[] _upstreams;
        private readonly ServerOptions _opt;
        private TcpListener _listener;
        private volatile Upstream _active;
        private volatile bool _running = true;
        private readonly ManualResetEventSlim _stopEvent = new ManualResetEventSlim(false);
        private readonly object _logLock = new object();

        public ProxyServer(Upstream[] upstreams, ServerOptions opt)
        {
            _upstreams = upstreams;
            _opt = opt;
            _active = upstreams[0];
        }

        public void Log(string msg)
        {
            if (!_opt.Verbose) { return; }
            lock (_logLock)
            {
                Console.WriteLine("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + msg);
                Console.Out.Flush();
            }
        }

        public void Start()
        {
            try
            {
                _listener = new TcpListener(IPAddress.Any, _opt.ListenPort);
                _listener.Start();
            }
            catch (Exception ex)
            {
                throw new Exception("无法监听端口 " + _opt.ListenPort + "（可能已被占用）：" + ex.Message, ex);
            }

            Log("监听中：0.0.0.0:" + _opt.ListenPort);
            for (int i = 0; i < _upstreams.Length; i++)
            {
                Log("  上游[" + i + "] = " + _upstreams[i].Describe());
            }
            Log("请把 HTTP_PROXY / HTTPS_PROXY 设为 http://127.0.0.1:" + _opt.ListenPort);
            Log("健康检查间隔 " + (_opt.HealthIntervalMs / 1000) + "s，深度检测=" + (_opt.DeepCheck ? "开" : "关") + "。Ctrl+C 退出。");
            Log("");

            // 把 accept 循环放到后台线程，Start() 立即返回，主线程留给 PowerShell 处理 Ctrl+C。
            // 否则主线程会卡在 AcceptTcpClient() 里，Ctrl+C 无法中断脚本。
            Thread acceptThread = new Thread(AcceptLoop);
            acceptThread.IsBackground = true;
            acceptThread.Name = "accept-loop";
            acceptThread.Start();

            Thread healthThread = new Thread(HealthLoop);
            healthThread.IsBackground = true;
            healthThread.Name = "health-loop";
            healthThread.Start();
        }

        public bool IsRunning
        {
            get { return _running; }
        }

        private void AcceptLoop()
        {
            while (_running)
            {
                try
                {
                    TcpClient client = _listener.AcceptTcpClient();
                    Task.Factory.StartNew(delegate { HandleClient(client); });
                }
                catch (Exception ex)
                {
                    if (_running) { Log("accept 错误：" + ex.Message); }
                }
            }
        }

        public void Stop()
        {
            _running = false;
            try { _stopEvent.Set(); } catch { }
            try { if (_listener != null) { _listener.Stop(); } } catch { }
        }

        // ---------- 健康检查 ----------

        private void HealthLoop()
        {
            while (_running)
            {
                try
                {
                    Upstream best = SelectUpstream();
                    if (best != null && !ReferenceEquals(best, _active))
                    {
                        Log("当前上游 -> " + best.Describe());
                        _active = best;
                    }
                }
                catch (Exception ex) { Log("健康检查异常：" + ex.Message); }
                if (_stopEvent.Wait(_opt.HealthIntervalMs)) { break; }
            }
        }

        // 按配置顺序挑选：优先“验证通过”的，其次“端口可达”的，最后直连
        private Upstream SelectUpstream()
        {
            Upstream reachable = null;
            for (int i = 0; i < _upstreams.Length; i++)
            {
                Upstream up = _upstreams[i];
                if (up.IsDirect)
                {
                    return (reachable != null) ? reachable : up;
                }
                int state = Probe(up);
                if (state == 2) { return up; }
                if (state == 1 && reachable == null) { reachable = up; }
            }
            return (reachable != null) ? reachable : _upstreams[_upstreams.Length - 1];
        }

        // 0 = 不可用, 1 = 端口可达但深度检测未通过, 2 = 完全可用
        private int Probe(Upstream up)
        {
            if (!TcpProbe(up.Host, up.Port, _opt.ConnectTimeoutMs)) { return 0; }
            if (!_opt.DeepCheck) { return 2; }
            return DeepProbe(up) ? 2 : 1;
        }

        private bool TcpProbe(string host, int port, int timeoutMs)
        {
            TcpClient c = new TcpClient();
            try
            {
                IAsyncResult ar = c.BeginConnect(host, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs, false)) { return false; }
                c.EndConnect(ar);
                return c.Connected;
            }
            catch { return false; }
            finally { SafeClose(c); }
        }

        private bool DeepProbe(Upstream up)
        {
            TcpClient c = new TcpClient();
            try
            {
                if (!ConnectWithTimeout(c, up.Host, up.Port, _opt.ConnectTimeoutMs)) { return false; }
                NetworkStream s = c.GetStream();
                if (up.IsSocks5)
                {
                    return Socks5Handshake(c, _opt.ProbeHost, _opt.ProbePort, 5000);
                }
                string req = "CONNECT " + _opt.ProbeHost + ":" + _opt.ProbePort + " HTTP/1.1\r\n"
                           + "Host: " + _opt.ProbeHost + ":" + _opt.ProbePort + "\r\n\r\n";
                byte[] rb = Encoding.ASCII.GetBytes(req);
                s.Write(rb, 0, rb.Length);
                s.Flush();
                HeadReader hr = new HeadReader(s);
                string[] lines; byte[] lo;
                if (!hr.TryRead(out lines, out lo)) { return false; }
                if (lines.Length == 0) { return false; }
                return lines[0].IndexOf(" 200") >= 0;
            }
            catch { return false; }
            finally { SafeClose(c); }
        }

        // ---------- 连接处理 ----------

        private List<Upstream> BuildOrder()
        {
            List<Upstream> order = new List<Upstream>();
            if (_active != null) { order.Add(_active); }
            for (int i = 0; i < _upstreams.Length; i++)
            {
                if (!ReferenceEquals(_upstreams[i], _active)) { order.Add(_upstreams[i]); }
            }
            return order;
        }

        private void HandleClient(TcpClient client)
        {
            try
            {
                client.NoDelay = true;
                NetworkStream cs = client.GetStream();
                HeadReader hr = new HeadReader(cs);
                string[] lines; byte[] leftover;
                if (!hr.TryRead(out lines, out leftover) || lines.Length == 0)
                {
                    SafeClose(client);
                    return;
                }

                string requestLine = lines[0];
                string method, target, version;
                ParseRequestLine(requestLine, out method, out target, out version);

                string host; int port; string path;
                if (method == "CONNECT")
                {
                    host = HostOf(target);
                    port = PortOf(target, 443);
                    path = "";
                }
                else
                {
                    ResolveOrigin(target, lines, out host, out port, out path);
                }

                List<Upstream> order = BuildOrder();
                for (int i = 0; i < order.Count; i++)
                {
                    Upstream up = order[i];
                    try
                    {
                        bool ok = (method == "CONNECT")
                            ? TryTunnel(up, host, port, leftover, client, cs)
                            : TryForward(up, host, port, method, target, version, path, lines, leftover, client, cs);
                        if (ok)
                        {
                            if (!ReferenceEquals(up, _active)) { _active = up; }
                            return;
                        }
                    }
                    catch (Exception ex)
                    {
                        Log("上游 " + up.Describe() + " 出错：" + ex.Message + "，尝试下一个");
                    }
                }

                Log("所有上游均不可用，请求失败：" + requestLine);
                SafeClose(client);
            }
            catch (Exception ex)
            {
                Log("连接处理异常：" + ex.Message);
                SafeClose(client);
            }
        }

        // HTTPS 隧道
        private bool TryTunnel(Upstream up, string host, int port, byte[] clientLeftover, TcpClient client, NetworkStream cs)
        {
            TcpClient remote = new TcpClient();
            try
            {
                remote.NoDelay = true;
                string thost = up.IsDirect ? host : up.Host;
                int tport = up.IsDirect ? port : up.Port;
                if (!ConnectWithTimeout(remote, thost, tport, _opt.ConnectTimeoutMs))
                {
                    Log("上游 " + up.Describe() + " 连不上 " + thost + ":" + tport + "，降级");
                    SafeClose(remote);
                    return false;
                }

                NetworkStream rs = remote.GetStream();
                byte[] upLeftover = new byte[0];
                if (up.IsSocks5)
                {
                    if (!Socks5Handshake(remote, host, port, _opt.ConnectTimeoutMs))
                    {
                        Log("上游 " + up.Describe() + " SOCKS5 握手失败，降级");
                        SafeClose(remote);
                        return false;
                    }
                    // SOCKS5 没有 HTTP 应答，替客户端合成一个 200
                    byte[] ok = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection established\r\n\r\n");
                    cs.Write(ok, 0, ok.Length);
                    cs.Flush();
                }
                else if (!up.IsDirect)
                {
                    string req = "CONNECT " + host + ":" + port + " HTTP/1.1\r\n"
                               + "Host: " + host + ":" + port + "\r\n"
                               + "Proxy-Connection: keep-alive\r\n\r\n";
                    byte[] rb = Encoding.ASCII.GetBytes(req);
                    rs.Write(rb, 0, rb.Length);
                    rs.Flush();

                    HeadReader hr = new HeadReader(rs);
                    string[] rl; byte[] lo;
                    if (!hr.TryRead(out rl, out lo))
                    {
                        Log("上游 " + up.Describe() + " CONNECT 前断开，降级");
                        SafeClose(remote);
                        return false;
                    }
                    if (rl.Length == 0 || rl[0].IndexOf(" 200") < 0)
                    {
                        Log("上游 " + up.Describe() + " 拒绝 CONNECT（" + (rl.Length > 0 ? rl[0] : "?") + "），降级");
                        SafeClose(remote);
                        return false;
                    }
                    upLeftover = lo;
                    // 把上游的 200 响应原样回传给客户端，否则客户端会一直等待 CONNECT 应答
                    if (hr.RawHeader != null && hr.RawHeader.Length > 0)
                    {
                        cs.Write(hr.RawHeader, 0, hr.RawHeader.Length);
                        cs.Flush();
                    }
                }
                else
                {
                    // 直连：本进程自己充当隧道端，同样必须先给客户端回 200，
                    // 否则客户端会一直等待 CONNECT 应答而挂起。
                    byte[] ok = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection established\r\n\r\n");
                    cs.Write(ok, 0, ok.Length);
                    cs.Flush();
                }

                Log("CONNECT " + host + ":" + port + "  ->  " + up.Describe());
                if (clientLeftover != null && clientLeftover.Length > 0) { rs.Write(clientLeftover, 0, clientLeftover.Length); }
                if (upLeftover.Length > 0) { cs.Write(upLeftover, 0, upLeftover.Length); }
                Relay(cs, rs);
                return true;
            }
            catch (Exception ex)
            {
                Log("隧道失败（" + up.Describe() + "）：" + ex.Message);
                SafeClose(remote);
                return false;
            }
        }

        // 明文 HTTP 转发
        private bool TryForward(Upstream up, string host, int port, string method, string target, string version, string path,
                                string[] lines, byte[] clientLeftover, TcpClient client, NetworkStream cs)
        {
            TcpClient remote = new TcpClient();
            try
            {
                remote.NoDelay = true;
                string thost;
                int tport;
                if (up.IsSocks5) { thost = up.Host; tport = up.Port; }
                else if (up.IsDirect) { thost = host; tport = port; }
                else { thost = up.Host; tport = up.Port; }
                if (!ConnectWithTimeout(remote, thost, tport, _opt.ConnectTimeoutMs))
                {
                    Log("上游 " + up.Describe() + " 连不上 " + thost + ":" + tport + "，降级");
                    SafeClose(remote);
                    return false;
                }

                NetworkStream rs = remote.GetStream();
                if (up.IsSocks5)
                {
                    if (!Socks5Handshake(remote, host, port, _opt.ConnectTimeoutMs))
                    {
                        Log("上游 " + up.Describe() + " SOCKS5 握手失败，降级");
                        SafeClose(remote);
                        return false;
                    }
                }
                string reqLine;
                if (up.IsDirect || up.IsSocks5)
                {
                    reqLine = method + " " + path + " " + version;
                }
                else
                {
                    reqLine = method + " " + target + " " + version;
                }

                StringBuilder sb = new StringBuilder();
                sb.Append(reqLine).Append("\r\n");
                for (int i = 1; i < lines.Length; i++) { sb.Append(lines[i]).Append("\r\n"); }
                sb.Append("\r\n");
                byte[] head = Encoding.GetEncoding("ISO-8859-1").GetBytes(sb.ToString());
                rs.Write(head, 0, head.Length);
                if (clientLeftover != null && clientLeftover.Length > 0) { rs.Write(clientLeftover, 0, clientLeftover.Length); }
                rs.Flush();

                Log("HTTP " + reqLine + "  ->  " + up.Describe());
                Relay(cs, rs);
                return true;
            }
            catch (Exception ex)
            {
                Log("转发失败（" + up.Describe() + "）：" + ex.Message);
                SafeClose(remote);
                return false;
            }
        }

        // ---------- SOCKS5 握手 ----------

        private static bool Socks5Handshake(TcpClient client, string host, int port, int timeoutMs)
        {
            try
            {
                NetworkStream s = client.GetStream();
                s.ReadTimeout = timeoutMs;
                s.WriteTimeout = timeoutMs;

                // 1) 问候：VER=5, NMETHODS=1, METHODS=[NO AUTHENTICATION REQUIRED]
                byte[] greet = new byte[] { 0x05, 0x01, 0x00 };
                s.Write(greet, 0, greet.Length);
                s.Flush();

                byte[] greetResp = ReadExact(s, 2);
                if (greetResp == null || greetResp[0] != 0x05 || greetResp[1] != 0x00) { return false; }

                // 2) CONNECT 请求：VER=5, CMD=1(CONNECT), RSV=0, ATYP, ADDR, PORT
                byte[] req = BuildSocks5Connect(host, port);
                s.Write(req, 0, req.Length);
                s.Flush();

                // 3) 应答：VER=5, REP=0(SUCCESS), RSV, ATYP, BND.ADDR, BND.PORT
                byte[] head = ReadExact(s, 4);
                if (head == null || head[0] != 0x05 || head[1] != 0x00) { return false; }
                byte atyp = head[3];
                if (atyp == 0x01) { if (ReadExact(s, 4) == null) { return false; } }
                else if (atyp == 0x04) { if (ReadExact(s, 16) == null) { return false; } }
                else if (atyp == 0x03)
                {
                    byte[] lenBuf = ReadExact(s, 1);
                    if (lenBuf == null) { return false; }
                    if (ReadExact(s, lenBuf[0]) == null) { return false; }
                }
                else { return false; }
                if (ReadExact(s, 2) == null) { return false; }
                return true;
            }
            catch { return false; }
        }

        private static byte[] ReadExact(Stream s, int count)
        {
            byte[] buf = new byte[count];
            int read = 0;
            while (read < count)
            {
                int n = s.Read(buf, read, count - read);
                if (n <= 0) { return null; }
                read += n;
            }
            return buf;
        }

        private static byte[] BuildSocks5Connect(string host, int port)
        {
            byte atyp;
            byte[] addr;
            IPAddress ip;
            if (IPAddress.TryParse(host, out ip))
            {
                atyp = (ip.AddressFamily == AddressFamily.InterNetwork) ? (byte)0x01 : (byte)0x04;
                addr = ip.GetAddressBytes();
            }
            else
            {
                atyp = 0x03;
                byte[] name = Encoding.ASCII.GetBytes(host);
                addr = new byte[1 + name.Length];
                addr[0] = (byte)name.Length;
                Array.Copy(name, 0, addr, 1, name.Length);
            }
            byte[] req = new byte[4 + addr.Length + 2];
            req[0] = 0x05; req[1] = 0x01; req[2] = 0x00; req[3] = atyp;
            Array.Copy(addr, 0, req, 4, addr.Length);
            int p = 4 + addr.Length;
            req[p] = (byte)((port >> 8) & 0xFF);
            req[p + 1] = (byte)(port & 0xFF);
            return req;
        }

        // ---------- 双向转发 ----------

        private void Relay(Stream a, Stream b)
        {
            Task t1 = a.CopyToAsync(b);
            Task t2 = b.CopyToAsync(a);
            try { Task.WaitAny(t1, t2); } catch { }
            // 某一方向结束后另一方向可能仍有数据在途（例如服务器正在回传响应体），
            // 立即关闭会把响应截断，这里给剩余方向一个有限的收尾窗口。
            try { Task.WaitAny(new Task[] { t1, t2 }, 3000); } catch { }
            try { a.Close(); } catch { }
            try { b.Close(); } catch { }
        }

        // ---------- 解析辅助 ----------

        private static void ParseRequestLine(string line, out string method, out string target, out string version)
        {
            string[] p = line.Split(' ');
            method = p.Length > 0 ? p[0].ToUpperInvariant() : "";
            target = p.Length > 1 ? p[1] : "";
            version = p.Length > 2 ? p[2] : "HTTP/1.1";
        }

        private static string HostOf(string authority)
        {
            int i = authority.LastIndexOf(':');
            if (i > 0) { return authority.Substring(0, i); }
            return authority;
        }

        private static int PortOf(string authority, int def)
        {
            int i = authority.LastIndexOf(':');
            if (i > 0)
            {
                int v;
                if (int.TryParse(authority.Substring(i + 1), out v)) { return v; }
            }
            return def;
        }

        private static void ResolveOrigin(string target, string[] lines, out string host, out int port, out string path)
        {
            path = "/";
            port = 80;
            if (target.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            {
                string rest = target.Substring(7);
                int slash = rest.IndexOf('/');
                string authority = (slash >= 0) ? rest.Substring(0, slash) : rest;
                path = (slash >= 0) ? rest.Substring(slash) : "/";
                host = HostOf(authority);
                port = PortOf(authority, 80);
                return;
            }
            // origin-form：回落到 Host 头
            host = "localhost";
            for (int i = 1; i < lines.Length; i++)
            {
                int c = lines[i].IndexOf(':');
                if (c > 0 && lines[i].Substring(0, c).Trim().ToLowerInvariant() == "host")
                {
                    string hv = lines[i].Substring(c + 1).Trim();
                    host = HostOf(hv);
                    port = PortOf(hv, 80);
                    break;
                }
            }
            path = (target.Length > 0 && target[0] == '/') ? target : "/";
        }

        private static bool ConnectWithTimeout(TcpClient c, string host, int port, int timeoutMs)
        {
            IAsyncResult ar = c.BeginConnect(host, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(timeoutMs, false)) { return false; }
            c.EndConnect(ar);
            return c.Connected;
        }

        private static void SafeClose(TcpClient c)
        {
            if (c == null) { return; }
            try { c.Close(); } catch { }
        }
    }

    // 逐字节读取一段 HTTP 头（保留头之后多余的字节）
    public class HeadReader
    {
        private readonly Stream _s;
        private byte[] _buf;
        public byte[] RawHeader;

        public HeadReader(Stream s)
        {
            _s = s;
            _buf = new byte[0];
        }

        public bool TryRead(out string[] lines, out byte[] leftover)
        {
            lines = null;
            leftover = new byte[0];
            RawHeader = null;
            int idx = IndexOfTerminator(_buf, 0);
            while (idx < 0)
            {
                byte[] chunk = new byte[8192];
                int n = _s.Read(chunk, 0, chunk.Length);
                if (n <= 0) { return false; }
                Append(chunk, n);
                idx = IndexOfTerminator(_buf, 0);
            }
            int headerLen = idx + 4;
            RawHeader = new byte[headerLen];
            Array.Copy(_buf, 0, RawHeader, 0, headerLen);
            string text = Encoding.GetEncoding("ISO-8859-1").GetString(_buf, 0, headerLen);
            string normalized = text.Replace("\r\n", "\n").TrimEnd('\n');
            lines = normalized.Length == 0 ? new string[0] : normalized.Split('\n');
            int rest = _buf.Length - headerLen;
            if (rest > 0)
            {
                leftover = new byte[rest];
                Array.Copy(_buf, headerLen, leftover, 0, rest);
            }
            _buf = new byte[0];
            return true;
        }

        private void Append(byte[] data, int count)
        {
            byte[] nb = new byte[_buf.Length + count];
            Array.Copy(_buf, 0, nb, 0, _buf.Length);
            Array.Copy(data, 0, nb, _buf.Length, count);
            _buf = nb;
        }

        private static int IndexOfTerminator(byte[] data, int from)
        {
            for (int i = Math.Max(0, from); i + 3 < data.Length; i++)
            {
                if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) { return i; }
            }
            return -1;
        }
    }
}
'@

Write-Host "正在编译内置代理核心（首次运行需要几秒）..." -ForegroundColor DarkGray
if (-not ('AdaptiveProxy.ProxyServer' -as [type])) {
    Add-Type -TypeDefinition $proxySource -Language CSharp -ErrorAction Stop
}
Write-Host "编译完成。" -ForegroundColor DarkGray
Write-Host ""

# 上游列表归一化：统一成 @{ scheme; host; port; kind }
# 注意：必须放在 Add-Type 之后，AdaptiveProxy.* 类型此时才存在。
$upstreamSpecs = New-Object System.Collections.ArrayList
$upstreamList = @($Upstreams)
if ($upstreamList.Count -gt 0) {
    foreach ($u in $upstreamList) {
        [void]$upstreamSpecs.Add([pscustomobject]@{ Raw = "$u" })
    }
} else {
    foreach ($p in @($ProxyPorts)) {
        [void]$upstreamSpecs.Add([pscustomobject]@{ Raw = "$p" })
    }
}

# 单个条目内部还可能带逗号（例如命令行 -Upstreams a,b 会被当成一个字符串传进来），这里再拆一次
$rawEntries = New-Object System.Collections.ArrayList
foreach ($spec in $upstreamSpecs) {
    foreach ($piece in ([string]$spec.Raw).Split(',')) {
        $t = $piece.Trim()
        if ($t -ne '') { [void]$rawEntries.Add($t) }
    }
}

$parsedUpstreams = New-Object System.Collections.ArrayList
foreach ($raw in $rawEntries) {
    if ($raw -match '^(?i:direct)$') {
        [void]$parsedUpstreams.Add((New-Object AdaptiveProxy.Upstream('DIRECT', '', 0, [AdaptiveProxy.UpstreamKind]::Direct)))
        continue
    }
    $scheme = 'http'
    $rest = $raw
    if ($raw -match '^(?i)(http|socks5)://(.+)$') {
        $scheme = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2]
    }
    # 去掉可能存在的凭据
    if ($rest -match '@') { $rest = ($rest -split '@')[-1] }
    $hostName = $rest
    $portNum = 0
    if ($rest -match '^(.+):(\d+)$') {
        $hostName = $Matches[1]
        $portNum = [int]$Matches[2]
    }
    elseif ($rest -match '^\d+$') {
        # 纯数字：等价于 'http://127.0.0.1:<port>'
        $hostName = '127.0.0.1'
        $portNum = [int]$rest
    }
    # 未指定端口时按协议给默认值
    if ($portNum -le 0) { $portNum = $(if ($scheme -eq 'socks5') { 1080 } else { 80 }) }
    $kind = $(if ($scheme -eq 'socks5') { [AdaptiveProxy.UpstreamKind]::Socks5 } else { [AdaptiveProxy.UpstreamKind]::Http })
    [void]$parsedUpstreams.Add((New-Object AdaptiveProxy.Upstream("$scheme-$hostName-$portNum", $hostName, $portNum, $kind)))
}

if ($AllowDirect) {
    # 列表末尾已经是 DIRECT 时不再重复添加；DIRECT 出现在列表中间时仍保留末尾兜底
    $lastIsDirect = ($parsedUpstreams.Count -gt 0) -and
                     ([AdaptiveProxy.UpstreamKind]$parsedUpstreams[$parsedUpstreams.Count - 1].Kind) -eq [AdaptiveProxy.UpstreamKind]::Direct
    if (-not $lastIsDirect) {
        [void]$parsedUpstreams.Add((New-Object AdaptiveProxy.Upstream('DIRECT', '', 0, [AdaptiveProxy.UpstreamKind]::Direct)))
    }
}

if ($parsedUpstreams.Count -eq 0) {
    Write-Host "配置错误：至少需要一个上游代理或开启直连回退。" -ForegroundColor Red
    exit 1
}

$options = New-Object AdaptiveProxy.ServerOptions
$options.ListenPort       = [int]$ListenPort
$options.ConnectTimeoutMs = [int]$ConnectTimeoutMs
$options.HealthIntervalMs = [int]($HealthIntervalSec * 1000)
$options.DeepCheck        = [bool]$DeepCheck
$options.ProbeHost        = $ProbeHost
$options.ProbePort        = [int]$ProbePort
$options.Verbose          = [bool]$Verbose

$server = New-Object AdaptiveProxy.ProxyServer($parsedUpstreams.ToArray(), $options)

try {
    $server.Start()
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

try {
    # Start() 已改为非阻塞；这里只负责在 Ctrl+C 停止后退出脚本。
    while ($server.IsRunning) { Start-Sleep -Milliseconds 250 }
}
finally {
    $server.Stop()
}
