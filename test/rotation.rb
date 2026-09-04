module Makoto
  # 順送りの規則（#223）。⚠⚠ **朝挨拶（#17）と曲紹介（#16）が同じものを使う**ので、
  # 🔴 **規則そのものをここで見る**（片方の呼び出し側からしか見ていないと、
  # **もう片方だけ壊れたことに気づけない** → #183）。
  class RotationTest < TestCase
    def records(size)
      return Array.new(size) do |i|
        {id: i + 1, slug: 'slug-%<index>03d' % {index: i}}
      end
    end

    def test_an_empty_pool_gives_nothing
      assert_nil(Rotation.pick([], 0))
    end

    def test_a_single_record_is_always_picked
      pool = records(1)

      assert_equal([pool.first], (0..5).map {|serial| Rotation.pick(pool, serial)}.uniq)
    end

    # ⚠ **通し番号が 1 進めば別の原稿。**🔴 **これが「連続で同じものが出ない」の本体。**
    def test_consecutive_serials_differ
      pool = records(10)
      picked = (0..99).map {|serial| Rotation.pick(pool, serial)}

      assert_equal([], picked.each_cons(2).select {|a, b| a == b})
    end

    # ⚠⚠ **1 周で全件が 1 回ずつ。**⚠ **出ない原稿を作らない。**
    def test_one_cycle_covers_every_record
      pool = records(9)
      3.times do |cycle|
        picked = (0...pool.size).map {|i| Rotation.pick(pool, (cycle * pool.size) + i)}

        assert_equal(pool.sort_by {|record| record[:slug]},
          picked.sort_by {|record| record[:slug]}, "周 #{cycle}")
      end
    end

    # 🔴 **周ごとに並びが変わる**（#223 の本体）。⚠⚠ **素の順送りだと、本数ぶん進む
    # たびにまったく同じ順番が戻る。**
    def test_the_order_changes_every_cycle
      pool = records(12)
      orders = (0..3).map do |cycle|
        (0...pool.size).map {|i| Rotation.pick(pool, (cycle * pool.size) + i)[:slug]}
      end

      assert_equal(orders.size, orders.uniq.size)
    end

    # ⚠⚠ **前半・後半を保つので、同じ原稿が戻るのは最短でも本数の半分。**
    # 🔴 **完全に組み替えると周の境目で最短 2 まで落ちる。**
    def test_the_gap_never_falls_below_half_the_pool
      pool = records(12)
      seen = {}
      gaps = []
      (0...(pool.size * 6)).each do |serial|
        slug = Rotation.pick(pool, serial)[:slug]
        gaps.push(serial - seen[slug]) if seen[slug]
        seen[slug] = serial
      end

      assert_operator(gaps.min, :>=, pool.size / 2)
    end

    # 🔴 **鍵は `slug`。`id` ではない**（#223 / #224・Codex の P2）。⚠⚠ **`id` は
    # DB ごとの採番**なので、⚠ **`id` で並べるとステージングの下見が本番の並びを
    # 言い当てられない。**
    def test_the_order_does_not_depend_on_the_database_ids
      pool = records(8)
      # ⚠ **並び（前半・後半の割れ方）は入力の順で決まる**ので、⚠⚠ **動かすのは
      # `id` だけ。**🔴 **鍵が `slug` である限り、番号を振り直しても並びは変わらない。**
      renumbered = pool.map.with_index(100) {|record, id| record.merge(id: id)}
      serials = (0...16).to_a

      assert_equal(serials.map {|s| Rotation.pick(pool, s)[:slug]},
        serials.map {|s| Rotation.pick(renumbered, s)[:slug]})
    end

    # ⚠ **移送前の行は `slug` を持たない**（→ #224）。⚠⚠ **その箱の中では決定的。**
    def test_records_without_a_slug_still_rotate
      pool = Array.new(6) {|i| {id: i + 1, slug: nil}}
      picked = (0...12).map {|serial| Rotation.pick(pool, serial)[:id]}

      assert_equal([], picked.each_cons(2).select {|a, b| a == b})
      assert_equal(pool.map {|record| record[:id]}.sort, picked.first(6).sort)
    end
  end
end
