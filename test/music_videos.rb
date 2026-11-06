require 'tmpdir'

module Makoto
  # MV のある曲の表（#498）。
  class MusicVideosTest < TestCase
    URL = 'https://music.apple.com/jp/music-video/test/1312882764?uo=4'.freeze

    def with_table(entries, aliases: nil)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, MusicVideos::FILE), entries.to_yaml) if entries
        File.write(File.join(dir, TrackAliases::FILE), aliases.to_yaml) if aliases
        yield MusicVideos.new(dir)
      end
    end

    def entry(name, url: URL)
      return {'name' => name, 'url' => url, 'noticed' => Date.new(2026, 10, 5), 'reason' => 'テスト'}
    end

    def track(name)
      return {name: name, dedupe_key: TrackImporter.dedupe_key(name)}
    end

    # ⚠ **表は無くてもよい**（あとから足せる）。
    def test_is_empty_without_a_file
      with_table(nil) do |subject|
        assert_true(subject.empty?)
        assert_nil(subject.url_for(track('ねこざかなダンシング')))
      end
    end

    # 🔴 **突き合わせは `dedupe_key`**（⚠ **盤違い・表記ゆれでも当たる**）。
    def test_matches_by_the_dedupe_key
      with_table([entry('ねこざかなダンシング')]) do |subject|
        assert_equal(URL, subject.url_for(track('ねこざかなダンシング')))
        assert_equal(URL, subject.url_for(track('ねこざかな　ダンシング♪')))
        assert_nil(subject.url_for(track('ねこざかな体操')))
        assert_nil(subject.url_for(nil))
      end
    end

    # ⚠⚠ **別名表の後で比べる**（`track.dedupe_key` は別名表を当てた後の鍵）。
    def test_matches_after_the_aliases
      aliases = [{'names' => ['ねこざかなダンシング', 'ネコザカナダンシング'], 'reason' => 'テスト'}]

      with_table([entry('ネコザカナダンシング')], aliases: aliases) do |subject|
        assert_equal(URL, subject.url_for({dedupe_key: TrackImporter.normalize('ねこざかなダンシング')}))
      end
    end

    # 🔴 **曲データに当たらない名前を返す**（書き間違い・配信終了の合図）。
    def test_unused_names
      with_table([entry('ねこざかなダンシング'), entry('そんな曲は無い')]) do |subject|
        present = Set[TrackImporter.dedupe_key('ねこざかなダンシング')]

        assert_equal(['そんな曲は無い'], subject.unused(present))
      end
    end

    # 🔴 **取り込みと同じ許可リスト**（#283）。⚠⚠ **手で書いた表だけ素通しにしない。**
    def test_a_url_outside_the_allowed_hosts_is_an_error
      ['http://music.apple.com/jp/music-video/test/1', 'https://example.test/mv/1', ''].each do |url|
        with_table([entry('ねこざかなダンシング', url: url)]) do |subject|
          assert_raise(Ginseng::ValidateError, url) {subject.entries}
        end
      end
    end

    # 🔴 **`name` の無い行は何にも当たらない**ので、⚠⚠ **黙って素通ししない。**
    def test_a_blank_name_is_an_error
      with_table([entry(''), entry('ねこざかなダンシング')]) do |subject|
        assert_raise(Ginseng::ValidateError) {subject.entries}
      end
    end

    # ⚠ **行が Hash でなければ誤り**（`- ねこざかなダンシング` と書いてしまう形）。
    def test_a_bare_string_is_an_error
      with_table(['ねこざかなダンシング']) do |subject|
        assert_raise(Ginseng::ValidateError) {subject.entries}
      end
    end

    # ⚠ **壊れた YAML も黙って素通ししない。**
    def test_broken_yaml_is_an_error
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, MusicVideos::FILE), "- name: [\n")

        assert_raise(Ginseng::ValidateError) {MusicVideos.new(dir).entries}
      end
    end

    # 🔴 **リポジトリの表が読めて、曲データの音源に当たること**（#498 の実データ）。
    def test_the_seed_table_matches_the_daily_tracks
      dir = File.join(Environment.dir, 'seed')
      subject = MusicVideos.new(dir)
      daily = JSON.parse(File.read(File.join(dir, TrackImporter::DAILY)))
      present = daily.to_set {|row| TrackImporter.dedupe_key(row['trackName'])}

      assert_false(subject.empty?)
      assert_empty(subject.unused(present))
    end
  end
end
