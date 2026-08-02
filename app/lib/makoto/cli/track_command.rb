module Makoto
  # 曲データの運用操作。管理コンソールを作らない決定の帰結として、
  # 投入も確認も CLI から行う（台詞コーパスと同じ）。
  class TrackCommand < Thor
    include Package

    def self.exit_on_failure?
      return true
    end

    option :dir, type: :string, desc: '取り込み元のディレクトリ（既定は /track/dir）'
    desc 'import', 'seed/ の収集物（JSON）を投入する。何度実行してもよい'
    def import
      counts = TrackImporter.new(options[:dir]).exec
      counts.each {|key, value| puts "#{key}: #{value}"}
    rescue Sequel::DatabaseError => e
      warn "投入できませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    rescue Ginseng::NotFoundError => e
      warn "取り込み元が見つかりません: #{error_message(e)}"
      exit 1
    end

    desc 'stat', '投入済みの曲数を表示する'
    def stat
      tracks = TrackRepository.new
      report('全体', tracks, tracks.dataset)
      report('ライブ用', tracks, tracks.live)
    rescue Sequel::DatabaseError => e
      warn "読めませんでした。先に `rake migration:run` を実行してください: #{error_message(e)}"
      exit 1
    end

    private

    # ⚠ 行数と曲数を必ず並べて出す。同じ曲が名義違いで複数行あるので、行数だけ見ると
    # 「8 時間の枠が埋まる」と誤解する（→ #13）。
    def report(label, tracks, records)
      puts "#{label}: #{records.count} 行 / #{tracks.dedupe_key_count(records)} 曲"
      tracks.count_by_kind(records).sort_by {|_, count| -count}.each do |kind, count|
        unique = tracks.dedupe_key_count(tracks.by_kind(kind, records))
        puts "  #{kind}: #{count} 行 / #{unique} 曲"
      end
      puts "  リンクあり: #{tracks.linkable(records).count} 行"
    end
  end
end
