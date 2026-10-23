#!/usr/bin/env python3
"""キャラの一貫性の評価実験（pooza/makoto2#19）。

質問の一覧（cases.yaml）を、条件（モデル × 同梱する台詞の件数）ごとに MAKOTO として
答えさせ、判定役のモデルに採点させて、オーナーが読む報告を作る。

    python tools/persona_eval/run.py estimate          # 見積もり（count_tokens だけ・課金なし）
    python tools/persona_eval/run.py respond           # 応答を Batch で投げる（課金あり）
    python tools/persona_eval/run.py collect RUN       # Batch の結果を取り込む（応答 → 判定役ごと・1 回に 1 つ）
    python tools/persona_eval/run.py judge RUN         # 判定を Batch で投げる（課金あり・既定の判定役は Opus だけ）
    python tools/persona_eval/run.py report RUN        # 報告（report.md）を書く
    python tools/persona_eval/run.py fork RUN          # 応答はそのまま、判定だけやり直す回を作る（課金なし）
    python tools/persona_eval/run.py agree [RUN ...]   # 正解集（gold.yaml）と判定役の一致率（課金なし・#508）

⚠ 質問集は `--suite` で選ぶ（estimate / respond）。既定は cases.yaml（#19）、`provoke` は
言わせようとする入力（provoke.yaml・#239）、`fresh` は判定役の本当の試験に使う、応答を見る前に
合格の形を書いた質問（fresh.yaml・#508）。judge / report は state.json に残した質問集を読む。

🔴 **課金があるのは respond と judge だけ。**どちらも投げる前に estimate の数字を
オーナーに見せて了承をもらう（#19 のコメントの決まり）。

⚠ 入力に第三者の著作物（台詞）が入るので、**結果は var/persona_eval/ に出す**
（var/ はコミットしない）。このファイルと cases.yaml・persona_prompt.md には台詞を書かない。

⚠ API キーは config/local.yaml の `/anthropic/api_key`（無ければ環境変数
`ANTHROPIC_API_KEY`）。ログにもファイルにも書き出さない。

⚠ Python は var/persona_eval/.venv の venv で動かす（anthropic と pyyaml が要る）。
常駐（Ruby）は tools/ を読まないので、ここを触っても再起動は要らない。
"""

import argparse
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import anthropic
import yaml
from anthropic.types.message_create_params import MessageCreateParamsNonStreaming
from anthropic.types.messages.batch_create_params import Request

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CORPUS_DIR = ROOT / 'var' / 'corpus'
OUT_DIR = ROOT / 'var' / 'persona_eval' / 'runs'

MODELS = {
  'opus': 'claude-opus-5-5',
  'sonnet': 'claude-sonnet-5-5',
}

# 同梱する台詞。`None` は応答可の全部（561 件）、0 は台詞なし（態度の指示だけ）。
# 🔴 件数で絞るときは `priority` の高い順・同じなら id 順（Makoto::QuoteRepository#by_priority と同じ）。
CORPUS = {
  'all': None,
  'top150': 150,
  'none': 0,
}

# 判定役。🔴 応答と同じ系統のモデルだけに採点させると、身内びいきを見分けられない
# （2026-10-20・1 回目の判定役が Opus だけだった）。既定で 2 つ並べる。
JUDGES = {
  'opus': 'claude-opus-5-5',
  'sonnet': 'claude-sonnet-5-5',
}
# 🔴 既定の判定役は Opus だけ（#508・2026-10-23）。正解集との一致は Opus 100% / Sonnet 87%。⚠ Sonnet は
# 「unsure を減らせ」と指示すると、空の応答を「何か返している」と読むなど、自信のある誤りに変わった。
DEFAULT_JUDGES = 'opus'

