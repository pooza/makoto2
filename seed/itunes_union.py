#!/usr/bin/env python3
# 宮本佳那子 / 剣崎真琴 / キュアソード の和集合で iTunes から曲を集める試作。
# MAKOTO 立て直しの track 自動登録が実現可能かを確かめるための調査用スクリプト。
import json
import time
import urllib.parse
import urllib.request

KEYWORDS = ['宮本佳那子', '宮本 佳那子', '剣崎真琴', 'キュアソード']
BASE = 'https://itunes.apple.com'
UA = {'User-Agent': 'makoto-track-survey/0.1 (research)'}


def get(path, **params):
    params.setdefault('country', 'jp')
    url = f'{BASE}/{path}?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=30) as res:
        body = json.loads(res.read().decode('utf-8'))
    time.sleep(1.2)  # 公称の目安 20req/min を守る
    return body.get('results', [])


def matches(name):
    return any(k.replace(' ', '') in (name or '').replace(' ', '') for k in KEYWORDS)


# 1. 3 つの名前でアーティストを引き、名前に該当語を含むものだけ残す
artists = {}
for kw in ['宮本佳那子', '剣崎真琴', 'キュアソード']:
    for r in get('search', term=kw, entity='musicArtist', limit=25):
        if matches(r.get('artistName')):
            artists[r['artistId']] = r['artistName']

print(f'対象アーティスト {len(artists)} 件')
for aid, name in artists.items():
    print(f'  {aid}  {name}')

# 2. アーティストごとに曲を列挙。200 で頭打ちならアルバム経由でも拾う
tracks = {}
for aid, name in artists.items():
    songs = [r for r in get('lookup', id=aid, entity='song', limit=200) if r.get('wrapperType') == 'track']
    if len(songs) >= 200:
        for al in [r for r in get('lookup', id=aid, entity='album', limit=200) if r.get('wrapperType') == 'collection']:
            songs += [r for r in get('lookup', id=al['collectionId'], entity='song', limit=200)
                      if r.get('wrapperType') == 'track']
    for s in songs:
        tracks.setdefault(s['trackId'], s)
    print(f'  {name}: {len(songs)} 曲（累計ユニーク {len(tracks)}）')

# 3. 集計
rows = sorted(tracks.values(), key=lambda t: (t.get('releaseDate') or '', t.get('trackName') or ''))
print(f'\n和集合 {len(rows)} 曲 / {len({t.get("collectionId") for t in rows})} アルバム')

names = {}
for t in rows:
    names.setdefault(t['trackName'], []).append(t)
print(f'曲名でまとめると {len(names)} 曲（TV サイズ・別音源の重複を畳んだ場合）')

with open('itunes_union.json', 'w', encoding='utf-8') as f:
    json.dump(rows, f, ensure_ascii=False, indent=2)
print('→ itunes_union.json')
