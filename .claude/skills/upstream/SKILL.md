---
name: upstream
description: makoto2 が使う上流 gem（ginseng-core / ginseng-fediverse / ginseng-style）の新しい版へ追随する。Release ノートの破壊的変更を読み、Gemfile のピンを上げ、テスト・lint・下見の前後比較・実機の配置で確かめて PR を出す。ユーザーが「上流に追随して」「ginseng を上げて」などと明示したときだけ使う。
disable-model-invocation: true
---

# 上流 gem（`ginseng-*`）への追随

⚠ **この手順の正本はこのファイル**（#539 で `docs/CLAUDE.md`「`ginseng-*` との往復」「追随した」の各節から手順の部分を移した）。**各回の追随の記録（何が変わり、何を畳んだか）は docs に残す。**
🔴 **PR を出すので明示呼び出しに限ってある。**
⚠ **上流への依頼の出し方と、上流の PR のレビュー（Codex の走査）はこのスキルの外**（`ginseng-style` の `docs/workflow.md` が正本）。🔴 **`ginseng-*` には専任のエージェントがいる。こちらは催促までで止め、上流をマージしない。**

## 1. どこまで上げるかを決める

```sh
grep -A4 'ginseng-' Gemfile.lock | grep -E 'remote|revision|tag'   # いまのピン
for r in ginseng-core ginseng-fediverse; do
  gh release list --repo "pooza/$r" --limit 30 --json tagName,publishedAt --jq '.[] | "\(.tagName) \(.publishedAt[0:10])"'
done
```

- ⚠ **既定は「その時点の最新」**（途中の版で止めても、次に上げるときに同じ破壊的変更を読み直すことになる）
- 🔴 **gem どうしの床を見る**（例: fediverse 4.0.0 は core 2.0.0 以上が必須）。片方だけ上げて解決が止まったら、もう片方も上げる
- 🔴 **11/1〜11/4 とその直前には上げない**（常駐の依存を動かす。→ docs「デプロイ・運用」）

## 2. Release ノートを読む（飛ばさない）

```sh
d=<スクラッチの置き場>
for t in <いまの版より後のタグ>; do gh release view "$t" --repo pooza/ginseng-core --json body --jq .body > "$d/core-$t.md"; done
```

- 🔴 **major の版は全部読む**（「⚠ この版で変わること」「破壊的変更」「利用側で確かめること」の節）。minor / patch も ⚠ / 🔴 の行は拾う
- 読んだら、**当たりうる口を makoto2 の中で grep する**（`app` `bin` `config` `test` `Rakefile`）。⚠ 上流が名指しした利用側の書き方（上書き点・定数・例外の文言）を使っていないか
- ⚠ 上流が「makoto2 では当たらない」と書いていても、自分で grep して確かめる

## 3. ピンを上げる

```sh
sed -i "s/tag: 'v<旧>'/tag: 'v<新>'/" Gemfile        # 🔴 タグで固定（ginseng-style だけは SHA）
bundle update --conservative ginseng-core ginseng-fediverse
git diff Gemfile.lock | grep -E '^[+-] '
```

- 🔴 **`--conservative` を付ける。**⚠ 付けないと依存先まで上がる（2026-11-05 に `facets` 3 → 4 が混ざった）。ほかの gem の版上げは別の PR にする
- ⚠ 増えた依存（例: `resolv`）は Release ノートの記載と合っているかを見る

## 4. 確かめる

```sh
bundle exec rake test
bundle exec rubocop
bundle exec rake config:lint
```

- 🔴 **落ちたテストは「なぜ落ちたか」まで読む。**⚠ 期待値を書き換えて通すのは、**上流の変更でテストの観測のほうがずれた**と説明できるときだけ（例: 上流の `run_stop` がシグナル 0 で在否を訊くようになり、`kill` の記録に 0 が混ざった → 0 を数えない）。説明をテストのコメントに残す
- 🔴 **下見の全文を前後で比べる**（`git stash` で前の版に戻して同じコマンドを流す）:

  ```sh
  bin/makoto live setlist --date=<次の 11/4> --mc --body --limit=160 > after.live
  bin/makoto morning preview --date=<日付> > after.morning
  ```

  ⚠ `song preview` は同じ版でも毎回変わる（乱数）ので比べない
- 🔴 **実機の配置で当たる変更は、実機を見る**（例: core 2.0.0 の `save_config` は `tmp` / `tmp/cache` が symlink だと起動で止まる → `stat -c '%F' tmp tmp/cache` を `bydo` と `rubicon` で）
- ⚠⚠ **「回避策を上流へ返した先で挙動が変わった」形を探す**（#198 / #199 / #257）。上流に寄りかかって消した守りが、新しい版でも同じ答えを返すか

## 5. PR を出す

- 題は `chore: ginseng-core <旧> → <新>・ginseng-fediverse <旧> → <新>（#n）`。本文に、読んだ major ごとの「makoto2 に当たるか」の表、テストを直したならその理由、下見の比較の結果を書く
- ⚠ 依存の版上げは常駐の挙動を変えうるので、**マージしたら [deploy スキル](../deploy/SKILL.md) で `bydo` に当てて確かめる**（ユーザーの指示で）
- 記録は `docs/CLAUDE.md` の「`ginseng-*` との往復」の下に `#### ✅ 追随した（YYYY-MM-DD・#n）` で（何が変わり、何を畳み、何を確かめたか）
- ⚠ 上流の Issue（makoto2 から出したもの）が閉じていなければ、そのことを makoto2 の Issue に書いて残す（例: #525 は上流 `ginseng-core#739` が open のまま）