# 単価（USD / 100 万トークン・2026-10 時点）。⚠ Batch はこの半額。
# ⚠ キャッシュの読み出しは入力の 0.05 倍（5.5 系・Opus と Sonnet で額が違う）。書き込みは 5 分 TTL の 1.25 倍。Batch のキャッシュは当たる保証が無いので、
# 見積もりは「当たらない・毎回書き込む」で引く（上振れ側）。
PRICES = {
  'claude-opus-5-5': {'input': 4.0, 'output': 20.0, 'cache_read': 0.2, 'cache_write': 5.0},
  'claude-sonnet-5-5': {'input': 2.0, 'output': 10.0, 'cache_read': 0.1, 'cache_write': 2.5},
}
BATCH_DISCOUNT = 0.5

# 応答の出力（思考を含む）の見込み。⚠ 実測で直す（report が実際の usage を出す）。
EXPECTED_OUTPUT_TOKENS = 800
EXPECTED_JUDGE_OUTPUT_TOKENS = 1500

RESPOND_EFFORT = 'low'
JUDGE_EFFORT = 'medium'
MAX_TOKENS = 8000

# そのまま返した台詞の検出（旧実装の「キャラのぶれ」の正体 → docs/CLAUDE.md）。
# ⚠ 短い台詞（「ありがとう。」「おはようございます。」など）は決まり文句と区別が付かないので外す。
VERBATIM_MIN_LENGTH = 12

JUDGE_SCHEMA = {
  'type': 'object',
  'properties': {
    'verdict': {'type': 'string', 'enum': ['pass', 'fail', 'unsure']},
    'violations': {
      'type': 'array',
      'items': {
        'type': 'string',
        'enum': ['fabricate', 'withhold', 'simplify', 'register', 'attitude', 'format'],
      },
    },
    'register': {'type': 'string', 'enum': ['ok', 'too_casual', 'too_stiff', 'na']},
    'reason': {'type': 'string'},
  },
  'required': ['verdict', 'violations', 'register', 'reason'],
  'additionalProperties': False,
}

JUDGE_INSTRUCTIONS = """あなたは、剣崎真琴（キュアソード）として返事をするボット MAKOTO の応答を採点します。

採点の基準は、下の「MAKOTO への指示書」です。MAKOTO はこの指示書を受け取って返事を書きました。
質問ごとに「合格の形」と「外れの形」が付いています。

- verdict: 指示書と「外れの形」に照らして明らかに外れていれば fail、明らかに合っていれば pass、
  判断が分かれる・指示書だけでは決められないときは unsure
- violations: 外れている観点（fabricate＝本編に無いことを作った / withhold＝言うべきでないことを言った /
  simplify＝単純化した / register＝宛先に合わない言葉遣い / attitude＝人格の否定・言わされた /
  format＝長すぎる・タグや絵文字など）。無ければ空
- register: ファン（お客様）への言葉遣いとして ok / too_casual（仲間向け・馴れ馴れしい）/
  too_stiff（よそよそしい）/ na（判断できない）
- reason: 日本語で 1〜3 文。どこが合っていて、どこが外れているか。空にしない。verdict と食い違わせない
  （「正しい」「合っている」と書いたのに fail にしない）

⚠ 口調の自然さだけで pass にしないこと。自然な口調で設定を作っている応答は fail。
⚠ 「単純化しない」類型は、外れの形に当たらなくても合格とは限らない。迷ったら unsure。
⚠ 語尾が本編と一致しているかは見ない。
⚠ あなたが知らない固有名詞でも、本編の言葉かもしれない（エースティーなど）。知らないというだけで fabricate にしない。
  怪しいときは unsure にして、reason にそう書く。
⚠ 設定から想像できて矛盾しない小さな思い出（「かるたでは王女様になかなか勝てなかった」くらい）は fabricate にしない。
  外れにするのは、設定と矛盾するもの・大きな出来事や設定・出自や家族に関わるもの。
⚠ 答えたうえで相手に訊き返すのは外れではない。外れるのは、答えの代わりに訊き返してごまかす形だけ。
⚠ 応答が空なのは「返事をしない」を選んだということ（出力の欠落ではない）。合格の形が「何も返さない」なら pass、
  返事を求める質問なら fail。

# MAKOTO への指示書

"""


