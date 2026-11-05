#!/usr/bin/env bash
# Codex（chatgpt-codex-connector[bot]）のレビューを 4 経路で走査する（同期 5.）。⚠ 読むだけ。
#
#   .claude/skills/sync/scripts/codex.sh <owner/repo> <PR 番号> ...
#
# 経路: pulls/N/reviews（本文）・pulls/N/comments（インライン）・issues/N/comments（要約）・issues/N/reactions（👍 / 👀）。
# 🔴 片付いたかの判定はインラインごとの「返信 ＋ 👍」。PR への 👍 は「ある巡が指摘なしで終わった」印で、
#    PR 全体が片付いた印ではない（→ docs/CLAUDE.md の同期 5.）。
set -u
bot='chatgpt-codex-connector[bot]'
repo=$1
shift
status=0
for n in "$@"; do
  echo "== $repo#$n"
  # ⚠ --paginate を落とさない（既定は 1 ページだけ）。
  comments=$(gh api --paginate "repos/$repo/pulls/$n/comments") || { echo '⚠ 走査に失敗した。結果を信用しないこと'; status=1; continue; }
  echo "$comments" | jq -s -r --arg bot "$bot" '
    add // [] | . as $all
    | map(select(.user.login == $bot and .in_reply_to_id == null))
    | if length == 0 then "  インライン: 0 件" else .[] |
      . as $c
      | ([$all[] | select(.in_reply_to_id == $c.id)] | length) as $replies
      | "  インライン \($c.id) \(if $replies > 0 then "返信あり" else "⚠ 未返信" end) 👍=\($c.reactions["+1"]) \($c.body | split("\n")[0] | .[0:80])"
    end'
  gh api --paginate "repos/$repo/issues/$n/comments" | jq -s -r --arg bot "$bot" '
    add // [] | map(select(.user.login == $bot)) | .[]
    | ((.body | capture("has_any_findings\":(?<f>[a-z]+)") | .f) // "?") as $f
    | "  要約 \(.created_at) findings=\($f)"'
  gh api --paginate "repos/$repo/pulls/$n/reviews" | jq -s -r --arg bot "$bot" '
    add // [] | map(select(.user.login == $bot)) | "  review 本文: \(length) 件"'
  gh api --paginate "repos/$repo/issues/$n/reactions" | jq -s -r --arg bot "$bot" '
    add // [] | map(select(.user.login == $bot)) | .[] | "  PR へのリアクション \(.content) \(.created_at)"'
done
exit $status
