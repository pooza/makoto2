#!/usr/bin/env python3
"""旧 MAKOTO の pg_dump（プレーン SQL）を、ストア非依存の JSON に落とす。

旧 DB のスナップショットは `makoto_2026-02-13.sql.zst` の 1 個しか存在せず、
それ以降のデータは取得できない（docs/makoto-legacy.md）。データストアが
決まる前でもコーパスを扱えるように、COPY ブロックだけを読んで JSON にする。

psql を必要としない。COPY のテキスト形式を直接パースする。

    python3 tools/pgdump_to_json.py var/corpus/makoto_2026-02-13.sql var/corpus

⚠ 出力にはアカウント情報と第三者の著作物（台詞）が含まれる。
   public リポジトリにコミットしないこと（`/var/` は .gitignore 済み）。
"""

import json
import re
import sys
from pathlib import Path

# COPY テキスト形式のエスケープ。https://www.postgresql.org/docs/current/sql-copy.html
UNESCAPE = {
  'b': '\b',
  'f': '\f',
  'n': '\n',
  'r': '\r',
  't': '\t',
  'v': '\v',
  '\\': '\\',
}

COPY_RE = re.compile(
  r'^COPY (?P<table>public\.\w+) \((?P<columns>[^)]*)\) FROM stdin;\n(?P<body>.*?)^\\\.$',
  re.S | re.M,
)

# 整数として扱う列。COPY は型を持たないため、ここで明示する。
INT_COLUMNS = {
  'id', 'series_id', 'form_id', 'episode', 'priority', 'month', 'day',
  'account_id', 'favorability',
}
BOOL_COLUMNS = {'exclude', 'exclude_respond', 'makoto'}


def unescape(field):
  """COPY テキスト形式の 1 フィールドを Python の値に戻す。"""
  if field == r'\N':
    return None
  out = []
  i = 0
  while i < len(field):
    c = field[i]
    if c != '\\':
      out.append(c)
      i += 1
      continue
    nxt = field[i + 1] if i + 1 < len(field) else ''
    if nxt in UNESCAPE:
      out.append(UNESCAPE[nxt])
      i += 2
    else:
      # 未知のエスケープはバックスラッシュごと残す（欠落より目立つほうがよい）
      out.append(c)
      i += 1
  return ''.join(out)


def coerce(column, value):
  if value is None:
    return None
  if column in BOOL_COLUMNS:
    return value == 't'
  if column in INT_COLUMNS:
    return int(value)
  return value


def parse(sql):
  """テーブル名 -> 行（dict）のリスト。"""
  tables = {}
  for m in COPY_RE.finditer(sql):
    name = m.group('table').split('.', 1)[1]
    columns = [c.strip() for c in m.group('columns').split(',')]
    rows = []
    for line in m.group('body').split('\n'):
      if line == '':
        continue
      fields = line.split('\t')
      if len(fields) != len(columns):
        raise ValueError(f'{name}: 列数が合わない（{len(fields)} != {len(columns)}）: {line[:80]}')
      rows.append({c: coerce(c, unescape(f)) for c, f in zip(columns, fields)})
    tables[name] = rows
  return tables


def main():
  if len(sys.argv) != 3:
    print(__doc__)
    return 1
  dump = Path(sys.argv[1])
  outdir = Path(sys.argv[2])
  outdir.mkdir(parents=True, exist_ok=True)

  tables = parse(dump.read_text(encoding='utf-8'))
  for name, rows in sorted(tables.items()):
    path = outdir / f'{name}.json'
    path.write_text(
      json.dumps(rows, ensure_ascii=False, indent=2) + '\n',
      encoding='utf-8',
    )
    print(f'{name}\t{len(rows)}\t{path}')
  return 0


if __name__ == '__main__':
  sys.exit(main())