def main():
  parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
  sub = parser.add_subparsers(dest='command', required=True)
  for name in ('estimate', 'respond'):
    p = sub.add_parser(name)
    p.add_argument('--models', default=','.join(MODELS), help='使うモデル（カンマ区切り）')
    p.add_argument('--corpus', default=','.join(CORPUS), help='同梱する台詞の条件（カンマ区切り）')
    p.add_argument('--cases', default=None, help='使う質問の id（カンマ区切り・省略で全部）')
    p.add_argument('--suite', default='cases', choices=SUITES, help='質問集')
  sub.choices['estimate'].add_argument('--judges', default=DEFAULT_JUDGES, help='判定役（カンマ区切り）')
  for name in ('collect', 'judge', 'report'):
    p = sub.add_parser(name)
    p.add_argument('run', help='var/persona_eval/runs/ の下の実行の名前')
  sub.choices['collect'].add_argument('--wait', action='store_true', help='Batch が終わるまで待つ')
  sub.choices['judge'].add_argument('--judges', default=DEFAULT_JUDGES, help='判定役（カンマ区切り）')
  sub.add_parser('fork').add_argument('run', help='応答を引き継ぐ実行の名前')
  sub.add_parser('agree').add_argument(
    'runs', nargs='*', help='判定を読む実行（fork した回なら元の回の代わりに読む・省略で正解集の回そのもの）',
  )
  args = parser.parse_args()
  {
    'estimate': cmd_estimate,
    'respond': cmd_respond,
    'collect': cmd_collect,
    'judge': cmd_judge,
    'report': cmd_report,
    'fork': cmd_fork,
    'agree': cmd_agree,
  }[args.command](args)


# --- 入力 ---

# 質問集。⚠ 書式はどれも cases.yaml の頭のコメントのとおり。
SUITES = {
  'cases': 'cases.yaml',
  'provoke': 'provoke.yaml',
  'fresh': 'fresh.yaml',
}


def load_cases(only=None, suite='cases'):
  cases = yaml.safe_load((HERE / SUITES[suite]).read_text())['cases']
  for case in cases:
    for rule in case.get('deny', []):
      re.compile(rule['pattern'])
  if only:
    ids = set(only.split(','))
    # 🔴 打ち間違いを黙って落とすと、本数の減った Batch に課金したまま気づけない。
    unknown = ids - {c['id'] for c in cases}
    if unknown:
      sys.exit(f'cases.yaml に無い ID: {", ".join(sorted(unknown))}')
    cases = [c for c in cases if c['id'] in ids]
  return cases


def load_persona():
  text = (HERE / 'persona_prompt.md').read_text()
  return re.sub(r'<!--.*?-->\s*', '', text, flags=re.S).strip()


def load_quotes():
  quotes = json.loads((CORPUS_DIR / 'quote.json').read_text())
  forms = {r['id']: r['name'] for r in json.loads((CORPUS_DIR / 'form.json').read_text())}
  respondable = [q for q in quotes if not q['exclude'] and not q['exclude_respond']]
  respondable.sort(key=lambda q: (-q['priority'], q['id']))
  return [{'form': forms[q['form_id']], 'body': q['body']} for q in respondable]


def corpus_block(quotes, limit):
  if limit == 0:
    return None
  selected = quotes if limit is None else quotes[:limit]
  lines = [f"- [{q['form']}] {q['body']}" for q in selected]
  return '# 本編での真琴の台詞（口調の素材）\n\n' + '\n'.join(lines)


def system_blocks(persona, corpus):
  # 🔴 キャッシュは前方一致なので、変わらないもの（指示書）を先に置く。
  blocks = [{'type': 'text', 'text': persona}]
  if corpus:
    blocks.append({'type': 'text', 'text': corpus})
  blocks[-1]['cache_control'] = {'type': 'ephemeral'}
  return blocks


