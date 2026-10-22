## 変更内容

## 確認
- [ ] `pnpm typecheck`
- [ ] `pnpm test`
- [ ] `node --test tests/release/*.test.mjs`
- [ ] `pnpm test:macos`

## リリースPRのみ（staging → main）
- [ ] `native-release / build`（アプリビルド・パッケージ試験）成功
- [ ] stagingでまとめた変更の動作確認
- [ ] merge commitでマージ（squash/rebaseしない）

## 更新時の影響
Daemon・保存データ・既存ターミナルへの影響があれば記載。
