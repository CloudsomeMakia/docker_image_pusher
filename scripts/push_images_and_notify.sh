#!/usr/bin/env bash
set -euo pipefail
umask 077

for key in IMAGE_PUSH_WEBHOOK_URL IMAGE_PUSH_WEBHOOK_AUTHORIZATION; do
    if [[ -z "${!key:-}" ]]; then
        printf 'Missing required secret: %s\n' "$key" >&2
        exit 1
    fi
done

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
: > "$work_dir/images.tsv"

# Do not expose Docker diagnostics, which may contain credentials.
run_docker() {
    if ! docker "$@" > /dev/null 2>&1; then
        printf 'docker %s failed\n' "$1" >&2
        exit 1
    fi
}
printf '%s\n' "$ALIYUN_REGISTRY_PASSWORD" |
    run_docker login --username "$ALIYUN_REGISTRY_USER" --password-stdin "$ALIYUN_REGISTRY"

# Same collision rule: only differing source namespaces add a namespace prefix.
declare -A duplicate_images=()
declare -A temp_map=()
parse_line() {
    read -r -a pull_args <<< "$line"
    source=${pull_args[${#pull_args[@]}-1]}
    image=${source%%@*}
    image_name_tag=${image##*/}
    image_name=${image_name_tag%%:*}
    IFS=/ read -r -a parts <<< "$image"
    name_space=""
    if [[ ${#parts[@]} == 3 ]]; then
        name_space=${parts[1]}
    elif [[ ${#parts[@]} == 2 ]]; then
        name_space=${parts[0]}
    fi
}
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    parse_line
    if [[ -n "${temp_map[$image_name]:-}" ]]; then
        if [[ "${temp_map[$image_name]}" != "${name_space}_" ]]; then
            duplicate_images[$image_name]=true
        fi
    else
        temp_map[$image_name]="${name_space}_"
    fi
done < images.txt

index=0
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    parse_line
    # Pass all whitespace-separated arguments, including --platform, without eval/globbing.
    run_docker pull "${pull_args[@]}"
    platform=""
    for ((i=0; i<${#pull_args[@]}-1; i++)); do
        case "${pull_args[i]}" in
            --platform=*) platform=${pull_args[i]#--platform=} ;;
            --platform) platform=${pull_args[i+1]} ;;
        esac
    done
    platform_prefix=""
    if [[ -n "$platform" ]]; then
        platform_prefix="${platform//\//_}_"
    fi
    name_space_prefix=""
    if [[ -n "${duplicate_images[$image_name]:-}" && -n "$name_space" ]]; then
        name_space_prefix="${name_space}_"
    fi
    target="$ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/$platform_prefix$name_space_prefix$image_name_tag"
    run_docker tag "$source" "$target"
    run_docker push "$target"

    # Inspect the pulled source before cleanup. A missing/ambiguous digest is optional.
    if ! docker image inspect --format '{{json .RepoDigests}}' "$source" \
        > "$work_dir/digests-$index.json" 2>/dev/null; then
        printf 'null\n' > "$work_dir/digests-$index.json"
    fi
    printf '%s\t%s\t%s\n' "$source" "$target" "$platform" >> "$work_dir/images.tsv"
    index=$((index + 1))
    echo '开始清理磁盘空间'
    df -hT
    run_docker rmi "$source"
    run_docker rmi "$target"
    echo '磁盘空间清理完毕'
    df -hT
done < images.txt

python3 - "$work_dir" <<'PY'
import json
import os
from pathlib import Path
import re
import sys

work = Path(sys.argv[1])

def repository(reference):
    name = reference.split('@', 1)[0]
    if ':' in name.rsplit('/', 1)[-1]:
        name = name.rsplit(':', 1)[0]
    parts = name.split('/')
    if len(parts) == 1 or not ('.' in parts[0] or ':' in parts[0] or parts[0] == 'localhost'):
        parts.insert(0, 'docker.io')
    if parts[0] == 'index.docker.io':
        parts[0] = 'docker.io'
    if parts[0] == 'docker.io' and len(parts) == 2:
        parts.insert(1, 'library')
    return '/'.join(parts)

images = []
for index, line in enumerate((work / 'images.tsv').read_text().splitlines()):
    source, target, platform = line.split('\t')
    image = {'source': source, 'target': target}
    if platform:
        image['platform'] = platform
    try:
        digests = json.loads((work / f'digests-{index}.json').read_text())
    except (ValueError, OSError):
        digests = None
    if isinstance(digests, list):
        # Never take an arbitrary RepoDigest from another repository/tag history.
        matches = sorted({digest for digest in digests
                          if isinstance(digest, str)
                          and re.fullmatch(r'[^\s@]+@sha256:[0-9a-f]{64}', digest)
                          and repository(digest) == repository(source)
                          and ('@' not in source or digest.split('@')[1] == source.split('@')[1])})
        if len(matches) == 1:
            image['digest'] = matches[0]
    images.append(image)

env = os.environ
payload = {
    'repo': env['GITHUB_REPOSITORY'],
    'run_id': env['GITHUB_RUN_ID'],
    'run_attempt': env['GITHUB_RUN_ATTEMPT'],
    'sha': env['GITHUB_SHA'],
    'branch': env['GITHUB_REF_NAME'],
    'run_url': f"{env['GITHUB_SERVER_URL'].rstrip('/')}/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}",
    'status': 'success',
    'images': images,
}
with (work / 'payload.json').open('w') as file:
    json.dump(payload, file)
PY

# No redirects or curl config: do not forward the auth header to another endpoint.
# Suppress stderr too: curl errors can include the URL. Never print the response body.
for attempt in 1 2 3; do
    if http_code=$(curl --disable -sS -o "$work_dir/response" -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 --request POST \
        -H 'Content-Type: application/json' \
        -H "$IMAGE_PUSH_WEBHOOK_AUTHORIZATION" \
        --data-binary "@$work_dir/payload.json" \
        --url "$IMAGE_PUSH_WEBHOOK_URL" 2>/dev/null); then
        if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
            printf 'Webhook HTTP %s\n' "$http_code"
            exit 0
        fi
    else
        http_code=000
    fi
    [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code=000
    printf 'Webhook attempt %s failed (HTTP %s)\n' "$attempt" "$http_code" >&2
    if [[ "$attempt" != 3 ]]; then
        sleep "$attempt"
    fi
done
exit 1
