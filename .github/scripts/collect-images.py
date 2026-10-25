#!/usr/bin/env python3
"""Extract image fields from rendered YAML, with Docker Hub normalization."""
import sys
from pathlib import Path
import yaml


def normalize(image):
    image = image.strip()
    first = image.split('/')[0]
    if '/' not in image:
        image = 'docker.io/library/' + image
    elif '.' not in first and ':' not in first and first != 'localhost':
        image = 'docker.io/' + image
    if image.startswith('docker.io/') and image.count('/') == 1:
        image = image.replace('docker.io/', 'docker.io/library/', 1)
    if '@sha256:' not in image and ':' not in image.rsplit('/', 1)[-1]:
        raise ValueError(f'Unpinned image: {image}')
    if image.endswith(':latest'):
        raise ValueError(f'Unpinned image: {image}')
    return image


def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == 'image' and isinstance(value, str):
                yield normalize(value)
            else:
                yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def compose_images(directory):
    """Images CI can fetch; pull_policy=never means a separately supplied archive."""
    for path in Path(directory).glob('*/compose.yaml'):
        for service in yaml.safe_load(path.read_text())['services'].values():
            if service.get('pull_policy') == 'never':
                continue
            yield normalize(service['image'])


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--compose-dir':
        images = compose_images(sys.argv[2])
    elif len(sys.argv) == 1:
        images = (image for doc in yaml.safe_load_all(sys.stdin) for image in walk(doc))
    else:
        raise SystemExit('Usage: collect-images.py [--compose-dir DIRECTORY]')
    for image in sorted(set(images)):
        print(image)
