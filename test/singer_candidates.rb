module Makoto
  class SingerCandidatesTest < TestCase
    SINGERS = ['五條真由美', 'キュア・カルテット', '宮本佳那子', '池田彩', '工藤真由'].freeze
    GIRLS = [
      {'precure_name' => 'キュアブロッサム', 'human_name' => '花咲 つぼみ'},
      {'precure_name' => 'キュアソード', 'human_name' => '剣崎 真琴'},
    ].freeze

    def setup
      super
      @next_id = 3000
    end

    def add_track(name, artist, kind: 'vocal')
      @next_id += 1
      track_db[:track].insert(id: @next_id, name: name, artist_name: artist, kind: kind,
        release_date: Date.parse('2026-01-01'), dedupe_key: TrackImporter.dedupe_key(name))
    end

    # ⚠ テストの曲データには前から入っている行があるので、足した名前だけを見る。
    def mine(items, names)
      return items.select {|item| names.include?(item.name)}
    end

    def subject
      return SingerCandidates.new(tracks: TrackRepository.new(track_db), singers: SINGERS, girls: GIRLS)
    end

    # 🔴 **辞書に当たる名前は出さず、当たらない名前を曲数の多い順に出す**（#565）。
    def test_exec_lists_names_missing_from_the_dictionary
      add_track('うた 1', '五條真由美・高橋秀幸')
      add_track('うた 2', '高橋秀幸')
      add_track('うた 3', '新人 歌手 & 池田 彩')
      # ⚠ 同じ名義の同じ曲は 1 回（盤違いで水増ししない）。⚠ 歌でない曲は見ない。
      add_track('うた 2', '高橋秀幸')
      add_track('うた 4', '劇伴の人', kind: 'bgm')
      # ⚠ 同じ曲の名義の書き方違い・同じ名義に 2 度書かれた名前も 1 回（#727）。
      add_track('うた 1', '高橋秀幸/五條真由美, 高橋秀幸 & 五條 真由美')
      candidates = mine(subject.exec, ['高橋秀幸', '新人歌手', '劇伴の人', '五條真由美', '池田彩'])

      assert_equal([['高橋秀幸', 2], ['新人歌手', 1]], candidates.map {|item| [item.name, item.count]})
      assert_equal('うた 1', candidates.first.example)
    end

    # ⚠ **括弧の中は割らず、辞書の名前も消さない**。⚠ コーラス区画は落とす。⚠ 長い名前（グループ）から消す。
    def test_names_of_keeps_brackets
      assert_equal(['剣崎真琴(CV:宮本佳那子)'], subject.names_of('剣崎真琴(CV:宮本佳那子)'))
      assert_equal([], subject.names_of('キュア・カルテット(五條真由美・池田彩)'))
      assert_equal([], subject.names_of('工藤真由 コーラス:高橋秀幸'))
      assert_equal(['キュアミラクル(CV:高橋李依)', 'キュアマジカル(CV:堀江由衣)'],
        subject.names_of('キュアミラクル(CV:高橋李依)、キュアマジカル(CV:堀江由衣)'))
      # ⚠ 空白が詰まっても `with` / `feat.` で割る（#727）。
      assert_equal(['ヤング', 'フレッシュ'], subject.names_of('五條真由美 with ヤング・フレッシュ'))
      assert_equal(['ハミィ(CV:三石琴乃)'], subject.names_of('工藤真由&池田彩withハミィ(CV:三石琴乃)'))
      assert_equal(['新人歌手'], subject.names_of('池田彩 feat. 新人 歌手'))
    end

    # 作品名・キャラクター名義（括弧つき・`/girls` の名前）・それ以外の候補に分ける。
    def test_kind_of
      assert_equal('title', subject.kind_of('ひろがるスカイ!プリキュア'))
      assert_equal('title', subject.kind_of('映画キミとアイドル'))
      assert_equal('character', subject.kind_of('キュアミラクル(CV:高橋李依)'))
      assert_equal('character', subject.kind_of('つぼみ'))
      assert_equal('character', subject.kind_of('キュアソード'))
      assert_equal('character', subject.kind_of('剣崎真琴'))
      assert_equal('candidate', subject.kind_of('高橋秀幸'))
    end

    # ⚠ 候補 → キャラクター名義 → 作品名の順。
    def test_exec_orders_by_kind
      add_track('うた 1', 'ひろがるスカイ!プリキュア')
      add_track('うた 2', 'つぼみ')
      add_track('うた 3', '高橋秀幸')

      kinds = mine(subject.exec, ['ひろがるスカイ!プリキュア', 'つぼみ', '高橋秀幸']).map(&:kind)

      assert_equal(['candidate', 'character', 'title'], kinds)
    end
  end
end
