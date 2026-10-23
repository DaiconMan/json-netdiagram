<#
render.ps1 — JSON → 図のPNG（検証つき）  Windows PowerShell 5.1 / PowerShell 7 (Windows)

使い方:
  .\render.ps1 -FromClipboard        # 生成AIの回答をコピーして実行（JSON部分だけ抜き出して diagram.json に保存→描画）
  .\render.ps1 diagram.json          # ファイルから
  .\render.ps1 diagram.json -Out flow.png -Font "Yu Gothic UI"

終了コード: 0=OK(diagram.png) / 1=検証NG(diagram_debug.png に赤枠) / 2=JSON構文・スキーマ不正
-FromClipboard でNGのときは、生成AIにそのまま貼れる修正依頼文をクリップボードに入れます。

配置: layer（段）と col（列）の格子。canvas.direction が TB なら段は上→下、LR なら左→右。
線:   route "straight"（直線、既定）/ "bus"（くし形・カギ形。親→幹線→子）/ "loop"（差し戻し。外側を回る）
枠:   groups（メンバーを囲む枠）/ lanes（スイムレーン。全体を貫く帯）
検証: JSON構文 / 必須キー / type / id重複 / 参照切れ / ノード重なり / 線のノード貫通 / 線ラベルの重なり /
      線ラベルのグループ枠線かぶり / グループ名にかかる線 / グループ・レーンへの非メンバー混入 /
      グループ枠同士・レーン同士の重なり / レーン未所属 / 図の大きさ上限 / フォント未収録文字（豆腐）
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Spec = "diagram.json",
    [string]$Out = "diagram.png",
    [string]$Font = "",
    [switch]$FromClipboard
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Has($o, $name) { ($null -ne $o) -and ($o.PSObject.Properties.Name -contains $name) }
function Get-Prop($o, $name, $default) { if (Has $o $name) { $o.$name } else { $default } }
function Resolve-Abs($p) { if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location).Path $p } }

$specPath = Resolve-Abs $Spec
$outPath = Resolve-Abs $Out
$debugPath = [IO.Path]::ChangeExtension($outPath, $null).TrimEnd('.') + "_debug.png"

function Exit-Schema($msg) {
    Write-Host "NG: $msg" -ForegroundColor Red
    if ($FromClipboard) {
        Set-Clipboard -Value "render.ps1 で読み込めませんでした。以下を直した diagram.json を全体で出し直してください（JSONのみ、コメント・末尾カンマなし）:`n- $msg"
        Write-Host "（修正依頼文をクリップボードにコピーしました）"
    }
    exit 2
}

# ---------------------------------------------------------------- 種類（type → 塗り, 線, 形）
$types = [ordered]@{
    # ネットワーク
    firewall = @('#FDE2D6', '#C0392B', 'round'); router = @('#D6E8FA', '#2E6DB4', 'round'); switch = @('#D6E8FA', '#2E6DB4', 'round')
    ap = @('#E0F4FA', '#1B87B5', 'round'); server = @('#DDF3DF', '#2E8B57', 'round'); vm = @('#EEF8EE', '#2E8B57', 'dashed')
    cloud = @('#EEEEEE', '#7F8C8D', 'ellipse'); user = @('#FFF4CC', '#B7950B', 'round'); storage = @('#EDE7F6', '#5E35B1', 'cylinder')
    # ソフトウェア
    client = @('#FFF4CC', '#B7950B', 'round'); service = @('#DDF3DF', '#2E8B57', 'round'); database = @('#EDE7F6', '#5E35B1', 'cylinder')
    queue = @('#FCE4EC', '#AD1457', 'subprocess'); external = @('#F4F4F4', '#666666', 'dashed')
    # 組織
    person = @('#FFFFFF', '#2E6DB4', 'round'); dept = @('#D6E8FA', '#2E6DB4', 'rect')
    # フロー・手順
    start = @('#DDF3DF', '#2E8B57', 'stadium'); end = @('#FDE2D6', '#C0392B', 'stadium'); process = @('#FFFFFF', '#333333', 'rect')
    decision = @('#FFF4CC', '#B7950B', 'diamond'); data = @('#E0F4FA', '#1B87B5', 'parallelogram'); document = @('#FFFFFF', '#555555', 'document')
    subprocess = @('#FFFFFF', '#333333', 'subprocess'); step = @('#D6E8FA', '#2E6DB4', 'round')
    # 資料
    box = @('#FFFFFF', '#333333', 'round'); emphasis = @('#FDE2D6', '#C0392B', 'round'); note = @('#FFF9C4', '#C9A400', 'note')
}
$typeList = ($types.Keys -join ' / ')

