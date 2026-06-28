# ============================================================
# 「情绪补给站」→ GitHub Pages 全自动部署脚本
# 无需安装 git / GitHub CLI / Node.js；纯 PowerShell + GitHub REST API
# 用法：
#   1) 先在 https://github.com/settings/tokens 生成一个 PAT（勾选 repo 权限）
#   2) 在 PowerShell 里运行：
#      cd d:\编程AI\编程管理文件\创作
#      powershell -ExecutionPolicy Bypass -File .\deploy-to-github.ps1
#   3) 按提示输入 GitHub 用户名 和 Token（Token 输入时不显示字符）
# 输出：部署完成的公网 HTTPS 分享链接 + 后续更新方法
# ============================================================
#Requires -Version 5
$ErrorActionPreference = "Stop"

# -------- 配置 --------
$RepoName    = "emotion-station"
$RepoDesc    = "[情绪补给站] 青少年心灵Spa工具 - 先安抚情绪，再理解真相"
$FilesToPush = @(
    @{ Local = (Join-Path $PSScriptRoot "index.html");          Remote = "index.html" },
    @{ Local = (Join-Path $PSScriptRoot "emotion-station.html"); Remote = "emotion-station.html" }
)
$ApiBase     = "https://api.github.com"
$ApiVersion  = "2022-11-28"
$UserAgent   = "emo-station-deploy/1.0"
$MaxPollSec  = 180   # Pages 构建最多等 3 分钟

