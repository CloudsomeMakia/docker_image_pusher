#!/usr/bin/env bash
set -euo pipefail

# Only mocks are put on PATH; no real Docker, network, or Secrets are used.
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

script = Path(sys.argv[1]) / 'scripts/push_images_and_notify.sh'
mock = r'''
import json
import os
from pathlib import Path
import sys

state = Path(os.environ['MOCK_STATE'])
args = sys.argv[1:]
kind = Path(sys.argv[0]).name

def record(name, value):
    with (state / name).open('a') as f:
        f.write(json.dumps(value) + '\n')

if kind == 'sleep':
    record('sleeps', args)
    sys.exit(0)
if kind == 'docker':
    op = args[0]
    if op == 'login':
        assert args == ['login', '--username', os.environ['ALIYUN_REGISTRY_USER'],
                        '--password-stdin', os.environ['ALIYUN_REGISTRY']]
        assert sys.stdin.read() == os.environ['ALIYUN_REGISTRY_PASSWORD'] + '\n'
        record('docker', ['login'])
    else:
        record('docker', args)
    if op == os.environ.get('FAIL_OP') and 'mysql:8.0' in args[1:]:
        print(os.environ['ALIYUN_REGISTRY_PASSWORD'], file=sys.stderr)
        sys.exit(1)
    if op == 'push' and os.environ.get('FAIL_OP') == 'push' and args[1].endswith('mysql:8.0'):
        print(os.environ['ALIYUN_REGISTRY_PASSWORD'], file=sys.stderr)
        sys.exit(1)
    if op == 'image':
        if os.environ.get('INSPECT_MODE') == 'fail':
            sys.exit(1)
        source = args[-1].split('@')[0]
        repository = source.rsplit(':', 1)[0]
        if '/' not in repository:
            repository = 'docker.io/library/' + repository
        if os.environ.get('INSPECT_MODE') == 'unrelated':
            repository = 'unrelated/image'
        print(json.dumps([repository + '@sha256:' + 'a' * 64]))
    sys.exit(0)

assert kind == 'curl'
assert args[0] == '--disable'
assert '-sS' in args and '-v' not in args and '--location' not in args
assert args[args.index('--request') + 1] == 'POST'
assert args[args.index('--url') + 1] == os.environ['IMAGE_PUSH_WEBHOOK_URL']
headers = [args[i + 1] for i, arg in enumerate(args) if arg == '-H']
assert headers == ['Content-Type: application/json', os.environ['IMAGE_PUSH_WEBHOOK_AUTHORIZATION']]
assert 0 < int(args[args.index('--max-time') + 1]) <= 30
assert 0 < int(args[args.index('--connect-timeout') + 1]) <= 10
assert args[args.index('-w') + 1] == '%{http_code}'
payload_arg = args[args.index('--data-binary') + 1]
assert payload_arg.startswith('@')
payload = json.loads(Path(payload_arg[1:]).read_text())
# Notification must follow both successful pushes.
operations = [json.loads(line) for line in (state / 'docker').read_text().splitlines()]
assert sum(op[0] == 'push' for op in operations) == int(os.environ['EXPECTED_IMAGES'])
record('payloads', payload)
responses = os.environ.get('RESPONSES', '204').split(',')
count = len((state / 'payloads').read_text().splitlines())
response = responses[min(count - 1, len(responses) - 1)]
# Simulate potentially sensitive response bodies and curl diagnostics.
Path(args[args.index('-o') + 1]).write_text(os.environ['IMAGE_PUSH_WEBHOOK_AUTHORIZATION'])
if response == 'timeout':
    print(os.environ['IMAGE_PUSH_WEBHOOK_URL'], file=sys.stderr)
    print('000', end='')
    sys.exit(28)
print(response, end='')
'''

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    for name in ('docker', 'curl', 'sleep'):
        path = bin_dir / name
        path.write_text('#!' + sys.executable + '\n' + mock)
        path.chmod(0o700)

    base = {
        'PATH': str(bin_dir) + os.pathsep + os.defpath,
        'HOME': str(root),
        'ALIYUN_REGISTRY': 'registry.example.invalid',
        'ALIYUN_NAME_SPACE': 'test-space',
        'ALIYUN_REGISTRY_USER': 'fake-private-user-sentinel',
        'ALIYUN_REGISTRY_PASSWORD': 'fake-private-password-sentinel',
        'IMAGE_PUSH_WEBHOOK_URL': 'https://webhook.invalid/fake-private-url-sentinel',
        'IMAGE_PUSH_WEBHOOK_AUTHORIZATION': 'Authorization: Bearer fake-private-token-sentinel',
        'GITHUB_REPOSITORY': 'test-owner/test-repo',
        'GITHUB_RUN_ID': '12345',
        'GITHUB_RUN_ATTEMPT': '2',
        'GITHUB_SHA': 'b' * 40,
        'GITHUB_REF_NAME': 'test-"branch\\name',
        'GITHUB_SERVER_URL': 'https://github.example.invalid',
        'EXPECTED_IMAGES': '2',
    }
    default_images = ('# ignored\n\n  # ignored too\n   \n'
                      '--platform=linux/arm64 casbin/casdoor:v4.29.0\n'
                      '--platform=linux/arm64 mysql:8.0')
    target_prefix = base['ALIYUN_REGISTRY'] + '/' + base['ALIYUN_NAME_SPACE'] + '/'

    def case(name, *, changes=None, missing=(), images=default_images,
             success=True, calls=1, error=None):
        work = root / name
        work.mkdir()
        (work / 'images.txt').write_text(images)
        env = dict(base, MOCK_STATE=str(work))
        env.update(changes or {})
        for key in missing:
            env.pop(key, None)
        result = subprocess.run(['bash', str(script)], cwd=work, env=env,
                                capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        payload_path = work / 'payloads'
        payload_text = payload_path.read_text() if payload_path.exists() else ''
        for secret in (base['ALIYUN_REGISTRY_USER'], base['ALIYUN_REGISTRY_PASSWORD'],
                       base['IMAGE_PUSH_WEBHOOK_URL'], base['IMAGE_PUSH_WEBHOOK_AUTHORIZATION'],
                       'fake-private-token-sentinel', 'Authorization:'):
            assert secret not in output + payload_text, name + ': sensitive output'
        assert (result.returncode == 0) == success, name + ': unexpected exit status'
        if error:
            assert error in output, name + ': missing safe error message'
        payloads = [json.loads(line) for line in payload_text.splitlines()]
        assert len(payloads) == calls, name + ': unexpected notification count'
        operations_path = work / 'docker'
        operations = ([json.loads(line) for line in operations_path.read_text().splitlines()]
                      if operations_path.exists() else [])
        for payload in payloads:
            assert payload['repo'] == base['GITHUB_REPOSITORY']
            assert payload['run_id'] == base['GITHUB_RUN_ID']
            assert payload['run_attempt'] == base['GITHUB_RUN_ATTEMPT']
            assert payload['sha'] == base['GITHUB_SHA']
            assert payload['branch'] == base['GITHUB_REF_NAME']
            assert payload['run_url'] == 'https://github.example.invalid/test-owner/test-repo/actions/runs/12345'
            assert payload['status'] == 'success'
            assert len(payload['images']) == int(env['EXPECTED_IMAGES'])
        assert all(p == payloads[0] for p in payloads), name + ': retry payload changed'
        sleep_path = work / 'sleeps'
        sleeps = sleep_path.read_text().splitlines() if sleep_path.exists() else []
        assert len(sleeps) == max(0, calls - 1), name + ': unexpected backoff count'
        print('PASS: ' + name)
        return payloads, operations

    payloads, operations = case('success')
    assert payloads[0]['images'] == [
        {'source': 'casbin/casdoor:v4.29.0', 'target': target_prefix + 'linux_arm64_casdoor:v4.29.0',
         'platform': 'linux/arm64', 'digest': 'casbin/casdoor@sha256:' + 'a' * 64},
        {'source': 'mysql:8.0', 'target': target_prefix + 'linux_arm64_mysql:8.0',
         'platform': 'linux/arm64', 'digest': 'docker.io/library/mysql@sha256:' + 'a' * 64},
    ]
    assert [op for op in operations if op[0] == 'pull'] == [
        ['pull', '--platform=linux/arm64', 'casbin/casdoor:v4.29.0'],
        ['pull', '--platform=linux/arm64', 'mysql:8.0'],
    ]
    for op in ('pull', 'tag', 'push'):
        _, operations = case(op + '-failure', changes={'FAIL_OP': op}, success=False, calls=0,
                             error='docker ' + op + ' failed')
        assert sum(entry[0] == 'push' for entry in operations) <= (2 if op == 'push' else 1)
    for key in ('IMAGE_PUSH_WEBHOOK_URL', 'IMAGE_PUSH_WEBHOOK_AUTHORIZATION'):
        for empty in (False, True):
            _, operations = case(key + ('-empty' if empty else '-missing'),
                                 changes={key: ''} if empty else {}, missing=() if empty else (key,),
                                 success=False, calls=0, error='Missing required secret: ' + key)
            assert not operations
    case('http-failure', changes={'RESPONSES': '503'}, success=False, calls=3, error='HTTP 503')
    case('timeout-failure', changes={'RESPONSES': 'timeout'}, success=False, calls=3, error='HTTP 000')
    case('redirect-failure', changes={'RESPONSES': '302'}, success=False, calls=3)
    case('retry-success', changes={'RESPONSES': '503,timeout,200'}, calls=3)
    for mode in ('fail', 'unrelated'):
        payloads, _ = case('inspect-' + mode, changes={'INSPECT_MODE': mode})
        assert all('digest' not in image for image in payloads[0]['images'])
    payloads, _ = case('collision-and-no-platform', images=(
        '--platform linux/arm64 xhofe/alist:latest\n'
        '--platform=linux/arm64 xiaoyaliu/alist:latest\n'
        'mysql:8.0\n'), changes={'EXPECTED_IMAGES': '3'})
    assert [image['target'] for image in payloads[0]['images']] == [
        target_prefix + 'linux_arm64_xhofe_alist:latest',
        target_prefix + 'linux_arm64_xiaoyaliu_alist:latest',
        target_prefix + 'mysql:8.0',
    ]
    assert 'platform' not in payloads[0]['images'][2]
    payloads, _ = case('same-namespace-not-collision', images='casbin/casdoor:v1\ncasbin/casdoor:v2\n')
    assert [image['target'] for image in payloads[0]['images']] == [
        target_prefix + 'casdoor:v1', target_prefix + 'casdoor:v2']
print('All mock tests passed (no network or real images).')
PY
