module Makoto
  class ServerSentEventsTest < TestCase
    def events_of(*chunks)
      parser = ServerSentEvents.new
      events = []
      chunks.each {|chunk| parser.feed(chunk) {|event| events.push(event)}}
      return events
    end

    def test_an_event
      events = events_of("event: notification\ndata: {\"id\":\"1\"}\n\n")

      assert_equal(1, events.size)
      assert_equal('notification', events.first.name)
      assert_equal('{"id":"1"}', events.first.data)
    end

    # 🔴 **塊は行の途中で切れる**（TCP の都合）。
    def test_an_event_split_across_chunks
      events = events_of('event: notifi', "cation\ndata: {\"id\"", ":\"1\"}\n", "\n")

      assert_equal(['notification'], events.map(&:name))
      assert_equal('{"id":"1"}', events.first.data)
    end

    # ⚠ **`:thump` は注釈で、イベントにならない**（→ `MentionListener` は届いたことだけ数える）。
    def test_a_comment_is_not_an_event
      assert_empty(events_of(":thump\n", ":thump\n\n"))
    end

    def test_multiline_data_and_crlf
      events = events_of("data: a\r\ndata: b\r\n\r\n")

      assert_equal('message', events.first.name)
      assert_equal("a\nb", events.first.data)
    end

    # ⚠ **マルチバイトが塊の境目で割れても化けない。**
    def test_a_multibyte_character_split_across_chunks
      bytes = "data: 真琴\n\n".b
      events = events_of(bytes[0, 8], bytes[8..])

      assert_equal('真琴', events.first.data)
    end

    def test_an_event_without_data_is_dropped
      assert_empty(events_of("event: delete\n\n"))
    end
  end
end
