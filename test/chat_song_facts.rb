module Makoto
  class ChatSongFactsTest < TestCase
    def setup
      super
      add_track(2001, 'HEART GOES ON', '池田彩&工藤真由', '2010-07-07')
      add_track(2002, 'HEART GOES ON', '池田 彩 & 工藤真由', '2011-01-26')
      add_track(2003, 'HEART GOES ON(オリジナル・カラオケ)', 'ハートキャッチプリキュア!', '2010-07-07', kind: 'karaoke')
      @facts = ChatSongFacts.new(tracks: TrackRepository.new(track_db))
    end

    def add_track(id, name, artist, released, kind: 'vocal')
      track_db[:track].insert(id: id, name: name, artist_name: artist, kind: kind,
        release_date: Date.parse(released), dedupe_key: TrackImporter.dedupe_key(name))
    end

    def nowplaying(title, artist = nil)
      lines = ["Title: #{title}", 'Album: テストアルバム']
      lines.push("Artist: #{artist}") if artist
      lines.push('', 'ど定番')
      return lines.join("\n")
    end

    def prompt(*contents)
      return @facts.to_prompt(contents.map {|content| {role: 'user', content: content}})
    end

    # 🔴 **投稿の名義が欠けていたら、曲データの名義を渡し、欠けていると添える**（#668 の「HEART GOES ON」）。
    def test_a_missing_artist_is_completed_from_the_track_data
      text = prompt(nowplaying('HEART GOES ON', '工藤真由'), '真琴さん、HEART GOES ONはどうよ。')

      assert_include(text, '「HEART GOES ON」: 池田 彩 & 工藤真由（投稿の「Artist: 工藤真由」は名義が欠けている）')
      assert_include(text, '相手を正す口調にしない')
    end

    # ⚠ 同じ名義なら何も渡さない（空白や全角の違いは同じとみなす）。
    def test_nothing_is_passed_when_the_artist_matches
      assert_nil(prompt(nowplaying('HEART GOES ON', '池田彩 & 工藤真由')))
    end

    # ⚠ 投稿に名義が無ければ、曲データの名義が 1 つに決まるときだけ渡す（欠けているとは言わない）。
    def test_the_artist_is_passed_when_the_post_has_none
      text = prompt(nowplaying('HEART GOES ON'))

      assert_include(text, '「HEART GOES ON」: 池田 彩 & 工藤真由')
      assert_not_include(text, '欠けている')
    end

    # 🔴 **同じ曲名で名義が 2 つ以上なら断定しない**（同名の別の歌・別名義）。
    def test_ambiguous_artists_are_not_asserted
      assert_nil(prompt(nowplaying('しまうまグルグル')))
      assert_nil(prompt(nowplaying('しまうまグルグル', 'テスト')))
    end

    # ⚠ 名義が曲データのどれにも含まれなければ、表記の違いかもしれないので渡さない。
    def test_an_unrelated_artist_is_not_corrected
      assert_nil(prompt(nowplaying('HEART GOES ON', 'Aya Ikeda')))
    end

    # ⚠ 曲データに無い曲・歌でない曲（カラオケ・劇伴）は渡さない。
    def test_unknown_or_non_song_titles_are_skipped
      assert_nil(prompt(nowplaying('知らない曲', '誰か')))
      assert_nil(prompt(nowplaying('サブタイトル', 'テスト')))
      assert_nil(prompt('Title なしの投稿'))
    end

    # ⚠ 名義は同じ投稿の中の、その曲名の後ろのものだけを組にする。
    def test_artists_are_paired_with_the_title_before_them
      text = prompt("Title: テストのうた My True Love!\nTitle: HEART GOES ON\nArtist: 工藤真由")

      lines = text.lines.map(&:chomp)

      assert_include(lines, '- 「テストのうた My True Love!」: テスト歌手')
      assert_include(lines, '- 「HEART GOES ON」: 池田 彩 & 工藤真由（投稿の「Artist: 工藤真由」は名義が欠けている）')
    end

    # ⚠ 話し手が 2 人以上だと発言の頭に acct が付く（PR #688 の Codex の P2）。
    def test_titles_after_a_speaker_label_are_read
      text = prompt("bob: #{nowplaying('HEART GOES ON', '工藤真由')}")

      assert_include(text, '（投稿の「Artist: 工藤真由」は名義が欠けている）')
    end

    # ⚠ 同じ曲が何度か出たら、新しい投稿の名義で比べる（PR #688 の Codex の P2）。
    def test_the_newest_credit_is_compared
      complete = nowplaying('HEART GOES ON', '池田彩&工藤真由')
      missing = nowplaying('HEART GOES ON', '工藤真由')

      assert_include(prompt(complete, missing), '名義が欠けている')
      assert_nil(prompt(missing, complete))
    end

    # 🔴 **引けなくても返事は止めない**（nil を返すだけ）。
    def test_a_lookup_failure_returns_nil
      broken = Object.new
      def broken.dataset = raise(Sequel::DatabaseError, 'gone')
      facts = ChatSongFacts.new(tracks: broken)

      assert_nil(facts.to_prompt([{role: 'user', content: nowplaying('HEART GOES ON')}]))
    end
  end
end
