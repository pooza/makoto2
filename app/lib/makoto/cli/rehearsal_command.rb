module Makoto
  # リハーサルの結果を読む口（#110）。⚠ **投稿はしない。**
  #
  # ⚠⚠ **ログを標準入力から受ける。**⚠ **journald に依存しない形にしておく** —
  # **箱ごとにログの置き場が違っても、同じ集計が使える**（そして 11/4 当日の本番の
  # ログをそのまま流し込める）。
  #
  # ```
  # journalctl _SYSTEMD_UNIT=makoto2.service SYSLOG_IDENTIFIER=makoto2 \
  #   --since '01:20' --until '02:10' -o cat | makoto rehearsal report
  # ```
  #
  # 🔴 **常駐のユニットで絞る**（#165）。⚠⚠ **`bin/makoto` の CLI は常駐と同じ ident
  # （`makoto2`）でログを出す**ので、⚠ **`-t makoto2` だけで拾うと、リハーサル中に人が
  # 叩いた CLI の HTTP まで同じ入力に混ざる** — 🔴 **`red?` は `http_errors` を見るので、
  # CLI が 1 本 4xx を踏むだけで `exit 1`**（2026-08-22 に実際に踏んだ）。
  #
  # ⚠ **絞るのは journald の側で、この道具は journald に依存しない形のまま。**
  # ⚠⚠ **ログの行にプロセスを見分ける印を足す案は採らない** — 🔴 **ログの形を変えると
  # 「日付以外は全く同じ」が崩れる**（この道具の前提そのもの）。⚠ **journald は
  # どの行にも `_SYSTEMD_UNIT` を持っている**ので、**足さずに絞れる。**
  #
  # ⚠ **実測**（2026-09-19・`bydo`）— **手で叩いた CLI の行は `session-c437.scope`、
  # 常駐の行は `makoto2.service`。**同じ窓で **4 行 → 3 行**（CLI の `GET` が落ちた）。
  #
  # 🔴 **終了コードで赤を返す**（0 = 想定どおり / 1 = 赤あり）。⚠⚠ **毎リリース回す
  # ものなので、人が表を読まなくても落ちること**が要る。
  class RehearsalCommand < Thor
    include Package

    def self.exit_on_failure?
      return true
    end

    desc 'report [FILE]', 'リハーサルのログを集計する（省略時は標準入力）'
    long_desc <<~TEXT
      終了コード: 0 = 想定どおり / 1 = 赤あり

      赤になるもの（正本は RehearsalReport#red?）: 何も見ていない（枠が 0 / ハートビートが 0）／
      登録を見送った投稿／集計の受け皿に入らなかった error 行／枠あたりの exec 回数／重複投稿／
      投稿の失敗／HTTP の 4xx・5xx／履歴の通知の失敗／痕跡の書き込みの失敗／予算を超えた枠

      ⚠⚠ いちばん重要なのは「枠あたりの exec 回数」。#109 は 500 が出たから気づいたが、
      500 が出なくなったら逆に静かに壊れる（重複投稿する）ので、回数そのものを毎回数える。

      ⚠ 沈黙した枠は数えられない（本文が無いときの 1 行は debug → #114）。
    TEXT
    def report(path = nil)
      report = RehearsalReport.new(lines(path))
      puts report
      exit 1 if report.red?
    rescue Errno::ENOENT, Errno::EACCES => e
      warn "ログが読めませんでした: #{error_message(e)}"
      exit 1
    end

    private

    # ⚠ **行を溜めない。**⚠⚠ **8 時間 160 枠のログは 1 万行を超える**ので、
    # 列挙子のまま渡す（`RehearsalReport` は 1 行ずつ数える）。
    #
    # ⚠ **`File.foreach` はブロック無しなら列挙子を返し、読み終えたら閉じる。**
    # ⚠⚠ **`File.open(path).each_line` は開きっぱなしになる。**
    def lines(path)
      return $stdin.each_line if path.blank?
      return File.foreach(path)
    end
  end
end
