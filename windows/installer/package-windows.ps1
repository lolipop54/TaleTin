[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NsisCompiler,
    [Parameter(Mandatory)][string]$VcRuntimeDirectory,
    [string]$ReleaseDirectory,
    [string]$DeliveryDirectory,
    [string]$SignToolPath,
    [string]$CertificateThumbprint,
    [uri]$TimestampUrl,
    [switch]$UnsignedPreview
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (!$ReleaseDirectory) {
    $ReleaseDirectory = Join-Path $project 'build\windows\x64\runner\Release'
}
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$compiler = (Resolve-Path -LiteralPath $NsisCompiler).Path

$versionLine = (Select-String -LiteralPath (Join-Path $project 'pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$').Matches
if ($versionLine.Count -ne 1) { throw 'pubspec.yaml 未提供 Windows 版本和构建号。' }
$version = $versionLine[0].Groups[1].Value
$buildNumber = $versionLine[0].Groups[2].Value
$releaseVersion = "$version+$buildNumber"

$exe = Join-Path $release 'taletin.exe'
if ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne $releaseVersion) {
    throw 'Windows 程序的版本与 pubspec.yaml 不一致，请重新构建。'
}
$header = [IO.File]::ReadAllBytes($exe)
$peOffset = [BitConverter]::ToInt32($header, 0x3c)
if ([BitConverter]::ToUInt32($header, $peOffset) -ne 0x4550 -or
    [BitConverter]::ToUInt16($header, $peOffset + 4) -ne 0x8664) {
    throw 'taletin.exe 不是 x64 Windows 程序。'
}
$dill = Join-Path $release 'data\app.so'
# 确认本次 AOT 包含便携模式，且没有编译进始终启用测试书库的旧分支。
$aotStrings = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dill))
if (!$aotStrings.Contains('TaleTin.portable') -or $aotStrings.Contains('TaleTin-test-library')) {
    throw '请使用 GT_WINDOWS_ISOLATED_TEST_LIBRARY=false 构建含便携模式的 Release。'
}
foreach ($file in @(
    'flutter_windows.dll', 'gt_reader_native.dll', 'taletin_mobi.dll',
    'pdfium.dll', 'sqlite3.dll', 'file_selector_windows_plugin.dll',
    'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin'
)) {
    $asset = Get-Item -LiteralPath (Join-Path $release $file)
    if ($asset.Length -le 0) { throw "发布文件为空：$file" }
}

if ($UnsignedPreview) {
    if ($CertificateThumbprint -or $SignToolPath -or $TimestampUrl) {
        throw '未签名预览和签名参数请分别使用。'
    }
} else {
    if (!$CertificateThumbprint -or !$SignToolPath -or !$TimestampUrl) {
        throw '公开包需要指定证书指纹、SignToolPath 和 RFC 3161 TimestampUrl。'
    }
    if ($CertificateThumbprint -notmatch '^[a-fA-F0-9]{40}$' -or
        !$TimestampUrl.IsAbsoluteUri -or $TimestampUrl.Scheme -notin @('http', 'https')) {
        throw '请提供 40 位证书指纹及 HTTP 或 HTTPS 时间戳服务地址。'
    }
    $signTool = (Resolve-Path -LiteralPath $SignToolPath).Path
    $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
    $machineStore = !$cert
    if ($machineStore) {
        $cert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
    }
    if (!$cert -or !$cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date)) {
        throw '证书库没有对应的有效证书及签名私钥。'
    }
    $signOptions = @('sign', '/fd', 'SHA256', '/sha1', $CertificateThumbprint,
        '/tr', $TimestampUrl.AbsoluteUri, '/td', 'SHA256')
    if ($machineStore) { $signOptions += '/sm' }
}

function Confirm-ReleaseSignature([string]$File) {
    $signature = Get-AuthenticodeSignature -LiteralPath $File
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Thumbprint -ne $CertificateThumbprint -or
        !$signature.TimeStamperCertificate) {
        throw "发布签名或时间戳无效：$File"
    }
}

$work = Join-Path $project ('build\windows-package-' + [guid]::NewGuid().ToString('N'))
$stage = (New-Item -ItemType Directory -Path (Join-Path $work 'runtime') -Force).FullName
$out = (New-Item -ItemType Directory -Path (Join-Path $work 'output')).FullName
Copy-Item -LiteralPath $exe -Destination $stage
Get-ChildItem -LiteralPath $release -Filter '*.dll' -File | Copy-Item -Destination $stage
Copy-Item -LiteralPath (Join-Path $release 'data') -Destination $stage -Recurse
$license = Join-Path $project 'LICENSE'
if (Test-Path -LiteralPath $license) {
    Copy-Item -LiteralPath $license -Destination (Join-Path $stage 'LICENSE.txt')
}
foreach ($file in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    $dll = Join-Path $VcRuntimeDirectory $file
    $signature = Get-AuthenticodeSignature -LiteralPath $dll
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
        throw "VC++ 运行库未通过 Microsoft 签名验证：$dll"
    }
    Copy-Item -LiteralPath $dll -Destination $stage -Force
}