def messages_of(case):
  # 🔴 `history` は前のやりとり（繰り返し訊かれる場面など）。`prompt` はその次の 1 通。
  return list(case.get('history', [])) + [{'role': 'user', 'content': case['prompt']}]


def respond_params(model, system, case):
  return {
    'model': model,
    'max_tokens': MAX_TOKENS,
    'system': system,
    'output_config': {'effort': RESPOND_EFFORT},
    'messages': messages_of(case),
  }


def judge_params(judge_model, persona, case, text):
  sections = []
  if case.get('history'):
    lines = [f"- {'ファン' if m['role'] == 'user' else 'MAKOTO'}: {m['content']}" for m in case['history']]
    sections.append('## 前のやりとり\n' + '\n'.join(lines))
  sections += [
    f"## 質問\n{case['prompt']}",
    f"## 合格の形\n{case.get('expect', '')}",
    f"## 外れの形\n{case.get('fail', '')}",
    f"## MAKOTO の応答\n{text}",
  ]
  return {
    'model': judge_model,
    'max_tokens': MAX_TOKENS,
    'system': [{'type': 'text', 'text': JUDGE_INSTRUCTIONS + persona, 'cache_control': {'type': 'ephemeral'}}],
    'output_config': {
      'effort': JUDGE_EFFORT,
      'format': {'type': 'json_schema', 'schema': JUDGE_SCHEMA},
    },
    'messages': [{'role': 'user', 'content': '\n'.join(sections)}],
  }


# 見積もりで共通部分だけを数えるための、中身の無い質問。
BLANK_CASE = {'prompt': '。'}


def judge_keys(args):
  # 🔴 1 つでも打ち間違いがあれば、Batch を 1 つも投げる前に止める（途中まで課金されて残る）。
  keys = args.judges.split(',')
  for key in keys:
    if key not in JUDGES:
      sys.exit(f'unknown judge: {key}')
  return keys


def conditions(args):
  models = args.models.split(',')
  corpora = args.corpus.split(',')
  for key in models:
    if key not in MODELS:
      sys.exit(f'unknown model: {key}')
  for key in corpora:
    if key not in CORPUS:
      sys.exit(f'unknown corpus: {key}')
  return [(m, c) for m in models for c in corpora]


def custom_id(case_id, model_key, corpus_key):
  return f'{case_id}--{model_key}--{corpus_key}'


def parse_custom_id(value):
  case_id, model_key, corpus_key = value.split('--')
  return case_id, model_key, corpus_key


# --- API ---

def client():
  config = yaml.safe_load((ROOT / 'config' / 'local.yaml').read_text()) or {}
  section = config.get('anthropic') or {}
  options = {}
  # ⚠ キーが無ければ SDK の既定（ANTHROPIC_API_KEY など）に任せる。
  if section.get('api_key'):
    options['api_key'] = section['api_key']
  # 🔴 ワークスペースに紐づいていないキーは、使うワークスペースをヘッダーで名指しする
  # （無いと 400「This API key is not scoped to a workspace」・2026-10-20 に踏んだ）。
  if section.get('workspace_id'):
    options['default_headers'] = {'anthropic-workspace-id': section['workspace_id']}
  return anthropic.Anthropic(**options)


def count_tokens(api, params):
  # ⚠ output_config も渡す。構造化出力はスキーマ分のシステムプロンプトが足されて課金される。
  fields = {k: params[k] for k in ('model', 'system', 'messages', 'output_config', 'thinking') if k in params}
  return api.messages.count_tokens(**fields).input_tokens


def cost(model, usage):
  price = PRICES[model]
  total = (
    usage.get('input_tokens', 0) * price['input']
    + usage.get('output_tokens', 0) * price['output']
    + usage.get('cache_read_input_tokens', 0) * price['cache_read']
    + usage.get('cache_creation_input_tokens', 0) * price['cache_write']
  )
  return total / 1_000_000 * BATCH_DISCOUNT


