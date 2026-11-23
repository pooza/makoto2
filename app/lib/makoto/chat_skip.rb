module Makoto
  # 受けた通知を、LLM を呼ばずに見送る判定（→ `ChatResponder`）。
  # ⚠ `ChatResponder` から切り出した（#701 で `Metrics/ClassLength` に当たった）。
  # ⚠ `done` / `repository` / `gate` / `@seen` は取り込む側のもの。
  module ChatSkip
    private

    # LLM を呼ばずに終える理由があれば、その結果（無ければ nil）。
    def skip_thread(thread, account, notification, received_at)
      closed = repository.closed_thread?(thread.root_id, account['id'])
      return done(:closed_thread, notification) if closed
      return done(:empty, notification) if thread.messages.empty?
      # ⚠ **前のやりとりを引いた後にも、窓の締め切りを見る**（#701）— 外の口を順に引く待ちが締め切りを食うと、
      # LLM に払った後で返事を捨てていた。⚠ 記憶・ニュースは `respond` の中で引くので、そこは返事の後の判定まで。
      return done(:late_in_window, notification) if gate.late?(received_at)
      return nil
    end

    def seen?(id)
      return true if @seen.include?(id.to_s)
      @seen.push(id.to_s)
      @seen.shift while @seen.size > ChatResponder::SEEN_MAX
      return false
    end
  end
end
