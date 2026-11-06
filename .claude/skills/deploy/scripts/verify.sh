#!/usr/bin/env bash
# 再起動のあとの確認（deploy 4.）。⚠ 読むだけ。
#
#   .claude/skills/deploy/scripts/verify.sh <ホスト>
#
# 見るもの: 常駐の status（revision・jobs）・直近の起動の登録ログ（枠の名前 7 行）・heartbeat の版・
# drop-in が無いこと・監視の口 3 本。
# 🔴 jobs の本数だけを見ない。名前が出るのは登録ログだけ（#237 の Codex の P1）。
# shellcheck disable=SC2029 # ホスト名・パス・時刻は手元で展開して渡す（意図どおり）
set -u
host=${1:?ホストを指定する（bydo / rubicon）}
status=0
out=$(ssh -o ConnectTimeout=10 "$host" 'sudo -u deploy -i bash -s' 2>&1 <<'SH'
cd ~/repos/makoto2 || exit 1
echo "checkout $(git log -1 --format=%h) $(git rev-parse --abbrev-ref HEAD)"
st=$(bin/makoto status 2>&1)
echo "status-exit $?"
printf '%s\n' "$st" | grep -v DEPRECATION
SH
) || status=1
echo "$out" | grep -v '^status-exit '
# 🔴 status の error 行と終了コードを捨てない（#559）。⚠ warning（終了コード 2）は ⚠ を出すだけ。
code=$(echo "$out" | sed -n 's/^status-exit \([0-9]*\)$/\1/p')
if echo "$out" | grep -q '^error: ' || [ "${code:-1}" = 1 ]; then
  echo "🔴 makoto status が error を返した（終了コード ${code:-?}・上の error: 行）"
  status=1
elif echo "$out" | grep -q '^warning: ' || [ "$code" = 2 ]; then
  echo "⚠ makoto status が warning を返した（上の warning: 行）"
fi
log=$(mktemp)
trap 'rm -f "$log"' EXIT
echo "== 登録ログ（直近の起動）"
since=$(ssh "$host" "systemctl show makoto2 -p ActiveEnterTimestamp --value")
ssh "$host" "sudo journalctl _SYSTEMD_UNIT=makoto2.service --since '$since' -o cat --no-pager" > "$log" 2>/dev/null
grep -o '{"scheduler":"register"[^}]*}' "$log" | sed -n 's/.*"post":"\([^"]*\)".*/  \1/p'
grep -o '{"scheduler":"heartbeat"[^}]*}' "$log" | tail -1
count=$(grep -c '"scheduler":"register"' "$log")
if [ "$count" -eq 0 ]; then
  echo "🔴 起動のあとの登録ログが無い（まだ上がっていない・ログの形が変わった）"
  status=1
fi
echo "== systemd"
dropin=$(ssh "$host" 'systemctl show makoto2 -p DropInPaths --value')
ssh "$host" 'systemctl show makoto2 -p ActiveEnterTimestamp -p NRestarts' | tr '\n' ' '
echo
if [ -n "$dropin" ]; then
  echo "🔴 drop-in が残っている: $dropin（リハーサルの撤収漏れ → #174）"
  status=1
fi
echo "== 監視の口"
for path in /healthz /healthz/posting /healthz/orphans; do
  code=$(ssh "$host" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4567$path")
  echo "  $path $code"
  [ "$code" = 200 ] || status=1
done
exit $status
