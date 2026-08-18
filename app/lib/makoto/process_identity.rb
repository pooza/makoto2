module Makoto
  # 「その pid は本当に MAKOTO の常駐か」を `/proc/{pid}/cmdline` の argv から確かめる規則。
  #
  # ⚠⚠ **`Process.kill(0, pid)` は「その番号のプロセスが在るか」しか見ない。**
  # ⚠ **pid は再利用される**ので、pid ファイルが実体とずれると**無関係なプロセスを
  # 常駐だと答える**（#80 の黄 6。⚠ 実測で `sleep 300` の pid を書くと
  # `running (PID 354866)` と表示された）。
  #
  # 🔴 **孤児の判定（#61）は最初からここまで見ているのに、自分の pid ファイルだけが
  # 素通しだった。**⚠⚠ **同じ規則を 2 箇所で使うために切り出した**ので、
  # **孤児の側だけが厳しくて自分の側が緩い、という食い違いが起きない。**
  module ProcessIdentity
    PROC_DIR = '/proc'.freeze
    # ⚠ 常駐の実体。`bin/makoto` の CLI とは別物なので、これで CLI 自身は拾わない。
    PROCESS_NAME = 'makoto_daemon.rb'.freeze

    # ⚠ インタプリタのオプション（`ruby --yjit bin/makoto_daemon.rb start`）。
    # **読み飛ばす対象**であって、スクリプトの位置を固定で決め打たない。
    OPTION_PREFIX = '-'.freeze

    # ⚠⚠ **「次の要素がスクリプト」とみなしてよいのは、先頭が Ruby のときだけ**
    # （#80 の緑 6）。⚠ **これが無いと `vim app/lib/makoto/daemon/makoto_daemon.rb` を
    # 常駐と報告する**（実測）。**編集・閲覧・grep はどれもこの形。**
    INTERPRETER_PATTERN = /\Aruby[\d.]*\z/

    # ⚠ **常駐にならないサブコマンド**（#80 の緑 6）。⚠⚠ **`bin/makoto_daemon.rb status`
    # は即座に終わる**ので、これを孤児と数えると**監視を叩くたびに誤報しうる。**
    #
    # ⚠ **`restart` は除かない** — **fork した子は argv を引き継ぐ**ので、
    # ⚠⚠ **本物の常駐が `restart` のまま走っている**（実機の形）。
    TRANSIENT_COMMANDS = ['stop', 'status'].freeze

    module_function

    # その pid は常駐か。
    #
    # ⚠⚠ **確かめられないときは true に倒す**（`/proc` の無い環境・`EACCES`・
    # 列挙してから消えたプロセス）。⚠ **呼ぶ側は既に `Process.kill(0)` で在ることを
    # 確かめている**ので、⚠⚠ **「確かめられない」を「死んでいる」に倒すと、健全な
    # 常駐が二重に起動する。**⚠ **黙って素通しにもならない** — 読めた argv が
    # 別物なら false を返す。
    def daemon_pid?(pid, proc_dir: PROC_DIR)
      return false unless pid
      return true unless File.directory?(proc_dir)
      found = argv(File.join(proc_dir, pid.to_s))
      return true if found.empty?
      return daemon?(found)
    rescue SystemCallError
      return true
    end

    # その argv は常駐のものか。
    #
    # ⚠ **cmdline の部分一致にしない**（#61）。⚠⚠ **argv にこの文字列を含むだけの
    # 無関係なプロセスを孤児と報告する**（実測）。**踏みやすいのは運用側の経路** —
    # 復旧のラッパースクリプト・デプロイのシェル・`pgrep` のワンライナー。
    # **docs が「復旧コマンドはラッパースクリプトに逃がす」と決めている以上、
    # この形は運用に組み込まれる。**
    def daemon?(argv)
      return script_candidates(argv).any? do |script, command|
        next false unless File.basename(script.to_s) == PROCESS_NAME
        next false if TRANSIENT_COMMANDS.include?(command.to_s)
        next true
      end
    end

    # 「実行されているスクリプト」になりうる argv の要素。⚠ **2 つだけ。**
    #
    # 1. **argv の 0 番目** — ⚠⚠ 実機の常駐は **`bin/makoto_daemon.rb start` という
    #    1 要素**になっている（bundler 経由の起動で `$0` が書き換わる。2026-08-15 に
    #    bydo の `/proc` を実測）。⚠ **要素をそのまま突き合わせると本物を取り逃がす**
    #    ので、要素の中を空白で割ってから見る
    # 2. **インタプリタのオプションを読み飛ばした次の 1 つ** — `ruby bin/makoto_daemon.rb`
    #    のほか、⚠ **`ruby --yjit bin/makoto_daemon.rb` や `ruby -W0 …` でも見つける**
    #    （位置で決め打つと取り逃がす。#68 のレビュー指摘）
    #
    # ⚠⚠ **オプションでない要素は 1 つ目で打ち切る。**`bash -lc 'bundle exec
    # bin/makoto_daemon.rb restart'` の第 3 要素は**スクリプトではなくシェルへの文字列**
    # なので、そこまで見ると部分一致に戻る（先頭の語は `bundle` なので落ちる）。
    #
    # 🔴 **2 つ目を見るのは、先頭が Ruby のときだけ**（#80 の緑 6）。⚠⚠ **これが
    # 無いと `vim app/lib/makoto/daemon/makoto_daemon.rb` が常駐になる**（実測）。
    # ⚠ **編集・閲覧・grep はどれもこの形**なので、開発中は恒常的に踏む。
    #
    # ⚠ **返すのは「スクリプト」と「その次の語」の組**（→ `TRANSIENT_COMMANDS`）。
    def script_candidates(argv)
      words = argv.first.to_s.split
      candidates = [[words.first, words[1]]]
      return candidates unless interpreter?(words.first)
      # ⚠ インタプリタ越しは 2 通り — argv の 0 番目の中に続く形と、要素が分かれる形。
      rest = words.size > 1 ? words.drop(1) : argv.drop(1).flat_map {|arg| arg.to_s.split}
      rest = rest.reject {|arg| arg.start_with?(OPTION_PREFIX)}
      return candidates.push([rest.first, rest[1]])
    end

    def interpreter?(value)
      return File.basename(value.to_s).match?(INTERPRETER_PATTERN)
    end

    # ⚠ `/proc/{pid}/cmdline` は NUL 区切り。**末尾に NUL の詰め物が付く**ので空要素を落とす。
    # ⚠ `ENOENT` / `ESRCH` は無視する。**列挙してから消えるプロセスがある。**
    # ⚠⚠ **`EACCES` は握らない**（読めなかったことを呼ぶ側に伝える → #54）。
    def argv(dir)
      return File.read(File.join(dir, 'cmdline')).split("\0").reject(&:empty?)
    rescue Errno::ENOENT, Errno::ESRCH
      return []
    end
  end
end
