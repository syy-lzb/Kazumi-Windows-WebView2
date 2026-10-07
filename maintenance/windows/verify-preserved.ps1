$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$protected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'protected-files.json') -Raw | ConvertFrom-Json
foreach ($entry in $protected) {
    $path = Join-Path $repoRoot $entry.Path
    if (!(Test-Path -LiteralPath $path)) {
        throw "Protected source missing: $($entry.Path)"
    }
    $blob = & git -C $repoRoot hash-object -- $entry.Path
    if ($LASTEXITCODE -ne 0 -or $blob -ne $entry.GitBlob) {
        throw "Protected source changed; review before release: $($entry.Path)"
    }
}
$pins = @(
    @{ Name = 'webview_windows'; Repository = 'flutter-webview-windows'; Commit = '04786a4df07cfd7fa3496f01b14699e60055dba9' },
    @{ Name = 'ech_http'; Repository = 'ech_http'; Commit = '8a0077271605774f75f05170225ebcc82352d361' },
    @{ Name = 'media_kit'; Repository = 'media-kit'; Commit = 'f7ac8bc029c0d29dca1b170c2322ec555ac60b40' },
    @{ Name = 'media_kit_video'; Repository = 'media-kit'; Commit = 'f7ac8bc029c0d29dca1b170c2322ec555ac60b40' }
)
$configPath = Join-Path $repoRoot '.dart_tool/package_config.json'
if (!(Test-Path -LiteralPath $configPath)) { throw 'Run flutter pub get before verifying dependencies.' }
$packages = (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).packages
$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'pubspec.lock') -Raw
foreach ($pin in $pins) {
    $pattern = '(?ms)^  ' + [regex]::Escape($pin.Name) + ':\r?\n(.*?)(?=^  [a-zA-Z_][\w]*:|\z)'
    $block = [regex]::Match($lock, $pattern).Groups[1].Value
    $url = 'https://github.com/syy-lzb/' + $pin.Repository + '.git'
    $resolved = [regex]::Match($block, '(?m)^      resolved-ref: "?([0-9a-f]{40})"?\s*$').Groups[1].Value
    if (!$block.Contains($url) -or $resolved -ne $pin.Commit -or $block -notmatch 'source: git') {
        throw "Dependency lock differs from verified fork: $($pin.Name)"
    }
    $package = @($packages | Where-Object name -eq $pin.Name)
    if ($package.Count -ne 1) { throw "Dependency not resolved: $($pin.Name)" }
    $rootUri = [Uri]::new([Uri]::new($configPath), $package[0].rootUri)
    $root = $rootUri.LocalPath
    $head = & git --no-optional-locks -C $root rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -ne $pin.Commit) {
        throw "Actual dependency commit differs: $($pin.Name)"
    }
    $dirty = @(& git --no-optional-locks -C $root status --porcelain)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
        throw "Dependency checkout has local changes: $($pin.Name)"
    }
}
Write-Output "Preserved: $($protected.Count) custom source files and $($pins.Count) pinned dependency packages."
