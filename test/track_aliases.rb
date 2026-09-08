require 'tmpdir'

module Makoto
  # 同じ曲だが表記が違うものの表（#123）。
  class TrackAliasesTest < TestCase
    def with_table(entries)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, TrackAliases::FILE), entries.to_yaml) if entries
        yield TrackAliases.new(dir)
      end
    end

    def entry(*names)
      return {'names' => names, 'noticed' => Date.new(2026, 9, 7), 'reason' => 'テスト'}
    end

    # ⚠ **表は無くてもよい**（あとから足せる）。
    def test_is_empty_without_a_file
      with_table(nil) do |subject|
        assert_true(subject.empty?)
        assert_empty(subject.table)
        assert_nil(subject.key_for('なにか'))
      end
    end

    # ⚠ **先頭が代表**（🔴 **鍵になるだけで、曲名は変えない**）。
    def test_the_first_name_is_the_key
      with_table([entry('五匹の子ぶたとチャールストン', 'ごひきのこぶたとチャールストン')]) do |subject|
        canonical = TrackImporter.normalize('五匹の子ぶたとチャールストン')

        assert_equal(
          canonical,
          subject.key_for(TrackImporter.normalize('ごひきのこぶたとチャールストン')),
        )
        # ⚠ **代表そのものは表に入れない**（自分を自分に写しても意味が無い）。
        assert_nil(subject.key_for(canonical))
      end
    end

    # ⚠⚠ **突き合わせは正規化した後。**🔴 **半角/全角や `♪` の有無は表に書かなくてよい**
    # （`TrackImporter::NOISE` が先に吸収する）。
    def test_matching_happens_after_normalization
      with_table([entry('五匹の子ぶたとチャールストン', 'ごひきのこぶたとチャールストン')]) do |subject|
        assert_equal(
          TrackImporter.normalize('五匹の子ぶたとチャールストン'),
          subject.key_for(TrackImporter.normalize('♪ごひきのこぶたと　チャールストン♪')),
        )
      end
    end

    # ⚠ **3 つ以上でも寄る**（同じ曲に表記が 3 通りあることはありうる）。
    def test_folds_more_than_two
      with_table([entry('あ', 'い', 'う')]) do |subject|
        assert_equal(TrackImporter.normalize('あ'), subject.key_for(TrackImporter.normalize('う')))
        assert_equal(3, subject.keys.size)
      end
    end

    # 🔴 **`names` が 1 つだけの行は何もしない**ので、⚠⚠ **書いたのに効いていないことに
    # 気づけない形になる。**⚠ **黙って素通ししない。**
    def test_a_single_name_is_an_error
      with_table([entry('五匹の子ぶたとチャールストン')]) do |subject|
        assert_raise(Ginseng::ValidateError) {subject.groups}
      end
    end

    # ⚠ **壊れた YAML も黙って素通ししない。**
    def test_broken_yaml_is_an_error
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, TrackAliases::FILE), "- names: [\n")

        assert_raise(Ginseng::ValidateError) {TrackAliases.new(dir).groups}
      end
    end

    # 🔴 **配っている表がそのまま読めること**（⚠ **`seed/` に置いたものが壊れていない**）。
    def test_the_shipped_table_loads
      subject = TrackAliases.new

      assert_false(subject.empty?)
      subject.groups.each {|names| assert_operator(names.size, :>=, 2)}
    end
  end
end
