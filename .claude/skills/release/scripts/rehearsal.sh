#!/usr/bin/env bash
# 当日通しリハーサル（release 4.）。🔴 bydo 専用（本番では回さない）。
#
#   .claude/skills/release/scripts/rehearsal.sh arm '2027-11-04 11:58:00 +0900' [scale]
#   .claude/skills/release/scripts/rehearsal.sh report <開始の時刻>   # 例 '2026-11-05 10:00'
#   .claude/skills/release/scripts/rehearsal.sh disarm
#
# arm:    drop-in を置き → daemon-reload → 🔴 restart の前に Environment を見せて止まる。
#         出発時刻が切れていなければ、そのあと restart を叩く（ここでは叩かない）。
# report: 常駐のユニットだけで絞って makoto rehearsal report に流す（CLI の行を混ぜない → #165）。
# disarm: drop-in を消し → daemon-reload → restart → systemd が持っている値と status を見る（#174）。
#         🔴 ls は撤収の証拠にならない（自動再起動はユニットを読み直さない）。
#
# ⚠ 値は引用符で囲む（systemd の Environment= は空白で区切るので、素で書くと時刻が落ちる）。
# shellcheck disable=SC2029 # ホスト名・パス・時刻は手元で展開して渡す（意図どおり）
set -u
host=bydo
dir=/etc/systemd/system/makoto2.service.d
case "${1:-}" in
  arm)
    start=${2:?出発時刻を指定する（例 '2027-11-04 11:58:00 +0900'）}
    scale=${3:-10}
    # 🔴 形を丸ごと検査する（#561）。⚠ drop-in の Environment= にそのまま書くので、`"` や改行が
    # 混ざると unit に指令を足せる。日付・時:分（秒・時差は省ける）だけを通す。
    if ! [[ "$start" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}(:[0-9]{2})?(\ [+-][0-9]{4})?$ ]]; then
      echo "🔴 出発時刻の形が違う（'$start'・例 '2027-11-04 11:58:00 +0900'）"
      exit 1
    fi
    # 🔴 上限は常駐と同じ `TimeTravel::MAX_SCALE` から引く（#580）。⚠⚠ 範囲の外を drop-in に書くと、
    # 常駐は `ConfigError` で起動に落ち、`Restart=always` のもとで落ち続ける。⚠ 数字をここに
    # 二重に書かない（上限は実測から引き直すもので、片方だけ動く）。
    max=$(sed -n 's/^ *MAX_SCALE = \([0-9][0-9]*\)$/\1/p' "$(dirname "$0")/../../../../app/lib/makoto/time_travel.rb")
    if [ -z "$max" ]; then
      echo "🔴 MAX_SCALE が読めない（time_travel.rb の形が変わった）"
      exit 1
    fi
    if ! [[ "$scale" =~ ^[1-9][0-9]*$ ]] || [ "$scale" -gt "$max" ]; then
      echo "🔴 倍率は 1〜$max の整数で（'$scale'・上限は実測から引いた値 → TimeTravel::MAX_SCALE）"
      exit 1
    fi
    printf '[Service]\nEnvironment="MAKOTO_FAKE_TIME=%s"\nEnvironment=MAKOTO_TIME_SCALE=%s\n' "$start" "$scale" |
      ssh "$host" "sudo mkdir -p $dir && sudo tee $dir/rehearsal.conf > /dev/null && sudo systemctl daemon-reload"
    ssh "$host" 'systemctl show makoto2 -p Environment'
    echo "⚠ 出発時刻が「$start」のまま渡っていることを確かめてから: ssh $host sudo systemctl restart makoto2"
    ;;
  report)
    since=${2:?開始の時刻を指定する}
    # 🔴 arm と同じ強さで形を検査する（#580）。⚠ リモートのシェル文字列に埋め込むので、`'` を
    # 含む値を通すと bydo 上でコマンドが走る。日付と時:分（秒は省ける）だけを通す。
    if ! [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(\ [0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]]; then
      echo "🔴 開始の時刻の形が違う（'$since'・例 '2026-11-05 10:00'）"
      exit 1
    fi
    ssh "$host" "sudo journalctl _SYSTEMD_UNIT=makoto2.service SYSLOG_IDENTIFIER=makoto2 --since '$since' -o cat --no-pager |
      sudo -u deploy -i bash -c 'cd ~/repos/makoto2 && bin/makoto rehearsal report'"
    ;;
  disarm)
    # 🔴 どこかで失敗したら撤収したと言わない（ssh が落ちて値が空でも緑に見えないように）。
    if ! ssh "$host" "sudo rm -rf $dir && sudo systemctl daemon-reload && sudo systemctl restart makoto2"; then
      echo "🔴 drop-in の削除か再起動に失敗した。撤収していない"
      exit 1
    fi
    sleep 15
    if ! env=$(ssh "$host" 'systemctl show makoto2 -p Environment -p DropInPaths') || [ -z "$env" ]; then
      echo "🔴 systemd の値が読めない。撤収を確かめられていない"
      exit 1
    fi
    echo "$env"
    if ! status=$(ssh "$host" 'sudo -u deploy -i bash -c "cd ~/repos/makoto2 && bin/makoto status"' 2>/dev/null); then
      echo "🔴 makoto status が失敗した（常駐が上がっていない・ssh が落ちた）"
      exit 1
    fi
    printf '%s\n' "$status" | grep -v DEPRECATION | head -3
    if printf '%s' "$env" | grep -q 'MAKOTO_FAKE_TIME\|MAKOTO_TIME_SCALE' || printf '%s' "$env" | grep -q 'DropInPaths=.'; then
      echo "🔴 騙した時刻か drop-in が systemd に残っている"
      exit 1
    fi
    if printf '%s' "$status" | grep -q 'time travel'; then
      echo "🔴 常駐がまだ騙した時刻に居る"
      exit 1
    fi
    echo "✅ 撤収した（drop-in なし・騙した時刻なし・status に time travel なし）"
    ;;
  *)
    sed -n '2,15p' "$0"
    exit 2
    ;;
esac
