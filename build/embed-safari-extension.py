#!/usr/bin/env python3
"""Build a Safari extension inside an existing app before signing its outer bundle."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXTENSION_SOURCE = ROOT / 'Sources/TicketLinkExtension'


def embed(app, resources):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    identifier = info['CFBundleIdentifier']
    if not re.fullmatch(r'[A-Za-z0-9.-]+', identifier):
        raise ValueError('The containing app needs a valid bundle identifier')
    if any(path.is_symlink() for path in resources.rglob('*')):
        raise ValueError('Extension resources must not contain symbolic links')
    manifest = json.loads((resources / 'manifest.json').read_text())
    if manifest.get('manifest_version') != 3:
        raise ValueError('A Manifest V3 web extension is required')
    manifest.pop('key', None)
    manifest.pop('update_url', None)
    sdk = os.environ.get('SDKROOT') or subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    destination = app / 'Contents/PlugIns/TicketLinks.appex'
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ticket-links-') as directory:
        work = Path(directory)
        extension = work / 'TicketLinks.appex'
        contents = extension / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        shutil.copytree(resources, contents / 'Resources')
        (contents / 'Resources/manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        metadata = {
            'CFBundleExecutable': 'TicketLinks',
            'CFBundleIdentifier': identifier + '.SafariExtension',
            'CFBundleName': 'Ticket Links',
            'CFBundleDisplayName': info.get('CFBundleDisplayName', info['CFBundleName']) + ' Links',
            'CFBundlePackageType': 'XPC!',
            'CFBundleShortVersionString': info['CFBundleShortVersionString'],
            'CFBundleVersion': info['CFBundleVersion'],
            'LSMinimumSystemVersion': '14.0',
            'NSExtension': {
                'NSExtensionPointIdentifier': 'com.apple.Safari.web-extension',
                'NSExtensionPrincipalClass': 'SafariWebExtensionHandler',
            },
        }
        (contents / 'Info.plist').write_bytes(plistlib.dumps(metadata))
        binaries = []
        for architecture in ['arm64', 'x86_64']:
            binary = work / architecture
            subprocess.run(['xcrun', 'clang', '-arch', architecture, '-isysroot', sdk,
                            '-mmacosx-version-min=14.0', '-fobjc-arc', '-fapplication-extension',
                            '-framework', 'Foundation', '-framework', 'SafariServices',
                            '-e', '_NSExtensionMain', '-lextension',
                            str(EXTENSION_SOURCE / 'SafariWebExtensionHandler.m'),
                            '-o', str(binary)], check=True)
            binaries.append(str(binary))
        subprocess.run(['xcrun', 'lipo', '-create', *binaries,
                        '-output', str(contents / 'MacOS/TicketLinks')], check=True)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(extension, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--resources', type=Path, default=EXTENSION_SOURCE / 'Resources')
    args = parser.parse_args()
    print(embed(args.app.resolve(), args.resources.resolve()))


if __name__ == '__main__':
    main()