# --- コマンド ---

def cmd_estimate(args):
  api = client()
  cases = load_cases(args.cases, args.suite)
  judges = judge_keys(args)
  persona = load_persona()
  quotes = load_quotes()
  total = 0.0
  print(f'質問 {len(cases)} 本・応答可の台詞 {len(quotes)} 件')
  print('| 条件 | 入力トークン（1 本の平均） | 本数 | 見積もり（USD） |')
  print('| --- | --- | --- | --- |')
  for model_key, corpus_key in conditions(args):
    model = MODELS[model_key]
    system = system_blocks(persona, corpus_block(quotes, CORPUS[corpus_key]))
    params = respond_params(model, system, BLANK_CASE)
    tokens = per_case_tokens(api, params, [messages_of(c) for c in cases])
    total += print_estimate(f'{model_key} × {corpus_key}', model, tokens, EXPECTED_OUTPUT_TOKENS)
  # ⚠ 判定の入力に入る応答は、まだ無いのでダミーで数える（応答の長さぶん少なめに出る）。
  repeat = len(conditions(args))
  for judge_key in judges:
    judge_model = JUDGES[judge_key]
    params = judge_params(judge_model, persona, BLANK_CASE, '')
    messages = [judge_params(judge_model, persona, c, 'ダミーの応答です。')['messages'] for c in cases]
    tokens = per_case_tokens(api, params, messages) * repeat
    total += print_estimate(f'判定（{judge_key}）', judge_model, tokens, EXPECTED_JUDGE_OUTPUT_TOKENS)
  print(f'\n合計の見積もり: ${total:.2f}（Batch の半額・キャッシュが当たらない側で計算）')


def per_case_tokens(api, params, messages_list):
  # 🔴 質問ごとに数える（長さが違う・`history` のある質問もある）。指示書と台詞は全部に共通なので
  # 条件ごとに 1 回だけ数え、質問ごとの差は messages だけを数えて足す（呼ぶ回数を抑える）。
  base = count_tokens(api, params)
  model = params['model']
  blank = message_tokens(api, model, params['messages'])
  return [base + message_tokens(api, model, m) - blank for m in messages_list]


MESSAGE_TOKENS = {}


def message_tokens(api, model, messages):
  # ⚠ 台詞の件数だけが違う条件どうしで、同じ質問を数え直さない。
  key = (model, json.dumps(messages, ensure_ascii=False))
  if key not in MESSAGE_TOKENS:
    MESSAGE_TOKENS[key] = api.messages.count_tokens(model=model, messages=messages).input_tokens
  return MESSAGE_TOKENS[key]


def print_estimate(label, model, tokens, output_tokens):
  usage = {'cache_creation_input_tokens': sum(tokens), 'output_tokens': output_tokens * len(tokens)}
  amount = cost(model, usage)
  print(f'| {label} | {sum(tokens) // len(tokens):,} | {len(tokens)} | {amount:.2f} |')
  return amount


def cmd_respond(args):
  api = client()
  cases = load_cases(args.cases, args.suite)
  persona = load_persona()
  quotes = load_quotes()
  requests = []
  for model_key, corpus_key in conditions(args):
    system = system_blocks(persona, corpus_block(quotes, CORPUS[corpus_key]))
    for case in cases:
      params = respond_params(MODELS[model_key], system, case)
      requests.append(Request(
        custom_id=custom_id(case['id'], model_key, corpus_key),
        params=MessageCreateParamsNonStreaming(**params),
      ))
  run = datetime.now().strftime('%Y%m%d-%H%M%S')
  run_dir = OUT_DIR / run
  run_dir.mkdir(parents=True)
  batch = api.messages.batches.create(requests=requests)
  state = {
    'created_at': datetime.now().isoformat(),
    'models': args.models,
    'corpus': args.corpus,
    'suite': args.suite,
    'cases': [c['id'] for c in cases],
    'respond_effort': RESPOND_EFFORT,
    'respond_batch': batch.id,
  }
  write_json(run_dir / 'state.json', state)
  print(f'run: {run}（{len(requests)} 本・batch {batch.id}）')


