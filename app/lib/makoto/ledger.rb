module Makoto
  # 足した設定の台帳（#526）を、チャットボットの指示書の 1 塊にする。
  #
  # 🔴 **台帳の正本は makoto-scripts の `ledger.md`**（private）。⚠⚠ **投稿前の原稿から拾った設定は
  # ネタバレになる**ので、public の makoto2 には置かない。実機では makoto-scripts のチェックアウトから読む。
  #
  # 🔴 **本人の記憶として渡す**（2026-11-09・オーナー）。⚠ 台帳は作品の外の見方（出どころ・根拠の slug）を
  # 持つが、渡すのは「中身」の列だけ。⚠ 「決まり」と「載せないと決めたもの」の節は渡さない。
  #
  # ⚠ **無ければ渡さない**（手元・CI には makoto-scripts が無いことがある）。
  #
  # 🔴 **前のやりとりで違うことを言っていたら、そちらを優先させる**（2026-11-09・評価で台帳と前の返事が
  # ぶつかり、答えを変えた・オーナー了承）。⚠ 相手が見ているのは前の返事なので、台帳に寄せて変えると食い違って見える。
  class Ledger
    include Package

    SKIP_SECTIONS = ['決まり', '載せないと決めたもの'].freeze

    HEADER = <<~TEXT.freeze
      # あなたの暮らしのこと

      これまでに話してきた、普段の暮らし・好み・仕事の習慣です。訊かれたら、これと食い違わないように答えてください。ここに無いことは話の流れで答えてよいですが、新しい設定として言い切りすぎないでください。
      ただし、この会話の前のやりとりであなたが答えたことは、この一覧より優先します。一覧と違っていても言い直さず、前の答えを保ってください（相手が見ているのは前の返事です）。
    TEXT

    def initialize(path = nil)
      @path = path
    end

    def path
      @path ||= File.expand_path(config['/chat/ledger/path'].to_s, Environment.dir)
      return @path
    end

    def exist?
      return File.file?(path)
    end

    # 指示書の塊。⚠ **無ければ nil。**
    def to_prompt
      return nil unless exist?
      sections = parse(File.read(path))
      return nil if sections.empty?
      body = sections.map do |title, items|
        "## #{title}\n\n#{items.map {|item| "- #{item}"}.join("\n")}"
      end
      return "#{HEADER}\n#{body.join("\n\n")}"
    end

    private

    # @return [Array<Array(String, Array<String>)>] 節の名前と、中身の列
    def parse(text)
      sections = []
      current = nil
      text.each_line do |line|
        if (title = line[/\A## (.+)/, 1])
          current = SKIP_SECTIONS.include?(title.strip) ? nil : [title.strip, []]
          sections.push(current) if current
        elsif current && (item = row(line))
          current.last.push(item)
        end
      end
      return sections.reject {|_, items| items.empty?}
    end

    # 表の 1 行目の列。⚠ 見出しの行（`中身`）と区切りの行は除く。⚠ 書き手向けの印（⚠）は落とす。
    def row(line)
      return nil unless line.start_with?('|')
      cell = line.split('|')[1].to_s.strip
      return nil if cell.empty? || cell == '中身' || cell.match?(/\A-+\z/)
      return cell.delete('⚠').squeeze(' ').strip
    end
  end
end
