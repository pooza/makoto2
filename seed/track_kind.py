#!/usr/bin/env python3
# 曲の種類（kind）を付ける規則（pooza/makoto2#294）。
#
# ⚠⚠ 2026-07-29 の収集で使った分類の段はリポジトリに残っていなかった（出力だけが seed/ にある）。
# これはデータから書き起こし直したもの。🔴 既存の行には当てない — itunes_corpus.py は
# 既存の行の kind を seed/ の値のまま保ち、新しく入った行にだけこれを当てる
# （抽選の割合と 11/4 の並びを動かさないため）。
#
# 規則（上から順に当てる。曲名・アルバム名は NFKC で揃えてから見る）:
#
#   karaoke       曲名に「カラオケ」「karaoke」
#   tv_size       曲名に「TVサイズ」「TV size」（間の空白は有っても無くても）
#   instrumental  曲名に「インスト」（⚠ 語の途中は除く — 「ツインストリーム」）/「Instrumental」
#                 ⚠ 「オリジナル・メロディ・インスト」も含む（#304 で vocal に入っていた形）
#   bgm           アルバム名に「サウンドトラック」「Soundtrack」「サントラ」「音楽集」
#   vocal         それ以外
#
# ⚠ 旧分類との食い違いは `python3 seed/track_kind.py --check` で見る（既存の行は変えないので、
#   食い違いは「旧分類がそう付けていた」という記録であって、直す対象ではない）。
import collections
import json
import re
import sys
import unicodedata

KINDS = ['vocal', 'bgm', 'karaoke', 'tv_size', 'instrumental']

RULES = [
    ('karaoke', 'name', re.compile(r'カラオケ|karaoke', re.I)),
    ('tv_size', 'name', re.compile(r'TV\s*(サイズ|size)', re.I)),
    # ⚠ 「インスト」は後ろにカタカナが続く形（ツインストリーム）を除く。
    #   「インストヴァージョン」「インストゥルメンタル」だけは明示して拾う。
    ('instrumental', 'name',
     re.compile(r'Instrumental|インストゥルメンタル|インスト(ヴァ|バ)ージョン|インスト(?![ァ-ヶー])', re.I)),
    ('bgm', 'collection', re.compile(r'サウンドトラック|Soundtrack|サントラ|音楽集', re.I)),
]


def norm(text):
    return unicodedata.normalize('NFKC', text or '')


def classify(track):
    """iTunes の行（trackName / collectionName を持つ）から kind を決める。"""
    fields = {'name': norm(track.get('trackName')), 'collection': norm(track.get('collectionName'))}
    for kind, field, pattern in RULES:
        if pattern.search(fields[field]):
            return kind
    return 'vocal'


def check(path):
    """seed/ の行に規則を当て、旧分類との食い違いを数える。"""
    rows = json.load(open(path, encoding='utf-8'))
    diff = collections.Counter()
    samples = collections.defaultdict(list)
    for row in rows:
        kind = classify(row)
        if kind != row.get('kind'):
            diff[(row.get('kind'), kind)] += 1
            samples[(row.get('kind'), kind)].append(row['trackName'])
    agree = len(rows) - sum(diff.values())
    print(f'{path}: {len(rows)} 行のうち {agree} 行が一致（{agree * 100 / len(rows):.1f}%）')
    for (old, new), count in diff.most_common():
        print(f'  旧 {old} → 規則 {new}: {count} 行（例: {" / ".join(samples[(old, new)][:3])}）')


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == '--check':
        for p in sys.argv[2:] or ['seed/makoto_tracks_daily.json']:
            check(p)
    else:
        print('usage: python3 seed/track_kind.py --check [seed/makoto_tracks_daily.json ...]')