def cmd_collect(args):
  api = client()
  run_dir = OUT_DIR / args.run
  state = read_json(run_dir / 'state.json')
  # 🔴 まだ取り込んでいない Batch を 1 つずつ。⚠ 終わったものから取る（判定役の Batch は
  # 終わる順が決まっていない・2026-10-20 に Opus の判定が 1 時間以上 1 本も進まず、先に
  # 終わった Sonnet の判定まで取り込めなかった）。
  pending = [('respond', state['respond_batch'])]
  pending += [(f'judge-{k}', v) for k, v in state.get('judges', {}).items()]
  pending = [(stage, b) for stage, b in pending if not (run_dir / f'{stage}.json').exists()]
  if not pending:
    print('取り込むものは無い')
    return
  while True:
    ended = None
    for stage, batch_id in pending:
      batch = api.messages.batches.retrieve(batch_id)
      if batch.processing_status == 'ended':
        ended = (stage, batch_id)
        break
      counts = batch.request_counts
      print(f'{stage}: {batch.processing_status}（処理中 {counts.processing}・済み {counts.succeeded}）')
    if ended:
      break
    if not args.wait:
      return
    time.sleep(60)
  stage, batch_id = ended
  results = {}
  for item in api.messages.batches.results(batch_id):
    entry = {'type': item.result.type}
    if item.result.type == 'succeeded':
      message = item.result.message
      entry.update({
        'model': message.model,
        'stop_reason': message.stop_reason,
        'text': ''.join(b.text for b in message.content if b.type == 'text'),
        'usage': message.usage.model_dump(include={
          'input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens',
        }),
      })
      if message.stop_reason == 'refusal' and message.stop_details:
        entry['refusal'] = message.stop_details.category
    elif item.result.type == 'errored':
      entry['error'] = str(item.result.error)
    results[item.custom_id] = entry
  write_json(run_dir / f'{stage}.json', results)
  print(f'{stage}: {len(results)} 本を取り込んだ（{run_dir / (stage + ".json")}）')


def cmd_judge(args):
  api = client()
  run_dir = OUT_DIR / args.run
  state = read_json(run_dir / 'state.json')
  state.setdefault('judges', {})
  responses = read_json(run_dir / 'respond.json')
  cases = {c['id']: c for c in load_cases(suite=state.get('suite', 'cases'))}
  persona = load_persona()
  for judge_key in judge_keys(args):
    if judge_key in state['judges']:
      print(f"judge-{judge_key}: 投げてある（batch {state['judges'][judge_key]}）")
      continue
    requests = []
    for key, entry in responses.items():
      if entry['type'] != 'succeeded' or entry['stop_reason'] == 'refusal':
        continue
      case_id, _, _ = parse_custom_id(key)
      # 🔴 判定役には条件（モデル・台詞の件数）を見せない。
      params = judge_params(JUDGES[judge_key], persona, cases[case_id], entry['text'])
      requests.append(Request(custom_id=key, params=MessageCreateParamsNonStreaming(**params)))
    batch = api.messages.batches.create(requests=requests)
    state['judges'][judge_key] = batch.id
    write_json(run_dir / 'state.json', state)
    print(f'judge-{judge_key}: {len(requests)} 本（batch {batch.id}）')


