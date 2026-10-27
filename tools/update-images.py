#!/usr/bin/env python3
"""Refresh pinned digests deliberately; never restart services. Review changes afterward."""
import argparse
import pathlib
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pull', action='store_true', help='download current tag versions before recording digests')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    candidates = list((root / '.config/containers/systemd').glob('*.container')) + list(root.glob('*-app/Containerfile'))
    changes = []
    # Resolve all digests before writing any file.
    for path in candidates:
        text = path.read_text()
        match = re.search(r'^(?:Image=|FROM )(docker.io/[^\s@]+)(?:@sha256:[0-9a-f]{64})?$', text, re.M)
        if not match: continue
        tag = match.group(1)
        if args.pull: subprocess.run(['podman', 'pull', tag], check=True)
        digest = subprocess.check_output(['podman', 'image', 'inspect', '--format', '{{.Digest}}', tag], text=True).strip()
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest): raise ValueError(f'Invalid digest for {tag}')
        prefix = 'Image=' if match.group(0).startswith('Image=') else 'FROM '
        changes.append((path, text[:match.start()] + prefix + tag + '@' + digest + text[match.end():]))
    for path, text in changes:
        temp = path.with_name(path.name + '.tmp')
        temp.write_text(text)
        temp.replace(path)
        print(path.relative_to(root))
    print('Digests recorded. Review git diff; reload/restart selected services deliberately.')
    print('For Python base changes, rebuild local images with rebuild-images.sh.')

if __name__ == '__main__': main()