# -------- 小工具 --------
function Bin64([byte[]]$bytes){ [Convert]::ToBase64String($bytes) }
function UTF8($s){ [System.Text.Encoding]::UTF8.GetBytes($s) }
function Hdr($token){
    @{
        "Authorization"      = "token $token"
        "Accept"             = "application/vnd.github+json"
        "X-GitHub-Api-Version"= $ApiVersion
        "User-Agent"         = $UserAgent
    }
}
function JSON($obj){ $obj | ConvertTo-Json -Depth 10 -Compress }
function Ask($prompt, $secure=$false){
    Write-Host -NoNewline -ForegroundColor Cyan "$prompt : "
    if($secure){ return (Read-Host -AsSecureString) }
    return (Read-Host).Trim()
}
function Sec2Plain([System.Security.SecureString]$s){
    try { $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# -------- 输入：优先环境变量（自动化模式 / 否则交互 --------
Write-Host "`n☁️  欢迎使用「情绪补给站」GitHub 一键部署脚本" -ForegroundColor Magenta
Write-Host "------------------------------------------------" -ForegroundColor DarkGray

$fromEnv = $false
if( (-not [string]::IsNullOrWhiteSpace($env:GITHUB_USER)) -and (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) ){
    $UserName = $env:GITHUB_USER.Trim()
    $Token    = $env:GITHUB_TOKEN.Trim()
    $fromEnv  = $true
    Write-Host "✅ 已从环境变量读取 GITHUB_USER / GITHUB_TOKEN → 跳过交互（用户名：$UserName）" -ForegroundColor Green
}else{
    Write-Host "👉 1. 请先登录 GitHub 打开下面链接生成 Token（勾选 repo 权限即可）：" -ForegroundColor Yellow
    Write-Host "       https://github.com/settings/tokens/new?scopes=repo&description=emo-station-deploy" -ForegroundColor Cyan
    Write-Host "👉 2. 生成后把 Token 复制好，下面会让你粘贴（粘贴时不会显示字符，放心）`n" -ForegroundColor Yellow

    $UserName = Ask "① 你的 GitHub 用户名（不是邮箱）"
    if([string]::IsNullOrWhiteSpace($UserName)){ Write-Host "用户名不能为空" -ForegroundColor Red; exit 2 }
    $TokenSecure = Ask "② 你的 GitHub Token（勾了 repo 权限的那个）" -secure $true
    $Token = Sec2Plain $TokenSecure
}
if([string]::IsNullOrWhiteSpace($Token)){ Write-Host "Token 不能为空" -ForegroundColor Red; exit 2 }

# 简单校验 Token 长相
if($Token -notmatch "^gh[pors]_[A-Za-z0-9]{36,}$"){
    Write-Warning "Token 格式看起来不太对（正确格式应该是 ghp_ / gho_ / ghs_ 开头 + 36+ 字母数字），不过我还是先帮你试试……"
}

$headers = Hdr $Token

# -------- Step 1: 检查/创建仓库 --------
Write-Host "`n[1/4] 🔍 检查仓库 $UserName/$RepoName 是否存在……" -ForegroundColor Cyan
try{
    $r = Invoke-RestMethod -UseBasicParsing -Uri "$ApiBase/repos/$UserName/$RepoName" -Headers $headers -Method Get -ErrorAction Stop
    Write-Host "     ✅ 仓库已存在（$($r.html_url)），直接上传文件" -ForegroundColor Green
    $DefaultBranch = $r.default_branch
}catch{
    # 仓库不存在 → 创建
    $status = $_.Exception.Response.StatusCode.value__
    if($status -ne 404){
        Write-Host "     ❌ 检查仓库失败：HTTP $status`n$($_.Exception.Message)" -ForegroundColor Red
        try { $_.Exception.Response.GetResponseStream() | % { $sr = New-Object System.IO.StreamReader($_); $t = $sr.ReadToEnd(); Write-Host "GitHub 说：$t" -ForegroundColor DarkRed } }catch{}
        exit 3
    }
    Write-Host "     ➕ 仓库不存在，创建中……" -ForegroundColor DarkCyan
    $body = JSON @{
        name        = $RepoName
        description = $RepoDesc
        private     = $false
        has_issues  = $false
        has_projects= $false
        has_wiki    = $false
        auto_init   = $false
        default_branch = "main"
        homepage    = "https://$UserName.github.io/$RepoName/"
    }
    try{
        $r = Invoke-RestMethod -UseBasicParsing -Uri "$ApiBase/user/repos" -Headers $headers -Method Post -Body $body -ContentType "application/json; charset=utf-8" -ErrorAction Stop
        Write-Host "     ✅ 仓库创建成功：$($r.html_url)" -ForegroundColor Green
        $DefaultBranch = $r.default_branch
    }catch{
        Write-Host "     ❌ 创建仓库失败：$($_.Exception.Message)" -ForegroundColor Red
        try { $_.Exception.Response.GetResponseStream() | % { $sr = New-Object System.IO.StreamReader($_); $t = $sr.ReadToEnd(); Write-Host "GitHub 返回：$t" -ForegroundColor DarkRed } }catch{}
        exit 4
    }
}

# -------- Step 2: 上传 2 个文件 --------
Write-Host "`n[2/4] 📤 上传 index.html & emotion-station.html 到 GitHub……" -ForegroundColor Cyan
$commitMsg = "deploy: 情绪补给站 initial commit $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
foreach($f in $FilesToPush){
    if(-not (Test-Path -LiteralPath $f.Local -PathType Leaf)){
        Write-Host "     ❌ 本地文件不存在：$($f.Local)" -ForegroundColor Red
        exit 5
    }
    $bytes  = [System.IO.File]::ReadAllBytes($f.Local)
    $b64    = Bin64 $bytes
    $apiUrl = "$ApiBase/repos/$UserName/$RepoName/contents/$($f.Remote)"

    # 先取 sha（如果文件已存在）
    $sha = $null
    try{
        $existing = Invoke-RestMethod -UseBasicParsing -Uri $apiUrl -Headers $headers -Method Get -ErrorAction Stop
        if($existing -and $existing.sha){ $sha = $existing.sha }
    }catch{
        $sc = $_.Exception.Response.StatusCode.value__
        if($sc -ne 404){
            Write-Host "     ⚠️ 读取 $($f.Remote) 状态失败 HTTP $sc，继续尝试" -ForegroundColor Yellow
        }
    }

    $payload = @{ message = $commitMsg; content = $b64 }
    if($sha){ $payload["sha"] = $sha }
    $body = JSON $payload

    try{
        $resp = Invoke-RestMethod -UseBasicParsing -Uri $apiUrl -Headers $headers -Method Put -Body $body -ContentType "application/json; charset=utf-8" -ErrorAction Stop
        $sizeKB = [math]::Round($bytes.Count/1KB,1)
        $action = if($sha){"更新"}else{"上传"}
        Write-Host "     ✅ $action $($f.Remote) OK（$sizeKB KB，commit: $($resp.commit.sha.Substring(0,7))）" -ForegroundColor Green
    }catch{
        Write-Host "     ❌ 上传 $($f.Remote) 失败：$($_.Exception.Message)" -ForegroundColor Red
        try { $_.Exception.Response.GetResponseStream() | % { $sr = New-Object System.IO.StreamReader($_); $t = $sr.ReadToEnd(); Write-Host "GitHub 返回：$t" -ForegroundColor DarkRed } }catch{}
        exit 6
    }
}

# -------- Step 3: 开启 GitHub Pages --------
Write-Host "`n[3/4] 🌐 开启 GitHub Pages（分支=$DefaultBranch，目录=/）……" -ForegroundColor Cyan
$pagesUrl = "$ApiBase/repos/$UserName/$RepoName/pages"
# 先检查是否已开启
$pagesEnabled = $false
try{
    $p = Invoke-RestMethod -UseBasicParsing -Uri $pagesUrl -Headers $headers -Method Get -ErrorAction Stop
    Write-Host "     ✅ Pages 已开启（状态：$($p.status)，URL：$($p.html_url)）" -ForegroundColor Green
    $pagesEnabled = $true
}catch{
    $sc = $_.Exception.Response.StatusCode.value__
    if($sc -ne 404){
        Write-Host "     ⚠️ Pages 检查失败 HTTP $sc，尝试继续启用……" -ForegroundColor Yellow
    }
}
if(-not $pagesEnabled){
    $body = JSON @{ build_type = "legacy"; source = @{ branch = $DefaultBranch; path = "/" } }
    try{
        $p = Invoke-RestMethod -UseBasicParsing -Uri $pagesUrl -Headers $headers -Method Post -Body $body -ContentType "application/json; charset=utf-8" -ErrorAction Stop
        Write-Host "     ✅ Pages 已成功开启（URL：$($p.html_url)）" -ForegroundColor Green
    }catch{
        Write-Host "     ❌ 开启 Pages 失败：$($_.Exception.Message)" -ForegroundColor Red
        try { $_.Exception.Response.GetResponseStream() | % { $sr = New-Object System.IO.StreamReader($_); $t = $sr.ReadToEnd(); Write-Host "GitHub 返回：$t" -ForegroundColor DarkRed } }catch{}
        exit 7
    }
}

# -------- Step 4: 等待 Pages 构建 + 验证可访问 --------
$PublicURL = "https://$UserName.github.io/$RepoName/"
Write-Host "`n[4/4] ⏳ 等待 Pages 构建完成（最多 $MaxPollSec 秒）……" -ForegroundColor Cyan
Write-Host "     目标地址：$PublicURL" -ForegroundColor DarkCyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$built = $false
$first = $true
while($sw.Elapsed.TotalSeconds -lt $MaxPollSec){
    try{
        $p = Invoke-RestMethod -UseBasicParsing -Uri $pagesUrl -Headers $headers -Method Get -ErrorAction Stop
        $st = $p.status
        Write-Host -NoNewline ("     {0,-25} 状态={1,-12} 已等 {2}s`r" -f "(第 $($sw.Elapsed.Seconds) 秒轮询)", $st, $([math]::Floor($sw.Elapsed.TotalSeconds)))
        if($st -in @("built","served","published")){ $built = $true; break }
        if($st -in @("errored","errored_build")){
            Write-Host "`n     ⚠️ Pages 构建报错，但网站可能已经可用；继续用 HTTP 探测" -ForegroundColor Yellow
            break
        }
    }catch{
        # 忽略轮询错误
    }
    Start-Sleep -Seconds 6
    $first = $false
}
Write-Host ""

# HTTP 探测 10 次，看看是否 200
Write-Host "     🛰️  HTTP 200 探测（最多 10 次）……" -ForegroundColor Cyan
$httpOk = $false
for($i=1; $i -le 10; $i++){
    try{
        $r = Invoke-WebRequest -UseBasicParsing -Uri $PublicURL -TimeoutSec 8 -ErrorAction Stop
        Write-Host "     ✅ 第 $i 次探测：HTTP $($r.StatusCode)（$($r.Content.Length) bytes）" -ForegroundColor Green
        $httpOk = $true
        break
    }catch{
        $sc = $_.Exception.Response.StatusCode.value__
        Write-Host ("     第 {0,2} 次探测：{1}" -f $i, ($sc ? "HTTP $sc" : $_.Exception.Message)) -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
    }
}

# -------- 最终输出 --------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "🎉 部署完成！你的「情绪补给站」已上线 🎉" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "🌐 公网分享链接（复制发给朋友，微信/浏览器直接可开）：" -ForegroundColor Yellow
Write-Host "   $PublicURL" -ForegroundColor Cyan
Write-Host ""
Write-Host "📦 你的 GitHub 仓库地址：" -ForegroundColor Yellow
Write-Host "   https://github.com/$UserName/$RepoName" -ForegroundColor Cyan
Write-Host ""
if($httpOk){
    Write-Host "✅ HTTP 200 验证通过，现在就能发给朋友啦！" -ForegroundColor Green
}else{
    Write-Host "⚠️  HTTP 还没返回 200（可能是 Pages 正在构建，最长不超过 10 分钟）" -ForegroundColor Yellow
    Write-Host "   👉 过 5 分钟手动打开上面的链接试试；如果你是第一次用 GitHub Pages，最长可能要 10 分钟"
}
Write-Host ""
Write-Host "------------------------------------------------" -ForegroundColor DarkGray
Write-Host "📝 后续更新代码（比如你又加了新的安慰语/动画）：" -ForegroundColor Yellow
Write-Host "   1. 在电脑上改完 emotion-station.html 后，复制一份覆盖同目录的 index.html"
Write-Host "   2. 再跑一次这个脚本："
Write-Host "      powershell -ExecutionPolicy Bypass -File .\deploy-to-github.ps1"
Write-Host "   → 脚本会自动检测仓库存在，只更新两个文件，30 秒内上线完成"
Write-Host ""
exit 0
