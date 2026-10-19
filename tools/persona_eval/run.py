#!/usr/bin/env python3
"""キャラの一貫性の評価実験（pooza/makoto2#19）。

質問の一覧（cases.yaml）を、条件（モデル × 同梱する台詞の件数）ごとに MAKOTO として
答えさせ、判定役のモデルに採点させて、オーナーが読む報告を作る。

    python tools/persona_eval/run.py estimate          # 見積もり（count_tokens だけ・課金なし）
    python tools/persona_eval/run.py respond           # 応答を Batch で投げる（課金あり）
    python tools/persona_eval/run.py collect RUN       # Batch の結果を取り込む（応答 → 判定の順）
    python tools/persona_eval/run.py judge RUN         # 判定を Batch で投げる（課金あり）
    python tools/persona_eval/run.py report RUN        # 報告（report.md）を書く

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

JUDGE_MODEL = 'claude-opus-5-5'

# 単価（USD / 100 万トークン・2026-10 時点）。⚠ Batch はこの半額。
# ⚠ キャッシュの書き込みは 5 分 TTL の 1.25 倍。Batch のキャッシュは当たる保証が無いので、
# 見積もりは「当たらない・毎回書き込む」で引く（上振れ側）。
PRICES = {
  'claude-opus-5-5': {'input': 4.0, 'output': 20.0, 'cache_read': 0.2, 'cache_write': 5.0},
  'claude-sonnet-5-5': {'input': 2.0, 'output': 10.0, 'cache_read': 0.2, 'cache_write': 2.5},
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
- reason: 日本語で 1〜3 文。どこが合っていて、どこが外れているか

⚠ 口調の自然さだけで pass にしないこと。自然な口調で設定を作っている応答は fail。
⚠ 「単純化しない」類型は、外れの形に当たらなくても合格とは限らない。迷ったら unsure。
⚠ 語尾が本編と一致しているかは見ない。

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
  for name in ('collect', 'judge', 'report'):
    p = sub.add_parser(name)
    p.add_argument('run', help='var/persona_eval/runs/ の下の実行の名前')
  p = sub.choices['collect']
  p.add_argument('--wait', action='store_true', help='Batch が終わるまで待つ')
  args = parser.parse_args()
  {
    'estimate': cmd_estimate,
    'respond': cmd_respond,
    'collect': cmd_collect,
    'judge': cmd_judge,
    'report': cmd_report,
  }[args.command](args)


# --- 入力 ---

def load_cases(only=None):
  cases = yaml.safe_load((HERE / 'cases.yaml').read_text())['cases']
  for case in cases:
    for rule in case.get('deny', []):
      re.compile(rule['pattern'])
  if only:
    ids = set(only.split(','))
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


def respond_params(model, system, case):
  return {
    'model': model,
    'max_tokens': MAX_TOKENS,
    'system': system,
    'output_config': {'effort': RESPOND_EFFORT},
    'messages': [{'role': 'user', 'content': case['prompt']}],
  }


def judge_params(persona, case, text):
  user = '\n'.join([
    f"## 質問\n{case['prompt']}",
    f"## 合格の形\n{case.get('expect', '')}",
    f"## 外れの形\n{case.get('fail', '')}",
    f"## MAKOTO の応答\n{text}",
  ])
  return {
    'model': JUDGE_MODEL,
    'max_tokens': MAX_TOKENS,
    'system': [{'type': 'text', 'text': JUDGE_INSTRUCTIONS + persona, 'cache_control': {'type': 'ephemeral'}}],
    'output_config': {
      'effort': JUDGE_EFFORT,
      'format': {'type': 'json_schema', 'schema': JUDGE_SCHEMA},
    },
    'messages': [{'role': 'user', 'content': user}],
  }


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
  key = (config.get('anthropic') or {}).get('api_key')
  # ⚠ キーが無ければ SDK の既定（ANTHROPIC_API_KEY など）に任せる。
  return anthropic.Anthropic(api_key=key) if key else anthropic.Anthropic()


def count_tokens(api, params):
  fields = {k: params[k] for k in ('model', 'system', 'messages')}
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
  cases = load_cases(args.cases)
  persona = load_persona()
  quotes = load_quotes()
  sample = cases[0]
  total = 0.0
  print(f'質問 {len(cases)} 本・応答可の台詞 {len(quotes)} 件')
  print('| 条件 | 入力トークン（1 本） | 本数 | 見積もり（USD） |')
  print('| --- | --- | --- | --- |')
  for model_key, corpus_key in conditions(args):
    model = MODELS[model_key]
    system = system_blocks(persona, corpus_block(quotes, CORPUS[corpus_key]))
    tokens = count_tokens(api, respond_params(model, system, sample))
    usage = {'cache_creation_input_tokens': tokens, 'output_tokens': EXPECTED_OUTPUT_TOKENS}
    amount = cost(model, usage) * len(cases)
    total += amount
    print(f'| {model_key} × {corpus_key} | {tokens:,} | {len(cases)} | {amount:.2f} |')
  n = len(cases) * len(conditions(args))
  judge_tokens = count_tokens(api, judge_params(persona, sample, 'ダミーの応答です。'))
  judge_usage = {'cache_creation_input_tokens': judge_tokens, 'output_tokens': EXPECTED_JUDGE_OUTPUT_TOKENS}
  judge_amount = cost(JUDGE_MODEL, judge_usage) * n
  print(f'| 判定（{JUDGE_MODEL}） | {judge_tokens:,} | {n} | {judge_amount:.2f} |')
  print(f'\n合計の見積もり: ${total + judge_amount:.2f}（Batch の半額・キャッシュが当たらない側で計算）')


def cmd_respond(args):
  api = client()
  cases = load_cases(args.cases)
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
  stage, batch_id = ('judge', state['judge_batch']) if 'judge_batch' in state else ('respond', state['respond_batch'])
  while True:
    batch = api.messages.batches.retrieve(batch_id)
    if batch.processing_status == 'ended':
      break
    counts = batch.request_counts
    print(f'{stage}: {batch.processing_status}（処理中 {counts.processing}・済み {counts.succeeded}）')
    if not args.wait:
      return
    time.sleep(60)
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
  if 'judge_batch' in state:
    sys.exit(f"判定は投げてある（batch {state['judge_batch']}）")
  responses = read_json(run_dir / 'respond.json')
  cases = {c['id']: c for c in load_cases()}
  persona = load_persona()
  requests = []
  for key, entry in responses.items():
    if entry['type'] != 'succeeded' or entry['stop_reason'] == 'refusal':
      continue
    case_id, _, _ = parse_custom_id(key)
    # 🔴 判定役には条件（モデル・台詞の件数）を見せない。
    params = judge_params(persona, cases[case_id], entry['text'])
    requests.append(Request(custom_id=key, params=MessageCreateParamsNonStreaming(**params)))
  batch = api.messages.batches.create(requests=requests)
  state['judge_batch'] = batch.id
  state['judge_model'] = JUDGE_MODEL
  write_json(run_dir / 'state.json', state)
  print(f'judge: {len(requests)} 本（batch {batch.id}）')


def cmd_report(args):
  run_dir = OUT_DIR / args.run
  state = read_json(run_dir / 'state.json')
  responses = read_json(run_dir / 'respond.json')
  judged = read_json(run_dir / 'judge.json') if (run_dir / 'judge.json').exists() else {}
  cases = {c['id']: c for c in load_cases()}
  bodies = [q['body'] for q in load_quotes() if len(q['body']) >= VERBATIM_MIN_LENGTH]
  conds = sorted({parse_custom_id(k)[1:] for k in responses}, key=lambda c: (list(MODELS).index(c[0]), list(CORPUS).index(c[1])))

  rows = {}
  for key, entry in responses.items():
    case_id, model_key, corpus_key = parse_custom_id(key)
    text = entry.get('text', '')
    case = cases[case_id]
    flags = [r['label'] for r in case.get('deny', []) if re.search(r['pattern'], text)]
    if any(b in text for b in bodies):
      flags.append('台詞そのまま')
    verdict = None
    if key in judged and judged[key].get('text'):
      verdict = json.loads(judged[key]['text'])
    rows[key] = {'entry': entry, 'flags': flags, 'verdict': verdict}

  out = [f'# 評価の報告 {args.run}', '']
  out.append(f"- 条件: モデル {state['models']} × 台詞 {state['corpus']}・effort {state['respond_effort']}")
  out.append(f"- 判定役: {state.get('judge_model', '（未実施）')}・条件は見せていない")
  out.append('- 🔴 目印（機械）は外れの検出だけ。当たらなくても合格とは限らない')
  out.append('')
  out.append('## 条件ごとのまとめ')
  out.append('')
  out.append('| 条件 | 本数 | pass | fail | unsure | 目印あり | 平均の長さ | 拒否・失敗 | 応答の費用（USD） |')
  out.append('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
  for model_key, corpus_key in conds:
    keys = [k for k in rows if parse_custom_id(k)[1:] == (model_key, corpus_key)]
    verdicts = [rows[k]['verdict']['verdict'] for k in keys if rows[k]['verdict']]
    texts = [rows[k]['entry'].get('text', '') for k in keys]
    broken = sum(1 for k in keys if rows[k]['entry']['type'] != 'succeeded' or rows[k]['entry'].get('stop_reason') == 'refusal')
    spent = sum(cost(MODELS[model_key], rows[k]['entry']['usage']) for k in keys if 'usage' in rows[k]['entry'])
    flagged = sum(1 for k in keys if rows[k]['flags'])
    avg = sum(len(t) for t in texts) / len(texts) if texts else 0
    out.append(
      f'| {model_key} × {corpus_key} | {len(keys)} | {verdicts.count("pass")} | {verdicts.count("fail")} '
      f'| {verdicts.count("unsure")} | {flagged} | {avg:.0f} 字 | {broken} | {spent:.2f} |'
    )
  judge_spent = sum(cost(JUDGE_MODEL, e['usage']) for e in judged.values() if 'usage' in e)
  out.append('')
  out.append(f'判定の費用: ${judge_spent:.2f}')
  out.append('')
  out.append('## 質問ごと')
  for case_id in state['cases']:
    case = cases[case_id]
    out.append('')
    out.append(f"### {case_id}（{case['axis']}）")
    out.append('')
    out.append(f"> {case['prompt']}")
    out.append('')
    out.append(f"- 合格の形: {case.get('expect', '')}")
    out.append(f"- 外れの形: {case.get('fail', '')}")
    out.append('')
    out.append('| 条件 | 応答 | 目印 | 判定 |')
    out.append('| --- | --- | --- | --- |')
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
      verdict = row['verdict']
      judged_text = f"**{verdict['verdict']}** {verdict['reason']}" if verdict else ''
      out.append(f"| {model_key} × {corpus_key} | {cell(text)} | {cell('・'.join(row['flags']))} | {cell(judged_text)} |")
  (run_dir / 'report.md').write_text('\n'.join(out) + '\n')
  print(run_dir / 'report.md')


# --- 小物 ---

def cell(text):
  return text.replace('|', '\\|').replace('\n', '<br>')


def read_json(path):
  return json.loads(path.read_text())


def write_json(path, value):
  path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
  main()
