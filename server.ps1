$ErrorActionPreference = "Stop"
$port = 8770
if (-not [string]::IsNullOrWhiteSpace($env:PORT)) { $port = [int]$env:PORT }
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$listener = New-Object System.Net.HttpListener
$prefix = if ([string]::IsNullOrWhiteSpace($env:PORT)) { "http://127.0.0.1:$port/" } else { "http://*:$port/" }
$listener.Prefixes.Add($prefix)
$rooms = @{}
$presence = @{}
$isHosted = -not [string]::IsNullOrWhiteSpace($env:PORT)
$adminKey = if ($isHosted) {
  if ([string]::IsNullOrWhiteSpace($env:SOOP_ADMIN_KEY)) { '' } else { $env:SOOP_ADMIN_KEY }
} else {
  if ([string]::IsNullOrWhiteSpace($env:SOOP_ADMIN_KEY)) { 'CHANGE-ME-KIMMENTAL' } else { $env:SOOP_ADMIN_KEY }
}

# Persistent profile storage.
# This survives a new trycloudflare URL and a server restart as long as this build folder remains.
# Keep profiles outside each downloaded build folder.
# This prevents profiles disappearing whenever the user tests a new build.
$dataBase = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($dataBase)) { $dataBase = Join-Path $root "data" }
$dataRoot = Join-Path $dataBase "SOOPContentMaker"
$profileRoot = Join-Path $dataRoot "profiles"
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null

$updateFile = Join-Path $dataRoot "update-config.json"
function Default-UpdateConfig {
  return [ordered]@{ latestVersion='1.0.0'; notice=''; downloadUrl=''; publishedAt=0 }
}
function Load-UpdateConfig {
  if (-not (Test-Path $updateFile -PathType Leaf)) { return (Default-UpdateConfig) }
  try { return ([IO.File]::ReadAllText($updateFile,[Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return (Default-UpdateConfig) }
}
function Save-UpdateConfig($cfg) {
  [IO.File]::WriteAllText($updateFile, ($cfg|ConvertTo-Json -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
}
function Admin-OK($key) { return (-not [string]::IsNullOrWhiteSpace($key) -and $key -eq $adminKey) }

function Normalize-Name($name) { return ((''+$name).Trim().ToLowerInvariant() -replace '\s+',' ') }
function Find-ProfileByName($name) {
  $n=Normalize-Name $name
  if ([string]::IsNullOrWhiteSpace($n)) { return $null }
  foreach($file in Get-ChildItem -Path $profileRoot -Filter '*.json' -File -ErrorAction SilentlyContinue){
    try{
      $p=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)|ConvertFrom-Json
      if((Normalize-Name $p.name) -eq $n){ return $p }
    }catch{}
  }
  return $null
}
function Streamer-Gate-OK($verified) {
  if(-not $isHosted){ return $true }
  return ((''+$verified).Trim() -eq '1')
}
function Valid-Game($game) {
  return @('bingo','kill','pinball','roulette','pick','race','ladder','tetris','none') -contains ((''+$game).Trim().ToLower())
}

function Clean-Presence {
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  foreach($k in @($presence.Keys)){ if($now-[int64]$presence[$k].lastSeen -gt 90000){ $presence.Remove($k) } }
}

function Get-ProfileFile($id) {
  $normalized = (''+$id).Trim().ToLower()
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $hash = $sha.ComputeHash($bytes)
    $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
    return (Join-Path $profileRoot ($hex + ".json"))
  } finally {
    $sha.Dispose()
  }
}

function Save-Profile($f) {
  $id = (''+$f['soopId']).Trim()
  if ([string]::IsNullOrWhiteSpace($id)) { return $null }
  $obj = [ordered]@{
    name = (''+$f['name']).Trim()
    soopId = $id
    url = (''+$f['url']).Trim()
    img = (''+$f['img'])
    savedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  }
  $json = $obj | ConvertTo-Json -Depth 5 -Compress
  [IO.File]::WriteAllText((Get-ProfileFile $id), $json, [Text.UTF8Encoding]::new($false))
  return $obj
}

function Load-Profile($id) {
  $file = Get-ProfileFile $id
  if (-not (Test-Path $file -PathType Leaf)) { return $null }
  try {
    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}



function ConvertTo-HashtableRecursive($obj) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [System.Collections.IDictionary]) { $h=@{}; foreach($k in $obj.Keys){$h[$k]=ConvertTo-HashtableRecursive $obj[$k]}; return $h }
  if ($obj -is [System.Management.Automation.PSCustomObject]) { $h=@{}; foreach($pr in $obj.PSObject.Properties){$h[$pr.Name]=ConvertTo-HashtableRecursive $pr.Value}; return $h }
  if (($obj -is [System.Collections.IEnumerable]) -and -not ($obj -is [string])) { return @($obj | ForEach-Object { ConvertTo-HashtableRecursive $_ }) }
  return $obj
}
function Get-ContentType([string]$path) {
  $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
  switch ($ext) {
    '.html' { return 'text/html; charset=utf-8' }
    '.htm'  { return 'text/html; charset=utf-8' }
    '.js'   { return 'application/javascript; charset=utf-8' }
    '.css'  { return 'text/css; charset=utf-8' }
    '.json' { return 'application/json; charset=utf-8' }
    '.svg'  { return 'image/svg+xml' }
    '.png'  { return 'image/png' }
    '.jpg'  { return 'image/jpeg' }
    '.jpeg' { return 'image/jpeg' }
    '.webp' { return 'image/webp' }
    '.gif'  { return 'image/gif' }
    '.ico'  { return 'image/x-icon' }
    default { return 'application/octet-stream' }
  }
}

function Send-StaticFile($ctx, [string]$filePath) {
  if (-not (Test-Path $filePath -PathType Leaf)) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes('404')
    $ctx.Response.StatusCode = 404
    $ctx.Response.ContentType = 'text/plain; charset=utf-8'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $ctx.Response.Close()
    return
  }
  $bytes = [System.IO.File]::ReadAllBytes($filePath)
  $ctx.Response.StatusCode = 200
  $ctx.Response.ContentType = Get-ContentType $filePath
  $ctx.Response.Headers.Add('Cache-Control','no-store, no-cache, must-revalidate, max-age=0')
  $ctx.Response.Headers.Add('Access-Control-Allow-Origin','*')
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length)
  $ctx.Response.Close()
}

function Send-Json($ctx, $obj, $status = 200) {
  $json = $obj | ConvertTo-Json -Depth 10 -Compress
  $data = [Text.Encoding]::UTF8.GetBytes($json)
  $ctx.Response.StatusCode = $status
  $ctx.Response.ContentType = 'application/json; charset=utf-8'
  $ctx.Response.Headers.Add('Cache-Control','no-store, no-cache, must-revalidate, max-age=0')
  $ctx.Response.Headers.Add('Access-Control-Allow-Origin','*')
  $ctx.Response.Headers.Add('Access-Control-Allow-Methods','GET, POST, OPTIONS')
  $ctx.Response.Headers.Add('Access-Control-Allow-Headers','Content-Type')
  $ctx.Response.ContentLength64 = $data.Length
  $ctx.Response.OutputStream.Write($data,0,$data.Length)
  $ctx.Response.Close()
}

