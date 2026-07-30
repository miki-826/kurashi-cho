# くらし帳 / Household AI

端末内にだけ記録を残す、Android向けの家計簿アプリです。余白のある帳面と小さな庭をモチーフに、数字だけではなく暮らしの流れを穏やかに見渡せる体験を目指しています。

## できること

- 支出の手動記録、編集、削除
- カメラまたはギャラリーの画像を添えた記録
- 月ごとの予算、残額、カテゴリ別の内訳
- 履歴のキーワード検索とカテゴリ絞り込み
- 月次記録をMarkdownとしてクリップボードへ出力
- SharedPreferencesを使った端末内保存

写真は手入力を補助するために添付でき、アプリから外部サーバーへ送信しません。端末内AIによるOCR/Gemini Nanoの自動抽出は、別途ネイティブ連携を追加する拡張ポイントとして残しています。

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

生成済みのデバッグAPKは `build/app/outputs/flutter-apk/app-debug.apk` にあります。
