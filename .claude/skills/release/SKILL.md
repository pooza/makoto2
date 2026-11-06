---
name: release
description: makoto2 のリリース手順 1.〜11.（箱の消化・リリース前レビュー・セキュリティ・ステージング検証と当日通しリハーサル・バンプ・develop → main の PR・タグとリリース・本番デプロイ・箱を空にする・記録）。ユーザーが「リリースしましょう」などと明示したときだけ使う。
disable-model-invocation: true
---

# リリース手順

⚠ **この手順の正本はこのファイル**（#536 で `docs/CLAUDE.md`「通常リリース手順」から移した）。**「なぜそうするか」と踏んだ記録は `docs/CLAUDE.md` の同名の節と各リリースの節に残してある。**ブランチ戦略・バージョニング・マイルストーンの運用は手順ではなく文脈なので docs のまま。
🔴 **外向きの操作（マージ・タグ・Release・本番デプロイ）を含む。**各段はユーザーの指示を確かめてから進める。
🔴 **通したかはリリース PR のチェック（[`release.md`](../../../.github/PULL_REQUEST_TEMPLATE/release.md)）に残す**（#197）。⚠ チェックを付けるのは、このリリースの差分に対して実施したものだけ。

## マージの前

1. **箱の Issue をすべて消化する。**⚠ 例外は「本番に当てるまで閉じられない」Issue だけ（コードと `bydo` での確認まで済み、残りが `rubicon` への適用だけ）— open のまま「実作業済み・本番はデプロイで当てる」と書いて通し、9. で当てて閉じる
2. **リリース前レビュー**: [release-review スキル](../release-review/SKILL.md)。⚠⚠ **ここで止まる。**`release-review` は明示呼び出しなので、ユーザーに `/release-review` を頼み、赤が片付くまで先へ進まない
3. **セキュリティレビュー**:

   ```sh
   bundle exec bundle-audit check --update
   gh api repos/pooza/makoto2/dependabot/alerts -X GET -f state=open --jq 'length'
   ```

   ⚠ Dependabot だけでは足りない（`open-pull-requests-limit: 0`）。⚠ 週次の `audit.yml` は `main` に入るまで動かない — **新しく足した `schedule` のワークフローは、マージ後に `workflow_dispatch` で緑 / 赤 / 赤の 3 回を当てる**（→ docs）
4. **ステージング検証**（省略不可）: [deploy スキル](../deploy/SKILL.md) で `bydo` に当て、変えた機能を実機で踏む（下見・異常系を作って踏ませる → docs「モンキーテストは実機で当てる」）。

   **当日通しリハーサル**は 🔴 **11/4 の並び（本編・カバー・MC）や投稿の経路を動かす版で回す**（⚠ 11/4 を過ぎてコードの変更が無い版は省いてよい — v0.8.1 の前例）:

   🔴 **ただし 11/4 の後のシーズンオフは、次のシーズンが近くなるまで回さない**（2026-11-06・オーナー判断。v0.9.0 は並びが動く版だが省いた）。⚠ **並びを動かした版を省いたら、次に回すときは最後に回した版からの差分ぜんぶを相手にする**（下見 `bin/makoto live setlist --date=<次の 11/4> --mc` は版ごとに回してよい）

   ```sh
   .claude/skills/release/scripts/rehearsal.sh arm '<次の 11/4> 11:58:00 +0900' 10
   #   → 出発時刻が切れていないのを見てから: ssh bydo sudo systemctl restart makoto2
   .claude/skills/release/scripts/rehearsal.sh report '<restart した時刻>'   # 終了コード 0 で緑
   .claude/skills/release/scripts/rehearsal.sh disarm                       # 🔴 live-close を見届けたらすぐ
   ```

   - 🔴 **前回の通しの開始から 3 時間空ける**（投稿の制限が 300 本 / 3 時間・通し 1 回は約 162 本）
   - 🔴 **実況の時間と、`bydo` の日常の枠（`gate.sh bydo 50` で見る）に重ねない**。実況の窓は `bin/makoto song slot` の「実況の窓:」が正本（日曜 08:30〜・毎晩 20:00〜・水木 19:30〜・土 20:30〜 — 弱い窓も混む時間帯なので避ける・#466）
   - ⚠ **約 49 分**（scale 10）。終わりを待つ見張りは `"post":"live-close","slot"` で待つ（`"post":"live-close"` だけだと起動時の登録ログに当たる）
   - ⚠ 集計が緑でも、**ユーザーが目視する時間をとる**（読んで自然かは機械では見られない）
   - 記録は `docs/CLAUDE.md` の「N 回目の当日通しリハーサル」の節に（集計の出力・POST の実時間・撤収の確認）
5. **バージョンバンプ**を確かめる（`config/application.yaml` の `version`。着手時に済んでいるはず）
6. **リリース PR**（`develop` → `main`）:

   ```sh
   gh pr create --base main --head develop --template release.md --title "Release vX.Y.Z"
   gh pr view <番号> --json baseRefName
   ```

   ⚠ 常設の PR を着手時に開いてあるなら、それを使う（テンプレートは開いた時点で入れ、進むたびにチェックを付ける）。題や本文の直しは `gh api -X PATCH`（`gh pr edit` は落ちる）
7. **CI の緑を確かめてマージ**（コードが同じでも CI の結果を踏む）。🔴 待つのは**いまの head の SHA の run**（前の run の緑を拾わない）:

   ```sh
   gh run list --branch develop --limit 3 --json headSha,status,conclusion
   ```

## マージの後

8. **タグとリリース**（名前はタグ名だけ — 「〜版」を付けない）:

   ```sh
   git fetch origin && git tag vX.Y.Z origin/main && git push origin vX.Y.Z
   gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file <リリースノート>
   ```

9. **本番へデプロイ**: [deploy スキル](../deploy/SKILL.md) で `rubicon` に当てる（時刻の門・実況の時間・本番の下見まで）。1. で残した「本番はデプロイで当てる」Issue はここで当てて閉じる。⚠ `0.9` は本番で `track import` が流れたあと `restart` まで
10. **箱を空にして閉じる** — その箱の Issue を 1 件残らず「クローズ」か「他の箱へ移動」にする。結果は Issue のコメントに書く（会話に置かない）。日付でしか確かめられないものは日付の箱へ。重みは:

    ```sh
    .claude/skills/sync/scripts/milestones.sh
    ```

    ⚠ マイルストーン API の `closed_issues` はリリース PR を含む。記録は Issue だけで数える
11. **リリース後の更新**: ① `docs/CLAUDE.md`（箱の表の行を「リリース済み」に・`### ✅ vX.Y.Z をリリースし、本番へ入れた` の節）② 公開ドキュメント（README）③ chubo2 の `docs/infra-history.md`（main へ直接）④ メモリの経過ログ ⑤ 節目の版（本番で新しい種類の投稿が始まる・ライブの前の最後の版など）なら `docs/CLAUDE.md`「沿革」に 1 行（日付は JST・#527）

⚠ 送った黄・緑の受け皿（`0.x.1` / `0.x.2` の箱）の決まりは `docs/CLAUDE.md`「バージョニング」。
