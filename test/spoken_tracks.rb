require 'tmpdir'

module Makoto
  # 歌ではなく語りのトラックの表（#298）。
  class SpokenTracksTest < TestCase
    def with_table(entries, aliases: nil)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, SpokenTracks::FILE), entries.to_yaml) if entries
        File.write(File.join(dir, TrackAliases::FILE), aliases.to_yaml) if aliases
        yield SpokenTracks.new(dir)
      end
    end

    def entry(name)
      return {'name' => name, 'noticed' => Date.new(2026, 9, 11), 'reason' => 'テスト'}
    end

    def track(name)
      return {name: name, dedupe_key: TrackImporter.dedupe_key(name)}
    end

    # ⚠ **表は無くてもよい**（あとから足せる）。
    def test_is_empty_without_a_file
      with_table(nil) do |subject|
        assert_true(subject.empty?)
        assert_false(subject.include?(track('ドラマ『テスト』')))
      end
    end

    # 🔴 **突き合わせは `dedupe_key`**（⚠ **盤違い・表記ゆれでも当たる**）。
    def test_matches_by_the_dedupe_key
      with_table([entry('ドラマ『テスト』')]) do |subject|
        assert_true(subject.include?(track('ドラマ『テスト』')))
        assert_true(subject.include?(track('ドラマ　『テスト』♪')))
        assert_false(subject.include?(track('しまうまグルグル')))
        assert_false(subject.include?(nil))
      end
    end

    # ⚠⚠ **別名表の後で比べる**（`track.dedupe_key` は別名表を当てた後の鍵）。
    def test_matches_after_the_aliases
      aliases = [{'names' => ['ドラマ『テスト』', 'どらま『てすと』'], 'reason' => 'テスト'}]

      with_table([entry('どらま『てすと』')], aliases: aliases) do |subject|
        assert_true(subject.include?({dedupe_key: TrackImporter.normalize('ドラマ『テスト』')}))
      end
    end

    # 🔴 **曲データに当たらない名前を返す**（書き間違い・配信終了の合図）。
    def test_unused_names
      with_table([entry('ドラマ『テスト』'), entry('そんなドラマは無い')]) do |subject|
        present = Set[TrackImporter.dedupe_key('ドラマ『テスト』')]

        assert_equal(['そんなドラマは無い'], subject.unused(present))
      end
    end

    # 🔴 **`name` の無い行は何にも当たらない**ので、⚠⚠ **黙って素通ししない。**
    def test_a_blank_name_is_an_error
      with_table([entry(''), entry('ドラマ『テスト』')]) do |subject|
        assert_raise(Ginseng::ValidateError) {subject.names}
      end
    end

    # ⚠ **行が Hash でなければ誤り**（`- ドラマ『テスト』` と書いてしまう形）。
    def test_a_bare_string_is_an_error
      with_table(['ドラマ『テスト』']) do |subject|
        assert_raise(Ginseng::ValidateError) {subject.names}
      end
    end

    # ⚠ **壊れた YAML も黙って素通ししない。**
    def test_broken_yaml_is_an_error
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, SpokenTracks::FILE), "- name: [\n")

        assert_raise(Ginseng::ValidateError) {SpokenTracks.new(dir).names}
      end
    end

    # 🔴 **配っている表がそのまま読め、全部が普段用の曲データに当たること**
    # （⚠ **当たらない行は「表に書いたのに効いていない」**）。
    def test_the_shipped_table_hits_the_daily_corpus
      subject = SpokenTracks.new
      path = File.join(Environment.dir, config['/track/dir'], TrackImporter::DAILY)
      present = JSON.parse(File.read(path), symbolize_names: true)
        .to_set {|row| TrackImporter.dedupe_key(row[:trackName])}

      assert_false(subject.empty?)
      assert_equal([], subject.unused(present))
    end
  end
end
