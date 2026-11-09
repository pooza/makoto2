module Makoto
  # SSE（Server-Sent Events）の読み手（#29）。⚠ **切れ目を問わず流し込める** —
  # 🔴 **受け取る塊は行の途中で切れる**（TCP の都合で、1 イベントが 2 回に分かれて届く）。
  #
  # ⚠ **`:` で始まる行は注釈**で、イベントにはならない。⚠⚠ **Mastodon は無通信の間も
  # 15 秒ごとに `:thump` を流す**ので、**「繋がっているか」はこれで分かる**（→ `MentionListener`）。
  #
  # ⚠ 仕様の `id` / `retry` は使わない（Mastodon は送ってこない）ので読み捨てる。
  class ServerSentEvents
    Event = Data.define(:name, :data)

    def initialize
      @buffer = String.new(encoding: Encoding::BINARY)
      reset
    end

    # 塊を流し込み、揃ったイベントを 1 つずつ渡す。
    #
    # @yieldparam event [Event]
    def feed(chunk)
      @buffer << chunk.to_s.b
      while (index = @buffer.index("\n"))
        line = @buffer.slice!(0..index).force_encoding(Encoding::UTF_8).scrub.chomp
        line = line.delete_suffix("\r")
        event = parse_line(line)
        yield event if event && block_given?
      end
    end

    private

    # ⚠ **空行でイベントが閉じる。**⚠ `data` が 1 行も無いイベントは捨てる（仕様どおり）。
    def parse_line(line)
      return dispatch if line.empty?
      return nil if line.start_with?(':')
      field, value = line.split(':', 2)
      value = value.to_s.delete_prefix(' ')
      case field
      when 'event' then @name = value
      when 'data' then @data.push(value)
      end
      return nil
    end

    def dispatch
      event = Event.new(name: @name || 'message', data: @data.join("\n")) if @data.any?
      reset
      return event
    end

    def reset
      @name = nil
      @data = []
    end
  end
end
