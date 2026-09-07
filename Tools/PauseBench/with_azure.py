#!/usr/bin/env python3
"""Run the pause benchmark with AzureSTT from 1Password, without a plaintext env file."""
import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit


def main():
    response = subprocess.run(['op', 'item', 'get', 'AzureSTT', '--vault', 'Private', '--format', 'json'],
                              capture_output=True, text=True, timeout=150)
    if response.returncode:
        raise SystemExit('1Password could not authorize AzureSTT access. Approve access in 1Password and retry.')
    item = json.loads(response.stdout)
    fields = {str(f.get('label', '')).lower(): f.get('value', '') for f in item.get('fields', [])}
    key = fields.get('key') or fields.get('password')
    endpoint = fields.get('endpoint')
    if not endpoint:
        urls = item.get('urls', [])
        endpoint = next((u.get('href') for u in urls if str(u.get('label', '')).lower() == 'endpoint'), None)
        if not endpoint and len(urls) == 1: endpoint = urls[0].get('href')
    if not key or not endpoint:
        raise SystemExit('AzureSTT must contain a key/password and an endpoint field or URL.')
    # Tolerate accidental whitespace when pasting the resource URL into 1Password.
    endpoint = ''.join(endpoint.split())
    parsed = urlsplit(endpoint)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query:
        raise SystemExit('AzureSTT endpoint must be an HTTPS Azure resource root without credentials or query parameters.')
    env = os.environ.copy()
    env.update(AZURE_SPEECH_KEY=key.strip(), AZURE_SPEECH_ENDPOINT=endpoint)
    def command(args):
        if args and args[0] == 'natural':
            return [sys.executable, str(Path(__file__).with_name('natural.py')), *args[1:]]
        return [sys.executable, str(Path(__file__).with_name('bench.py')), *args]

    # A live session supports several benchmark iterations under one authorization.
    # Only benchmark argument arrays are accepted; no shell or arbitrary program.
    if sys.argv[1:] == ['--session']:
        print('Azure benchmark session ready. Credentials are held in memory only.', flush=True)
        for line in sys.stdin:
            if line.strip() == 'exit': return
            try:
                args = json.loads(line)
                if not isinstance(args, list) or not args or args[0] not in ('run', 'natural') or not all(isinstance(x, str) for x in args):
                    raise ValueError('Expected a benchmark run argument array')
                status = subprocess.run(command(args), env=env).returncode
                print(f'Benchmark finished: exit {status}', flush=True)
            except (ValueError, OSError) as error:
                print(f'Invalid benchmark request: {error}', flush=True)
        return
    raise SystemExit(subprocess.run(command(sys.argv[1:]), env=env).returncode)

if __name__ == '__main__': main()