function Read-Form($req) {
  $result = @{}
  $reader = New-Object IO.StreamReader($req.InputStream, $req.ContentEncoding)
  $body = $reader.ReadToEnd()
  $reader.Close()
  if ([string]::IsNullOrWhiteSpace($body)) { return $result }
  foreach ($pair in ($body -split '&')) {
    if ([string]::IsNullOrWhiteSpace($pair)) { continue }
    $parts = $pair -split '=',2
    $key = [Uri]::UnescapeDataString(($parts[0] -replace '\+',' '))
    $val = ''
    if ($parts.Count -gt 1) { $val = [Uri]::UnescapeDataString(($parts[1] -replace '\+',' ')) }
    $result[$key] = $val
  }
  return $result
}

function New-RoomCode {
  $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  do {
    $code = -join (1..6 | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
  } while ($rooms.ContainsKey($code))
  return $code
}

function Public-Room($room) {
  return [ordered]@{
    code = $room.code
    name = $room.name
    theme = $room.theme
    max = $room.max
    members = @($room.members)
    teamCount = $(if ($room.Contains('teamCount')) { $room.teamCount } else { 8 })
    content = $(if ($room.Contains('content')) { $room.content } else { 'none' })
    bingoMode = $(if ($room.Contains('bingoMode')) { $room.bingoMode } else { 'team' })
    bingoSize = $(if ($room.Contains('bingoSize')) { $room.bingoSize } else { 5 })
    bingoMissions = $(if ($room.Contains('bingoMissions')) { @($room.bingoMissions) } else { @() })
    bingoBoards = $(if ($room.Contains('bingoBoards')) { $room.bingoBoards } else { @{} })
    donationThreshold = $(if ($room.Contains('donationThreshold')) { $room.donationThreshold } else { 30 })
    donationRewardCells = $(if ($room.Contains('donationRewardCells')) { $room.donationRewardCells } else { 1 })
    donationRules = $(if ($room.Contains('donationRules')) { @($room.donationRules) } else { @([ordered]@{count=30;target='self';effect='complete_cells';pick='random';value=1}) })
    pendingDonation = $(if ($room.Contains('pendingDonation')) { $room.pendingDonation } else { $null })
    donationLog = $(if ($room.Contains('donationLog')) { @($room.donationLog) } else { @() })
    moduleStates = $(if ($room.Contains('moduleStates')) { $room.moduleStates } else { @{} })
  }
}

function Is-Host($room, $id) {
  $x = @($room.members | Where-Object {
    (''+$_.soopId).ToLower() -eq (''+$id).ToLower() -and $_.role -eq 'HOST'
  })
  return $x.Count -gt 0
}


function Get-BoardKeyForMember($room, $member) {
  if ($null -eq $member) { return '' }
  if ($room.bingoMode -eq 'individual') { return 'P:' + (''+$member.soopId).ToLower() }
  if ((''+$member.team) -match '^[1-8]팀$') { return 'T:' + (''+$member.team) }
  return ''
}

function Get-LineIndexes($size, $type, $index) {
  $arr = New-Object System.Collections.ArrayList
  if ($type -eq 'row') {
    for ($c=0; $c -lt $size; $c++) { [void]$arr.Add(($index*$size)+$c) }
  } elseif ($type -eq 'col') {
    for ($r=0; $r -lt $size; $r++) { [void]$arr.Add(($r*$size)+$index) }
  } elseif ($type -eq 'diag1') {
    for ($i=0; $i -lt $size; $i++) { [void]$arr.Add(($i*$size)+$i) }
  } elseif ($type -eq 'diag2') {
    for ($i=0; $i -lt $size; $i++) { [void]$arr.Add(($i*$size)+($size-1-$i)) }
  }
  return @($arr)
}

function Apply-BingoEffect($room, $boardKey, $effect, $pick, $value, $selectedIndex=-1, $lineType='', $lineIndex=-1) {
  if ([string]::IsNullOrWhiteSpace($boardKey) -or -not $room.bingoBoards.ContainsKey($boardKey)) { return 0 }

  $board = $room.bingoBoards[$boardKey]
  $size = [int]$room.bingoSize
  $effect = (''+$effect).Trim().ToLowerInvariant()
  $pick = (''+$pick).Trim().ToLowerInvariant()
  $value = [Math]::Max(1,[int]$value)
  $applied = 0

  if ($effect -in @('complete_cells','reset_cells','replace_cells')) {
    for ($k=0; $k -lt $value; $k++) {
      $pool = New-Object System.Collections.ArrayList

      for ($i=0; $i -lt $board.cells.Count; $i++) {
        if ($effect -eq 'complete_cells' -and -not [bool]$board.checked[$i]) { [void]$pool.Add($i) }
        elseif ($effect -eq 'reset_cells' -and [bool]$board.checked[$i]) { [void]$pool.Add($i) }
        elseif ($effect -eq 'replace_cells') { [void]$pool.Add($i) }
      }

      $idx = -1
      if ($selectedIndex -ge 0 -and $k -eq 0) {
        if ($pool -contains $selectedIndex) { $idx = $selectedIndex }
      } elseif ($pool.Count -gt 0) {
        $idx = [int]$pool[(Get-Random -Minimum 0 -Maximum $pool.Count)]
      }
      if ($idx -lt 0 -or $idx -ge $board.cells.Count) { break }

      if ($effect -eq 'complete_cells') {
        $c=@($board.checked)
        if (-not [bool]$c[$idx]) { $c[$idx]=$true; $applied++ }
        $board.checked=$c
      }
      elseif ($effect -eq 'reset_cells') {
        $c=@($board.checked)
        if ([bool]$c[$idx]) { $c[$idx]=$false; $applied++ }
        $board.checked=$c
      }
      elseif ($effect -eq 'replace_cells') {
        $missions=@($room.bingoMissions)
        if ($missions.Count -gt 0) {
          $old=''+$board.cells[$idx]
          $choices=@($missions | Where-Object { (''+$_) -ne $old })
          if ($choices.Count -eq 0) { $choices=$missions }
          $cells=@($board.cells)
          $cells[$idx]=$choices[(Get-Random -Minimum 0 -Maximum $choices.Count)]
          $board.cells=$cells
          $applied++
        }
      }

      if ($selectedIndex -ge 0) { break }
    }
  }
  elseif ($effect -in @('complete_line','reset_line')) {
    if ([string]::IsNullOrWhiteSpace($lineType)) {
      $eligible = New-Object System.Collections.ArrayList
      $all = New-Object System.Collections.ArrayList
      for ($i=0; $i -lt $size; $i++) {
        [void]$all.Add([ordered]@{t='row';i=$i})
        [void]$all.Add([ordered]@{t='col';i=$i})
      }
      [void]$all.Add([ordered]@{t='diag1';i=0})
      [void]$all.Add([ordered]@{t='diag2';i=0})

      foreach ($cand in @($all)) {
        $idxs=Get-LineIndexes $size $cand.t ([int]$cand.i)
        $hasApplicable=$false
        foreach ($idx in $idxs) {
          if ($effect -eq 'complete_line' -and -not [bool]$board.checked[$idx]) { $hasApplicable=$true; break }
          if ($effect -eq 'reset_line' -and [bool]$board.checked[$idx]) { $hasApplicable=$true; break }
        }
        if ($hasApplicable) { [void]$eligible.Add($cand) }
      }
      if ($eligible.Count -eq 0) { return 0 }
      $choice=$eligible[(Get-Random -Minimum 0 -Maximum $eligible.Count)]
      $lineType=''+$choice.t
      $lineIndex=[int]$choice.i
    }

    $idxs=Get-LineIndexes $size $lineType $lineIndex
    $c=@($board.checked)
    foreach ($idx in $idxs) {
      if ($effect -eq 'complete_line' -and -not [bool]$c[$idx]) { $c[$idx]=$true; $applied++ }
      elseif ($effect -eq 'reset_line' -and [bool]$c[$idx]) { $c[$idx]=$false; $applied++ }
    }
    $board.checked=$c
  }
  elseif ($effect -in @('complete_all','reset_all')) {
    $c=@($board.checked)
    for ($i=0; $i -lt $c.Count; $i++) {
      if ($effect -eq 'complete_all' -and -not [bool]$c[$i]) { $c[$i]=$true; $applied++ }
      elseif ($effect -eq 'reset_all' -and [bool]$c[$i]) { $c[$i]=$false; $applied++ }
    }
    $board.checked=$c
  }
  elseif ($effect -eq 'reshuffle') {
    $need=$size*$size
    $missions=@($room.bingoMissions)
    if ($missions.Count -gt 0) {
      $shuffled=@($missions | Sort-Object {Get-Random})
      $cells=New-Object System.Collections.ArrayList
      while ($cells.Count -lt $need) {
        foreach ($m in $shuffled) {
          if ($cells.Count -ge $need) { break }
          [void]$cells.Add($m)
        }
      }
      $board.cells=@($cells)
      $board.checked=@($false)*$need
      $applied=$need
    }
  }

  return $applied
}

function Add-DonationLog($room,$f,$member,$boardKey,$effect,$applied) {
  if (-not $room.Contains('donationLog')) { $room.donationLog=@() }
  $entry=[ordered]@{
    time=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    action=(''+$f['action']); donor=(''+$f['donor'])
    actorId=(''+$member.soopId); actorName=$member.name
    count=[int]$f['count']; boardKey=$boardKey
    applied=$applied; ruleAction=$effect
  }
  $log=@($room.donationLog)+@($entry)
  if ($log.Count -gt 30) { $log=@($log | Select-Object -Last 30) }
  $room.donationLog=$log
}

try { $listener.Start() } catch {
  Write-Host "Port $port is already in use. Close the old Content Maker server first." -ForegroundColor Red
  Read-Host "Press Enter"
  exit 1
}

Clear-Host
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " SOOP CONTENT MAKER - RELEASE CANDIDATE V15" -ForegroundColor Cyan
Write-Host " PERSISTENT PROFILE / TEAM / RECONNECT" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Backend listening on port $port" -ForegroundColor Green
Write-Host ""
Write-Host "Render backend is running." -ForegroundColor Yellow

$mime=@{'.html'='text/html; charset=utf-8';'.js'='application/javascript; charset=utf-8';'.css'='text/css; charset=utf-8';'.png'='image/png';'.jpg'='image/jpeg';'.jpeg'='image/jpeg';'.webp'='image/webp';'.svg'='image/svg+xml';'.txt'='text/plain; charset=utf-8'}

while($listener.IsListening){
  try {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath

    if ($req.HttpMethod -eq 'OPTIONS') {
      $ctx.Response.StatusCode = 204
      $ctx.Response.Headers.Add('Access-Control-Allow-Origin','*')
      $ctx.Response.Headers.Add('Access-Control-Allow-Methods','GET, POST, OPTIONS')
      $ctx.Response.Headers.Add('Access-Control-Allow-Headers','Content-Type')
      $ctx.Response.Close()
      continue
    }


    if ($req.HttpMethod -eq 'GET' -and -not $path.StartsWith('/api/')) {
      $rel = $path.TrimStart('/')
      if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
      if ($rel -match '\.\.') {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('400')
        $ctx.Response.StatusCode = 400
        $ctx.Response.ContentType = 'text/plain; charset=utf-8'
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length)
        $ctx.Response.Close()
        continue
      }
      $candidate = Join-Path $root $rel
      if (Test-Path $candidate -PathType Leaf) {
        Send-StaticFile $ctx $candidate
        continue
      }
    }

    if ($path -eq '/api/health') {
      Send-Json $ctx ([ordered]@{ok=$true; message='V15 RC / ISOLATED API / ADMIN / STREAMER GATE ready'})
      continue
    }


    if ($path -eq '/api/update/get' -and $req.HttpMethod -eq 'GET') {
      Send-Json $ctx ([ordered]@{ok=$true;update=(Load-UpdateConfig)})
      continue
    }

    if ($path -eq '/api/presence/heartbeat' -and $req.HttpMethod -eq 'POST') {
      $f=Read-Form $req
      $id=(''+$f['id']).Trim().ToLower()
      if(-not [string]::IsNullOrWhiteSpace($id)){
        $presence[$id]=[ordered]@{
          id=$f['id']; name=$f['name']; img=$f['img']; room=$f['room']; content=$f['content']; activeGame=$f['activeGame']; version=$f['version'];
          apiConnected=((''+$f['apiConnected']).Trim() -eq '1'); streamerVerified=((''+$f['streamerVerified']).Trim() -eq '1'); lastApiEvent=$f['lastApiEvent'];
          lastSeen=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }
      }
      Send-Json $ctx ([ordered]@{ok=$true;update=(Load-UpdateConfig)})
      continue
    }

    if ($path -eq '/api/admin/status' -and $req.HttpMethod -eq 'GET') {
      $key=(''+$req.QueryString['key']).Trim()
      if($isHosted -and [string]::IsNullOrWhiteSpace($adminKey)){ Send-Json $ctx ([ordered]@{ok=$false;message='서버에 SOOP_ADMIN_KEY 환경변수가 설정되지 않았습니다.'}) 503; continue }; if(-not (Admin-OK $key)){ Send-Json $ctx ([ordered]@{ok=$false;message='관리자 키가 맞지 않습니다.'}) 403; continue }
      Clean-Presence
      $active=@($presence.Values | Sort-Object lastSeen -Descending)
      $roomRows=@()
      foreach($r in $rooms.Values){ $roomRows += [ordered]@{code=$r.code;name=$r.name;content=$r.content;members=$r.members.Count;createdAt=$r.createdAt} }
      Send-Json $ctx ([ordered]@{ok=$true;now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();online=$active.Count;users=$active;rooms=$roomRows;update=(Load-UpdateConfig)})
      continue
    }

    if ($path -eq '/api/admin/update' -and $req.HttpMethod -eq 'POST') {
      $f=Read-Form $req
      if($isHosted -and [string]::IsNullOrWhiteSpace($adminKey)){ Send-Json $ctx ([ordered]@{ok=$false;message='서버에 SOOP_ADMIN_KEY 환경변수가 설정되지 않았습니다.'}) 503; continue }; if(-not (Admin-OK ((''+$f['key']).Trim()))){ Send-Json $ctx ([ordered]@{ok=$false;message='관리자 키가 맞지 않습니다.'}) 403; continue }
      $cfg=[ordered]@{latestVersion=((''+$f['latestVersion']).Trim());notice=((''+$f['notice']).Trim());downloadUrl=((''+$f['downloadUrl']).Trim());publishedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}
      if([string]::IsNullOrWhiteSpace($cfg.latestVersion)){ $cfg.latestVersion='1.0.0' }
      Save-UpdateConfig $cfg
      Send-Json $ctx ([ordered]@{ok=$true;update=$cfg})
      continue
    }

    if ($path -eq '/api/profile/save' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      if ([string]::IsNullOrWhiteSpace($f['name']) -or [string]::IsNullOrWhiteSpace($f['soopId'])) {
        Send-Json $ctx ([ordered]@{ok=$false;message='스트리머 이름과 SOOP ID가 필요합니다.'}) 400
        continue
      }
      $existingByName = Find-ProfileByName $f['name']
      if($null -ne $existingByName -and ((''+$existingByName.soopId).Trim().ToLower()) -ne ((''+$f['soopId']).Trim().ToLower())) {
        Send-Json $ctx ([ordered]@{ok=$false;message='이미 다른 스트리머가 사용 중인 닉네임입니다. 다른 닉네임을 사용해 주세요.'}) 409
        continue
      }
      $saved = Save-Profile $f
      Send-Json $ctx ([ordered]@{ok=$true;profile=$saved})
      continue
    }

    if ($path -eq '/api/profile/get' -and $req.HttpMethod -eq 'GET') {
      $id = (''+$req.QueryString['id']).Trim()
      if ([string]::IsNullOrWhiteSpace($id)) {
        Send-Json $ctx ([ordered]@{ok=$false;message='SOOP ID가 필요합니다.'}) 400
        continue
      }
      $saved = Load-Profile $id
      if ($null -eq $saved) {
        Send-Json $ctx ([ordered]@{ok=$true;found=$false})
      } else {
        Send-Json $ctx ([ordered]@{ok=$true;found=$true;profile=$saved})
      }
      continue
    }

    if ($path -eq '/api/room/create' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      if ([string]::IsNullOrWhiteSpace($f['nameHost']) -or [string]::IsNullOrWhiteSpace($f['idHost'])) {
        Send-Json $ctx ([ordered]@{ok=$false; message='프로필 이름/SOOP ID가 필요합니다.'}) 400
        continue
      }
      if(-not (Streamer-Gate-OK $f['verified'])) { Send-Json $ctx ([ordered]@{ok=$false;message='SOOP 스트리머 인증이 필요합니다. SOOP 확장 프로그램에서 본인 방송으로 실행해 주세요.'}) 403; continue }
      $max = 8
      [int]::TryParse($f['max'], [ref]$max) | Out-Null
      if ($max -lt 2) { $max = 2 }
      if ($max -gt 100) { $max = 100 }
      $code = New-RoomCode
      $members = New-Object System.Collections.ArrayList
      [void]$members.Add([ordered]@{
        name=$f['nameHost'];soopId=$f['idHost'];img=$f['imgHost'];
        role='HOST';team='1팀';activeGame='none';apiConnected=$false;lastApiEvent=0;joinedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      })
      $room = [ordered]@{
        code=$code;name=$f['name'];theme=$f['theme'];max=$max;
        password=$f['password'];members=$members;
        teamCount=8;content='none';bingoMode='team';bingoSize=5;bingoMissions=@();bingoBoards=@{};donationThreshold=30;donationRewardCells=1;donationRules=@([ordered]@{count=30;target='self';effect='complete_cells';pick='random';value=1});pendingDonation=$null;donationLog=@();moduleStates=@{};
        createdAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      }
      $rooms[$code] = $room
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/join' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not [string]::IsNullOrEmpty($room.password) -and $room.password -ne $f['password']) {
        Send-Json $ctx ([ordered]@{ok=$false;message='비밀번호가 맞지 않습니다.'}) 403; continue
      }
      $id = (''+$f['id']).Trim()
      if ([string]::IsNullOrWhiteSpace($id)) { Send-Json $ctx ([ordered]@{ok=$false;message='SOOP ID가 필요합니다.'}) 400; continue }
      if(-not (Streamer-Gate-OK $f['verified'])) { Send-Json $ctx ([ordered]@{ok=$false;message='SOOP 스트리머 인증이 필요합니다. SOOP 확장 프로그램에서 본인 방송으로 실행해 주세요.'}) 403; continue }
      $joinName=(''+$f['name']).Trim()
      $dupName=@($room.members | Where-Object { (Normalize-Name $_.name) -eq (Normalize-Name $joinName) -and (''+$_.soopId).ToLower() -ne $id.ToLower() }) | Select-Object -First 1
      if($null -ne $dupName){ Send-Json $ctx ([ordered]@{ok=$false;message='이 방에서 이미 사용 중인 닉네임입니다.'}) 409; continue }

      # Reconnect: same SOOP ID returns to the same slot and keeps team/role.
      $existing = @($room.members | Where-Object { (''+$_.soopId).ToLower() -eq $id.ToLower() }) | Select-Object -First 1
      if ($null -ne $existing) {
        if (-not [string]::IsNullOrWhiteSpace($f['name'])) { $existing.name = $f['name'] }
        if (-not [string]::IsNullOrWhiteSpace($f['img'])) { $existing.img = $f['img'] }
        if(-not $existing.Contains('activeGame')){$existing.activeGame='none'}
        if(-not $existing.Contains('apiConnected')){$existing.apiConnected=$false}
        if(-not $existing.Contains('lastApiEvent')){$existing.lastApiEvent=0}
        Send-Json $ctx ([ordered]@{ok=$true;reconnected=$true;room=(Public-Room $room)})
        continue
      }

      if ($room.members.Count -ge $room.max) {
        Send-Json $ctx ([ordered]@{ok=$false;message='방 최대 인원에 도달했습니다.'}) 409
        continue
      }
      [void]$room.members.Add([ordered]@{
        name=$f['name'];soopId=$id;img=$f['img'];
        role='PLAYER';team='미배정';activeGame='none';apiConnected=$false;lastApiEvent=0;joinedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      })
      Send-Json $ctx ([ordered]@{ok=$true;reconnected=$false;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/get' -and $req.HttpMethod -eq 'GET') {
      $code = (''+$req.QueryString['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $rooms[$code])})
      continue
    }

    if ($path -eq '/api/room/settings' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 변경할 수 있습니다.'}) 403; continue }

      $newMax = $room.max
      [int]::TryParse($f['max'], [ref]$newMax) | Out-Null
      if ($newMax -lt $room.members.Count) { $newMax = $room.members.Count }
      if ($newMax -lt 2) { $newMax = 2 }
      if ($newMax -gt 100) { $newMax = 100 }
      $newName = (''+$f['name']).Trim()
      if (-not [string]::IsNullOrWhiteSpace($newName)) { $room.name = $newName }
      $room.max = $newMax
      $teamCount = 2
      if ($room.Contains('teamCount')) { $teamCount = [int]$room.teamCount } else { $teamCount = 8 }
      if (-not [string]::IsNullOrWhiteSpace($f['teamCount'])) { [int]::TryParse($f['teamCount'], [ref]$teamCount) | Out-Null }
      if ($teamCount -lt 2) { $teamCount = 2 }
      if ($teamCount -gt 8) { $teamCount = 8 }
      $room.teamCount = $teamCount
      foreach ($member in $room.members) {
        if ($member.role -eq 'HOST') { continue }
        $mt = (''+$member.team).Trim()
        if ($mt -match '^(\d+)팀$') {
          $n = [int]$Matches[1]
          if ($n -gt $teamCount) { $member.team = '미배정' }
        }
      }
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }


    if ($path -eq '/api/room/member/activity' -and $req.HttpMethod -eq 'POST') {
      $f=Read-Form $req
      $code=(''+$f['code']).Trim().ToUpper();$actor=(''+$f['actorId']).Trim()
      if(-not $rooms.ContainsKey($code)){Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404;continue}
      $room=$rooms[$code]
      $m=@($room.members|Where-Object{(''+$_.soopId).ToLower() -eq $actor.ToLower()})|Select-Object -First 1
      if($null -eq $m){Send-Json $ctx ([ordered]@{ok=$false;message='방 참가자를 찾을 수 없습니다.'}) 404;continue}
      $game=((''+$f['activeGame']).Trim().ToLower());if(-not (Valid-Game $game)){$game='none'}
      $m.activeGame=$game
      $m.apiConnected=((''+$f['apiConnected']).Trim() -eq '1')
      [int64]$evt=0;[int64]::TryParse((''+$f['lastApiEvent']),[ref]$evt)|Out-Null
      if($evt -gt 0){$m.lastApiEvent=$evt}
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/content' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 콘텐츠를 선택할 수 있습니다.'}) 403; continue }
      $content = (''+$f['content']).Trim().ToLower()
      if (@('bingo','kill','pinball','roulette','pick','race','ladder','tetris') -notcontains $content) { $content = 'none' }
      $room.content = $content
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/bingo/generate' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 빙고판을 생성할 수 있습니다.'}) 403; continue }

      $raw = (''+$f['missions']).Replace("`r","")
      $missions = New-Object System.Collections.ArrayList
      foreach ($line in $raw.Split("`n")) {
        $x = (''+$line).Trim()
        if (-not [string]::IsNullOrWhiteSpace($x)) { [void]$missions.Add($x) }
      }
      $size = [int]$room.bingoSize
      $need = $size * $size
      if ($missions.Count -lt $need) {
        Send-Json $ctx ([ordered]@{ok=$false;message=("미션이 최소 " + $need + "개 필요합니다.")}) 400
        continue
      }
      $room.bingoMissions = @($missions)
      $boards = @{}

      if ($room.bingoMode -eq 'individual') {
        foreach ($member in $room.members) {
          if ($member.role -eq 'VIEWER') { continue }
          $key = 'P:' + (''+$member.soopId).ToLower()
          $picked = @($missions | Sort-Object {Get-Random} | Select-Object -First $need)
          $boards[$key] = [ordered]@{ label=$member.name; ownerId=$member.soopId; team=''; cells=@($picked); checked=@($false)*$need }
        }
      } else {
        $teams = @($room.members | Where-Object { $_.role -ne 'VIEWER' -and $_.team -match '^[1-8]팀$' } | ForEach-Object { $_.team } | Select-Object -Unique)
        if ($teams.Count -eq 0) {
          Send-Json $ctx ([ordered]@{ok=$false;message='팀 빙고는 최소 한 명이 1팀~8팀에 배정되어 있어야 합니다. 방장도 팀을 선택할 수 있습니다.'}) 400
          continue
        }
        foreach ($team in $teams) {
          $key = 'T:' + $team
          $picked = @($missions | Sort-Object {Get-Random} | Select-Object -First $need)
          $boards[$key] = [ordered]@{ label=$team; ownerId=''; team=$team; cells=@($picked); checked=@($false)*$need }
        }
      }
      $room.bingoBoards = $boards
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/bingo/reshuffle' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 다시 섞을 수 있습니다.'}) 403; continue }
      if ($room.bingoMissions.Count -lt 1 -or $room.bingoBoards.Count -lt 1) {
        Send-Json $ctx ([ordered]@{ok=$false;message='먼저 빙고판을 생성해 주세요.'}) 400
        continue
      }
      $size = [int]$room.bingoSize
      $need = $size * $size
      foreach ($key in @($room.bingoBoards.Keys)) {
        $board = $room.bingoBoards[$key]
        $picked = @($room.bingoMissions | Sort-Object {Get-Random} | Select-Object -First $need)
        $board.cells = @($picked)
        $board.checked = @($false) * $need
      }
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/bingo/toggle' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      $id = (''+$f['id']).Trim()
      $boardKey = (''+$f['boardKey']).Trim()
      $idx = -1
      [int]::TryParse($f['index'], [ref]$idx) | Out-Null
      if (-not $room.bingoBoards.ContainsKey($boardKey)) { Send-Json $ctx ([ordered]@{ok=$false;message='빙고판을 찾을 수 없습니다.'}) 404; continue }
      $board = $room.bingoBoards[$boardKey]
      if ($idx -lt 0 -or $idx -ge $board.checked.Count) { Send-Json $ctx ([ordered]@{ok=$false;message='빙고 칸 번호가 잘못되었습니다.'}) 400; continue }

      $member = @($room.members | Where-Object { (''+$_.soopId).ToLower() -eq $id.ToLower() }) | Select-Object -First 1
      if ($null -eq $member -or $member.role -eq 'VIEWER') { Send-Json $ctx ([ordered]@{ok=$false;message='이 빙고판을 조작할 권한이 없습니다.'}) 403; continue }
      $allowed = $false
      if ($member.role -eq 'HOST') { $allowed = $true }
      elseif ($room.bingoMode -eq 'individual' -and $boardKey -eq ('P:'+$id.ToLower())) { $allowed = $true }
      elseif ($room.bingoMode -eq 'team' -and $boardKey -eq ('T:'+(''+$member.team))) { $allowed = $true }
      if (-not $allowed) { Send-Json $ctx ([ordered]@{ok=$false;message='자기 개인/팀 빙고판만 체크할 수 있습니다.'}) 403; continue }

      $newChecked = @($board.checked)
      $newChecked[$idx] = -not [bool]$newChecked[$idx]
      $board.checked = $newChecked
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/bingo/reset' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 초기화할 수 있습니다.'}) 403; continue }
      foreach ($key in @($room.bingoBoards.Keys)) {
        $board = $room.bingoBoards[$key]
        $board.checked = @($false) * $board.cells.Count
      }
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/donation/settings' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 후원 규칙을 변경할 수 있습니다.'}) 403; continue }

      $threshold = 30
      [int]::TryParse($f['threshold'], [ref]$threshold) | Out-Null
      if ($threshold -lt 1) { $threshold = 1 }
      if ($threshold -gt 1000000) { $threshold = 1000000 }

      $reward = 1
      [int]::TryParse($f['rewardCells'], [ref]$reward) | Out-Null
      if ($reward -lt 1) { $reward = 1 }
      if ($reward -gt 25) { $reward = 25 }

      $room.donationThreshold = $threshold
      $room.donationRewardCells = $reward
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/donation/rules' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 후원 규칙을 변경할 수 있습니다.'}) 403; continue }

      $rules=New-Object System.Collections.ArrayList
      try {
        $parsed=ConvertFrom-Json (''+$f['rules'])
        foreach ($r in @($parsed)) {
          $count=0; [int]::TryParse((''+$r.count),[ref]$count)|Out-Null
          if ($count -lt 1) { continue }
          $value=1; [int]::TryParse((''+$r.value),[ref]$value)|Out-Null
          if ($value -lt 1) { $value=1 }; if ($value -gt 100) { $value=100 }
          $target=(''+$r.target)
          if (@('self','random_player','selected_player','random_enemy_team','selected_team','all') -notcontains $target) { $target='self' }
          $effect=(''+$r.effect).Trim().ToLowerInvariant()
          if (@('complete_cells','reset_cells','replace_cells','complete_line','reset_line','complete_all','reset_all','reshuffle') -notcontains $effect) { $effect='complete_cells' }
          $pick=(''+$r.pick).Trim().ToLowerInvariant()
          if (@('random','select') -notcontains $pick) { $pick='random' }
          [void]$rules.Add([ordered]@{count=$count;target=$target;effect=$effect;pick=$pick;value=$value})
        }
      } catch {}
      if ($rules.Count -eq 0) { [void]$rules.Add([ordered]@{count=30;target='self';effect='complete_cells';pick='random';value=1}) }
      $room.donationRules=@($rules|Sort-Object count)
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/donation/apply' -and $req.HttpMethod -eq 'POST') {
      $f=Read-Form $req
      $code=(''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room=$rooms[$code]
      $actorId=(''+$f['actorId']).Trim()
      $member=@($room.members|Where-Object{(''+$_.soopId).ToLower()-eq $actorId.ToLower()})|Select-Object -First 1
      if ($null -eq $member) { Send-Json $ctx ([ordered]@{ok=$false;message='방 참가자만 후원 이벤트를 적용할 수 있습니다.'}) 403; continue }
      $count=0; [int]::TryParse($f['count'],[ref]$count)|Out-Null

      $matched=$null
      foreach ($r in @($room.donationRules|Sort-Object count)) { if ($count -ge [int]$r.count) { $matched=$r } }
      if ($null -eq $matched) {
        Add-DonationLog $room $f $member '' 'none' 0
        Send-Json $ctx ([ordered]@{ok=$true;applied=0;pending=$false;room=(Public-Room $room)})
        continue
      }

      $target=(''+$matched.target).Trim().ToLowerInvariant()
      $effect=(''+$matched.effect).Trim().ToLowerInvariant()
      $pick=(''+$matched.pick).Trim().ToLowerInvariant()
      $value=[int]$matched.value
      $boardKeys=New-Object System.Collections.ArrayList
      $needTarget=$false; $targetKind=''

      if ($target -eq 'self') {
        $k=Get-BoardKeyForMember $room $member
        if (-not [string]::IsNullOrWhiteSpace($k)) { [void]$boardKeys.Add($k) }
      } elseif ($target -eq 'all') {
        foreach ($k in @($room.bingoBoards.Keys)) { [void]$boardKeys.Add((''+$k)) }
      } elseif ($target -eq 'random_player') {
        $candidates=@($room.members|Where-Object{$_.role-ne'VIEWER' -and (''+$_.soopId).ToLower()-ne $actorId.ToLower()})
        if ($candidates.Count -gt 0) {
          $chosen=$candidates[(Get-Random -Minimum 0 -Maximum $candidates.Count)]
          $k=Get-BoardKeyForMember $room $chosen
          if (-not [string]::IsNullOrWhiteSpace($k)) { [void]$boardKeys.Add($k) }
        }
      } elseif ($target -eq 'random_enemy_team') {
        $teams=@($room.members|Where-Object{$_.role-ne'VIEWER' -and $_.team-match'^[1-8]팀$' -and $_.team-ne $member.team}|ForEach-Object{$_.team}|Select-Object -Unique)
        if ($teams.Count -gt 0) { [void]$boardKeys.Add(('T:'+$teams[(Get-Random -Minimum 0 -Maximum $teams.Count)])) }
      } elseif ($target -eq 'selected_player') {
        $needTarget=$true; $targetKind='player'
      } elseif ($target -eq 'selected_team') {
        $needTarget=$true; $targetKind='team'
      }

      if ($needTarget) {
        $room.pendingDonation=[ordered]@{
          actorId=$actorId; donor=(''+$f['donor']); count=$count
          target=$target; targetKind=$targetKind; effect=$effect; pick=$pick; value=$value
          stage='target'; boardKey=''; remaining=$value
        }
        Send-Json $ctx ([ordered]@{ok=$true;applied=0;pending=$true;room=(Public-Room $room)})
        continue
      }

      if ($boardKeys.Count -eq 0) {
        Add-DonationLog $room $f $member '' $effect 0
        Send-Json $ctx ([ordered]@{ok=$true;applied=0;pending=$false;room=(Public-Room $room)})
        continue
      }

      if ($pick -eq 'select' -and @('complete_cells','reset_cells','replace_cells','complete_line','reset_line') -contains $effect -and $boardKeys.Count -eq 1) {
        $stage=$(if (@('complete_line','reset_line') -contains $effect) {'line'} else {'cell'})
        $room.pendingDonation=[ordered]@{
          actorId=$actorId; donor=(''+$f['donor']); count=$count
          target=$target; targetKind=''; effect=$effect; pick=$pick; value=$value
          stage=$stage; boardKey=(''+$boardKeys[0]); remaining=$value
        }
        Send-Json $ctx ([ordered]@{ok=$true;applied=0;pending=$true;room=(Public-Room $room)})
        continue
      }

      $applied=0
      foreach ($k in @($boardKeys)) { $applied += Apply-BingoEffect $room $k $effect $pick $value }
      Add-DonationLog $room $f $member ($boardKeys -join ',') $effect $applied
      Send-Json $ctx ([ordered]@{
        ok=$true; applied=$applied; pending=$false
        matchedRule=[ordered]@{count=[int]$matched.count;target=$target;effect=$effect;pick=$pick;value=$value}
        room=(Public-Room $room)
      })
      continue
    }

    if ($path -eq '/api/room/donation/select-target' -and $req.HttpMethod -eq 'POST') {
      $f=Read-Form $req; $code=(''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room=$rooms[$code]; $p=$room.pendingDonation
      if ($null -eq $p -or (''+$p.actorId).ToLower() -ne (''+$f['actorId']).ToLower()) { Send-Json $ctx ([ordered]@{ok=$false;message='선택 대기 중인 효과가 없습니다.'}) 400; continue }

      $boardKey=''
      if ($p.targetKind -eq 'team') {
        $team=(''+$f['team']).Trim()
        if ($team -notmatch '^[1-8]팀$') { Send-Json $ctx ([ordered]@{ok=$false;message='팀을 선택해 주세요.'}) 400; continue }
        $boardKey='T:'+$team
      } else {
        $targetId=(''+$f['targetId']).Trim()
        $targetMember=@($room.members|Where-Object{(''+$_.soopId).ToLower()-eq $targetId.ToLower()})|Select-Object -First 1
        $boardKey=Get-BoardKeyForMember $room $targetMember
      }
      if ([string]::IsNullOrWhiteSpace($boardKey) -or -not $room.bingoBoards.ContainsKey($boardKey)) { Send-Json $ctx ([ordered]@{ok=$false;message='대상 빙고판을 찾을 수 없습니다.'}) 400; continue }

      $p.boardKey=$boardKey
      if ($p.pick -eq 'select' -and @('complete_cells','reset_cells','replace_cells') -contains $p.effect) {
        $p.stage='cell'; $room.pendingDonation=$p
        Send-Json $ctx ([ordered]@{ok=$true;pending=$true;room=(Public-Room $room)}); continue
      }
      if ($p.pick -eq 'select' -and @('complete_line','reset_line') -contains $p.effect) {
        $p.stage='line'; $room.pendingDonation=$p
        Send-Json $ctx ([ordered]@{ok=$true;pending=$true;room=(Public-Room $room)}); continue
      }

      $applied=Apply-BingoEffect $room $boardKey $p.effect $p.pick ([int]$p.value)
      $fake=@{action='PENDING';donor=$p.donor;count=$p.count}
      $actor=@($room.members|Where-Object{(''+$_.soopId).ToLower()-eq (''+$p.actorId).ToLower()})|Select-Object -First 1
      Add-DonationLog $room $fake $actor $boardKey $p.effect $applied
      $room.pendingDonation=$null
      Send-Json $ctx ([ordered]@{ok=$true;pending=$false;applied=$applied;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/donation/select-cell' -and $req.HttpMethod -eq 'POST') {
      $f=Read-Form $req; $code=(''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room=$rooms[$code]; $p=$room.pendingDonation
      if ($null -eq $p -or $p.stage -ne 'cell' -or (''+$p.actorId).ToLower() -ne (''+$f['actorId']).ToLower()) { Send-Json $ctx ([ordered]@{ok=$false;message='칸 선택 대기 상태가 아닙니다.'}) 400; continue }
      $idx=-1; [int]::TryParse($f['index'],[ref]$idx)|Out-Null
      $applied=Apply-BingoEffect $room $p.boardKey $p.effect 'select' 1 $idx
      $p.remaining=[Math]::Max(0,[int]$p.remaining-1)
      if ($p.remaining -le 0) {
        $fake=@{action='PENDING';donor=$p.donor;count=$p.count}
        $actor=@($room.members|Where-Object{(''+$_.soopId).ToLower()-eq (''+$p.actorId).ToLower()})|Select-Object -First 1
        Add-DonationLog $room $fake $actor $p.boardKey $p.effect $applied
        $room.pendingDonation=$null
      } else { $room.pendingDonation=$p }
      Send-Json $ctx ([ordered]@{ok=$true;pending=($null-ne$room.pendingDonation);applied=$applied;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/donation/select-line' -and $req.HttpMethod -eq 'POST') {
      $f=Read-Form $req; $code=(''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room=$rooms[$code]; $p=$room.pendingDonation
      if ($null -eq $p -or $p.stage -ne 'line' -or (''+$p.actorId).ToLower() -ne (''+$f['actorId']).ToLower()) { Send-Json $ctx ([ordered]@{ok=$false;message='줄 선택 대기 상태가 아닙니다.'}) 400; continue }
      $lineType=(''+$f['lineType']); $lineIndex=0; [int]::TryParse($f['lineIndex'],[ref]$lineIndex)|Out-Null
      $applied=Apply-BingoEffect $room $p.boardKey $p.effect 'select' 1 -1 $lineType $lineIndex
      $fake=@{action='PENDING';donor=$p.donor;count=$p.count}
      $actor=@($room.members|Where-Object{(''+$_.soopId).ToLower()-eq (''+$p.actorId).ToLower()})|Select-Object -First 1
      Add-DonationLog $room $fake $actor $p.boardKey $p.effect $applied
      $room.pendingDonation=$null
      Send-Json $ctx ([ordered]@{ok=$true;pending=$false;applied=$applied;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/donation/cancel-pending' -and $req.HttpMethod -eq 'POST') {
      $f=Read-Form $req; $code=(''+$f['code']).Trim().ToUpper()
      if ($rooms.ContainsKey($code)) { $room=$rooms[$code]; if ($null-ne$room.pendingDonation -and ((''+$room.pendingDonation.actorId).ToLower()-eq (''+$f['actorId']).ToLower() -or (Is-Host $room $f['actorId']))) { $room.pendingDonation=$null } }
      Send-Json $ctx ([ordered]@{ok=$true;room=$(if($rooms.ContainsKey($code)){Public-Room $rooms[$code]}else{$null})})
      continue
    }

    if ($path -eq '/api/room/bingo/settings' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 빙고 설정을 변경할 수 있습니다.'}) 403; continue }
      $mode = (''+$f['mode']).Trim().ToLower()
      if ($mode -ne 'individual') { $mode = 'team' }
      $size = 5
      [int]::TryParse($f['size'], [ref]$size) | Out-Null
      if ($size -lt 3) { $size = 3 }
      if ($size -gt 10) { $size = 10 }
      $room.bingoMode = $mode
      $room.bingoSize = $size
      $room.bingoBoards = @{}
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/module/save' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code=(''+$f['code']).Trim().ToUpper(); $actor=(''+$f['actorId']).Trim(); $module=(''+$f['module']).Trim().ToLower()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room=$rooms[$code]
      $member=@($room.members | Where-Object { (''+$_.soopId).ToLower() -eq $actor.ToLower() })
      if ($member.Count -eq 0) { Send-Json $ctx ([ordered]@{ok=$false;message='방 참가자만 변경할 수 있습니다.'}) 403; continue }
      if (@('pubgbingo','kill','pinball','roulette','pick','race','ladder','tetris') -notcontains $module) { Send-Json $ctx ([ordered]@{ok=$false;message='지원하지 않는 콘텐츠입니다.'}) 400; continue }
      try { $state = ConvertTo-HashtableRecursive (ConvertFrom-Json -InputObject (''+$f['state'])) } catch { Send-Json $ctx ([ordered]@{ok=$false;message='콘텐츠 상태 형식이 올바르지 않습니다.'}) 400; continue }
      if (-not $room.Contains('moduleStates')) { $room.moduleStates=@{} }
      $room.moduleStates[$module]=$state
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/live/state' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code=(''+$f['code']).Trim().ToUpper(); $actor=(''+$f['actorId']).Trim(); $module=(''+$f['module']).Trim().ToLower()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room=$rooms[$code]
      $member=@($room.members | Where-Object { (''+$_.soopId).ToLower() -eq $actor.ToLower() }) | Select-Object -First 1
      if ($null -eq $member -or $member.role -eq 'VIEWER') { Send-Json $ctx ([ordered]@{ok=$false;message='참가자만 진행 상태를 보낼 수 있습니다.'}) 403; continue }
      if (@('bingo','kill') -notcontains $module) { Send-Json $ctx ([ordered]@{ok=$false;message='지원하지 않는 순위 모듈입니다.'}) 400; continue }
      try { $state = ConvertTo-HashtableRecursive (ConvertFrom-Json -InputObject (''+$f['state'])) } catch { Send-Json $ctx ([ordered]@{ok=$false;message='진행 상태 형식이 올바르지 않습니다.'}) 400; continue }
      if (-not $room.Contains('moduleStates')) { $room.moduleStates=@{} }
      if (-not $room.moduleStates.ContainsKey('live')) { $room.moduleStates['live']=@{} }
      $live=$room.moduleStates['live']
      if (-not $live.ContainsKey($module)) { $live[$module]=@{players=@{}} }
      if (-not $live[$module].ContainsKey('players')) { $live[$module]['players']=@{} }
      $state['name']=''+$member.name; $state['team']=''+$member.team; $state['updatedAt']=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $live[$module].players[$actor.ToLower()]=$state
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/tetris/state' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code=(''+$f['code']).Trim().ToUpper(); $actor=(''+$f['actorId']).Trim()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room=$rooms[$code]
      $member=@($room.members | Where-Object { (''+$_.soopId).ToLower() -eq $actor.ToLower() }) | Select-Object -First 1
      if ($null -eq $member -or $member.role -eq 'VIEWER') { Send-Json $ctx ([ordered]@{ok=$false;message='테트리스 참가자만 상태를 보낼 수 있습니다.'}) 403; continue }
      try { $state = ConvertTo-HashtableRecursive (ConvertFrom-Json -InputObject (''+$f['state'])) } catch { Send-Json $ctx ([ordered]@{ok=$false;message='테트리스 상태 형식이 올바르지 않습니다.'}) 400; continue }
      if (-not $room.Contains('moduleStates')) { $room.moduleStates=@{} }
      if (-not $room.moduleStates.ContainsKey('tetris')) { $room.moduleStates['tetris']=@{players=@{}} }
      $tt=$room.moduleStates['tetris']
      if (-not $tt.ContainsKey('players')) { $tt['players']=@{} }
      $tt.players[$actor.ToLower()]=$state
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/member/update' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 변경할 수 있습니다.'}) 403; continue }
      $targetId = (''+$f['targetId']).Trim()
      $m = @($room.members | Where-Object { (''+$_.soopId).ToLower() -eq $targetId.ToLower() }) | Select-Object -First 1
      if ($null -eq $m) { Send-Json $ctx ([ordered]@{ok=$false;message='참가자를 찾을 수 없습니다.'}) 404; continue }
      $team = (''+$f['team']).Trim()
      if ([string]::IsNullOrWhiteSpace($team)) { $team = '미배정' }
      if ($team -ne '미배정' -and $team -notmatch '^[1-8]팀$') { $team = '미배정' }

      $m.team = $team
      if ($m.role -ne 'HOST') {
        $role = (''+$f['role']).Trim().ToUpper()
        if ($role -ne 'VIEWER') { $role = 'PLAYER' }
        $m.role = $role
      }
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/member/kick' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$false;message='방을 찾을 수 없습니다.'}) 404; continue }
      $room = $rooms[$code]
      if (-not (Is-Host $room $f['hostId'])) { Send-Json $ctx ([ordered]@{ok=$false;message='방장만 내보낼 수 있습니다.'}) 403; continue }
      $targetId = (''+$f['targetId']).Trim()
      for ($i=$room.members.Count-1; $i -ge 0; $i--) {
        if ((''+$room.members[$i].soopId).ToLower() -eq $targetId.ToLower()) {
          if ($room.members[$i].role -eq 'HOST') { continue }
          $room.members.RemoveAt($i)
        }
      }
      Send-Json $ctx ([ordered]@{ok=$true;room=(Public-Room $room)})
      continue
    }

    if ($path -eq '/api/room/leave' -and $req.HttpMethod -eq 'POST') {
      $f = Read-Form $req
      $code = (''+$f['code']).Trim().ToUpper()
      $id = (''+$f['id']).Trim()
      if (-not $rooms.ContainsKey($code)) { Send-Json $ctx ([ordered]@{ok=$true;closed=$true}); continue }
      $room = $rooms[$code]
      $leaving = @($room.members | Where-Object { (''+$_.soopId).ToLower() -eq $id.ToLower() }) | Select-Object -First 1
      if ($null -ne $leaving -and $leaving.role -eq 'HOST') {
        $rooms.Remove($code)
        Send-Json $ctx ([ordered]@{ok=$true;closed=$true})
        continue
      }
      for ($i=$room.members.Count-1; $i -ge 0; $i--) {
        if ((''+$room.members[$i].soopId).ToLower() -eq $id.ToLower()) { $room.members.RemoveAt($i) }
      }
      Send-Json $ctx ([ordered]@{ok=$true;closed=$false;room=(Public-Room $room)})
      continue
    }

    $filePath = $path.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($filePath)) { $filePath='index.html' }
    $filePath=[Uri]::UnescapeDataString($filePath)
    $full=[IO.Path]::GetFullPath((Join-Path $root $filePath))
    if(-not $full.StartsWith([IO.Path]::GetFullPath($root)) -or -not (Test-Path $full -PathType Leaf)){
      $ctx.Response.StatusCode=404
      $data=[Text.Encoding]::UTF8.GetBytes('404')
      $ctx.Response.OutputStream.Write($data,0,$data.Length)
      $ctx.Response.Close()
      continue
    }
    $ext=[IO.Path]::GetExtension($full).ToLower()
    $ctx.Response.ContentType=if($mime.ContainsKey($ext)){$mime[$ext]}else{'application/octet-stream'}
    $ctx.Response.Headers.Add('Cache-Control','no-store, no-cache, must-revalidate, max-age=0')
    $ctx.Response.Headers.Add('Pragma','no-cache')
    $bytes=[IO.File]::ReadAllBytes($full)
    $ctx.Response.ContentLength64=$bytes.Length
    $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $ctx.Response.Close()
  } catch {
    try { if ($null -ne $ctx -and $ctx.Response.OutputStream) { $ctx.Response.Close() } } catch {}
  }
}
