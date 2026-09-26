import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_cask_dco import workflow_run_block

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'scripts/release-delivery.py'
spec = importlib.util.spec_from_file_location('release_delivery', HELPER)
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class ReleaseDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.asset = b'notarized and stapled archive'
        self.metadata = {
            'repository': 'starhaven-io/Brewy', 'commit': 'a' * 40,
            'tag': '0.27.0', 'build': '36', 'asset': 'Brewy-0.27.0.zip',
            'release_id': 42,
            'sha256': hashlib.sha256(self.asset).hexdigest(), 'length': len(self.asset),
        }
        self.feed = self.directory / 'appcast.xml'
        self.write_feed(self.feed, '0.27.0', '36')
        self.metadata['appcast_sha256'] = delivery.sha256(self.feed)
        self.hosted_asset = {'id': 73, 'name': self.metadata['asset'], 'size': len(self.asset),
                             'digest': 'sha256:' + self.metadata['sha256']}
        self.save_manifest()
        self.environment = {
            'GITHUB_REPOSITORY': self.metadata['repository'], 'GITHUB_SHA': self.metadata['commit'],
            'TAG': self.metadata['tag'], 'BUILD_NUMBER': self.metadata['build'],
            'GH_PUBLISH_TOKEN': 'fixture-publish-token',
            'GH_TOKEN': 'fixture-read-token',
            'RELEASE_ID': '42',
        }
        environment_patch = patch.dict(os.environ, self.environment)
        environment_patch.start()
        self.addCleanup(environment_patch.stop)
        self.published = False
        self.bad_tag_status = None
        self.provenance_fails = False
        self.replace_asset_after_download = False
        self.lose_publish_response = False
        self.tag_sha = self.metadata['commit']
        self.commands = []

    def write_feed(self, path, tag, build):
        path.write_text(f'''<rss xmlns:sparkle="{delivery.SPARKLE[1:-1]}"><channel><item>
<sparkle:shortVersionString>{tag}</sparkle:shortVersionString>
<sparkle:version>{build}</sparkle:version>
<enclosure url="https://github.com/starhaven-io/Brewy/releases/download/{tag}/Brewy-{tag}.zip"
length="{len(self.asset)}" sparkle:edSignature="prepared-signature"/>
</item></channel></rss>''')

    def save_manifest(self):
        (self.directory / 'delivery.json').write_text(json.dumps(self.metadata))

    def fake_run(self, args, **kwargs):
        self.commands.append(args)
        if args[1:3] == ['api', '--include']:
            status = self.bad_tag_status or ('200' if self.published else '404')
            return subprocess.CompletedProcess(args, 0 if status == '200' else 1,
                                               f'HTTP/2.0 {status} Fixture\n\n{{}}', '')
        if args[1:3] == ['api', 'repos/starhaven-io/Brewy/releases/assets/73']:
            self.assertEqual(args[3:], ['--header', 'Accept: application/octet-stream'])
            if not self.published:
                self.assertEqual(kwargs['env']['GH_TOKEN'], 'fixture-publish-token')
            kwargs['stdout'].write(self.asset)
            if self.replace_asset_after_download:
                self.hosted_asset['id'] = 74
            return subprocess.CompletedProcess(args, 0, None, b'')
        if args[1:3] == ['api', 'repos/starhaven-io/Brewy/releases/42'] and '--method' in args:
            self.assertEqual(args[3:], ['--method', 'PATCH', '-F', 'draft=false'])
            self.assertEqual(kwargs['env']['GH_TOKEN'], 'fixture-publish-token')
            self.assertTrue(any(command[1:3] == ['attestation', 'verify'] for command in self.commands))
            self.published = True
            if self.lose_publish_response:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, '{}', '')
        if args[1] == 'api':
            if '/commits/' in args[2]:
                result = {'sha': self.tag_sha}
            else:
                self.assertEqual(args[2], 'repos/starhaven-io/Brewy/releases/42')
                if not self.published:
                    self.assertEqual(kwargs['env']['GH_TOKEN'], 'fixture-publish-token')
                result = {
                    'id': 42,
                    'tag_name': '0.27.0', 'target_commitish': 'a' * 40,
                    'draft': not self.published, 'prerelease': False,
                    'assets': [self.hosted_asset],
                }
            return subprocess.CompletedProcess(args, 0, json.dumps(result), '')
        if args[1:3] == ['attestation', 'verify']:
            self.assertEqual(kwargs['env']['GH_TOKEN'], 'fixture-read-token')
            self.assertIn('--source-digest', args)
            self.assertIn('a' * 40, args)
            self.assertIn('starhaven-io/Brewy/.github/workflows/release.yml', args)
            self.assertIn('--deny-self-hosted-runners', args)
            if self.provenance_fails:
                raise subprocess.CalledProcessError(1, args)
        else:
            self.fail(f'Unexpected hosted operation: {args}')
        return subprocess.CompletedProcess(args, 0, '', '')

    def test_publish_then_retry_uses_existing_asset(self):
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            delivery.verify(self.directory, publish=True)
            delivery.verify(self.directory, publish=True)
            delivery.verify(self.directory)
        self.assertEqual(sum('PATCH' in command for command in self.commands), 1)
        self.assertEqual(sum(command[1:3] == ['attestation', 'verify'] for command in self.commands), 3)

    def test_lost_publication_response_recovers_without_republishing(self):
        self.lose_publish_response = True
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaises(subprocess.CalledProcessError):
                delivery.verify(self.directory, publish=True)
            delivery.verify(self.directory, publish=True)
        self.assertEqual(sum('PATCH' in command for command in self.commands), 1)

    def test_asset_replaced_during_verification_prevents_publication(self):
        self.replace_asset_after_download = True
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaisesRegex(ValueError, 'asset identity changed'):
                delivery.verify(self.directory, publish=True)
        self.assertFalse(self.published)

    def test_invalid_asset_id_prevents_download(self):
        self.hosted_asset['id'] = '73'
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaisesRegex(ValueError, 'Invalid release asset ID'):
                delivery.verify(self.directory, publish=True)
        self.assertFalse(any('/releases/assets/' in command[2] for command in self.commands))

    def test_provenance_failure_prevents_publication(self):
        self.provenance_fails = True
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaises(subprocess.CalledProcessError):
                delivery.verify(self.directory, publish=True)
        self.assertFalse(self.published)

    def test_changed_archive_prevents_publication(self):
        self.asset = b'X' * len(self.asset)
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaisesRegex(ValueError, 'Release bytes differ'):
                delivery.verify(self.directory, publish=True)
        self.assertFalse(self.published)

    def test_cask_verification_requires_published_release(self):
        with patch.dict(os.environ, GH_TOKEN='fixture-publish-token'), \
                patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaisesRegex(ValueError, 'not published'):
                delivery.verify(self.directory)
        self.assertFalse(self.published)

    def test_tag_lookup_errors_do_not_mean_absence(self):
        for status in ('403', '429', '500'):
            with self.subTest(status=status):
                self.bad_tag_status = status
                with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
                    with self.assertRaisesRegex(ValueError, 'Could not read release tag'):
                        delivery.verify(self.directory, publish=True)
        self.assertFalse(self.published)

    def test_changed_tag_blocks_recovery(self):
        self.published = True
        self.tag_sha = 'b' * 40
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaisesRegex(ValueError, 'tag binding changed'):
                delivery.verify(self.directory, publish=True)
        self.assertFalse(any('PATCH' in command for command in self.commands))

    def test_existing_tag_blocks_initial_publication(self):
        self.bad_tag_status = '200'
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaisesRegex(ValueError, 'tag binding changed'):
                delivery.verify(self.directory, publish=True)
        self.assertFalse(self.published)

    def test_tag_is_rechecked_after_publication(self):
        self.tag_sha = 'b' * 40
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaisesRegex(ValueError, 'tag binding changed'):
                delivery.verify(self.directory, publish=True)
        self.assertTrue(self.published)

    def test_replaced_hosted_asset_prevents_recovery(self):
        self.published = True
        self.hosted_asset['digest'] = 'sha256:' + 'b' * 64
        with patch.object(delivery.subprocess, 'run', side_effect=self.fake_run):
            with self.assertRaisesRegex(ValueError, 'Release asset mismatch'):
                delivery.verify(self.directory, publish=True)
        self.assertFalse(any('PATCH' in command for command in self.commands))

    def test_mismatched_metadata_and_appcast_fail_before_network(self):
        for key in ('commit', 'tag', 'build', 'sha256', 'appcast_sha256', 'release_id'):
            with self.subTest(key=key), patch.object(delivery.subprocess, 'run') as run:
                original = self.metadata[key]
                self.metadata[key] = 'invalid'
                self.save_manifest()
                with self.assertRaises(ValueError):
                    delivery.verify(self.directory, publish=True)
                run.assert_not_called()
                self.metadata[key] = original

    def test_retry_cannot_replace_newer_or_different_same_build_feed(self):
        current = self.directory / 'current.xml'
        for tag, build in [('0.28.0', '37'), ('0.27.0', '36'), ('0.26.0', '36')]:
            with self.subTest(tag=tag, build=build):
                self.write_feed(current, tag, build)
                current.write_text(current.read_text() + '\n')
                with self.assertRaises(ValueError):
                    delivery.check_feed(self.feed, current)
        self.write_feed(current, '0.26.0', '35')
        delivery.check_feed(self.feed, current)
        current.write_bytes(self.feed.read_bytes())
        delivery.check_feed(self.feed, current)

    def test_both_release_version_and_build_must_increase(self):
        current = self.directory / 'current.xml'
        self.write_feed(current, '0.26.0', '35')
        for tag, build in [('0.26.0', '36'), ('0.27.0', '35'), ('0.27.0', '0'), ('0.27.0', '36.1')]:
            with self.subTest(tag=tag, build=build), self.assertRaises(ValueError):
                delivery.check_version(tag, build, current)
        delivery.check_version('0.27.0', '36', current)

    def test_prepare_produces_verifiable_metadata(self):
        with patch.dict(os.environ, ARTIFACT_SHA256=self.metadata['sha256'], SPARKLE_LENGTH=str(len(self.asset))):
            subprocess.run([sys.executable, '-B', str(HELPER), 'prepare', str(self.directory)], check=True)
        self.assertEqual(json.loads((self.directory / 'delivery.json').read_text()), self.metadata)

    def test_built_app_must_match_both_requested_versions(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        block = workflow_run_block(workflow, 'Verify stapled app')
        block = block.replace('/usr/libexec/PlistBuddy', 'plist_buddy')
        stub = '''
ditto() { :; }
codesign() { :; }
xcrun() { :; }
spctl() { :; }
plist_buddy() {
  case "$2" in
    'Print :CFBundleShortVersionString') printf '%s' "${BUILT_VERSION}" ;;
    'Print :CFBundleVersion') printf '%s' "${BUILT_BUILD}" ;;
    *) return 1 ;;
  esac
}
'''
        for tag, build, expected in [('0.27.0', '36', 0), ('0.27.0', '35', 1), ('0.26.0', '36', 1)]:
            with self.subTest(tag=tag, build=build):
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c', stub + block],
                                        env={**os.environ, 'RUNNER_TEMP': str(self.directory),
                                             'ARTIFACT_NAME': 'test.zip', 'BUILT_VERSION': tag,
                                             'BUILT_BUILD': build}, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
