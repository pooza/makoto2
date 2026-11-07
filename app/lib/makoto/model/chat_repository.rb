module Makoto
  # チャットの記録を読み書きする口（#510）。⚠ **判断はここに置かない**（→ `ChatGate`）。
  class ChatRepository
    def initialize(db = Database.connection)
      @db = db
    end

    def events
      return @db[:chat_event]
    end

    def penalties
      return @db[:chat_penalty]
    end

    def record(account_id, acct, kind, at = Time.now)
      return events.insert(account_id: account_id.to_s, acct: acct.to_s, kind: kind.to_s, at: at)
    end

    # `since` より後に、その相手へ `kind` を返した回数。⚠ `account_id` が nil なら全員。
    def count(kind, since, account_id: nil)
      records = events.where(kind: kind.to_s).where {at > since}
      records = records.where(account_id: account_id.to_s) if account_id
      return records.count
    end

    def penalty(account_id)
      return penalties.where(account_id: account_id.to_s).first
    end

    def save_penalty(account_id, values)
      key = account_id.to_s
      if penalty(key)
        penalties.where(account_id: key).update(values)
      else
        penalties.insert(values.merge(account_id: key))
      end
      return penalty(key)
    end

    # ⚠ **行ごと消す**（印の回数も 0 に戻る）。オーナーが「間違いだった」と判断したとき。
    def forgive(account_id)
      return penalties.where(account_id: account_id.to_s).delete
    end

    def find_penalty_by_acct(acct)
      return penalties.where(acct: acct.to_s.delete_prefix('@')).first
    end

    def all_penalties
      return penalties.reverse(:marked_at).all
    end
  end
end