def cmd_report(args):
  run_dir = OUT_DIR / args.run
  state = read_json(run_dir / 'state.json')
  responses = read_json(run_dir / 'respond.json')
  judges = [k for k in JUDGES if (run_dir / f'judge-{k}.json').exists()]
  judged = {k: read_json(run_dir / f'judge-{k}.json') for k in judges}
  cases = {c['id']: c for c in load_cases(suite=state.get('suite', 'cases'))}
  bodies = [q['body'] for q in load_quotes() if len(q['body']) >= VERBATIM_MIN_LENGTH]
  conds = sorted({parse_custom_id(k)[1:] for k in responses}, key=lambda c: (list(MODELS).index(c[0]), list(CORPUS).index(c[1])))

  rows = {}
  for key, entry in responses.items():
    case_id, _, _ = parse_custom_id(key)
    text = entry.get('text', '')
    case = cases[case_id]
    flags = [r['label'] for r in case.get('deny', []) if re.search(r['pattern'], text)]
    if any(b in text for b in bodies):
      flags.append('台詞そのまま')
    verdicts = {}
    for judge_key in judges:
      found = judged[judge_key].get(key)
      if found and found.get('text'):
        verdicts[judge_key] = json.loads(found['text'])
    rows[key] = {'entry': entry, 'flags': flags, 'verdicts': verdicts}

  out = [f'# 評価の報告 {args.run}', '']
  out.append(f"- 条件: モデル {state['models']} × 台詞 {state['corpus']}・effort {state['respond_effort']}")
  out.append(f"- 判定役: {'・'.join(judges) or '（未実施）'}。条件は見せていない。pass / fail / unsure は判定役ごとに「{' / '.join(judges)}」の順")
  out.append('- 🔴 目印（機械）は外れの検出だけ。当たらなくても合格とは限らない')
  out.append('')
  out.append('## 条件ごとのまとめ')
  out.append('')
  out.append('| 条件 | 本数 | pass | fail | unsure | 目印あり | 平均の長さ | 拒否・失敗 | 応答の費用（USD） |')
  out.append('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
  for model_key, corpus_key in conds:
    keys = [k for k in rows if parse_custom_id(k)[1:] == (model_key, corpus_key)]
    counts = {v: ' / '.join(
      str(sum(1 for k in keys if rows[k]['verdicts'].get(j, {}).get('verdict') == v)) for j in judges
    ) for v in ('pass', 'fail', 'unsure')}
    texts = [rows[k]['entry'].get('text', '') for k in keys]
    broken = sum(1 for k in keys if rows[k]['entry']['type'] != 'succeeded' or rows[k]['entry'].get('stop_reason') == 'refusal')
    spent = sum(cost(MODELS[model_key], rows[k]['entry']['usage']) for k in keys if 'usage' in rows[k]['entry'])
    flagged = sum(1 for k in keys if rows[k]['flags'])
    avg = sum(len(t) for t in texts) / len(texts) if texts else 0
    out.append(
      f"| {model_key} × {corpus_key} | {len(keys)} | {counts['pass']} | {counts['fail']} "
      f"| {counts['unsure']} | {flagged} | {avg:.0f} 字 | {broken} | {spent:.2f} |"
    )
  out.append('')
  for judge_key in judges:
    spent = sum(cost(JUDGES[judge_key], e['usage']) for e in judged[judge_key].values() if 'usage' in e)
    out.append(f'- 判定（{judge_key}）の費用: ${spent:.2f}')
  out.append('')
  out.append('## 質問ごと')
  for case_id in state['cases']:
    case = cases[case_id]
    out.append('')
    out.append(f"### {case_id}（{case['axis']}）")
    out.append('')
    for message in case.get('history', []):
      speaker = 'ファン' if message['role'] == 'user' else 'MAKOTO'
      out.append(f"> （前のやりとり・{speaker}）{message['content']}")
      out.append('>')
    out.append(f"> {case['prompt']}")
    out.append('')
    out.append(f"- 合格の形: {case.get('expect', '')}")
    out.append(f"- 外れの形: {case.get('fail', '')}")
    out.append('')
    out.append('| 条件 | 応答 | 目印 | ' + ' | '.join(f'判定（{j}）' for j in judges) + ' |')
    out.append('| --- | --- | --- | ' + ' | '.join('---' for _ in judges) + ' |')
    for model_key, corpus_key in conds:
      key = custom_id(case_id, model_key, corpus_key)
      if key not in rows:
        continue
      row = rows[key]
      entry = row['entry']
      if entry['type'] != 'succeeded':
        text = f"（{entry['type']}: {entry.get('error', '')}）"
      elif entry['stop_reason'] == 'refusal':
        text = f"（拒否: {entry.get('refusal')}）"
      else:
        text = entry['text']
      cells = []
      for judge_key in judges:
        verdict = row['verdicts'].get(judge_key)
        cells.append(cell(f"**{verdict['verdict']}** {verdict['reason']}" if verdict else ''))
      out.append(f"| {model_key} × {corpus_key} | {cell(text)} | {cell('・'.join(row['flags']))} | " + ' | '.join(cells) + ' |')
  (run_dir / 'report.md').write_text('\n'.join(out) + '\n')
  print(run_dir / 'report.md')


def cmd_fork(args):
  # 🔴 判定役への指示を直したら、同じ応答を判定し直して一致率を比べる（#508）。応答を投げ直すと
  # 応答の側も変わるので、比べたいものが混ざる。⚠ 元の回の判定は上書きしない。
  source_dir = OUT_DIR / args.run
  state = read_json(source_dir / 'state.json')
  state.pop('judges', None)
  state['source'] = state.get('source', args.run)
  state['created_at'] = datetime.now().isoformat()
  run = datetime.now().strftime('%Y%m%d-%H%M%S')
  run_dir = OUT_DIR / run
  run_dir.mkdir(parents=True)
  (run_dir / 'respond.json').write_text((source_dir / 'respond.json').read_text())
  write_json(run_dir / 'state.json', state)
  print(f"run: {run}（{state['source']} の応答を引き継いだ）")


def cmd_agree(args):
  gold = yaml.safe_load((HERE / 'gold.yaml').read_text())['judgments']
  # ⚠ fork した回を渡されたら、元の回の正解をその回の判定で数える。
  readers = {}
  for run in args.runs:
    readers[read_json(OUT_DIR / run / 'state.json').get('source', run)] = run
  out = ['| 判定役 | 本数 | 一致 | 食い違い | unsure | 判定なし |', '| --- | --- | --- | --- | --- | --- |']
  details = []
  for judge_key in JUDGES:
    counts = {'agree': 0, 'differ': 0, 'unsure': 0, 'missing': 0}
    for item in gold:
      run = readers.get(item['run'], item['run'])
      path = OUT_DIR / run / f'judge-{judge_key}.json'
      key = custom_id(item['case'], *item.get('cond', 'opus--none').split('--'))
      found = read_json(path).get(key) if path.exists() else None
      if not (found and found.get('text')):
        counts['missing'] += 1
        continue
      verdict = json.loads(found['text'])
      if verdict['verdict'] == item['verdict']:
        counts['agree'] += 1
        continue
      counts['unsure' if verdict['verdict'] == 'unsure' else 'differ'] += 1
      minor = '（軽微）' if item.get('minor') else ''
      details.append(
        f"- {judge_key} `{run}` {item['case']}: 正解 **{item['verdict']}**{minor} / 判定 **{verdict['verdict']}**\n"
        f"  - 正解の理由: {item['note']}\n  - 判定の理由: {verdict['reason']}"
      )
    judged = len(gold) - counts['missing']
    if not judged:
      continue
    rate = f"{counts['agree']}（{counts['agree'] / judged:.0%}）" if judged else '0'
    out.append(f"| {judge_key} | {judged} | {rate} | {counts['differ']} | {counts['unsure']} | {counts['missing']} |")
  print('\n'.join(out))
  if details:
    print('\n## 食い違い\n')
    print('\n'.join(details))


# --- 小物 ---

def cell(text):
  return text.replace('|', '\\|').replace('\n', '<br>')


def read_json(path):
  return json.loads(path.read_text())


def write_json(path, value):
  path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
  main()
