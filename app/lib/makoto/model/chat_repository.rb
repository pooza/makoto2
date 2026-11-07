module Makoto
  # チャットの記録を読み書きする口（#510）。⚠ **判断はここに置かない**（→ `ChatGate`）。
  #
  # 🔴 **時刻はプロセスの地方時に寄せてから書く・比べる**（→ `local`）。⚠⚠ **SQLite には時差を持たない
  # 壁時計の文字列で入り、読むときは地方時として解釈される**ので、**`+09:00` の時刻を UTC のプロセスで
  # 書くと 9 時間ずれる**（PR #587 の CI で踏んだ・手元は JST なので揃って見えた）。
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
      return events.insert(account_id: account_id.to_s, acct: acct.to_s, kind: kind.to_s,
        at: local(at))
    end

    # `since` より後に、その相手へ `kind` を返した回数。⚠ `account_id` が nil なら全員。
    def count(kind, since, account_id: nil)
      from = local(since)
      records = events.where(kind: kind.to_s).where {at > from}
      records = records.where(account_id: account_id.to_s) if account_id
      return records.count
    end

    def penalty(account_id)
      return penalties.where(account_id: account_id.to_s).first
    end

    def save_penalty(account_id, values)
      key = account_id.to_s
      values = values.to_h {|name, value| [name, value.is_a?(Time) ? local(value) : value]}
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

    private

    def local(time)
      return time.is_a?(Time) ? time.getlocal : time
    end
  end
end