$suffix = if ($UnsignedPreview) { '-unsigned' } else { '' }
$baseName = "TaleTin-$releaseVersion-windows-x64"
$setupName = "$baseName-Setup$suffix"
$portableName = "$baseName-Portable$suffix.zip"
$icon = Join-Path $project 'windows\runner\resources\app_icon.ico'
$installer = Join-Path $out "$setupName.exe"
$stagedFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force)
$preflightList = Join-Path $work 'preflight-files.nsh'
$preflightInstructions = foreach ($file in $stagedFiles) {
    $relative = $file.FullName.Substring($stage.Length + 1).Replace('$', '$$')
    '!insertmacro CheckExistingFile "{0}"' -f $relative
}
Set-Content -LiteralPath $preflightList -Value $preflightInstructions -Encoding utf8BOM
$uninstallList = Join-Path $work 'uninstall-files.nsh'
$deleteInstructions = foreach ($file in $stagedFiles) {
    $relative = $file.FullName.Substring($stage.Length + 1).Replace('$', '$$')
    'Delete "$INSTDIR\{0}"' -f $relative
}
$deleteInstructions += foreach ($folder in Get-ChildItem -LiteralPath $stage -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending) {
    $relative = $folder.FullName.Substring($stage.Length + 1).Replace('$', '$$')
    'RMDir "$INSTDIR\{0}"' -f $relative
}
Set-Content -LiteralPath $uninstallList -Value $deleteInstructions -Encoding utf8BOM
$nsisOptions = @('/INPUTCHARSET', 'UTF8', '/V3', '/WX', "/DStageDir=$stage",
    "/DAppVersion=$releaseVersion", "/DFileVersion=$version.$buildNumber", "/DAppIcon=$icon",
    "/DOutputFile=$installer", "/DUninstallFiles=$uninstallList", "/DPreflightFiles=$preflightList")
if (!$UnsignedPreview) {
    $stagedExe = Join-Path $stage 'taletin.exe'
    & $signTool @signOptions $stagedExe
    if ($LASTEXITCODE -ne 0) { throw 'taletin.exe 签名失败。' }
    Confirm-ReleaseSignature $stagedExe
    # 卸载程序在编译时签名，然后才嵌入安装包。
    $signHook = Join-Path $work 'sign-uninstaller.nsh'
    $quotedOptions = ($signOptions | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    $signInstruction = '!uninstfinalize ''"{0}" {1} "%1"'' = 0' -f $signTool, $quotedOptions
    Set-Content -LiteralPath $signHook -Value $signInstruction -Encoding utf8BOM
    $nsisOptions += "/DSignHook=$signHook"
}
& $compiler @nsisOptions (Join-Path $PSScriptRoot 'taletin.nsi')
if ($LASTEXITCODE -ne 0) { throw "安装包编译失败（$LASTEXITCODE）。" }
if (!$UnsignedPreview) {
    & $signTool @signOptions $installer
    if ($LASTEXITCODE -ne 0) { throw '安装包签名失败。' }
    Confirm-ReleaseSignature $installer
}

# 安装包已生成。仅便携包增加此标记，两包复用同一份已构建的程序。
New-Item -ItemType File -Path (Join-Path $stage 'TaleTin.portable') | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$portable = Join-Path $out $portableName
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $portable, [IO.Compression.CompressionLevel]::Optimal, $false)
$checksums = foreach ($path in @($installer, $portable)) {
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$sha  $([IO.Path]::GetFileName($path))"
}
Set-Content -LiteralPath (Join-Path $out 'SHA256SUMS.txt') -Value $checksums -Encoding ascii
$delivery = if ($DeliveryDirectory) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DeliveryDirectory) } `
    else { Join-Path $project "build\deliverables\windows-$releaseVersion$suffix" }
if (Test-Path -LiteralPath $delivery) { throw "交付目录已存在：$delivery" }
$null = New-Item -ItemType Directory -Path $delivery -Force
Copy-Item -LiteralPath $installer, $portable, (Join-Path $out 'SHA256SUMS.txt') -Destination $delivery
Write-Output $delivery