# ---------------------------------------------------------------- 入力
if ($FromClipboard) {
    $raw = Get-Clipboard -Raw
    if (-not $raw) { Write-Host "NG: クリップボードが空です"; exit 2 }
    $i = $raw.IndexOf('{'); $j = $raw.LastIndexOf('}')
    if ($i -lt 0 -or $j -le $i) { Write-Host "NG: クリップボードにJSONが見つかりません"; exit 2 }
    [IO.File]::WriteAllText($specPath, $raw.Substring($i, $j - $i + 1), (New-Object Text.UTF8Encoding($false)))
    Write-Host "クリップボードのJSONを保存: $specPath"
}
if (-not (Test-Path $specPath)) { Write-Host "NG: $specPath がありません"; exit 2 }
try {
    $doc = [IO.File]::ReadAllText($specPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
} catch {
    Exit-Schema "JSON構文エラー: $($_.Exception.Message)"
}
function Test-Index($v) { try { $d = [double]$v; return ($d -ge 0 -and $d -eq [math]::Floor($d)) } catch { return $false } }
$specNodes = @(Get-Prop $doc 'nodes' @())
if ($specNodes.Count -eq 0) { Exit-Schema '"nodes" が空か配列ではありません' }
$k = 0
foreach ($n in $specNodes) {
    if (-not (Has $n 'id') -or -not (Has $n 'label')) { Exit-Schema "nodes[$k] に `"id`" と `"label`" が必要です" }
    if (-not (Has $n 'layer') -or -not (Has $n 'col')) { Exit-Schema "ノード $($n.id): `"layer`" と `"col`" が必要です" }
    if (-not (Test-Index $n.layer) -or -not (Test-Index $n.col)) { Exit-Schema "ノード $($n.id): `"layer`" と `"col`" は 0 以上の整数です" }
    $k++
}
$specEdges = @(Get-Prop $doc 'edges' @())
$k = 0
foreach ($e in $specEdges) { if (-not (Has $e 'from') -or -not (Has $e 'to')) { Exit-Schema "edges[$k] に `"from`" と `"to`" が必要です" }; $k++ }
$specGroups = @(Get-Prop $doc 'groups' @())
$k = 0
foreach ($g in $specGroups) { if (-not (Has $g 'id') -or -not (Has $g 'nodes')) { Exit-Schema "groups[$k] に `"id`" と `"nodes`" が必要です" }; $k++ }
$specLanes = @(Get-Prop $doc 'lanes' @())
$k = 0
foreach ($l in $specLanes) { if (-not (Has $l 'id') -or -not (Has $l 'label') -or -not (Has $l 'nodes')) { Exit-Schema "lanes[$k] に `"id`" と `"label`" と `"nodes`" が必要です" }; $k++ }

# ---------------------------------------------------------------- 設定・フォント
$canvas = Get-Prop $doc 'canvas' $null
$dirName = ([string](Get-Prop $canvas 'direction' 'TB')).ToUpper()
if ($dirName -ne 'TB' -and $dirName -ne 'LR') { Exit-Schema 'canvas.direction は "TB"（上→下）か "LR"（左→右）です' }
$dirLR = $dirName -eq 'LR'
$fs = [int](Get-Prop $canvas 'font_size' 14)
$rowGap = [int](Get-Prop $canvas 'row_gap' 150)
$layerGap = [int](Get-Prop $canvas 'layer_gap' 80)
$colGap = [int](Get-Prop $canvas 'col_gap' 48)
$maxW = [int](Get-Prop $canvas 'max_width' 2400)
$maxH = [int](Get-Prop $canvas 'max_height' 2400)
$uniform = [bool](Get-Prop $canvas 'uniform_width' $false)
$margin = 40; $padX = 16; $padY = 10; $minGap = 8

$installed = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
$fontName = $null
foreach ($c in @($Font, [string](Get-Prop $canvas 'font' ''), 'Meiryo UI', 'Meiryo', 'Yu Gothic UI', 'BIZ UDPGothic', 'MS UI Gothic', 'MS Gothic')) {
    if ($c -and ($installed -contains $c)) { $fontName = $c; break }
}
if (-not $fontName) { $fontName = 'Microsoft Sans Serif'; Write-Host "WARN: 日本語フォントが見つかりません" -ForegroundColor Yellow }
Write-Host "font=$fontName"
$nodeFont = New-Object System.Drawing.Font($fontName, [single]$fs, [System.Drawing.GraphicsUnit]::Pixel)
$titleFont = New-Object System.Drawing.Font($fontName, [single]($fs * 1.3), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$laneFont = New-Object System.Drawing.Font($fontName, [single]$fs, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

$errors = New-Object System.Collections.Generic.List[object]
function Add-Err($msg, $keys) { $script:errors.Add([pscustomobject]@{ Msg = $msg; Keys = @($keys) }) }
function Get-Label($o) { ([string](Get-Prop $o 'label' '')).Replace('\n', "`n") }

# 豆腐チェック（WPFのグリフ表で判定）
function Get-MissingGlyphs($name, $text) {
    try { Add-Type -AssemblyName PresentationCore } catch { return $null }
    $gt = $null
    $tf = New-Object System.Windows.Media.Typeface($name)
    if (-not $tf.TryGetGlyphTypeface([ref]$gt)) { return $null }
    $map = $gt.CharacterToGlyphMap
    $miss = New-Object 'System.Collections.Generic.SortedSet[string]'
    $i = 0
    while ($i -lt $text.Length) {
        $len = if ([char]::IsHighSurrogate($text[$i]) -and $i + 1 -lt $text.Length) { 2 } else { 1 }
        if (-not [char]::IsWhiteSpace($text[$i])) {
            try { $cp = [char]::ConvertToUtf32($text, $i); if (-not $map.ContainsKey($cp)) { [void]$miss.Add($text.Substring($i, $len)) } } catch {}
        }
        $i += $len
    }
    return , @($miss)
}
$allText = (($specNodes | ForEach-Object { [string]$_.label }) -join '') +
           (($specEdges | ForEach-Object { [string](Get-Prop $_ 'label' '') }) -join '') +
           (($specGroups | ForEach-Object { [string](Get-Prop $_ 'label' '') }) -join '') +
           (($specLanes | ForEach-Object { [string](Get-Prop $_ 'label' '') }) -join '') +
           [string](Get-Prop $canvas 'title' '')
$miss = Get-MissingGlyphs $fontName $allText
if ($null -eq $miss) { Write-Host "WARN: 豆腐チェックをスキップ（グリフ表を取得できず）" -ForegroundColor Yellow }
elseif ($miss.Count -gt 0) { Add-Err ("フォント未収録の文字（豆腐になる）: " + ($miss -join ' ')) $null }

# 計測
$bmp0 = New-Object System.Drawing.Bitmap(10, 10)
$g0 = [System.Drawing.Graphics]::FromImage($bmp0)
$g0.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$sfMeasure = [System.Drawing.StringFormat]::GenericTypographic.Clone()
$sfMeasure.FormatFlags = $sfMeasure.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces
$sfCenter = $sfMeasure.Clone()
$sfCenter.Alignment = [System.Drawing.StringAlignment]::Center
$sfCenter.LineAlignment = [System.Drawing.StringAlignment]::Center
function Measure-Text($text, $f) {
    $s = $script:g0.MeasureString([string]$text, $f, 100000, $script:sfMeasure)
    return , @([math]::Ceiling($s.Width), [math]::Ceiling($s.Height))
}
function Test-Overlap($a, $b, $m) { -not ($a[2] + $m -le $b[0] -or $b[2] + $m -le $a[0] -or $a[3] + $m -le $b[1] -or $b[3] + $m -le $a[1]) }
function Test-Contains($o, $i) { $o[0] -le $i[0] -and $o[1] -le $i[1] -and $o[2] -ge $i[2] -and $o[3] -ge $i[3] }
function Get-ShapeSize($shape, $tw, $th) {
    $w = $tw + 2 * $script:padX; $h = $th + 2 * $script:padY
    switch ($shape) {
        'diamond'       { $w = $w * 1.5 + 10; $h = $h * 1.7 }
        'ellipse'       { $w = $w * 1.3; $h = $h * 1.35 }
        'stadium'       { $w = $w + $h * 0.6 }
        'cylinder'      { $h = $h + 14 }
        'parallelogram' { $w = $w + 28 }
        'document'      { $h = $h + 10 }
        'note'          { $w = $w + 12 }
        'subprocess'    { $w = $w + 20 }
    }
    return , @([math]::Max(60, [math]::Ceiling($w)), [math]::Ceiling($h))
}
function Test-Hex($s) { $s -match '^#[0-9A-Fa-f]{6}$' }

# ---------------------------------------------------------------- ノード
$nodes = @{}
$order = New-Object System.Collections.Generic.List[string]
foreach ($n in $specNodes) {
    $nid = [string]$n.id
    if ($nodes.ContainsKey($nid)) { Add-Err "id 重複: ${nid}" $null; continue }
    $type = [string](Get-Prop $n 'type' 'box')
    if (-not $types.Contains($type)) { Add-Err "ノード ${nid}: type `"$type`" は使えない（使える type: $typeList）" $null; $type = 'box' }
    $st = $types[$type]
    $fill = $st[0]
    $fc = [string](Get-Prop $n 'color' '')
    if ($fc) { if (Test-Hex $fc) { $fill = $fc } else { Add-Err "ノード ${nid}: color は #RRGGBB 形式" $null } }
    $label = Get-Label $n
    $sz = Measure-Text $label $nodeFont
    $wh = Get-ShapeSize $st[2] $sz[0] $sz[1]
    $nodes[$nid] = @{ id = $nid; label = $label; type = $type; shape = $st[2]; fill = $fill; stroke = $st[1]; w = [double]$wh[0]; h = [double]$wh[1]; layer = [int]$n.layer; col = [int]$n.col }
    $order.Add($nid)
}
if ($uniform) {
    $uw = 0.0
    foreach ($nid in $order) { $nd = $nodes[$nid]; if ($nd.shape -ne 'diamond' -and $nd.shape -ne 'note' -and $nd.w -gt $uw) { $uw = $nd.w } }
    foreach ($nid in $order) { $nd = $nodes[$nid]; if ($nd.shape -ne 'diamond' -and $nd.shape -ne 'note') { $nd.w = $uw } }
}

# ---------------------------------------------------------------- 配置（段=primary軸, 列=secondary軸）
function XY($p, $s) { if ($script:dirLR) { return , @($p, $s) } else { return , @($s, $p) } }
function NP0($nd) { if ($script:dirLR) { $nd.rect[0] } else { $nd.rect[1] } }   # 段方向の始点
function NP1($nd) { if ($script:dirLR) { $nd.rect[2] } else { $nd.rect[3] } }   # 段方向の終点
function NS($nd) { if ($script:dirLR) { $nd.cy } else { $nd.cx } }               # 列方向の中心
$colSize = @{}; $layerSize = @{}; $maxCol = 0; $maxLayer = 0
foreach ($nid in $order) {
    $nd = $nodes[$nid]
    $s = if ($dirLR) { $nd.h } else { $nd.w }
    $p = if ($dirLR) { $nd.w } else { $nd.h }
    if (-not $colSize.ContainsKey($nd.col) -or $colSize[$nd.col] -lt $s) { $colSize[$nd.col] = $s }
    if (-not $layerSize.ContainsKey($nd.layer) -or $layerSize[$nd.layer] -lt $p) { $layerSize[$nd.layer] = $p }
    if ($nd.col -gt $maxCol) { $maxCol = $nd.col }; if ($nd.layer -gt $maxLayer) { $maxLayer = $nd.layer }
}
$sCenter = @{}; $acc = 0.0
for ($c = 0; $c -le $maxCol; $c++) {
    $size = if ($colSize.ContainsKey($c)) { $colSize[$c] } else { 0 }
    $sCenter[$c] = $acc + $size / 2; $acc += $size + $colGap
}
$pStart = @{}; $pEnd = @{}; $acc = 0.0
for ($L = 0; $L -le $maxLayer; $L++) {
    $size = if ($layerSize.ContainsKey($L)) { $layerSize[$L] } else { 0 }
    if ($dirLR) { $pStart[$L] = $acc; $acc += $size + $layerGap } else { $pStart[$L] = $L * $rowGap }
    $pEnd[$L] = $pStart[$L] + $size
}
foreach ($nid in $order) {
    $nd = $nodes[$nid]
    $pc = $pStart[$nd.layer] + $layerSize[$nd.layer] / 2
    $xy = XY $pc $sCenter[$nd.col]
    $nd.cx = $xy[0]; $nd.cy = $xy[1]
    $nd.rect = @(($nd.cx - $nd.w / 2), ($nd.cy - $nd.h / 2), ($nd.cx + $nd.w / 2), ($nd.cy + $nd.h / 2))
}

# ---------------------------------------------------------------- 線の経路
function Get-Clip($nd, $tx, $ty) {
    $dx = $tx - $nd.cx; $dy = $ty - $nd.cy; $hw = $nd.w / 2; $hh = $nd.h / 2
    if ($dx -eq 0 -and $dy -eq 0) { return , @($nd.cx, $nd.cy) }
    switch ($nd.shape) {
        'diamond' { $t = 1 / ([math]::Abs($dx) / $hw + [math]::Abs($dy) / $hh) }
        'ellipse' { $t = 1 / [math]::Sqrt([math]::Pow($dx / $hw, 2) + [math]::Pow($dy / $hh, 2)) }
        default {
            $kx = if ($dx -ne 0) { $hw / [math]::Abs($dx) } else { [double]::PositiveInfinity }
            $ky = if ($dy -ne 0) { $hh / [math]::Abs($dy) } else { [double]::PositiveInfinity }
            $t = [math]::Min($kx, $ky)
        }
    }
    return , @(($nd.cx + $dx * $t), ($nd.cy + $dy * $t))
}
function Test-PathHit($pts, $r) {
    for ($sg = 0; $sg -lt $pts.Count - 1; $sg++) {
        $s0 = $pts[$sg]; $s1 = $pts[$sg + 1]
        for ($s = 0; $s -le 40; $s++) {
            $px = $s0[0] + ($s1[0] - $s0[0]) * $s / 40; $py = $s0[1] + ($s1[1] - $s0[1]) * $s / 40
            if ($px -ge $r[0] -and $px -le $r[2] -and $py -ge $r[1] -and $py -le $r[3]) { return $true }
        }
    }
    return $false
}
function Test-PathClear($pts, $a, $b) {
    foreach ($o in $script:order) { if ($o -ne $a -and $o -ne $b -and (Test-PathHit $pts $script:nodes[$o].rect)) { return $false } }
    return $true
}
$loopCount = 0
# 戻り値: 折れ点の配列。不正なら文字列（エラー内容）
function Get-EdgePath($e) {
    $a = [string]$e.from; $b = [string]$e.to
    $na = $script:nodes[$a]; $nb = $script:nodes[$b]
    $route = [string](Get-Prop $e 'route' 'straight')
    if ($route -eq 'straight') {
        return , (@(, (Get-Clip $na $nb.cx $nb.cy)) + @(, (Get-Clip $nb $na.cx $na.cy)))
    }
    if ($route -eq 'bus') {
        if ($nb.layer -le $na.layer) { return "線 ${a}→${b}: route `"bus`" は to の layer が from より大きいときだけ使える（同じ段の隣へは `"straight`"、前の段へ戻る線は `"loop`"）" }
        $prev = $null
        foreach ($L in $script:layerSize.Keys) { if ($L -lt $nb.layer -and ($null -eq $prev -or $L -gt $prev)) { $prev = $L } }
        $busP = if ($null -ne $prev -and $prev -ge $na.layer) { ($script:pEnd[$prev] + (NP0 $nb)) / 2 } else { ((NP1 $na) + (NP0 $nb)) / 2 }
        if ($null -ne $prev -and $prev -ge $na.layer) { $busP = ($script:pEnd[$prev] + $script:pStart[$nb.layer]) / 2 }
        return , (@(, (XY (NP1 $na) (NS $na))) + @(, (XY $busP (NS $na))) + @(, (XY $busP (NS $nb))) + @(, (XY (NP0 $nb) (NS $nb))))
    }
    if ($route -eq 'loop') {
        # 段の範囲にあるノードの外側（列方向の両端）を回る。貫通しない側を選ぶ
        $lo = [math]::Min($na.layer, $nb.layer); $hi = [math]::Max($na.layer, $nb.layer)
        $sMin = [double]::MaxValue; $sMax = [double]::MinValue
        foreach ($o in $script:order) {
            $nd = $script:nodes[$o]
            if ($nd.layer -lt $lo -or $nd.layer -gt $hi) { continue }
            $s0 = if ($script:dirLR) { $nd.rect[1] } else { $nd.rect[0] }
            $s1 = if ($script:dirLR) { $nd.rect[3] } else { $nd.rect[2] }
            $sMin = [math]::Min($sMin, $s0); $sMax = [math]::Max($sMax, $s1)
        }
        $off = 24 + 14 * $script:loopCount; $script:loopCount++
        $pa = ((NP0 $na) + (NP1 $na)) / 2; $pb = ((NP0 $nb) + (NP1 $nb)) / 2
        $ha = if ($script:dirLR) { $na.h / 2 } else { $na.w / 2 }
        $hb = if ($script:dirLR) { $nb.h / 2 } else { $nb.w / 2 }
        foreach ($side in 1, -1) {
            $sL = if ($side -gt 0) { $sMax + $off } else { $sMin - $off }
            $ea = (NS $na) + $side * $ha
            $eb = (NS $nb) + $side * $hb
            $pts = @(, (XY $pa $ea)) + @(, (XY $pa $sL)) + @(, (XY $pb $sL)) + @(, (XY $pb $eb))
            if (Test-PathClear $pts $a $b) { return , $pts }
        }
        return , $pts
    }
    return "線 ${a}→${b}: route は straight / bus / loop のどれか"
}

$edgeList = New-Object System.Collections.Generic.List[object]
$ei = 0
foreach ($e in $specEdges) {
    $a = [string]$e.from; $b = [string]$e.to
    $key = "edge:${a}->${b}#${ei}"; $ei++
    if (-not $nodes.ContainsKey($a) -or -not $nodes.ContainsKey($b)) { Add-Err "線 ${a}→${b} の参照先が存在しない" $null; continue }
    if ($a -eq $b) { Add-Err "線 ${a}→${b} が自己参照" "node:$a"; continue }
    if (Test-Overlap $nodes[$a].rect $nodes[$b].rect 0) { continue }
    $pts = Get-EdgePath $e
    if ($pts -is [string]) { Add-Err $pts "node:$b"; continue }
    $style = [string](Get-Prop $e 'style' 'solid')
    if ($style -notin 'solid', 'dashed', 'dotted') { Add-Err "線 ${a}→${b}: style は solid / dashed / dotted のどれか" $null; $style = 'solid' }
    $col = [string](Get-Prop $e 'color' '')
    if ($col -and -not (Test-Hex $col)) { Add-Err "線 ${a}→${b}: color は #RRGGBB 形式" $null; $col = '' }
    $pos = 0.5
    try { $pos = [double](Get-Prop $e 'label_pos' 0.5) } catch {}
    $edgeList.Add(@{ key = $key; a = $a; b = $b; pts = $pts; route = [string](Get-Prop $e 'route' 'straight'); style = $style; color = $col
            arrow = [bool](Get-Prop $e 'arrow' $false); label = (Get-Label $e); pos = [math]::Min(0.9, [math]::Max(0.1, $pos)); posSet = (Has $e 'label_pos') })
}

# ---------------------------------------------------------------- グループ枠
function Get-Members($o) { @($o.nodes | ForEach-Object { [string]$_ }) }
$groupSide = @{}
function Get-GroupFrame($g) {
    $members = @(Get-Members $g | Where-Object { $script:nodes.ContainsKey($_) })
    if ($members.Count -eq 0) { return $null }
    $pad = [double](Get-Prop $g 'padding' 20)
    $x0 = [double]::MaxValue; $y0 = [double]::MaxValue; $x1 = [double]::MinValue; $y1 = [double]::MinValue
    foreach ($m in $members) {
        $r = $script:nodes[$m].rect
        $x0 = [math]::Min($x0, $r[0]); $y0 = [math]::Min($y0, $r[1]); $x1 = [math]::Max($x1, $r[2]); $y1 = [math]::Max($y1, $r[3])
    }
    $x0 -= $pad; $y0 -= $pad; $x1 += $pad; $y1 += $pad
    $lab = Get-Label $g
    if ($lab) {
        $th = (Measure-Text $lab $script:nodeFont)[1] + 6
        if ($script:groupSide[[string]$g.id] -eq 'bottom') { $y1 += $th } else { $y0 -= $th }
    }
    return , @($x0, $y0, $x1, $y1)
}
function Get-GroupLabelRect($fr, $side, $tw, $th) {
    if ($side -eq 'bottom') { return , @(($fr[0] + 8), ($fr[3] - 3 - $th), ($fr[0] + 8 + $tw), ($fr[3] - 3)) }
    return , @(($fr[0] + 8), ($fr[1] + 3), ($fr[0] + 8 + $tw), ($fr[1] + 3 + $th))
}
# グループ名は枠の上辺に置く。線が横切る場合は下辺に置く
foreach ($g in $specGroups) {
    $gid = [string]$g.id; $groupSide[$gid] = 'top'
    $lab = Get-Label $g
    if (-not $lab) { continue }
    $fr = Get-GroupFrame $g
    if ($null -eq $fr) { continue }
    $tsz = Measure-Text $lab $nodeFont
    $lr = Get-GroupLabelRect $fr 'top' $tsz[0] $tsz[1]
    if (@($edgeList | Where-Object { Test-PathHit $_.pts $lr }).Count -gt 0) { $groupSide[$gid] = 'bottom' }
}
$groupFrames = @{}
foreach ($g in $specGroups) { $fr = Get-GroupFrame $g; if ($null -ne $fr) { $groupFrames[[string]$g.id] = $fr } }

# ---------------------------------------------------------------- レーン（全体を貫く帯。見出しは段方向の先頭）
$laneFrames = @{}; $laneHeads = @{}
if ($specLanes.Count -gt 0) {
    $hdr = 0.0
    foreach ($l in $specLanes) {
        $ls = Measure-Text (Get-Label $l) $laneFont
        $need = if ($dirLR) { $ls[0] + 24 } else { $ls[1] + 14 }
        if ($need -gt $hdr) { $hdr = $need }
    }
    $pMin = [double]::MaxValue; $pMax = [double]::MinValue
    foreach ($nid in $order) { $pMin = [math]::Min($pMin, (NP0 $nodes[$nid])); $pMax = [math]::Max($pMax, (NP1 $nodes[$nid])) }
    foreach ($ed in $edgeList) { foreach ($pt in $ed.pts) { $pp = if ($dirLR) { $pt[0] } else { $pt[1] }; $pMin = [math]::Min($pMin, $pp); $pMax = [math]::Max($pMax, $pp) } }
    $pA = $pMin - 16 - $hdr; $pB = $pMax + 16
    foreach ($l in $specLanes) {
        $members = @(Get-Members $l | Where-Object { $nodes.ContainsKey($_) })
        if ($members.Count -eq 0) { continue }
        $s0 = [double]::MaxValue; $s1 = [double]::MinValue
        foreach ($m in $members) {
            $r = $nodes[$m].rect
            $a0 = if ($dirLR) { $r[1] } else { $r[0] }; $a1 = if ($dirLR) { $r[3] } else { $r[2] }
            $s0 = [math]::Min($s0, $a0); $s1 = [math]::Max($s1, $a1)
        }
        $half = [math]::Max(12, $colGap / 2)
        $s0 -= $half; $s1 += $half
        $p0 = XY $pA $s0; $p1 = XY $pB $s1; $h1 = XY ($pA + $hdr) $s1
        $laneFrames[[string]$l.id] = @($p0[0], $p0[1], $p1[0], $p1[1])
        $laneHeads[[string]$l.id] = @($p0[0], $p0[1], $h1[0], $h1[1])
    }
}

# ---------------------------------------------------------------- キャンバス（全体を平行移動して余白をそろえる）
$title = [string](Get-Prop $canvas 'title' '')
$top = $margin
$ts = $null
if ($title) { $ts = Measure-Text $title $titleFont; $top += $ts[1] + 16 }
$bx0 = [double]::MaxValue; $by0 = [double]::MaxValue; $bx1 = [double]::MinValue; $by1 = [double]::MinValue
$boxes = New-Object System.Collections.Generic.List[object]
foreach ($nid in $order) { $boxes.Add($nodes[$nid].rect) }
foreach ($v in $groupFrames.Values) { $boxes.Add($v) }
foreach ($v in $laneFrames.Values) { $boxes.Add($v) }
foreach ($ed in $edgeList) { foreach ($pt in $ed.pts) { $boxes.Add(@($pt[0], $pt[1], $pt[0], $pt[1])) } }
foreach ($r in $boxes) { $bx0 = [math]::Min($bx0, $r[0]); $by0 = [math]::Min($by0, $r[1]); $bx1 = [math]::Max($bx1, $r[2]); $by1 = [math]::Max($by1, $r[3]) }
$dx = $margin - $bx0; $dy = $top - $by0
$W = [int][math]::Ceiling($bx1 + $dx + $margin)
if ($title) { $W = [math]::Max($W, [int]($ts[0] + 2 * $margin)) ; $dx += ($W - [math]::Ceiling($bx1 + $dx + $margin)) / 2 }
$H = [int][math]::Ceiling($by1 + $dy + $margin)
function Move-Rect($r) { return , @(($r[0] + $script:dx), ($r[1] + $script:dy), ($r[2] + $script:dx), ($r[3] + $script:dy)) }
$rects = @{}
foreach ($nid in $order) {
    $nd = $nodes[$nid]; $nd.cx += $dx; $nd.cy += $dy; $nd.rect = Move-Rect $nd.rect; $rects["node:$nid"] = $nd.rect
}
foreach ($ed in $edgeList) { $ed.pts = @($ed.pts | ForEach-Object { , @(($_[0] + $dx), ($_[1] + $dy)) }) }
foreach ($k2 in @($groupFrames.Keys)) { $groupFrames[$k2] = Move-Rect $groupFrames[$k2]; $rects["group:$k2"] = $groupFrames[$k2] }
foreach ($k2 in @($laneFrames.Keys)) { $laneFrames[$k2] = Move-Rect $laneFrames[$k2]; $laneHeads[$k2] = Move-Rect $laneHeads[$k2]; $rects["lane:$k2"] = $laneFrames[$k2] }

# ---------------------------------------------------------------- 検証
if ($W -gt $maxW) { Add-Err "図の横幅が ${W}px で上限 ${maxW}px を超えている（段ごとの col を左から詰めて揃える、1段の数を減らして layer を分ける、col_gap を小さくする）" $null }
if ($H -gt $maxH) { Add-Err "図の高さが ${H}px で上限 ${maxH}px を超えている（layer を減らす、row_gap / layer_gap を小さくする、direction を変える）" $null }
for ($i = 0; $i -lt $order.Count; $i++) {
    for ($j = $i + 1; $j -lt $order.Count; $j++) {
        $a = $order[$i]; $b = $order[$j]
        if (Test-Overlap $nodes[$a].rect $nodes[$b].rect $minGap) { Add-Err "ノード ${a} と ${b} が重なっている（同じ layer・col か、間隔 ${minGap}px 未満。row_gap を広げるか col をずらす）" @("node:$a", "node:$b") }
    }
}
$labelRects = New-Object System.Collections.Generic.List[object]
if ($title) {
    $r = @((($W - $ts[0]) / 2), ($margin / 2), (($W + $ts[0]) / 2), ($margin / 2 + $ts[1]))
    $rects['title'] = $r
    $labelRects.Add(@{ key = 'title'; rect = $r; text = $title })
    foreach ($nid in $order) { if (Test-Overlap $nodes[$nid].rect $r 0) { Add-Err "ノード ${nid} がタイトルと重なっている" "node:$nid" } }
}
foreach ($k2 in $laneHeads.Keys) { $labelRects.Add(@{ key = "lane:$k2"; rect = $laneHeads[$k2]; text = "レーン見出し $k2" }) }

function Test-LabelClear($lr) {
    foreach ($o in $script:order) { if (Test-Overlap $script:nodes[$o].rect $lr 0) { return $false } }
    foreach ($L in $script:labelRects) { if (Test-Overlap $L.rect $lr 0) { return $false } }
    foreach ($gr in $script:groupFrames.Values) {
        $inside = $lr[0] -gt $gr[0] + 4 -and $lr[1] -gt $gr[1] + 4 -and $lr[2] -lt $gr[2] - 4 -and $lr[3] -lt $gr[3] - 4
        if ((Test-Overlap $lr $gr 4) -and -not $inside) { return $false }
    }
    return $true
}
foreach ($ed in $edgeList) {
    $a = $ed.a; $b = $ed.b; $pts = $ed.pts
    foreach ($o in $order) {
        if ($o -eq $a -or $o -eq $b) { continue }
        if (Test-PathHit $pts $nodes[$o].rect) {
            $hint = switch ($ed.route) {
                'bus' { "（幹線は from の真下/真横を通る。途中の layer では from と同じ col を空ける）" }
                'loop' { "（loop は外側を回る。経路上のノードの col をずらす）" }
                default { "（col をずらすか、route `"bus`" / `"loop`" を使う）" }
            }
            Add-Err "線 ${a}→${b} がノード ${o} を貫通している$hint" "node:$o"
        }
    }
    if ($ed.label) {
        # ラベルの位置: loop は外側の区間、bus は子へ入る最後の区間（短くて収まらなければ幹線から子へ曲がる区間）、straight は線上の label_pos
        $ls = Measure-Text $ed.label $nodeFont
        $si = if ($ed.route -eq 'loop') { 1 } else { $pts.Count - 2 }
        $lpos = $ed.pos
        if ($ed.route -eq 'bus') {
            # LR は段の間が狭いので、幹線から子へ曲がる縦の区間（子寄り）に置く。TB は子へ下りる区間（短すぎる場合は曲がる区間）
            $last = $pts[$pts.Count - 1]; $prevPt = $pts[$pts.Count - 2]
            $segLen = [math]::Abs($last[0] - $prevPt[0]) + [math]::Abs($last[1] - $prevPt[1])
            $need = if ([math]::Abs($last[0] - $prevPt[0]) -gt 0) { $ls[0] + 20 } else { $ls[1] + 14 }
            $mid = [math]::Abs($pts[2][0] - $pts[1][0]) + [math]::Abs($pts[2][1] - $pts[1][1])
            if ($mid -gt $ls[1] + 14 -and ($dirLR -or $segLen -lt $need)) {
                $si = 1
                if (-not $ed.posSet) { $lpos = 0.75 }
            }
        }
        $p = $pts[$si]; $q = $pts[$si + 1]
        # 指定位置から順に試し、ノード・ラベル・グループ枠線にかからない位置を選ぶ（どこもだめなら指定位置のまま検証でNG）
        $lr = $null
        foreach ($cand in @($lpos, 0.5, 0.35, 0.65, 0.25, 0.75, 0.15, 0.85) | Select-Object -Unique) {
            $mx = $p[0] + ($q[0] - $p[0]) * $cand; $my = $p[1] + ($q[1] - $p[1]) * $cand
            $try = @(($mx - $ls[0] / 2 - 6), ($my - $ls[1] / 2 - 3), ($mx + $ls[0] / 2 + 6), ($my + $ls[1] / 2 + 3))
            if ($null -eq $lr) { $lr = $try }
            if (Test-LabelClear $try) { $lr = $try; break }
        }
        $ed.lr = $lr; $rects[$ed.key] = $lr
        foreach ($o in $order) { if (Test-Overlap $nodes[$o].rect $lr 0) { Add-Err "線ラベル「$($ed.label)」(${a}→${b}) がノード ${o} に重なっている（ラベルの位置は自動で試したがどこも重なる。row_gap（TB）/ layer_gap（LR）を 40 増やす）" $ed.key } }
        foreach ($L in $labelRects) { if (Test-Overlap $L.rect $lr 0) { Add-Err "線ラベル「$($ed.label)」(${a}→${b}) が「$($L.text)」と重なっている" $ed.key } }
        $labelRects.Add(@{ key = $ed.key; rect = $lr; text = $ed.label })
    }
}

$groups = New-Object System.Collections.Generic.List[object]
foreach ($g in $specGroups) {
    $gid = [string]$g.id
    $members = Get-Members $g
    $bad = @($members | Where-Object { -not $nodes.ContainsKey($_) })
    if ($bad.Count) { Add-Err "グループ ${gid} のメンバーが存在しない: $($bad -join ', ')" $null; continue }
    if ($members.Count -eq 0) { Add-Err "グループ ${gid} にメンバーがいない" $null; continue }
    $gr = $groupFrames[$gid]
    $x0 = $gr[0]; $y0 = $gr[1]; $x1 = $gr[2]; $y1 = $gr[3]
    foreach ($o in $order) { if ($members -notcontains $o -and (Test-Overlap $nodes[$o].rect $gr 0)) { Add-Err "グループ ${gid} の枠に非メンバー ${o} が入っている（メンバーの col を連続させ、非メンバーを範囲外へ）" "node:$o" } }
    $lab = Get-Label $g
    $lr = $null
    if ($lab) {
        $tsz = Measure-Text $lab $nodeFont
        $lr = Get-GroupLabelRect $gr $groupSide[$gid] $tsz[0] $tsz[1]
        foreach ($L in $labelRects) { if (Test-Overlap $L.rect $lr 0) { Add-Err "グループ名「${lab}」が「$($L.text)」と重なっている" "group:$gid" } }
        if (@($edgeList | Where-Object { Test-PathHit $_.pts $lr }).Count -gt 0) { Add-Err "グループ名「${lab}」に線がかかっている（枠の上辺・下辺とも線が横切る。メンバーの col をずらすか、グループ名を短くする）" "group:$gid" }
    }
    $m4 = 4
    foreach ($L in $labelRects) {
        if (-not $L.key.StartsWith('edge:')) { continue }
        $r2 = $L.rect
        $inside = $r2[0] -gt $x0 + $m4 -and $r2[1] -gt $y0 + $m4 -and $r2[2] -lt $x1 - $m4 -and $r2[3] -lt $y1 - $m4
        if ((Test-Overlap $r2 $gr $m4) -and -not $inside) { Add-Err "線ラベル「$($L.text)」がグループ ${gid} の枠線にかかっている（ラベルの位置は自動で試したがどこも枠にかかる。row_gap（TB）/ layer_gap（LR）を 40 増やすか、グループの間の col / layer を1つ空ける）" $L.key }
    }
    if ($lab) { $labelRects.Add(@{ key = "group:$gid"; rect = $lr; text = $lab }) }
    $groups.Add(@{ id = $gid; rect = $gr; label = $lab; lr = $lr })
}
for ($i = 0; $i -lt $groups.Count; $i++) {
    for ($j = $i + 1; $j -lt $groups.Count; $j++) {
        $ga = $groups[$i]; $gb = $groups[$j]
        if ((Test-Overlap $ga.rect $gb.rect $minGap) -and -not (Test-Contains $ga.rect $gb.rect) -and -not (Test-Contains $gb.rect $ga.rect)) {
            Add-Err "グループ $($ga.id) と $($gb.id) の枠が重なっている（別グループは col を1つ以上空ける、または padding を小さくする）" @("group:$($ga.id)", "group:$($gb.id)")
        }
    }
}

$lanes = New-Object System.Collections.Generic.List[object]
if ($specLanes.Count -gt 0) {
    $owner = @{}
    foreach ($l in $specLanes) {
        $lid = [string]$l.id
        $members = Get-Members $l
        $bad = @($members | Where-Object { -not $nodes.ContainsKey($_) })
        if ($bad.Count) { Add-Err "レーン ${lid} のメンバーが存在しない: $($bad -join ', ')" $null }
        if (-not $laneFrames.ContainsKey($lid)) { Add-Err "レーン ${lid} にメンバーがいない" $null; continue }
        foreach ($m in $members) { if ($owner.ContainsKey($m)) { Add-Err "ノード ${m} が複数のレーン（$($owner[$m]), ${lid}）に入っている" "node:$m" } else { $owner[$m] = $lid } }
        $fr = $laneFrames[$lid]
        foreach ($o in $order) { if ($members -notcontains $o -and (Test-Overlap $nodes[$o].rect $fr 0)) { Add-Err "レーン ${lid} の帯に非メンバー ${o} が入っている（レーンごとに col を分け、同じレーンのノードは同じ col 範囲に置く）" "node:$o" } }
        $lanes.Add(@{ id = $lid; rect = $fr; head = $laneHeads[$lid]; label = (Get-Label $l) })
    }
    foreach ($nid in $order) { if (-not $owner.ContainsKey($nid)) { Add-Err "ノード ${nid} がどのレーンにも入っていない（lanes を使うときは全ノードをどれかのレーンに入れる）" "node:$nid" } }
    for ($i = 0; $i -lt $lanes.Count; $i++) {
        for ($j = $i + 1; $j -lt $lanes.Count; $j++) {
            if (Test-Overlap $lanes[$i].rect $lanes[$j].rect 0) { Add-Err "レーン $($lanes[$i].id) と $($lanes[$j].id) の帯が重なっている（レーンごとに col を分ける）" @("lane:$($lanes[$i].id)", "lane:$($lanes[$j].id)") }
        }
    }
}

# ---------------------------------------------------------------- 描画
function C($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function RF($r) { New-Object System.Drawing.RectangleF([single]$r[0], [single]$r[1], [single]($r[2] - $r[0]), [single]($r[3] - $r[1])) }
function PF($x, $y) { New-Object System.Drawing.PointF([single]$x, [single]$y) }
function New-RoundPath($r, $rad) {
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = [single]$r[0]; $y = [single]$r[1]; $w = [single]($r[2] - $r[0]); $h = [single]($r[3] - $r[1])
    $rad = [math]::Min($rad, [math]::Min($w, $h) / 2); $d = [single](2 * $rad)
    $gp.AddArc($x, $y, $d, $d, 180, 90); $gp.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $gp.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $gp.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    return $gp
}
function Draw-Node($g, $nd) {
    $r = $nd.rect; $x = $r[0]; $y = $r[1]; $w = $r[2] - $r[0]; $h = $r[3] - $r[1]
    $fill = New-Object System.Drawing.SolidBrush((C $nd.fill)); $pen = New-Object System.Drawing.Pen((C $nd.stroke), 2)
    $tr = $r
    switch ($nd.shape) {
        'rect' { $g.FillRectangle($fill, (RF $r)); $g.DrawRectangle($pen, [single]$x, [single]$y, [single]$w, [single]$h) }
        'ellipse' { $g.FillEllipse($fill, (RF $r)); $g.DrawEllipse($pen, (RF $r)) }
        'stadium' { $gp = New-RoundPath $r ($h / 2); $g.FillPath($fill, $gp); $g.DrawPath($pen, $gp) }
        'diamond' {
            $pts = [System.Drawing.PointF[]]@((PF ($x + $w / 2) $y), (PF ($x + $w) ($y + $h / 2)), (PF ($x + $w / 2) ($y + $h)), (PF $x ($y + $h / 2)))
            $g.FillPolygon($fill, $pts); $g.DrawPolygon($pen, $pts)
        }
        'parallelogram' {
            $k = 14
            $pts = [System.Drawing.PointF[]]@((PF ($x + $k) $y), (PF ($x + $w) $y), (PF ($x + $w - $k) ($y + $h)), (PF $x ($y + $h)))
            $g.FillPolygon($fill, $pts); $g.DrawPolygon($pen, $pts)
        }
        'note' {
            $f = 12
            $pts = [System.Drawing.PointF[]]@((PF $x $y), (PF ($x + $w - $f) $y), (PF ($x + $w) ($y + $f)), (PF ($x + $w) ($y + $h)), (PF $x ($y + $h)))
            $g.FillPolygon($fill, $pts); $g.DrawPolygon($pen, $pts)
            $g.DrawLines($pen, [System.Drawing.PointF[]]@((PF ($x + $w - $f) $y), (PF ($x + $w - $f) ($y + $f)), (PF ($x + $w) ($y + $f))))
            $tr = @($x, $y, ($x + $w - 6), ($y + $h))
        }
        'document' {
            $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
            $b = $y + $h - 8
            $gp.AddLine([single]$x, [single]$b, [single]$x, [single]$y); $gp.AddLine([single]$x, [single]$y, [single]($x + $w), [single]$y)
            $gp.AddLine([single]($x + $w), [single]$y, [single]($x + $w), [single]$b)
            $gp.AddBezier([single]($x + $w), [single]$b, [single]($x + $w * 0.7), [single]($b - 12), [single]($x + $w * 0.3), [single]($b + 14), [single]$x, [single]$b)
            $gp.CloseFigure(); $g.FillPath($fill, $gp); $g.DrawPath($pen, $gp)
            $tr = @($x, $y, ($x + $w), ($y + $h - 10))
        }
        'cylinder' {
            $e = 14
            $g.FillRectangle($fill, [single]$x, [single]($y + $e / 2), [single]$w, [single]($h - $e))
            $g.FillEllipse($fill, [single]$x, [single]($y + $h - $e), [single]$w, [single]$e)
            $g.DrawArc($pen, [single]$x, [single]($y + $h - $e), [single]$w, [single]$e, 0, 180)
            $g.DrawLine($pen, [single]$x, [single]($y + $e / 2), [single]$x, [single]($y + $h - $e / 2))
            $g.DrawLine($pen, [single]($x + $w), [single]($y + $e / 2), [single]($x + $w), [single]($y + $h - $e / 2))
            $g.FillEllipse($fill, [single]$x, [single]$y, [single]$w, [single]$e); $g.DrawEllipse($pen, [single]$x, [single]$y, [single]$w, [single]$e)
            $tr = @($x, ($y + $e), ($x + $w), ($y + $h))
        }
        'subprocess' {
            $g.FillRectangle($fill, (RF $r)); $g.DrawRectangle($pen, [single]$x, [single]$y, [single]$w, [single]$h)
            $g.DrawLine($pen, [single]($x + 9), [single]$y, [single]($x + 9), [single]($y + $h)); $g.DrawLine($pen, [single]($x + $w - 9), [single]$y, [single]($x + $w - 9), [single]($y + $h))
        }
        'dashed' { $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash; $gp = New-RoundPath $r 8; $g.FillPath($fill, $gp); $g.DrawPath($pen, $gp) }
        default { $gp = New-RoundPath $r 8; $g.FillPath($fill, $gp); $g.DrawPath($pen, $gp) }
    }
    $g.DrawString($nd.label, $script:nodeFont, $script:textBrush, (RF $tr), $script:sfCenter)
}

$bmp = New-Object System.Drawing.Bitmap([int]$W, [int]$H)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gfx.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$gfx.Clear([System.Drawing.Color]::White)
$textBrush = New-Object System.Drawing.SolidBrush((C '#111111'))

$li = 0
foreach ($ln in $lanes) {
    $bg = if ($li % 2 -eq 0) { '#FAFBFC' } else { '#F1F5F9' }; $li++
    $gfx.FillRectangle((New-Object System.Drawing.SolidBrush((C $bg))), (RF $ln.rect))
    $gfx.FillRectangle((New-Object System.Drawing.SolidBrush((C '#E2E8F0'))), (RF $ln.head))
    $pen = New-Object System.Drawing.Pen((C '#94A3B8'), 1)
    $rf = RF $ln.rect; $gfx.DrawRectangle($pen, $rf.X, $rf.Y, $rf.Width, $rf.Height)
    $gfx.DrawString($ln.label, $laneFont, $textBrush, (RF $ln.head), $sfCenter)
}
foreach ($gr in $groups) {
    $gfx.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(170, 240, 240, 240))), (RF $gr.rect))
    $pen = New-Object System.Drawing.Pen((C '#888888'), 2); $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $rf = RF $gr.rect; $gfx.DrawRectangle($pen, $rf.X, $rf.Y, $rf.Width, $rf.Height)
    if ($gr.label) { $gfx.DrawString($gr.label, $nodeFont, (New-Object System.Drawing.SolidBrush((C '#555555'))), [single]$gr.lr[0], [single]$gr.lr[1], $sfMeasure) }
}
foreach ($ed in $edgeList) {
    $ec = if ($ed.color) { $ed.color } else { '#444444' }
    $pen = New-Object System.Drawing.Pen((C $ec), 2)
    if ($ed.style -eq 'dashed') { $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash }
    if ($ed.style -eq 'dotted') { $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot }
    if ($ed.arrow) { $pen.CustomEndCap = New-Object System.Drawing.Drawing2D.AdjustableArrowCap(5, 5) }
    $pf = [System.Drawing.PointF[]]@($ed.pts | ForEach-Object { PF $_[0] $_[1] })
    $gfx.DrawLines($pen, $pf)
}
foreach ($nid in $order) { Draw-Node $gfx $nodes[$nid] }
foreach ($ed in $edgeList) {
    if ($ed.label) {
        $gfx.FillRectangle([System.Drawing.Brushes]::White, (RF $ed.lr))
        $gfx.DrawString($ed.label, $nodeFont, $textBrush, (RF $ed.lr), $sfCenter)
    }
}
if ($title) { $gfx.DrawString($title, $titleFont, $textBrush, [single]$rects['title'][0], [single]$rects['title'][1], $sfMeasure) }

if ($errors.Count -gt 0) {
    $red = New-Object System.Drawing.Pen([System.Drawing.Color]::Red, 3)
    $seen = @{}
    foreach ($er in $errors) {
        foreach ($kk in $er.Keys) {
            if ($kk -and $rects.ContainsKey($kk) -and -not $seen.ContainsKey($kk)) {
                $seen[$kk] = 1; $r = $rects[$kk]
                $gfx.DrawRectangle($red, [single]($r[0] - 3), [single]($r[1] - 3), [single]($r[2] - $r[0] + 6), [single]($r[3] - $r[1] + 6))
            }
        }
    }
    $bmp.Save($debugPath, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "NG: $($errors.Count)件（赤枠: $debugPath）" -ForegroundColor Red
    $lines = @(); $no = 1
    foreach ($er in $errors) { $lines += "  $no. $($er.Msg)"; $no++ }
    $lines | ForEach-Object { Write-Host $_ }
    if ($FromClipboard) {
        Set-Clipboard -Value ("render.ps1 の検証でNGでした。以下をすべて直した diagram.json を全体で出し直してください（JSONのみ）:`n" + ($lines -join "`n"))
        Write-Host "（修正依頼文をクリップボードにコピーしました。生成AIにそのまま貼ってください）"
    }
    exit 1
}
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host "OK: nodes=$($order.Count) edges=$($edgeList.Count) groups=$($groups.Count) lanes=$($lanes.Count) size=${W}x${H} → $outPath" -ForegroundColor Green
exit 0
