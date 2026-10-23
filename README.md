# json-netdiagram

生成AIに図の **JSON** を書かせ、PowerShell で **PNG** に描画するツールです。
描画の前に図の崩れを検証し、NG なら生成AIにそのまま貼れる修正依頼文を作ります。

ネットワーク構成図のほか、組織図・業務フロー・手順書・システム構成図・提案資料の概念図を作れます。

- Windows 標準の機能だけで動きます（Windows PowerShell 5.1 / PowerShell 7、追加インストール不要）
- 座標は生成AIに決めさせません。`layer`（段）と `col`（列）だけを決めさせ、配置・サイズ・線ラベルの位置はスクリプト側で計算します

## ファイル

| ファイル | 内容 |
|---|---|
| `render.ps1` | JSON を検証して PNG に描画する |
| `prompts/network.txt` | ネットワーク構成図 |
| `prompts/org.txt` | 組織図 |
| `prompts/flow.txt` | 業務フロー（スイムレーン） |
| `prompts/procedure.txt` | 手順書 |
| `prompts/architecture.txt` | システム構成図（ソフトウェア・クラウド） |
| `prompts/concept.txt` | 提案資料・説明資料の概念図 |

`prompts/` の各ファイルは、生成AIに貼る依頼文です。スキーマとルールを全部含んでいるので、1 枚貼るだけで使えます。

## 使い方

1. 作りたい図の `prompts/*.txt` を開き、末尾の【構成】欄を書き換えて、全文を生成AI（ChatGPT、Claude、Copilot など）に貼ります。
2. 生成AIが出した JSON のコードブロックをコピーして、次を実行します。

   ```powershell
   .\render.ps1 -FromClipboard
   ```

3. 結果
   - **OK**: `diagram.png` ができます。
   - **NG**: `diagram_debug.png`（問題箇所に赤枠）ができ、「以下を直した JSON を出し直して」という依頼文がクリップボードに入ります。それを生成AIに貼って、2 に戻ります。

ファイルから描画することもできます。

```powershell
.\render.ps1 diagram.json
.\render.ps1 diagram.json -Out flow.png -Font "Yu Gothic UI"
```

実行ポリシーで止まる場合は、`powershell -ExecutionPolicy Bypass -File .\render.ps1 -FromClipboard` で実行してください。

## 終了コード

| コード | 意味 |
|---|---|
| 0 | OK（`diagram.png` を出力） |
| 1 | 検証 NG（`diagram_debug.png` に赤枠） |
| 2 | JSON の構文・スキーマ不正 |

## JSON の要点

| 項目 | 内容 |
|---|---|
| `canvas.direction` | `TB`（段が上→下）/ `LR`（段が左→右） |
| `canvas.row_gap` / `layer_gap` / `col_gap` | 段の間隔（TB は段の頭同士、LR は段の隙間）/ 列の隙間 |
| `canvas.uniform_width` | `true` で箱の幅をそろえる（組織図・手順書向け） |
| `canvas.max_width` / `max_height` | 図の大きさの上限（既定 2400px） |
| `nodes[].type` | 箱の種類。色と形が決まる（下表） |
| `nodes[].color` | 塗りの色を `#RRGGBB` で上書き（任意） |
| `edges[].route` | `straight`（直線）/ `bus`（くし形・カギ形）/ `loop`（前の段へ戻る線。外側を回る） |
| `edges[].style` | `solid` / `dashed` / `dotted` |
| `edges[].arrow` / `color` | 矢印の有無 / 線の色（任意） |
| `groups` | メンバーを囲む枠。グループ名は線と重ならない位置（上辺か下辺）に自動で置きます |
| `lanes` | スイムレーン（担当者ごとの帯）。全体を貫く帯として描きます |

### type の一覧

| 分類 | type | 形 |
|---|---|---|
| ネットワーク | `firewall` `router` `switch` `ap` `server` `user` | 角丸 |
| | `vm` | 破線の角丸 |
| | `cloud` | だ円 |
| | `storage` | 円柱 |
| ソフトウェア | `client` `service` | 角丸 |
| | `database` | 円柱 |
| | `queue` | 両端に縦線のある四角 |
| | `external` | 破線の角丸 |
| 組織 | `person` | 角丸 |
| | `dept` | 四角 |
| フロー・手順 | `start` `end` | 両端が丸い形 |
| | `process` | 四角 |
| | `decision` | ひし形 |
| | `data` | 平行四辺形 |
| | `document` | 下が波形の書類 |
| | `subprocess` | 両端に縦線のある四角 |
| | `step` | 角丸 |
| 資料 | `box` `emphasis` | 角丸（emphasis は強調色） |
| | `note` | 角が折れた付箋 |

## 検証する項目

- JSON の構文、必須キー、type、id の重複、存在しない id の参照
- ノード同士の重なり、線がほかのノードを貫通していないか
- 線ラベルとノード・ほかのラベル・グループの枠線の重なり（ラベルの位置は自動で試し、どこにも置けないときだけ NG）
- グループ名に線がかかっていないか、グループの枠に非メンバーが入っていないか、グループ同士の枠の重なり（入れ子は可）
- レーンの帯に非メンバーが入っていないか、レーン同士の重なり、どのレーンにも入っていないノード
- 図の大きさが上限を超えていないか
- フォントに無い文字（豆腐になる文字）

## 補足

- 文字の描画と計測は System.Drawing、豆腐の判定は WPF のグリフ情報を使っています。
- フォントは Meiryo UI → Meiryo → Yu Gothic UI → BIZ UDPGothic → MS UI Gothic → MS Gothic の順に、入っているものを使います。
- `render.ps1` は日本語を含むため、BOM 付き UTF-8 で保存しています（Windows PowerShell 5.1 での文字化け対策）。編集するときも BOM 付きのまま保存してください。
- PowerShell 7 の JSON 読み込みは末尾カンマを許容するため、末尾カンマは 5.1 でだけ構文エラーになります。
- シーケンス図やガントチャートのように、段と列の格子に乗らない図には向きません。

## ライセンス

MIT
