module Makoto
  # 最近出した曲を避ける（#41）。
  class TrackHistoryTest < TestCase
    def setup
      super
      @repository = TrackRepository.new(track_db)
      @history_repository = TrackHistoryRepository.new(track_db)
    end

    def history(size = 3)
      return TrackHistory.new(post: 'song', size: size, repository: @history_repository)
    end

    def candidates
      return @repository.distinct(@repository.linkable)
    end

    # ⚠ 記録した曲を `dedupe_key` で引き当てる。
    def record(subject, id)
      return subject.record(@repository.dataset.first(id: id))
    end

    # ⚠ **設定を消せば止まる**（#77）。🔴 **0 なら読みにも書きにも行かない。**
    def test_is_a_no_op_without_a_size
      subject = history(0)

      assert_false(subject.enabled?)
      assert_nil(record(subject, 1001))
      assert_equal(0, subject.count)
      assert_equal(candidates.count, subject.exclude(candidates).count)
    end

    # 🔴 **出した曲が次の母集合から外れる**（この Issue の核心）。
    def test_excludes_what_was_posted
      subject = history
      record(subject, 1001)

      assert_not_include(subject.exclude(candidates).select_map(:id), 1001)
    end

    # ⚠⚠ **鍵は `track.id` ではなく `dedupe_key`。**🔴 **同じ曲の別名義行が続けて
    # 出ない**（**id で覚えると同じ曲が別名義で何度も出る** → docs/track-corpus.md）。
    #
    # ⚠ **記録するのは代表ではない行**（`1002` ＝ 別名義）で、⚠⚠ **外れるのは代表
    # （`1001`）のほう** — 🔴 **id で照らしていたら外れない。**
    def test_excludes_the_whole_song_not_the_row
      subject = history

      assert_equal(
        @repository.dataset.first(id: 1001)[:dedupe_key],
        @repository.dataset.first(id: 1002)[:dedupe_key],
      )
      assert_include(candidates.select_map(:id), 1001)
      record(subject, 1002)

      assert_not_include(subject.exclude(candidates).select_map(:id), 1001)
    end

    # ⚠ **窓の外に出たものは戻ってくる**（🔴 **避けるのは直近 `size` 本だけ**）。
    def test_forgets_beyond_the_window
      subject = history(1)
      record(subject, 1001)
      record(subject, 1003)

      assert_include(subject.exclude(candidates).select_map(:id), 1001)
      assert_not_include(subject.exclude(candidates).select_map(:id), 1003)
    end

    # 🔴 **避けきれなくなったら古いものから解禁する**（⚠⚠ **沈黙させない**）。
    #
    # ⚠ **`nil` を返すとその枠が投稿されない**ので、**重複を許すほうを採る。**
    def test_gives_up_rather_than_going_silent
      subject = history(100)
      candidates.select_map(:id).each {|id| record(subject, id)}

      assert_not_empty(subject.exclude(candidates).select_map(:id))
      assert_equal(candidates.count, subject.exclude(candidates).count)
    end

    # ⚠ **枠ごとに別の履歴**（🔴 **後から別の枠が曲を出すようになっても混ざらない**）。
    def test_keeps_posts_apart
      record(history, 1001)
      other = TrackHistory.new(post: 'other', size: 3, repository: @history_repository)

      assert_include(other.exclude(candidates).select_map(:id), 1001)
      assert_equal(0, other.count)
    end

    # ⚠⚠ **書けなくても投稿を落とさない**（`PostingJob#record` と同じ判断）。
    def test_survives_a_broken_repository
      broken = Object.new
      def broken.record(*)
        raise Sequel::DatabaseError, 'boom'
      end
      subject = TrackHistory.new(post: 'song', size: 3, repository: broken)

      assert_nothing_raised {subject.record(@repository.dataset.first(id: 1001))}
      assert_nil(subject.record(@repository.dataset.first(id: 1001)))
    end
  end
end
