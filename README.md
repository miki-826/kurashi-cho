# くらし帳 / Household AI

端末内にだけ記録を残す、Android向けの家計簿アプリです。余白のある帳面と小さな庭をモチーフに、数字だけではなく暮らしの流れを穏やかに見渡せる体験を目指しています。

## できること

- 支出の手動記録、編集、削除
- カメラまたはギャラリーの画像を添えた記録
- 端末内OCRによる店舗・日付・合計候補の読み取り
- 対応端末でのGemini Nano（ML Kit Prompt API）による購入明細の整理
- 商品・サービス明細ごとの数量、金額、カテゴリ編集
- 月ごとの予算、残額、カテゴリ別の内訳
- 商品名を含む履歴検索とカテゴリ絞り込み
- 月次記録と商品明細をMarkdownファイルとして共有・保存
- Drift / SQLiteを正本とする端末内保存

写真、OCR文字列、家計データは独自サーバーへ送信しません。Gemini Nanoが非対応・未準備・解析失敗の場合も、OCR候補を引き継いだ手入力、閲覧、集計、出力は利用できます。旧バージョンのSharedPreferencesデータは初回起動時にSQLiteへ自動移行します。

Gemini NanoはAndroidのAICoreとML Kit Prompt APIが利用可能な端末で動作します。設定画面で `AVAILABLE / DOWNLOADABLE / UNAVAILABLE` に対応した日本語表示を確認でき、必要な場合はモデルを準備できます。

## 起動

```bash
flutter pub get
flutter run
```

Windowsで日本語を含むパスからAPKを生成する場合は、短いASCIIパスへ一時的に割り当てると安定します。

```powershell
subst R: "C:\path\to\household_ai"
Set-Location R:\
flutter build apk --debug
subst R: /D
```

生成済みAPKは `build/app/outputs/flutter-apk/` にあります。配布版はGitHub Releasesからダウンロードできます。
