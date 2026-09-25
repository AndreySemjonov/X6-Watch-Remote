$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT', 'User') }
    $taskSwift = (Get-Command swift.exe -ErrorAction Stop).Source
    $taskSwiftCompiler = Join-Path (Split-Path $taskSwift) 'swiftc.exe'
    & $taskSwift --version
    if ($LASTEXITCODE -ne 0) { throw 'Swift unavailable' }
    & $taskSwift test --package-path Packages/X6Core
    if ($LASTEXITCODE -ne 0) { throw 'Swift core tests failed' }
    & $taskSwift run --package-path Packages/X6Core x6-fixture-check Packages/X6Core/Tests/X6CoreTests/Fixtures/x6-v1.1.7.json
    if ($LASTEXITCODE -ne 0) { throw 'Fixture comparison failed' }
    python ../tools/check_bluetooth_transport.py
    if ($LASTEXITCODE -ne 0) { throw 'Bluetooth transport callback checks failed' }
    $taskSources = Get-ChildItem WatchApp/*.swift | ForEach-Object FullName
    & $taskSwiftCompiler -frontend -parse @taskSources
    if ($LASTEXITCODE -ne 0) { throw 'Watch Swift syntax parse failed' }
    $taskPlutil = Get-Command plutil.exe -ErrorAction SilentlyContinue
    if ($taskPlutil) {
        & $taskPlutil.Source -lint WatchApp/Info.plist X6Remote.xcodeproj/project.pbxproj
        if ($LASTEXITCODE -ne 0) { throw 'Project/plist syntax check failed' }
    }
    Write-Output 'PASS: Windows checks. Watch source was syntax-parsed ONLY; Apple SDK typechecking and device tests require Xcode.'
} finally { Pop-Location }
