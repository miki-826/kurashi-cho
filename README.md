# くらし帳 / Household AI

Android向けの、やさしく続けられる家計簿アプリです。手入力、レシート読取、商品別カテゴリ、予算管理、検索、月次集計まで、日々の記録を端末内で完結できます。

## 主な機能

- 支出の手入力、編集、削除
- カメラまたはギャラリー画像の添付
- ML Kitによる端末内OCR
- 対応端末でのGemini Nano（ML Kit Prompt API）解析
- 任意設定のクラウドGemini APIによる高精度な画像解析
- 1枚の画像に写った複数レシート・請求・決済の個別抽出と一括保存
- 1件の購入内の商品・サービス明細、数量、金額、カテゴリ編集
- 月別予算、残額、カテゴリ別内訳
- 店名・商品名の履歴検索とカテゴリ絞り込み
- 月次記録と商品明細のMarkdown共有
- Drift / SQLiteによる端末内保存

## Gemini APIを使う

設定画面の「クラウドGemini API」で、Google AI Studioから取得したAPIキー、利用モデル、クラウド解析の有効・無効を設定できます。接続確認を行ってから画像を読み取ると、複数費用の抽出を利用できます。

APIキーはOSの暗号化ストレージに保存します。ただし、配布されたモバイルアプリ内のキーを完全に秘匿することはできません。個人利用の制限付きキーを使い、課金・割り当てをGoogle側で管理してください。クラウド解析を有効にした場合だけ、選択した画像と端末内OCR文字列をGoogle Gemini APIへ送信します。無効時は従来どおり端末内処理だけを利用します。

## 開発

```bash
flutter pub get
flutter run
```

Windowsで日本語を含むパスからAPK生成に失敗する場合は、一時的にASCIIパスのジャンクションまたはドライブへ割り当ててビルドしてください。

```powershell
subst R: "C:\path\to\household_ai"
Set-Location R:\
flutter build apk --debug
subst R: /D
```

生成済みAPKは `build/app/outputs/flutter-apk/` に出力されます。配布版はGitHub Releasesからダウンロードできます。
