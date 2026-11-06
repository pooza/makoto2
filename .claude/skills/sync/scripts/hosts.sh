#!/usr/bin/env bash
# 実機の 3 点を見る（同期 3.）。置いてあるもの（チェックアウト）・動いているもの（常駐が起動時に読んだ revision）・
# その版が持つ枠の本数。⚠ 読むだけ（再起動もレシピの適用もしない）。
#
#   .claude/skills/sync/scripts/hosts.sh [ホスト ...]   # 既定は bydo rubicon
#
# ⚠ ホスト名・アドレスはこのリポジトリに書かない（public）。~/.ssh/config の Host 行から引く。
set -u
hosts=("$@")
[ ${#hosts[@]} -eq 0 ] && hosts=(bydo rubicon)
status=0
for name in "${hosts[@]}"; do
  echo "== $name"
  # ⚠ Host 行は FQDN（bydo.b-shock.local）なので前方一致で引く。完全一致に「直さない」（→ docs/CLAUDE.md）。
  fqdn=$(awk -v h="$name" 'tolower($1) == "host" && index($2, h) == 1 {print $2; exit}' ~/.ssh/config 2>/dev/null)
  if [ -z "$fqdn" ]; then
    echo "⚠ ~/.ssh/config に $name の Host 行が無い。判定できない"
    status=1
    continue
  fi
  # ⚠ 名前が引けないのは「届かない」ではない。自宅 LAN 宛ての VPN を繋いでからもう一度。
  if ! getent hosts "$fqdn" > /dev/null; then
    echo "⚠ $fqdn の名前が引けない。VPN を繋いでから、もう一度回す"
    status=1
    continue
  fi
  out=$(ssh -o ConnectTimeout=10 "$name" 'sudo -u deploy -i bash -s' 2>&1 <<'SH'
cd ~/repos/makoto2 || exit 1
st=$(bin/makoto status 2>&1)
echo "status-exit $?"
printf '%s\n' "$st" | grep -v DEPRECATION | grep -Ev '^(error|warning): ' | head -2
printf '%s\n' "$st" | grep -E '^(error|warning): '
echo "checkout $(git log -1 --format=%h) $(git rev-parse --abbrev-ref HEAD)"
SH
)
  echo "$out" | grep -v '^status-exit '
  # 🔴 DropInPaths が空であること（リハーサルの drop-in の撤収漏れ → #174）。
  ssh -o ConnectTimeout=10 "$name" 'systemctl show makoto2 -p ActiveEnterTimestamp -p NRestarts -p DropInPaths' 2>&1 | tr '\n' ' '
  echo
  # 🔴 status の error 行と終了コードを捨てない（#559）。⚠ 生きていても投稿の見送り・heartbeat の古さは
  # error で出る。warning（終了コード 2）は ⚠ を出すだけで、判定は落とさない。
  code=$(echo "$out" | sed -n 's/^status-exit \([0-9]*\)$/\1/p')
  if echo "$out" | grep -q '^error: ' || [ "${code:-1}" = 1 ]; then
    echo "🔴 makoto status が error を返した（終了コード ${code:-?}・上の error: 行）"
    status=1
  elif echo "$out" | grep -q '^warning: ' || [ "$code" = 2 ]; then
    echo "⚠ makoto status が warning を返した（上の warning: 行）"
  fi
  revision=$(echo "$out" | sed -n 's/.*revision \([0-9a-f]*\)).*/\1/p')
  checkout=$(echo "$out" | sed -n 's/^checkout \([0-9a-f]*\) .*/\1/p')
  if [ -z "$revision" ] || [ -z "$checkout" ]; then
    echo "⚠ revision かチェックアウトが読めない（常駐が止まっている・status の形が変わった）"
    status=1
  elif [ "${checkout#"$revision"}" = "$checkout" ] && [ "${revision#"$checkout"}" = "$revision" ]; then
    echo "⚠ 動いているもの（$revision）と置いてあるもの（$checkout）が違う。次に見るのは差分の中身"
    echo "  git log $revision..$checkout --name-only  # docs/ tools/ README.md の外が動いていたら restart まで"
    status=1
  else
    echo "✅ 動いているもの ＝ 置いてあるもの（$checkout）"
  fi
done
exit $status
