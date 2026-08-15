module Makoto
  class MessageSelectorTest < TestCase
    # 朝挨拶（#17）が使う想定の許可リスト。
    MORNING_TYPES = ['holiday', 'birthday', 'morning'].freeze

    def setup
      super
      @repository = MessageRepository.new(corpus_db)
    end

    def selector(types = MORNING_TYPES)
      return MessageSelector.new(types, repository: @repository, random: Random.new(20_261_104))
    end

    def jst(month, day, year: 2026)
      return Time.new(year, month, day, 7, 0, 0, '+09:00')
    end

    # ⚠⚠ #12 の完了条件。11/4 に birthday の原稿が選ばれること。
    # ⚠ 旧データの birthday は month / day を持たないので、日付の正本は
    # `/message/anniversary`。
    def test_birthday_is_selected_on_the_anniversary
      message = selector.find(jst(11, 4))

      assert_equal('birthday', message[:type])
      assert_equal(2006, message[:id])
    end

    # ⚠⚠ 記念日の type はその日以外では選ばれない。除かないと毎朝バースデーの
    # 原稿が出る。
    def test_birthday_is_not_selected_on_other_days
      Array.new(20) {|i| selector.find(jst(5, i + 1))}.each do |message|
        assert_not_equal('birthday', message[:type])
      end
    end

    # ⚠⚠ 季節指定を持つ birthday（実データに 4 件ある誤分類）は誕生日に使わない。
    # 11/4 に紅葉や梨の話が出てしまう。
    def test_seasoned_birthday_is_not_selected_on_the_anniversary
      assert_not_equal(2004, selector.find(jst(11, 4))[:id])
    end

    # 特定日（毎年）。元日は holiday の原稿で上書きする。
    def test_holiday_overrides_the_day
      message = selector.find(jst(1, 1))

      assert_equal(2003, message[:id])
      assert_equal('holiday', message[:type])
    end

    # ⚠ 段の順。**その年だけの原稿が、毎年の原稿より勝つ。**台本（#13 / #14）が
    # この段に入る。
    def test_year_specific_message_wins
      id = @repository.create(type: 'holiday', body: '2026 年だけの元日', year: 2026, month: 1, day: 1)

      assert_equal(id, selector.find(jst(1, 1))[:id])
      # ⚠ 翌年は毎年の原稿に戻る。
      assert_equal(2003, selector.find(jst(1, 1, year: 2027))[:id])
    end

    # 季節。7 月は夏の原稿。
    def test_season_is_used
      assert_equal(2002, selector.find(jst(7, 15))[:id])
    end

    # 季節の原稿が無い月は通年の原稿。
    def test_falls_back_to_undated
      assert_equal(2001, selector.find(jst(5, 15))[:id])
    end

    # ⚠⚠ 許可リストに無い type は、日付が一致しても選ばれない（ライブの台本を
    # 朝挨拶が横取りしない）。
    def test_types_are_a_whitelist
      @repository.create(type: 'live', body: 'ライブ開始！', year: 2026, month: 11, day: 4)
      message = selector.find(jst(11, 4))

      assert_not_equal('live', message[:type])
      assert_equal('live', selector(['live']).find(jst(11, 4))[:type])
    end

    # ⚠ 原稿が無ければ nil。**通常の生成にフォールバックする合図**であって、
    # 例外にしない。
    def test_returns_nil_without_any_message
      assert_nil(selector(['nothing']).find(jst(5, 15)))
      assert_nil(selector(['nothing']).call(jst(5, 15)))
    end

    # PostingJob の source としてそのまま渡せること（call が本文を返す）。
    def test_call_returns_the_body
      assert_equal(@repository.dataset[id: 2003][:body], selector.call(jst(1, 1)))
    end

    # ⚠ ホストの TZ ではなく /scheduler/timezone で日付を出すこと。UTC のホストで
    # 11/4 の朝を渡しても誕生日と判定されること。
    def test_date_comes_from_the_configured_timezone
      # 2026-11-03 22:00 UTC ＝ JST では 11/4 の 07:00。
      assert_equal('birthday', selector.find(Time.utc(2026, 11, 3, 22, 0))[:type])
      # ⚠ 11/4 15:00 UTC ＝ JST では 11/5。記念日から外れること。
      assert_not_equal('birthday', selector.find(Time.utc(2026, 11, 4, 15, 0))[:type])
    end

    # ⚠⚠ 許可リストが記念日の type だけのとき、記念日以外の日は**何も返さない**こと。
    # ⚠ 段 4 / 5 に空の許可リストを渡すと「絞り込まない」と解釈され、無関係な type の
    # 原稿を出してしまう（→ #46 の Codex 指摘）。
    def test_anniversary_only_selector_returns_nil_on_other_days
      assert_nil(selector(['birthday']).find(jst(5, 15)))
      assert_equal('birthday', selector(['birthday']).find(jst(11, 4))[:type])
    end

    # ⚠ 下見は日付をそのまま渡せること。時刻を作らせるとホストの TZ で 1 日ずれる。
    def test_accepts_a_date
      assert_equal('birthday', selector.find(Date.new(2026, 11, 4))[:type])
      assert_equal(2003, selector.find(Date.new(2026, 1, 1))[:id])
    end

    # ⚠ 11/1〜11/3 は予告（#14）、11/4 はライブ当日。**予告も記念日として登録する**
    # ことで、日付を持たない予告の原稿が段 5 に混ざらない（→ Announcement）。
    # ⚠⚠ **1 日に複数の type を持てる**（#13）。値は常に配列で返す。
    def test_anniversary_types_come_from_config
      expected = {
        '11-01' => ['announcement'],
        '11-02' => ['announcement'],
        '11-03' => ['announcement', 'live_eve'],
        '11-04' => ['birthday', 'live_open', 'live_mc', 'live_close'],
      }

      assert_equal(expected, selector.anniversary_types)
    end

    # ⚠ 設定に単数で書いても配列で返る（既存の書き方を壊さない）。
    def test_a_single_type_is_wrapped_in_an_array
      config['/message/anniversary/11-04'] = 'birthday'

      assert_equal(['birthday'], selector.anniversary_types['11-04'])
    end

    # ⚠⚠ **許可リストに無い記念日の type は、その日でも選ばれない。**11/4 には誕生日と
    # ライブの台本が同居するので、⚠ **朝挨拶がライブの台本を横取りしない**ことが要る。
    def test_anniversary_types_on_respects_the_allow_list
      assert_equal(['birthday'], selector(['birthday']).anniversary_types_on(Date.new(2026, 11, 4)))
      assert_equal(['live_mc'], selector(['live_mc']).anniversary_types_on(Date.new(2026, 11, 4)))
      assert_empty(selector(['birthday']).anniversary_types_on(Date.new(2026, 5, 15)))
    end

    # ⚠ 記念日として予約された type の全体。呼び出し側の登録漏れ検査に使う。
    def test_reserved_types_are_flattened
      assert_equal(['announcement', 'live_eve', 'birthday', 'live_open', 'live_mc', 'live_close'],
        selector.reserved_types)
    end

    # ⚠⚠ **`list` は順序が安定する。**ライブの MC は「原稿を台本の順に消化する」ので、
    # ⚠ 乱択の `find` では同じ原稿が何度も出て、出ない原稿が残る（→ LiveProgram）。
    def test_list_is_ordered_and_stable
      ids = selector.list(jst(11, 4)).map {|row| row[:id]}

      assert_equal(ids.sort, ids)
      assert_equal(ids, selector.list(jst(11, 4)).map {|row| row[:id]})
    end

    # ⚠⚠ **並べる鍵は `slug`。id ではない**（#69）。⚠ **id は取り込んだ順**なので、
    # **台本の途中に 1 本足すと、それが必ず末尾に来る。**台本は位置で意味が決まる
    # （`最後の1曲。` は最後でなければ嘘になる）ので、ファイルの並びがそのまま出ること。
    def test_list_follows_the_slug_not_the_insertion_order
      ['live-mc-00', 'live-mc-01', 'live-mc-02'].each do |slug|
        @repository.upsert(slug: slug, type: 'live_mc', body: slug, month: 11, day: 4, year: 2026)
      end
      # ⚠ あとから台本の途中に差し込む（id は最大になる）。
      @repository.upsert(slug: 'live-mc-00a', type: 'live_mc', body: 'live-mc-00a',
        month: 11, day: 4, year: 2026)
      rows = selector(['live_mc']).list(jst(11, 4))

      assert_equal(['live-mc-00', 'live-mc-00a', 'live-mc-01', 'live-mc-02'], rows.map {|row| row[:body]})
      assert_operator(rows[1][:id], :>, rows.last[:id])
    end

    # ⚠ 原稿が無ければ空配列（例外にしない）。
    def test_list_is_empty_when_nothing_matches
      assert_empty(selector(['live_mc']).list(jst(5, 15)))
    end

    def test_rejects_empty_types
      assert_raise(Ginseng::ConfigError) {MessageSelector.new([], repository: @repository)}
    end
  end
end
