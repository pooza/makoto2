module Makoto
  # プリキュアの情報を引く口（[cure-api](https://github.com/pooza/cure-api)）。
  #
  # ⚠⚠ **rubicure を直接使わない。**プリキュアの基礎情報の正本は cure-api 側にある
  # （→ docs/CLAUDE.md「プリキュアの情報は cure-api から REST で取る」）。
  # ⚠ **足りない情報を MAKOTO 側に抱え込まない。**シリーズ名や歌手名をこのリポジトリに
  # 書き始めたら、正本が 2 つに割れた合図。
  #
  # ## ⚠ 落ちてもライブは止めない
  #
  # ライブ（#13）のゲストコーナーはこれを引くが、⚠⚠ **cure-api が落ちていても
  # 8 時間の進行そのものは走らせる**（→ docs/CLAUDE.md「LLM が落ちてもライブは走る」と
  # 同じ判断）。⚠ **ただし黙って素通ししない** — 引けなければカバーを置かずに警告を残す
  # （「静かに出ない」を避ける）。
  #
  # ## 🔴 引けたものは写しに残す（#88）
  #
  # ⚠⚠ **「落ちてもライブは止めない」だけでは足りなかった。**⚠ **`LiveProgram` は
  # その日の並びを最初の枠で 1 回だけ組む**ので、**12:02 の一瞬の不通が「その日は
  # ゲストコーナーが無い」に直結する。**⚠⚠ **しかも再起動を挟むと、生きていた日と
  # 落ちていた日で並びそのものが変わる**（実測で 160 枠中 127 枠の中身が違った）。
  #
  # **そこで、引けた名義をローカルの写しに残し、引けないときはそれを使う。**
  #
  # - ⚠ **これは状態ではなく写し。**消しても次に引けば作り直せるので、
  #   **「進行位置は状態ではなく計算で出す」とは衝突しない**（`Heartbeat` と同じ扱い）
  # - ⚠⚠ **黙って古いものを使わない。**写しから読んだことは `stale?` で外に出す
  # - ⚠ **写しを使い始めたら、その process では引き直さない。**⚠⚠ **ライブの最中に
  #   cure-api が復活して並びが変わるほうが困る**（→ 上記「同じ日付なら同じ並び」）
  class CureApiService
    include Package

    PREFIX = '/cure_api'.freeze

    # 引けなかったあと、次に試すまでの間隔（秒）。
    #
    # ⚠⚠ **失敗を焼き付けない**（#88・#80 の黄 4）。⚠ **旧実装は `||=` だったので、
    # 失敗時の `[]` も真になり、常駐を入れ直すまで二度と引き直さなかった。**
    #
    # ⚠ **かといって毎回引き直せない** — `singer?` は `pool` の `select` の中で
    # ⚠⚠ **曲の数だけ呼ばれる**（実データで 800 回超）。**間を置く。**
    RETRY_INTERVAL = 60

    CACHE_NAME = 'cure_api_singers.json'.freeze

    # ⚠ **名義を「何人並んでいるか」で割る区切り**（#65・`credit_count`）。
    # ⚠⚠ **`split_artist` の区切りとは別物**（あちらは括弧も `CV:` も割る）。
    #
    # ⚠ **`with` / `feat.` は入れる。**実データの名義 15 件に出て、⚠⚠ **全件が
    # 「単独の歌手 ＋ もう 1 組」の区切り**（`うちやえゆか with Splash Stars`）。
    # 入れないと**この形が単独名義として重みを 2 倍もらう**（#67 のレビュー指摘）。
    # ⚠ **`\b` は使わない。**`normalize` が空白を落とすので `うちやえゆかwithSplashStars`
    # になり、⚠⚠ **`\bwith\b` は非 ASCII の隣で効かない**（`and` と同じ罠）。
    #
    # ⚠ **`and` は入れない。**実データに `and` を含む名義は 0 件。⚠ **`with` と違って
    # 出てこないので、書いても「対応済み」に見えるだけ害になる。**
    CREDIT_SEPARATOR = %r{[,、&＆/／]|with|feat\.?}i

    # ⚠⚠ **中黒は「2 つ以上あるときだけ」区切りとみなす**（#65・#67 のレビュー指摘）。
    #
    # ⚠ **中黒は名前の中にも入る** — `キュア・カルテット` `ヤング・フレッシュ`
    # `ルールー・アムール` はどれも 1 組。無条件に割ると**単独名義が複数名義に化ける。**
    # ⚠ 一方 `Machico・吉武千颯・北川理恵・ローラ・…`（8 人）は**割らないと単独名義**
    # として重みを 2 倍もらう。実データではこの 2 つが中黒の数で分かれる。
    #
    # ⚠ **括弧を落としてから数える。**`キュア・レインボーズ(五條真由美・うちやえゆか・…)`
    # は括弧の中に中黒が並ぶだけで、名義そのものは 1 組。
    #
    # ⚠ **例外は `ピョートル・イリイチ・チャイコフスキー`**（1 人だが中黒 2 つ）。
    # ⚠⚠ **カバーの母集合はプリキュア歌手に絞ってあるので届かない**（実測）。
    MIDDLE_DOT = '・'.freeze
    MIDDLE_DOT_THRESHOLD = 2

    # 取得したものはプロセスの寿命だけ持つ。⚠ **8 時間のライブ中に何度も引かない**
    # （並びは日付ごとに 1 回組むだけだが、キャッシュが無いと再起動のたびに引く）。
    def initialize(http: nil)
      @http = http
      @cache = {}
      @stale = false
      @failed_at = nil
    end

    # ⚠ **いま返している名義が、ローカルの写しから来ているか**（#88）。
    # ⚠⚠ **カバーを置く側が警告を出すために見る**（黙って古いもので組まない）。
    def stale?
      return @stale
    end

    def url
      return config["#{PREFIX}/url"].to_s
    end

    # プリキュア歌手の名義（グループの構成員を含む）。
    #
    # ⚠ **グループ名だけでなく構成員も返す。**曲データの名義は
    # 「キュア・レインボーズ(五條真由美・…)」のように**構成員が並んで書かれる**ことが
    # あり、グループ名だけでは照合できない。
    #
    # @return [Array<String>] 正規化済みの名義。⚠ 引けなければ空配列
    #
    # ⚠⚠ **`||=` にしない**（#88）。**失敗時の `[]` も真**なので、⚠ **数秒の不通が
    # 常駐の寿命ぶん続く形**だった。⚠⚠ **引けたときと、写しで代われたときだけ覚える。**
    def singer_names
      return @cache[:singer_names] if @cache[:singer_names]
      # ⚠ 失敗した直後は引き直さない（`select` の中から曲の数だけ呼ばれる）。
      return [] unless retryable?
      names = fetch_singer_names
      return @cache[:singer_names] = store_singer_names(names) if names.any?
      @failed_at = Time.now
      return fall_back_to_stored
    end

    # その名義がプリキュア歌手か。
    #
    # ⚠⚠ **曲データの `artist_name` は 1 名義とは限らない。**「吉武千颯&礒部花凜/北川理恵/
    # 駒形友梨/Machico/宮本佳那子、映画プリキュアオールスターズF」のような文字列なので、
    # ⚠ **区切って、どれか 1 つでも歌手辞書に居れば真**とする。
    #
    # ⚠ 「歌っちゃ王」（カラオケレーベル）や「オルゴール」盤は辞書に居ないので、
    # この判定だけで落ちる（→ 曲データの `kind` の誤分類とは別の防御）。
    #
    # ⚠⚠ **分割する前に、名義そのものを辞書と突き合わせる。**辞書には
    # 「キュア・カルテット」のように**区切り文字を名前の中に持つ名義**が居るので
    # （66 名義中 6 つ）、いきなり割ると「キュア」＋「カルテット」になって
    # **どちらも辞書に無い＝落ちる。**⚠ 実データで 9 行が落ちていた。
    def singer?(artist_name)
      names = singer_names
      return false if names.empty?
      return true if names.include?(self.class.normalize(artist_name))
      return split_artist(artist_name).intersect?(names)
    end

    # ⚠ 引けたか。**カバーを置かない判断と、警告を出す判断に使う。**
    def available?
      return singer_names.any?
    end

    # 名義に何人が並んでいるか（#65）。⚠ **`split_artist` は使えない。**
    # あちらは**歌手辞書に当てるために**括弧も `CV:` も割るので、
    # ⚠⚠ **`パンプルル姫(CV:花澤香菜)` が 2 人、`秋元こまち(CV:永野 愛) & 水無月かれん
    # (CV:前田 愛)` が 4 人**になる。**当てる規則と数える規則は別物。**
    #
    # ⚠ **括弧の中は数えない**（CV 表記・コーラス表記は「もう 1 人」ではない）。
    def self.credit_count(value)
      return [credit_parts(value).size, 1].max
    end

    # 名義を突き合わせられる形にしたもの。⚠ **正規化（NFKC ＋ 空白除去）＋ 括弧落とし**
    # までで、**割らない。**
    #
    # ⚠⚠ **括弧の中は名義として扱わない**（`CV:` 表記・コーラス表記は「もう 1 人」では
    # ない → `credit_count`）。⚠ **`グロッサムX2(CV:宮本佳那子)` は `グロッサムX2`。**
    #
    # 🔴 **「含むか」を見たいだけの側はここで足りる**（→ `LiveProgram#own_credit?`）。
    # ⚠⚠ **区切り位置は「含むか」の答えを変えない**ので、⚠ **中黒を区切りにするか
    # という一番あやふやな判断を巻き込まずに済む**（→ `credit_separator`）。
    #
    # 🔴 **括弧の種類は `split_artist` と揃える**（Codex の指摘・PR #156）。
    # ⚠⚠ **`花奈〈CV: 宮本 佳那子〉` は実在の書き方**（→ `split_artist` のコメント）で、
    # ⚠ **山括弧を落とさないと `own_credit?` が中の人を拾って役名義ごと隠す** —
    # **「括弧の中は見ない」という約束が書き方しだいで破れる。**
    # ⚠ **いまの曲データに `〈〉` は 0 件**だが、**取り込み直しで増えうる。**
    BRACKETS = /[(（\[「『〈][^)）\]」』〉]*[)）\]」』〉]/

    def self.credit_text(value)
      return normalize(value).gsub(BRACKETS, '')
    end

    # 名義を「並んでいる 1 組ずつ」に割ったもの。⚠ **正規化済み**（→ `credit_text`）。
    #
    # 🔴 **割り方の規則を 2 つ持たない**ためにここに置く。⚠⚠ **割る必要があるのは
    # 「何人並んでいるか」を数える側だけ**（#65 の `credit_count`）。
    def self.credit_parts(value)
      stripped = credit_text(value)
      return stripped.split(credit_separator(stripped)).map(&:strip).compact_blank
    end

    # ⚠ **中黒を区切りに足すかは名義ごとに決まる**（→ 上記 `MIDDLE_DOT`）。
    def self.credit_separator(stripped)
      return CREDIT_SEPARATOR if stripped.count(MIDDLE_DOT) < MIDDLE_DOT_THRESHOLD
      return Regexp.union(CREDIT_SEPARATOR, MIDDLE_DOT)
    end

    # ⚠ 表記の揺れを落とす。cure-api 側の `Datasource.normalize_name` と同じ規則
    # （NFKC ＋ 空白除去）。⚠⚠ **スプレッドシートは「宮本 佳那子」、iTunes 由来の
    # 曲データは「宮本佳那子」。**ここが噛み合わないと 1 件も一致しない。
    def self.normalize(value)
      return value.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]/, '')
    end

    # 引けた名義の写しの置き場。⚠ **テストは別のファイルに落とす**（`Heartbeat` と
    # 同じ理由 — 稼働中の写しをテストが書き換えると、当日の並びが変わる）。
    def self.cache_path
      name = Environment.test? ? 'cure_api_singers_test.json' : CACHE_NAME
      return File.join(Environment.dir, 'tmp/cache', name)
    end

    private

    def retryable?
      return true unless @failed_at
      return (Time.now - @failed_at) > RETRY_INTERVAL
    end

    # ⚠ **引けたら写しを更新する。**⚠⚠ **書けなくても引けた名義はそのまま返す**
    # （写しは保険であって、これが無いと動かないものではない）。
    def store_singer_names(names)
      path = self.class.cache_path
      temp = "#{path}.#{Process.pid}.tmp"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(temp, names.to_json)
      # ⚠ **差し替えで書く**（切り詰めてから書くと、その隙に読んだ側が壊れた JSON を
      # 掴む → `Heartbeat#write` と同じ）。
      File.rename(temp, path)
      return names
    rescue SystemCallError => e
      logger.error(cure_api: 'singers', error: e)
      return names
    ensure
      FileUtils.rm_f(temp) if temp
    end

    # ⚠ **引けなければ写しで代わる**（#88）。⚠⚠ **黙って代わらない。**
    def fall_back_to_stored
      names = stored_singer_names
      return [] if names.empty?
      @stale = true
      logger.warn(cure_api: 'singers', message: 'falling back to the stored copy',
        count: names.size)
      # ⚠⚠ **ここは覚える。**⚠ **ライブの最中に cure-api が復活して並びが変わるほうが
      # 困る**（→ 上記「写しを使い始めたら、その process では引き直さない」）。
      return @cache[:singer_names] = names
    end

    def stored_singer_names
      path = self.class.cache_path
      return [] unless File.file?(path)
      names = JSON.parse(File.read(path))
      return Array(names).map(&:to_s).reject(&:empty?)
    rescue JSON::ParserError, SystemCallError, TypeError
      return []
    end

    def http
      return @http ||= HTTP.new
    end

    # 曲データの名義を個々の名前に割る。
    #
    # ⚠ 括弧の中身も拾う。「キュア・レインボーズ(五條真由美・うちやえゆか・…)」は
    # **グループ名が辞書に在る**が、⚠ 「花奈〈CV: 宮本 佳那子〉」のように
    # **中の人だけが辞書に居る**書き方もある。
    def split_artist(value)
      parts = self.class.normalize(value).split(%r{[,、&＆/／・〜~()（）\[\]「」『』〈〉]|with|feat\.?|CV:?}i)
      return parts.map(&:strip).reject(&:empty?)
    end

    def fetch_singer_names
      raise Ginseng::ConfigError, "#{PREFIX}/url is missing" if url.empty?
      records = http.get("#{url}/singers").parsed_response
      return report_malformed(records) unless valid_records?(records)
      names = records.flat_map do |record|
        [record['name'], *members_of(record)]
      end
      return names.map {|name| self.class.normalize(name)}.reject(&:empty?).uniq
    rescue => e
      # ⚠⚠ **落ちてもライブは止めない。**ただし黙らない（→ 上記）。
      logger.error(cure_api: 'singers', error: e)
      return []
    end

    # 🔴 **200 で非 JSON が返る形を弾く**（#105）。
    #
    # ⚠⚠ **`String#[]` は部分一致で substring を返す。**⚠ 応答が HTML でも
    # `Array(records)` は `[本文]` になり、`record['name']` が **`"name"` の 4 文字**を
    # 返す（`<meta name=...>` でまず含まれる）。🔴 **`["name"]` という名義リストが
    # 成立し、`available?` が真になる。**
    #
    # ⚠ **運用側からは「cure-api は生きているのに 1 件も一致しない」と見える**ので
    # 誤診しやすい（⚠⚠ 実際には 11/4 のゲストコーナー 8 曲がゼロになる）。
    #
    # ⚠ **nginx の 502 / 503 は `GatewayError` になるので対象外。**踏むのは
    # **前段が 200 で非 JSON を返す形**（メンテページ・vhost の誤ルーティング）。
    def valid_records?(records)
      return false unless records.is_a?(Array)
      return records.all?(Hash)
    end

    # ⚠⚠ **汚れた写しを焼き付けない**（#88 の保険を守る）。`store_singer_names` は
    # 「引けた」ときだけ走るので、⚠ **ここで `[]` に倒せば写しは更新されない。**
    #
    # ⚠ **本文は載せない**（HTML が丸ごとログに出る）。⚠⚠ **型だけで十分に区別できる。**
    def report_malformed(records)
      logger.warn(cure_api: 'singers', message: 'unexpected response shape',
        type: records.class.to_s)
      return []
    end

    # ⚠ **`members` は配列のときだけ拾う。**Hash が来ると `Array()` が組の配列を返し、
    # ⚠⚠ **`[["name", "..."]]` のような値が名義に混ざる。**
    def members_of(record)
      members = record['members']
      return members.is_a?(Array) ? members : []
    end
  end
end
