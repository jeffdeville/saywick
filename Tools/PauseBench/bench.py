#!/usr/bin/env python3
"""Reproducible raw-ASR comparison; standard library only (fixtures use macOS say/ffmpeg)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ('handy', 'legacy500', 'server1500', 'server2000', 'azureSemantic')
WORDS = re.compile(r"[\w]+(?:['’][\w]+)*", re.UNICODE)


def tokens(text):
    return list(WORDS.finditer(text))


def alignment(reference, actual):
    """Levenshtein word alignment; only exact matches can anchor pause scoring."""
    a = [x.group().casefold().replace('’', "'") for x in tokens(reference)]
    b = [x.group().casefold().replace('’', "'") for x in tokens(actual)]
    dp = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a)+1): dp[i][0] = i
    for j in range(len(b)+1): dp[0][j] = j
    for i in range(1, len(a)+1):
        for j in range(1, len(b)+1):
            dp[i][j] = min(dp[i-1][j]+1, dp[i][j-1]+1, dp[i-1][j-1]+(a[i-1] != b[j-1]))
    i, j = len(a), len(b)
    matched = {}
    while i or j:
        if i and j and dp[i][j] == dp[i-1][j-1]+(a[i-1] != b[j-1]):
            if a[i-1] == b[j-1]: matched[i-1] = j-1
            i -= 1; j -= 1
        elif i and dp[i][j] == dp[i-1][j]+1: i -= 1
        else: j -= 1
    return dp[-1][-1], matched


def score(case, actual):
    edits, matched = alignment(case['reference'], actual)
    ref, out = tokens(case['reference']), tokens(actual)
    result = dict(word_edits=edits, reference_words=len(ref), wer=edits / max(1, len(ref)),
                  false_sentence_breaks=0, false_capitals=0, unexpected_capitals=0, missed_sentence_breaks=0,
                  unscorable_pauses=0, scored_pauses=0)
    result['unexpected_capitals'] = sum(ref[i].group()[0].islower() and out[j].group()[0].isupper()
                                        for i, j in matched.items())
    for pause in case['pauses']:
        right = pause['before_word']
        # Adjacent exact matches prevent omissions/repeated words from misleading the metric.
        if right-1 not in matched or right not in matched or matched[right] != matched[right-1]+1:
            result['unscorable_pauses'] += 1
            continue
        left_out, right_out = out[matched[right-1]], out[matched[right]]
        punctuation = actual[left_out.end():right_out.start()]
        terminal = bool(re.search(r'[.!?。！？]', punctuation))
        result['scored_pauses'] += 1
        if pause['kind'] == 'thinking':
            result['false_sentence_breaks'] += int(terminal)
            # A proper noun or "I" is not a false capital.
            expected = ref[right].group()
            result['false_capitals'] += int(expected[0].islower() and right_out.group()[0].isupper())
        else:
            result['missed_sentence_breaks'] += int(not terminal)
    return result


def read_wav(path):
    with wave.open(str(path), 'rb') as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getcomptype()) != (1, 2, 16000, 'NONE'):
            raise ValueError(f'{path}: expected mono 16 kHz PCM16 WAV')
        return w.readframes(w.getnframes())


def write_wav(path, pcm):
    with wave.open(str(path), 'wb') as w:
        w.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        w.writeframes(pcm)


def synthesize(text, path, voice):
    aiff = path.with_suffix('.aiff')
    subprocess.run(['say', '-v', voice, '-r', '155', '-o', str(aiff), text], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(aiff), '-ac', '1', '-ar', '16000',
                    '-c:a', 'pcm_s16le', str(path)], check=True)
    pcm = read_wav(path)
    # Remove TTS's outside silence so inserted gaps are controlled; preserve 20 ms margins.
    import array
    values = array.array('h', pcm)
    if os.sys.byteorder != 'little': values.byteswap()
    voiced = [i for i, v in enumerate(values) if abs(v) > 150]
    if not voiced: raise ValueError('TTS produced no speech')
    start, end = max(0, voiced[0]-320), min(len(values), voiced[-1]+321)
    return pcm[start*2:end*2]


def generate(args):
    dest = Path(args.output).resolve(); dest.mkdir(parents=True, exist_ok=True)
    scenarios = [
        ('thinking', 'I would like to send the report', 'after we review the numbers',
         'I would like to send the report after we review the numbers.'),
        ('thinking', 'Please remind me to pick up', 'the blue notebook tomorrow',
         'Please remind me to pick up the blue notebook tomorrow.'),
        ('sentence', 'The report is ready.', 'Please send it tomorrow.',
         'The report is ready. Please send it tomorrow.'),
    ]
    cases = []
    for n, (kind, left, right, reference) in enumerate(scenarios):
        a = synthesize(left, dest / f'part-{n}-a.wav', args.voice)
        b = synthesize(right, dest / f'part-{n}-b.wav', args.voice)
        for gap in (0, 500, 1000, 2000, 5000):
            name = f'{kind}-{n}-{gap}ms'
            # Identical speech samples for every gap duration, with leading/trailing margins.
            pcm = bytes(6400) + a + bytes(gap*32) + b + bytes(16000)
            wav = dest / f'{name}.wav'; write_wav(wav, pcm)
            cases.append(dict(id=name, wav=wav.name, reference=reference, source='synthetic-segmented',
                              pauses=[dict(before_word=len(tokens(left)), kind=kind,
                                           inserted_ms=gap, audio_start_ms=200+len(a)/32)]))
    (dest/'manifest.json').write_text(json.dumps(dict(version=1, voice=args.voice, cases=cases), indent=2)+'\n')
    print(dest/'manifest.json')


def challenge(args):
    """Repeatable follow-up to the starter corpus: hard pauses and Stop timing."""
    source = Path(args.manifest).resolve()
    manifest = json.loads(source.read_text())
    dest = Path(args.output).resolve(); dest.mkdir(parents=True, exist_ok=True)
    by_id = {c['id']: c for c in manifest['cases']}
    selected = ['thinking-1-2000ms', 'thinking-1-5000ms', 'sentence-2-5000ms']
    required = selected + ['thinking-0-0ms']
    if not all(k in by_id for k in required): raise ValueError('Challenge requires the generated starter corpus')
    cases = [dict(by_id[k], wav=str(source.parent/by_id[k]['wav'])) for k in selected]
    base = by_id['thinking-0-0ms']
    pcm = read_wav(source.parent/base['wav'])
    for name, audio in [('stop-immediate', pcm[:-16000]), ('stop-after-idle', pcm+bytes(5*32000))]:
        path = dest/(name+'.wav'); write_wav(path, audio)
        cases.append(dict(base, id=name, wav=str(path)))
    output = dest/'manifest.json'
    output.write_text(json.dumps(dict(version=1, cases=cases), indent=2)+'\n')
    print(output)


def run(args):
    manifest_path = Path(args.manifest).resolve()
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('version') != 1: raise ValueError('Unsupported manifest version')
    ids = [case['id'] for case in manifest['cases']]
    if not ids or len(set(ids)) != len(ids): raise ValueError('Corpus must have unique, nonempty case IDs')
    dest = Path(args.output).resolve(); dest.mkdir(parents=True, exist_ok=True)
    rows = []
    run_meta = dict(manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                    git_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    git_diff_sha256=hashlib.sha256(subprocess.check_output(['git', 'diff'], cwd=ROOT)).hexdigest(),
                    profiles=args.profiles, repeats=args.repeats)
    # Include untracked harness files and exact runner binaries, not only git diff.
    source_paths = sorted((ROOT/'Tools/PauseBench').rglob('*.py')) + sorted((ROOT/'Tools/PauseBench').rglob('*.swift')) + sorted((ROOT/'Tools/PauseBench/HandyRunner').rglob('*.rs'))
    source_paths += [ROOT/'Tools/PauseBench/HandyRunner/Cargo.lock', ROOT/'Sources/VoiceKeyboardCore/VoiceLiveProtocol.swift']
    run_meta['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths}
    run_meta['runner_sha256'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in map(Path, (args.azure_bin, args.handy_bin)) if p.is_file()}
    if args.handy_model and Path(args.handy_model).is_file():
        with open(args.handy_model, 'rb') as f: run_meta['handy_model_sha256'] = hashlib.file_digest(f, 'sha256').hexdigest()
    (dest/'run.json').write_text(json.dumps(run_meta, indent=2)+'\n')
    cases = manifest['cases'][:args.limit] if args.limit else manifest['cases']
    for case in cases:
        if not re.fullmatch(r'[A-Za-z0-9_-]+', case['id']): raise ValueError('Unsafe case id')
        if not tokens(case['reference']): raise ValueError('Empty reference')
        for pause in case['pauses']:
            if pause['kind'] not in ('thinking', 'sentence') or not 0 < pause['before_word'] < len(tokens(case['reference'])):
                raise ValueError('Invalid pause annotation')
        source = manifest_path.parent/case['wav']
        pcm = read_wav(source)
        pcm_path = dest/f"{case['id']}.pcm"; pcm_path.write_bytes(pcm)
        for repeat in range(args.repeats):
            for profile in args.profiles:
                result_path = dest/f"{case['id']}-{profile}-{repeat}.json"
                # Old output must never masquerade as a successful new invocation.
                result_path.unlink(missing_ok=True)
                result = dict(status='skipped')
                if profile == 'handy':
                    if not args.handy_model or not args.silero_model or not Path(args.handy_bin).is_file():
                        result['reason'] = 'Handy runner/model/VAD model not configured'
                        command = None
                    else:
                        command = [args.handy_bin, args.handy_model, str(source), str(result_path), args.silero_model, args.handy_vad]
                elif not os.environ.get('AZURE_SPEECH_KEY') or not os.environ.get('AZURE_SPEECH_ENDPOINT'):
                    result['reason'] = 'Azure credentials unavailable'; command = None
                else:
                    command = [args.azure_bin, profile, str(pcm_path), str(result_path)]
                print(f"{case['id']} {profile} repeat={repeat+1}", flush=True)
                if command:
                    try:
                        child_env = os.environ.copy()
                        if profile == 'handy':
                            child_env.pop('AZURE_SPEECH_KEY', None)
                            child_env.pop('AZURE_SPEECH_ENDPOINT', None)
                        completed = subprocess.run(command, capture_output=True, text=True, env=child_env, timeout=len(pcm)/32000+120)
                        if result_path.exists(): result = json.loads(result_path.read_text())
                        else: result = dict(status='error', error=completed.stderr[-3000:])
                        if completed.returncode and result.get('status') == 'ok':
                            result = dict(status='error', error=f'Runner exited {completed.returncode}')
                    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
                        result = dict(status='error', error=str(e))
                if result.get('status') == 'ok' and not result.get('text', '').strip():
                    result['status'] = 'error'
                    result['error'] = 'Recognizer returned no text for a fixture with expected speech'
                if result.get('status') == 'ok':
                    result['metrics'] = score(case, result['text'])
                    result['finalization_ms'] = result['elapsed_ms'] - result['stop_ms']
                result.update(case_id=case['id'], profile=profile, repeat=repeat,
                              reference=case['reference'], audio_sha256=hashlib.sha256(pcm).hexdigest(),
                              pauses=case['pauses'])
                encoded = json.dumps(result, indent=2)
                secret = os.environ.get('AZURE_SPEECH_KEY')
                if secret: encoded = encoded.replace(secret, '[redacted]')
                result_path.write_text(encoded+'\n')
                rows.append(result)
                report(rows, dest)
    if not any(r['status'] == 'ok' for r in rows): raise SystemExit('No successful recognizer runs; see report.md')
    print(dest/'report.md')
    if args.require_all and any(r['status'] != 'ok' for r in rows):
        raise SystemExit('Incomplete comparison: some recognizer runs were skipped or failed')
    if args.check_candidate:
        issues = regression_issues(rows, args.check_candidate)
        if issues: raise SystemExit('Regression check failed: ' + '; '.join(issues))


def regression_issues(rows, candidate):
    baseline = {(r['case_id'], r['repeat']): r for r in rows if r['profile'] == 'legacy500'}
    proposed = {(r['case_id'], r['repeat']): r for r in rows if r['profile'] == candidate}
    if not baseline or baseline.keys() != proposed.keys(): return ['missing matched baseline/candidate runs']
    if any(r['status'] != 'ok' for r in list(baseline.values())+list(proposed.values())):
        return ['baseline/candidate contains skipped or failed runs']
    issues = []
    for key in baseline:
        if baseline[key]['audio_sha256'] != proposed[key]['audio_sha256']:
            return ['baseline/candidate audio differs']
    for metric in ('word_edits', 'false_sentence_breaks', 'false_capitals', 'unexpected_capitals', 'missed_sentence_breaks', 'unscorable_pauses'):
        old = sum(r['metrics'][metric] for r in baseline.values())
        new = sum(r['metrics'][metric] for r in proposed.values())
        if new > old: issues.append(f'{metric}: {old} -> {new}')
    return issues


def report(rows, dest):
    lines = ['# Raw pause benchmark', '',
             'Handy is a comparison, not ground truth. Scores use the annotated reference. Lower is better.', '',
             '| Profile | OK / skipped / failed | Word error rate | False breaks | Pause capitals | All unexpected capitals | Missed true breaks | Unscorable pauses |',
             '|---|---:|---:|---:|---:|---:|---:|---:|']
    for profile in PROFILES:
        group = [r for r in rows if r['profile'] == profile]
        if not group: continue
        ok = [r for r in group if r['status'] == 'ok']
        counts = f"{len(ok)} / {sum(r['status']=='skipped' for r in group)} / {sum(r['status']=='error' for r in group)}"
        if not ok: lines.append(f'| {profile} | {counts} | — | — | — | — | — | — |'); continue
        sums = {k: sum(r['metrics'][k] for r in ok) for k in ok[0]['metrics']}
        lines.append(f"| {profile} | {counts} | {sums['word_edits']/sums['reference_words']:.1%} | "
                     f"{sums['false_sentence_breaks']} | {sums['false_capitals']} | {sums['unexpected_capitals']} | {sums['missed_sentence_breaks']} | {sums['unscorable_pauses']} |")
    lines += ['', '## Matched comparison with legacy500', '']
    for candidate in ('server1500', 'server2000', 'azureSemantic'):
        issues = regression_issues(rows, candidate)
        lines.append(f"- {candidate}: " + ('; '.join(issues) if issues else 'No aggregate accuracy regression on matched runs.'))
    lines += ['', 'This is an accuracy check, not proof of improvement. Inspect latency and individual failures too.',
              '', '## Individual outputs', '']
    for r in rows:
        lines += [f"### {r['case_id']} · {r['profile']} · repeat {r['repeat']+1}", '', f"Reference: {r['reference']}", '']
        if r['status'] == 'ok':
            lines += [f"Raw: {r['text']}", '', f"Finalization after Stop: {r['finalization_ms']:.0f} ms", '']
        else: lines += [f"{r['status']}: {r.get('reason', r.get('error', 'unknown'))}", '']
    (dest/'report.md').write_text('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    gen = sub.add_parser('generate'); gen.add_argument('--output', default='.build/pause-bench/corpus')
    gen.add_argument('--voice', default='Samantha'); gen.set_defaults(func=generate)
    followup = sub.add_parser('challenge')
    followup.add_argument('manifest'); followup.add_argument('--output', required=True)
    followup.set_defaults(func=challenge)
    run_parser = sub.add_parser('run')
    run_parser.add_argument('manifest'); run_parser.add_argument('--output', required=True)
    run_parser.add_argument('--profiles', nargs='+', choices=PROFILES, default=list(PROFILES))
    run_parser.add_argument('--require-all', action='store_true', help='Fail when any requested run is skipped or fails')
    run_parser.add_argument('--check-candidate', choices=PROFILES[2:], help='Fail on incomplete or worse accuracy than legacy500')
    run_parser.add_argument('--repeats', type=int, default=1); run_parser.add_argument('--limit', type=int)
    run_parser.add_argument('--azure-bin', default=str(ROOT/'.build/debug/pause-bench-azure'))
    run_parser.add_argument('--handy-bin', default=str(ROOT/'.build/PauseBenchHandy/release/pause-bench-handy'))
    run_parser.add_argument('--handy-model'); run_parser.add_argument('--silero-model')
    run_parser.add_argument('--handy-vad', choices=('silero','earshot','off'), default='silero')
    run_parser.set_defaults(func=run)
    args = parser.parse_args()
    if hasattr(args, 'repeats') and args.repeats < 1: parser.error('--repeats must be positive')
    args.func(args)

if __name__ == '__main__': main()
