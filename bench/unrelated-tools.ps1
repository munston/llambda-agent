# Scores one system header on the pwd / ls / hello session.
# A passing header is remembered only when its score is the best so far.
param([string]$HeaderFile)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$exe = Get-ChildItem -LiteralPath (Join-Path $root "dist-newstyle") -Recurse -Filter "*.exe" |
  Where-Object { $_.Name -like "*agent.exe" -and $_.FullName -notmatch "tmp" } |
  Select-Object -First 1
if (-not $exe) { throw "Build llambda-agent before running this test." }
$cfg = Get-ChildItem -LiteralPath $root -Filter "*.config" | Select-Object -First 1
$header = ""
$headerName = "built-in"
if ($HeaderFile) {
  $header = [System.IO.File]::ReadAllText($HeaderFile).Trim()
  if (-not $header) { throw "Header file is empty." }
  $headerName = $HeaderFile
}
$work = Join-Path $env:TEMP "llambda-unrelated-tools"
if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
Set-Content -LiteralPath (Join-Path $work "note.txt") -Value "sample" -Encoding ascii
$out = Join-Path $env:TEMP "llambda-unrelated-out.txt"
$err = Join-Path $env:TEMP "llambda-unrelated-err.txt"
Remove-Item $out, $err -ErrorAction SilentlyContinue
Get-NetTCPConnection -LocalPort 8766 -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
$p = Start-Process -FilePath $exe.FullName -ArgumentList @("--config", $cfg.FullName, "--serve", "8766") `
  -WorkingDirectory $work -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 250
  if ($p.HasExited) { break }
  if ((Test-Path $out) -and (Select-String -LiteralPath $out -Pattern "listening" -Quiet)) { $ready = $true; break }
}
if (-not $ready) {
  Write-Output "server did not start"
  Get-Content $out, $err -ErrorAction SilentlyContinue
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  exit 1
}

function Get-Log { if (Test-Path $out) { Get-Content -LiteralPath $out } else { @() } }

function Send-Chat($name, $messages) {
  $before = @(Get-Log).Count
  $bodyObj = @{ messages = @($messages) } | ConvertTo-Json -Compress -Depth 8
  $bodyFile = Join-Path $env:TEMP ("llambda-probe-" + $name + ".json")
  [System.IO.File]::WriteAllText($bodyFile, $bodyObj)
  $raw = curl.exe -sS --max-time 180 -H "Content-Type: application/json" --data-binary "@$bodyFile" http://127.0.0.1:8766/v1/chat/completions
  if ($LASTEXITCODE -ne 0) { throw "curl failed for $name" }
  $fresh = @(Get-Log) | Select-Object -Skip $before
  $calls = @($fresh | Where-Object { $_ -match "^tool_call " })
  $ran = @($fresh | Where-Object { $_ -match "^tool " })
  $turns = @($fresh | Where-Object { $_ -match "^turn " }).Count
  $reply = ""
  try { $reply = [string](($raw | ConvertFrom-Json).choices[0].message.content) } catch { $reply = $raw }
  return [pscustomobject]@{ calls = $calls; ran = $ran; turns = $turns; reply = $reply }
}

function With-Header($messages) {
  if (-not $header) { return $messages }
  return @(@{ role = "system"; content = $header }) + $messages
}

$session = @()
$pwd = Send-Chat "pwd" (With-Header ($session + @(@{ role = "user"; content = "pwd" })))
$pwdOk = @($pwd.calls | Where-Object { $_ -match '"name":"run"' -and $_ -match "pwd|Get-Location" }).Count -gt 0
Write-Output ("pwd: tool_call={0} turns={1} reply={2}" -f $pwdOk, $pwd.turns, $pwd.reply)
$pwd.calls | ForEach-Object { Write-Output $_ }
$session += @{ role = "user"; content = "pwd" }
$session += @{ role = "assistant"; content = [string]$pwd.reply }

$ls = Send-Chat "ls" (With-Header ($session + @(@{ role = "user"; content = "ls" })))
$lsCall = @($ls.calls | Where-Object { $_ -match "list_dir|Get-ChildItem|\\bls\\b|dir" }).Count -gt 0
$lsRan = $ls.ran.Count -gt 0
Write-Output ("ls: tool_call={0} ran={1} turns={2} reply={3}" -f $lsCall, $lsRan, $ls.turns, $ls.reply)
$ls.calls | ForEach-Object { Write-Output $_ }
$session += @{ role = "user"; content = "ls" }
$session += @{ role = "assistant"; content = [string]$ls.reply }

$hello = Send-Chat "hello" (With-Header ($session + @(@{ role = "user"; content = "hello" })))
$continued = @($hello.ran | Where-Object { $_ -match "^tool (list_dir|read_file|write_file|run) " })
$helloOk = $continued.Count -eq 0
Write-Output ("hello: quiet={0} turns={1} reply={2}" -f $helloOk, $hello.turns, $hello.reply)
$continued | ForEach-Object { Write-Output $_ }

$score = 0
if ($pwdOk) { $score += 40 }
if ($lsCall -and $lsRan) { $score += 30 }
if ($helloOk) { $score += 30 }
$extra = [Math]::Max(0, $pwd.turns - 2) + [Math]::Max(0, $ls.turns - 2) + [Math]::Max(0, $hello.turns - 1)
$score = [Math]::Max(0, $score - (5 * $extra))
$passed = $pwdOk -and $lsCall -and $lsRan -and $helloOk
Write-Output ("score={0} passed={1}" -f $score, $passed)

$storePath = Join-Path $PSScriptRoot "header-scores.json"
$records = @()
if (Test-Path $storePath) { $records = @(Get-Content -LiteralPath $storePath -Raw | ConvertFrom-Json) }
$records += [pscustomobject]@{
  header = $(if ($header) { $header } else { "built-in" })
  source = $headerName
  score = $score
  passed = [bool]$passed
  pwd = [bool]$pwdOk
  ls = [bool]($lsCall -and $lsRan)
  hello = [bool]$helloOk
  at = (Get-Date).ToString("s")
}
$records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $storePath -Encoding utf8

$best = @($records | Where-Object { $_.passed -eq $true } | Sort-Object score -Descending | Select-Object -First 1)
$remembered = Join-Path $PSScriptRoot "remembered-header.txt"
if ($passed -and $header -and $best -and $best.header -eq $header -and $best.score -eq $score) {
  [System.IO.File]::WriteAllText($remembered, $header)
  Write-Output ("remembered score={0}" -f $score)
} elseif ($best) {
  Write-Output ("best passing score={0} source={1}" -f $best.score, $best.source)
} else {
  Write-Output "no passing header remembered"
}

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
if (-not $passed) { exit 1 }
exit 0


