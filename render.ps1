<#
render.ps1 — JSON → 構成図PNG（検証つき）  Windows PowerShell 5.1 / PowerShell 7 (Windows)

使い方:
  .\render.ps1 -FromClipboard        # 生成AIの回答をコピーして実行（JSON部分だけ抜き出して diagram.json に保存→描画）
  .\render.ps1 diagram.json          # ファイルから
  .\render.ps1 diagram.json -Out net.png -Font "Yu Gothic UI"

終了コード: 0=OK(diagram.png) / 1=検証NG(diagram_debug.png に赤枠) / 2=JSON構文・スキーマ不正
-FromClipboard でNGのときは、生成AIにそのまま貼れる修正依頼文をクリップボードに入れます。

検証: JSON構文 / 必須キー / id重複 / 参照切れ / ノード重なり / 文字はみ出し / 線のノード貫通 /
      線ラベル・タイトル・グループ名の重なり / 線ラベルのグループ枠線かぶり / グループへの非メンバー混入 /
      キャンバス外 / フォント未収録文字（豆腐）
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
$specNodes = @(Get-Prop $doc 'nodes' @())
if ($specNodes.Count -eq 0) { Exit-Schema '"nodes" が空か配列ではありません' }
$k = 0
foreach ($n in $specNodes) {
    if (-not (Has $n 'id') -or -not (Has $n 'label')) { Exit-Schema "nodes[$k] に `"id`" と `"label`" が必要です" }
    if (-not (Has $n 'layer') -and -not ((Has $n 'x') -and (Has $n 'y'))) { Exit-Schema "ノード $($n.id): `"layer`" か `"x`",`"y`" が必要です" }
    $k++
}
$specEdges = @(Get-Prop $doc 'edges' @())
$k = 0
foreach ($e in $specEdges) { if (-not (Has $e 'from') -or -not (Has $e 'to')) { Exit-Schema "edges[$k] に `"from`" と `"to`" が必要です" }; $k++ }
$specGroups = @(Get-Prop $doc 'groups' @())
$k = 0
foreach ($g in $specGroups) { if (-not (Has $g 'id') -or -not (Has $g 'nodes')) { Exit-Schema "groups[$k] に `"id`" と `"nodes`" が必要です" }; $k++ }

# ---------------------------------------------------------------- 設定・フォント
$canvas = Get-Prop $doc 'canvas' $null
$fs = [int](Get-Prop $canvas 'font_size' 14)
$rowGap = [int](Get-Prop $canvas 'row_gap' 150)
$colGap = [int](Get-Prop $canvas 'col_gap' 48)
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

$errors = New-Object System.Collections.Generic.List[object]
function Add-Err($msg, $keys) { $script:errors.Add([pscustomobject]@{ Msg = $msg; Keys = @($keys) }) }

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
function Get-Clip($cx, $cy, $hw, $hh, $tx, $ty) {
    $dx = $tx - $cx; $dy = $ty - $cy
    if ($dx -eq 0 -and $dy -eq 0) { return , @($cx, $cy) }
    $kx = if ($dx -ne 0) { $hw / [math]::Abs($dx) } else { [double]::PositiveInfinity }
    $ky = if ($dy -ne 0) { $hh / [math]::Abs($dy) } else { [double]::PositiveInfinity }
    $t = [math]::Min($kx, $ky)
    return , @(($cx + $dx * $t), ($cy + $dy * $t))
}
function Get-Label($o) { ([string](Get-Prop $o 'label' '')).Replace('\n', "`n") }

# ---------------------------------------------------------------- ノード
$nodes = @{}
$order = New-Object System.Collections.Generic.List[string]
foreach ($n in $specNodes) {
    $nid = [string]$n.id
    if ($nodes.ContainsKey($nid)) { Add-Err "id 重複: ${nid}" $null; continue }
    $label = Get-Label $n
    $sz = Measure-Text $label $nodeFont
    $hasW = Has $n 'w'; $hasH = Has $n 'h'
    $w = if ($hasW) { [double]$n.w } else { $sz[0] + 2 * $padX }
    $h = if ($hasH) { [double]$n.h } else { $sz[1] + 2 * $padY }
    if (($hasW -or $hasH) -and ($sz[0] + $padX -gt $w -or $sz[1] + $padY -gt $h)) {
        Add-Err "ノード ${nid} の文字がはみ出し（必要 $($sz[0] + 2 * $padX)x$($sz[1] + 2 * $padY) / 指定 ${w}x${h}）" "node:$nid"
    }
    $nodes[$nid] = @{
        id = $nid; label = $label; w = $w; h = $h; type = [string](Get-Prop $n 'type' '')
        layer = (Get-Prop $n 'layer' $null); col = (Get-Prop $n 'col' $null)
        fixed = ((Has $n 'x') -and (Has $n 'y')); x = (Get-Prop $n 'x' $null); y = (Get-Prop $n 'y' $null)
    }
    $order.Add($nid)
}

# 配置: layer(行)+col(列) の格子 / layerのみなら行内で等間隔 / x,y 固定
$layers = @{}
foreach ($nid in $order) {
    $nd = $nodes[$nid]
    if (-not $nd.fixed) {
        $li = [int]$nd.layer
        if (-not $layers.ContainsKey($li)) { $layers[$li] = New-Object System.Collections.Generic.List[string] }
        $layers[$li].Add($nid)
    }
}
$grid = $false
foreach ($nid in $order) { if ($null -ne $nodes[$nid].col) { $grid = $true } }
if ($grid) {
    foreach ($nid in $order) {
        $nd = $nodes[$nid]
        if (-not $nd.fixed -and $null -eq $nd.col) { Add-Err "ノード ${nid}: 格子モードでは `"col`" が必要（他のノードが col を使用）" $null; $nd.col = 0 }
    }
}
$title = [string](Get-Prop $canvas 'title' '')
$top = $margin
if ($title) { $top += (Measure-Text $title $titleFont)[1] + 16 }

$autoW = 0.0
$colW = @{}
if ($grid) {
    foreach ($nid in $order) {
        $nd = $nodes[$nid]
        if (-not $nd.fixed) { $c = [int]$nd.col; if (-not $colW.ContainsKey($c) -or $colW[$c] -lt $nd.w) { $colW[$c] = $nd.w } }
    }
    $ncol = 0
    foreach ($c in $colW.Keys) { if ($c + 1 -gt $ncol) { $ncol = $c + 1 } }
    for ($c = 0; $c -lt $ncol; $c++) { if (-not $colW.ContainsKey($c)) { $colW[$c] = 0 } }
    foreach ($v in $colW.Values) { $autoW += $v }
    $autoW += $colGap * [math]::Max($ncol - 1, 0)
} else {
    foreach ($li in $layers.Keys) {
        $t = 0.0; foreach ($i in $layers[$li]) { $t += $nodes[$i].w }
        $t += $colGap * ($layers[$li].Count - 1)
        if ($t -gt $autoW) { $autoW = $t }
    }
}
$hasWidth = Has $canvas 'width'; $hasHeight = Has $canvas 'height'
$W = if ($hasWidth) { [int]$canvas.width } else { [int]($autoW + 2 * $margin) }
$maxLayer = 0; foreach ($li in $layers.Keys) { if ($li -gt $maxLayer) { $maxLayer = $li } }
$maxH = 0.0; foreach ($nid in $order) { if ($nodes[$nid].h -gt $maxH) { $maxH = $nodes[$nid].h } }
$H = if ($hasHeight) { [int]$canvas.height } else { [int]($top + $maxLayer * $rowGap + $margin + $maxH) }

$colX = @{}
if ($grid) {
    $x = ($W - $autoW) / 2
    foreach ($c in ($colW.Keys | Sort-Object)) { $colX[$c] = $x + $colW[$c] / 2; $x += $colW[$c] + $colGap }
}
foreach ($li in ($layers.Keys | Sort-Object)) {
    $ids = $layers[$li]
    $mh = 0.0; foreach ($i in $ids) { if ($nodes[$i].h -gt $mh) { $mh = $nodes[$i].h } }
    $cy = $top + $li * $rowGap + $mh / 2
    if ($grid) {
        foreach ($i in $ids) { $nodes[$i].cx = $colX[[int]$nodes[$i].col]; $nodes[$i].cy = $cy }
    } else {
        $t = 0.0; foreach ($i in $ids) { $t += $nodes[$i].w }
        $t += $colGap * ($ids.Count - 1)
        $x = ($W - $t) / 2
        foreach ($i in $ids) { $nodes[$i].cx = $x + $nodes[$i].w / 2; $nodes[$i].cy = $cy; $x += $nodes[$i].w + $colGap }
    }
}
$rects = @{}
foreach ($nid in $order) {
    $nd = $nodes[$nid]
    if ($nd.fixed) { $nd.cx = [double]$nd.x; $nd.cy = [double]$nd.y }
    $nd.rect = @(($nd.cx - $nd.w / 2), ($nd.cy - $nd.h / 2), ($nd.cx + $nd.w / 2), ($nd.cy + $nd.h / 2))
    $rects["node:$nid"] = $nd.rect
    # 固定座標ノードは、サイズ未指定ならキャンバスを広げて収める
    if ($nd.fixed -and -not $hasWidth -and $nd.rect[2] + $margin -gt $W) { $W = [int]($nd.rect[2] + $margin) }
    if ($nd.fixed -and -not $hasHeight -and $nd.rect[3] + $margin -gt $H) { $H = [int]($nd.rect[3] + $margin) }
}

# グループ枠（存在するメンバーのみで計算。メンバー不正の検証は後段）
function Get-GroupFrame($g) {
    $members = @($g.nodes | ForEach-Object { [string]$_ } | Where-Object { $script:nodes.ContainsKey($_) })
    if ($members.Count -eq 0) { return $null }
    $pad = [double](Get-Prop $g 'padding' 24)
    $x0 = [double]::MaxValue; $y0 = [double]::MaxValue; $x1 = [double]::MinValue; $y1 = [double]::MinValue
    foreach ($m in $members) {
        $r = $script:nodes[$m].rect
        $x0 = [math]::Min($x0, $r[0]); $y0 = [math]::Min($y0, $r[1]); $x1 = [math]::Max($x1, $r[2]); $y1 = [math]::Max($y1, $r[3])
    }
    $x0 -= $pad; $y0 -= $pad; $x1 += $pad; $y1 += $pad
    $lab = Get-Label $g
    if ($lab) { $y0 -= (Measure-Text $lab $script:nodeFont)[1] + 6 }
    return , @($x0, $y0, $x1, $y1)
}

# 自動サイズのときは、グループ枠まで含めて余白 margin で収まるよう全体を平行移動・拡張する
$bx0 = [double]::MaxValue; $by0 = [double]::MaxValue; $bx1 = [double]::MinValue; $by1 = [double]::MinValue
$boxes = @($order | ForEach-Object { , $nodes[$_].rect }) + @($specGroups | ForEach-Object { , (Get-GroupFrame $_) } | Where-Object { $null -ne $_ })
foreach ($r in $boxes) { $bx0 = [math]::Min($bx0, $r[0]); $by0 = [math]::Min($by0, $r[1]); $bx1 = [math]::Max($bx1, $r[2]); $by1 = [math]::Max($by1, $r[3]) }
$shiftX = 0.0; $shiftY = 0.0
if (-not $hasWidth) { $shiftX = $margin - $bx0; $W = [int][math]::Ceiling([math]::Max($W, $bx1 + $shiftX + $margin)) }
if (-not $hasHeight) { $shiftY = [math]::Max(0, $top - $by0); $H = [int][math]::Ceiling([math]::Max($H, $by1 + $shiftY + $margin)) }
if ($shiftX -ne 0 -or $shiftY -ne 0) {
    foreach ($nid in $order) {
        $nd = $nodes[$nid]
        $nd.cx += $shiftX; $nd.cy += $shiftY
        $nd.rect = @(($nd.rect[0] + $shiftX), ($nd.rect[1] + $shiftY), ($nd.rect[2] + $shiftX), ($nd.rect[3] + $shiftY))
        $rects["node:$nid"] = $nd.rect
    }
}

# ---------------------------------------------------------------- 検証
foreach ($nid in $order) {
    $r = $nodes[$nid].rect
    if (-not ($r[0] -ge 0 -and $r[1] -ge 0 -and $r[2] -le $W -and $r[3] -le $H)) { Add-Err "ノード ${nid} がキャンバス外（${W}x${H}）" "node:$nid" }
}
for ($i = 0; $i -lt $order.Count; $i++) {
    for ($j = $i + 1; $j -lt $order.Count; $j++) {
        $a = $order[$i]; $b = $order[$j]
        if (Test-Overlap $nodes[$a].rect $nodes[$b].rect $minGap) { Add-Err "ノード ${a} と ${b} が重なっている（間隔 ${minGap}px 未満）" @("node:$a", "node:$b") }
    }
}
$labelRects = New-Object System.Collections.Generic.List[object]
if ($title) {
    $ts = Measure-Text $title $titleFont
    $r = @((($W - $ts[0]) / 2), ($margin / 2), (($W + $ts[0]) / 2), ($margin / 2 + $ts[1]))
    $rects['title'] = $r
    $labelRects.Add(@{ key = 'title'; rect = $r; text = $title })
}

$edges = New-Object System.Collections.Generic.List[object]
$ei = 0
foreach ($e in $specEdges) {
    $a = [string]$e.from; $b = [string]$e.to
    $key = "edge:${a}->${b}#${ei}"; $ei++
    if (-not $nodes.ContainsKey($a) -or -not $nodes.ContainsKey($b)) { Add-Err "線 ${a}→${b} の参照先が存在しない" $null; continue }
    if ($a -eq $b) { Add-Err "線 ${a}→${b} が自己参照" "node:$a"; continue }
    $na = $nodes[$a]; $nb = $nodes[$b]
    if (Test-Overlap $na.rect $nb.rect 0) { continue }
    $p = Get-Clip $na.cx $na.cy ($na.w / 2) ($na.h / 2) $nb.cx $nb.cy
    $q = Get-Clip $nb.cx $nb.cy ($nb.w / 2) ($nb.h / 2) $na.cx $na.cy
    foreach ($o in $order) {
        if ($o -eq $a -or $o -eq $b) { continue }
        $orc = $nodes[$o].rect
        for ($s = 0; $s -le 40; $s++) {
            $px = $p[0] + ($q[0] - $p[0]) * $s / 40; $py = $p[1] + ($q[1] - $p[1]) * $s / 40
            if ($px -ge $orc[0] -and $px -le $orc[2] -and $py -ge $orc[1] -and $py -le $orc[3]) { Add-Err "線 ${a}→${b} がノード ${o} を貫通している" "node:$o"; break }
        }
    }
    $lab = Get-Label $e
    $lr = $null
    if ($lab) {
        $ls = Measure-Text $lab $nodeFont
        $pos = 0.5
        try { $pos = [double](Get-Prop $e 'label_pos' 0.5) } catch {}
        $pos = [math]::Min(0.9, [math]::Max(0.1, $pos))
        $mx = $p[0] + ($q[0] - $p[0]) * $pos; $my = $p[1] + ($q[1] - $p[1]) * $pos
        $lr = @(($mx - $ls[0] / 2 - 6), ($my - $ls[1] / 2 - 3), ($mx + $ls[0] / 2 + 6), ($my + $ls[1] / 2 + 3))
        $rects[$key] = $lr
        foreach ($o in $order) { if (Test-Overlap $nodes[$o].rect $lr 0) { Add-Err "線ラベル「${lab}」(${a}→${b}) がノード ${o} に重なっている" $key } }
        foreach ($L in $labelRects) { if (Test-Overlap $L.rect $lr 0) { Add-Err "線ラベル「${lab}」(${a}→${b}) が「$($L.text)」と重なっている" $key } }
        $labelRects.Add(@{ key = $key; rect = $lr; text = $lab })
    }
    $edges.Add(@{ p = $p; q = $q; dashed = ([string](Get-Prop $e 'style' 'solid') -eq 'dashed'); arrow = [bool](Get-Prop $e 'arrow' $false); label = $lab; lr = $lr })
}

$groups = New-Object System.Collections.Generic.List[object]
foreach ($g in $specGroups) {
    $gid = [string]$g.id
    $members = @($g.nodes | ForEach-Object { [string]$_ })
    $bad = @($members | Where-Object { -not $nodes.ContainsKey($_) })
    if ($bad.Count) { Add-Err "グループ ${gid} のメンバーが存在しない: $($bad -join ', ')" $null; continue }
    if ($members.Count -eq 0) { Add-Err "グループ ${gid} にメンバーがいない" $null; continue }
    $lab = Get-Label $g
    $th = 0; $tw = 0
    if ($lab) { $tsz = Measure-Text $lab $nodeFont; $tw = $tsz[0]; $th = $tsz[1] }
    $gr = Get-GroupFrame $g
    $x0 = $gr[0]; $y0 = $gr[1]; $x1 = $gr[2]; $y1 = $gr[3]
    $rects["group:$gid"] = $gr
    if (-not ($x0 -ge 0 -and $y0 -ge 0 -and $x1 -le $W -and $y1 -le $H)) { Add-Err "グループ ${gid} の枠がキャンバス外" "group:$gid" }
    foreach ($o in $order) { if ($members -notcontains $o -and (Test-Overlap $nodes[$o].rect $gr 0)) { Add-Err "グループ ${gid} の枠に非メンバー ${o} が入っている" "node:$o" } }
    $lr = $null
    if ($lab) {
        $lr = @(($x0 + 8), ($y0 + 3), ($x0 + 8 + $tw), ($y0 + 3 + $th))
        foreach ($L in $labelRects) { if (Test-Overlap $L.rect $lr 0) { Add-Err "グループ名「${lab}」が「$($L.text)」と重なっている" "group:$gid" } }
    }
    $m4 = 4
    foreach ($L in $labelRects) {
        if (-not $L.key.StartsWith('edge:')) { continue }
        $r2 = $L.rect
        $inside = $r2[0] -gt $x0 + $m4 -and $r2[1] -gt $y0 + $m4 -and $r2[2] -lt $x1 - $m4 -and $r2[3] -lt $y1 - $m4
        if ((Test-Overlap $r2 $gr $m4) -and -not $inside) { Add-Err "線ラベル「$($L.text)」がグループ ${gid} の枠線にかかっている（label_pos を 0.25 や 0.75 にずらす）" $L.key }
    }
    if ($lab) { $labelRects.Add(@{ key = "group:$gid"; rect = $lr; text = $lab }) }
    $groups.Add(@{ id = $gid; rect = $gr; label = $lab; lr = $lr })
}
# グループ同士: 入れ子（完全に内側）は可、部分的な重なり・接触は NG
function Test-Contains($o, $i) { $o[0] -le $i[0] -and $o[1] -le $i[1] -and $o[2] -ge $i[2] -and $o[3] -ge $i[3] }
for ($i = 0; $i -lt $groups.Count; $i++) {
    for ($j = $i + 1; $j -lt $groups.Count; $j++) {
        $ga = $groups[$i]; $gb = $groups[$j]
        if ((Test-Overlap $ga.rect $gb.rect $minGap) -and -not (Test-Contains $ga.rect $gb.rect) -and -not (Test-Contains $gb.rect $ga.rect)) {
            Add-Err "グループ $($ga.id) と $($gb.id) の枠が重なっている（別グループは col を1つ以上空ける、または padding を小さくする）" @("group:$($ga.id)", "group:$($gb.id)")
        }
    }
}
if ($title) {
    foreach ($nid in $order) { if (Test-Overlap $nodes[$nid].rect $rects['title'] 0) { Add-Err "ノード ${nid} がタイトルと重なっている" "node:$nid" } }
}

# ---------------------------------------------------------------- 描画
function C($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function RF($r) { New-Object System.Drawing.RectangleF([single]$r[0], [single]$r[1], [single]($r[2] - $r[0]), [single]($r[3] - $r[1])) }
function New-RoundPath($r, $rad) {
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = [single]$r[0]; $y = [single]$r[1]; $w = [single]($r[2] - $r[0]); $h = [single]($r[3] - $r[1]); $d = [single](2 * $rad)
    $gp.AddArc($x, $y, $d, $d, 180, 90); $gp.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $gp.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $gp.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    return $gp
}
$typeColors = @{
    firewall = @('#FDE2D6', '#C0392B'); switch = @('#D6E8FA', '#2E6DB4'); router = @('#D6E8FA', '#2E6DB4')
    server = @('#DDF3DF', '#2E8B57'); cloud = @('#EEEEEE', '#7F8C8D'); user = @('#FFF4CC', '#B7950B')
}
$bmp = New-Object System.Drawing.Bitmap([int]$W, [int]$H)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gfx.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$gfx.Clear([System.Drawing.Color]::White)
$textBrush = New-Object System.Drawing.SolidBrush((C '#111111'))

foreach ($gr in $groups) {
    $gfx.FillRectangle((New-Object System.Drawing.SolidBrush((C '#F7F7F7'))), (RF $gr.rect))
    $pen = New-Object System.Drawing.Pen((C '#888888'), 2); $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $rf = RF $gr.rect; $gfx.DrawRectangle($pen, $rf.X, $rf.Y, $rf.Width, $rf.Height)
    if ($gr.label) { $gfx.DrawString($gr.label, $nodeFont, (New-Object System.Drawing.SolidBrush((C '#555555'))), [single]$gr.lr[0], [single]$gr.lr[1], $sfMeasure) }
}
foreach ($e in $edges) {
    $pen = New-Object System.Drawing.Pen((C '#444444'), 2)
    if ($e.dashed) { $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash }
    if ($e.arrow) { $pen.CustomEndCap = New-Object System.Drawing.Drawing2D.AdjustableArrowCap(5, 5) }
    $gfx.DrawLine($pen, [single]$e.p[0], [single]$e.p[1], [single]$e.q[0], [single]$e.q[1])
}
foreach ($nid in $order) {
    $nd = $nodes[$nid]
    $cols = if ($typeColors.ContainsKey($nd.type)) { $typeColors[$nd.type] } else { @('#FFFFFF', '#333333') }
    $fill = New-Object System.Drawing.SolidBrush((C $cols[0])); $pen = New-Object System.Drawing.Pen((C $cols[1]), 2)
    if ($nd.type -eq 'cloud') { $gfx.FillEllipse($fill, (RF $nd.rect)); $gfx.DrawEllipse($pen, (RF $nd.rect)) }
    else { $gp = New-RoundPath $nd.rect 8; $gfx.FillPath($fill, $gp); $gfx.DrawPath($pen, $gp) }
    $gfx.DrawString($nd.label, $nodeFont, $textBrush, (RF $nd.rect), $sfCenter)
}
foreach ($e in $edges) {
    if ($e.label) {
        $gfx.FillRectangle([System.Drawing.Brushes]::White, (RF $e.lr))
        $gfx.DrawString($e.label, $nodeFont, $textBrush, (RF $e.lr), $sfCenter)
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
Write-Host "OK: nodes=$($order.Count) edges=$($edges.Count) groups=$($groups.Count) size=${W}x${H} → $outPath" -ForegroundColor Green
exit 0
