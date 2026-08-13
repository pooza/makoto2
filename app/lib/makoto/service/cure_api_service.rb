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
  class CureApiService
    include Package

    PREFIX = '/cure_api'.freeze

    # 取得したものはプロセスの寿命だけ持つ。⚠ **8 時間のライブ中に何度も引かない**
    # （並びは日付ごとに 1 回組むだけだが、キャッシュが無いと再起動のたびに引く）。
    def initialize(http: nil)
      @http = http
      @cache = {}
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
    def singer_names
      return @cache[:singer_names] ||= fetch_singer_names
    end

    # その名義がプリキュア歌手か。
    #
    # ⚠⚠ **曲データの `artist_name` は 1 名義とは限らない。**「吉武千颯&礒部花凜/北川理恵/
    # 駒形友梨/Machico/宮本佳那子、映画プリキュアオールスターズF」のような文字列なので、
    # ⚠ **区切って、どれか 1 つでも歌手辞書に居れば真**とする。
    #
    # ⚠ 「歌っちゃ王」（カラオケレーベル）や「オルゴール」盤は辞書に居ないので、
    # この判定だけで落ちる（→ #56 の誤分類とは別の防御）。
    def singer?(artist_name)
      names = singer_names
      return false if names.empty?
      return split_artist(artist_name).intersect?(names)
    end

    # ⚠ 引けたか。**カバーを置かない判断と、警告を出す判断に使う。**
    def available?
      return singer_names.any?
    end

    # ⚠ 表記の揺れを落とす。cure-api 側の `Datasource.normalize_name` と同じ規則
    # （NFKC ＋ 空白除去）。⚠⚠ **スプレッドシートは「宮本 佳那子」、iTunes 由来の
    # 曲データは「宮本佳那子」。**ここが噛み合わないと 1 件も一致しない。
    def self.normalize(value)
      return value.to_s.unicode_normalize(:nfkc).gsub(/[[:space:]]/, '')
    end

    private

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
      names = Array(records).flat_map do |record|
        [record['name'], *Array(record['members'])]
      end
      return names.map {|name| self.class.normalize(name)}.reject(&:empty?).uniq
    rescue => e
      # ⚠⚠ **落ちてもライブは止めない。**ただし黙らない（→ 上記）。
      logger.error(cure_api: 'singers', error: e)
      return []
    end
  end
end
