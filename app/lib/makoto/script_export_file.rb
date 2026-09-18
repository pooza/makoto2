module Makoto
  # 原稿の書き出し先（#273・`makoto message export --out`）。
  #
  # 🔴 **原稿の正本は private の `makoto-scripts`**（#224）で、⚠⚠ **このリポジトリは public。**
  # 手順は makoto2 のチェックアウトから `../makoto-scripts/morning.yaml` へ書く形なので、
  # ⚠ **`../` を 1 つ落とすだけで作業ツリーの直下に原稿が落ち、次の `git add -A` で載る。**
  # 🔴 **クラスのコメントに書いた不変条件を、ここで強制する。**
  class ScriptExportFile
    attr_reader :path

    def initialize(value, force: false)
      @value = value
      @force = force
      @path = resolve(value)
    end

    # 🔴 **0600 で書く。**⚠⚠ **`File.write` は umask 任せ（`bydo` / `rubicon` では 0644）で、
    # しかも既にあるファイルの mode を変えない**ので、**`--force` で上書きしても緩いまま残る**
    # → `chmod` も当てる。⚠ **存在の確認と作成を 1 手にする**（`EXCL`・TOCTOU を作らない）。
    # ⚠ **`NOFOLLOW` は、解決した後に残るリンク（行き先の無いもの）を辿って作らせないため。**
    def write(text)
      flags = File::WRONLY | File::CREAT | File::NOFOLLOW
      flags |= @force ? File::TRUNC : File::EXCL
      File.open(path, flags, 0o600) do |file|
        file.chmod(0o600)
        file.write(text)
      end
    end

    private

    # ⚠ **シンボリックリンクを解いてから比べる**（`File.expand_path` は辿らない）。
    # ⚠ **親ディレクトリが無ければ `realpath` が `ENOENT` で落ちる**（どのみち書けない）。
    def resolve(value)
      expanded = File.expand_path(value)
      path = File.join(File.realpath(File.dirname(expanded)), File.basename(expanded))
      path = File.realpath(path) if File.exist?(path)
      root = File.realpath(Environment.dir)
      if path == root || path.start_with?("#{root}/")
        raise Ginseng::ValidateError,
          "#{value} はこのリポジトリ（#{root}）の中です。原稿は public な作業ツリーへ書き出せません"
      end
      return path
    end
  end
end
