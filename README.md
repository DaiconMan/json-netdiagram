# json-netdiagram

生成AIにネットワーク構成図の **JSON** を書かせ、PowerShell で **PNG** に描画するツールです。
描画の前に図の崩れを検証し、NG なら生成AIにそのまま貼れる修正依頼文を作ります。

- Windows 標準の機能だけで動きます（Windows PowerShell 5.1 / PowerShell 7、追加インストール不要）
- 座標は生成AIに決めさせません。`layer`（行）と `col`（列）だけを決めさせ、配置とサイズはスクリプト側で計算します
- 線は直線のほか、1 台から多数へ分かれる構成向けに「くし形」（`"route": "bus"`）で引けます（例: スイッチ配下の AP 20 台）

## ファイル

| ファイル | 内容 |
|---|---|
| `prompt.txt` | 生成AIに貼る依頼文（スキーマとルール入り） |
| `render.ps1` | JSON を検証して PNG に描画する |

## 使い方

1. `prompt.txt` の【構成】欄を書き換えて、全文を生成AI（ChatGPT、Claude、Copilot など）に貼ります。
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
.\render.ps1 diagram.json -Out net.png -Font "Yu Gothic UI"
```

実行ポリシーで止まる場合は、`powershell -ExecutionPolicy Bypass -File .\render.ps1 -FromClipboard` で実行してください。

## 終了コード

| コード | 意味 |
|---|---|
| 0 | OK（`diagram.png` を出力） |
| 1 | 検証 NG（`diagram_debug.png` に赤枠） |
| 2 | JSON の構文・スキーマ不正 |

## 検証する項目

- JSON の構文、必須キー、id の重複、存在しない id の参照
- ノード同士の重なり、ノードのキャンバス外へのはみ出し
- 線がほかのノードを貫通していないか
- 線ラベルとノード・タイトル・グループ名の重なり、線ラベルがグループの枠線にかかっていないか
- グループ名に線がかかっていないか（グループ名は枠の上辺に置き、線が横切るときは自動で下辺に移します）
- グループの枠にメンバー以外のノードが入っていないか、グループ同士の枠が重なっていないか（入れ子は可）
- フォントに無い文字（豆腐になる文字）

## 線の引き方（route）

| 値 | 引き方 | 向いている場面 |
|---|---|---|
| `straight`（既定） | ノード同士を直線で結ぶ | 上流から下流への 1 対 1、1 対 2 程度の接続 |
| `bus` | 親の真下に下ろし、子の行のすぐ上を横に通して、各子へ下ろす | 1 台から 3 台以上へ分かれる接続 |

`bus` の子が多いときは、`layer` を分けて複数の段に並べます。幹線は親の真下を通るので、途中の段では親と同じ `col` を空けておきます。
VLAN などで子を分けたいときは、VLAN ごとに段を分けて `group` で囲むと見やすくなります。

## 補足

- 文字の描画と計測は System.Drawing、豆腐の判定は WPF のグリフ情報を使っています。
- フォントは Meiryo UI → Meiryo → Yu Gothic UI → BIZ UDPGothic → MS UI Gothic → MS Gothic の順に、入っているものを使います。
- `render.ps1` は日本語を含むため、BOM 付き UTF-8 で保存しています（Windows PowerShell 5.1 での文字化け対策）。編集するときも BOM 付きのまま保存してください。
- PowerShell 7 の JSON 読み込みは末尾カンマを許容するため、末尾カンマは 5.1 でだけ構文エラーになります。

## ライセンス

MIT
