import unittest
from verify_experimental_apk import declarations, verify


def tree(package):
    return f'''E: manifest
  E: permission
    A: android:name(0x01010003)="{package}.DYNAMIC_RECEIVER"
  E: uses-permission
    A: android:name(0x01010003)="android.permission.INTERNET"
  E: application
    E: provider
      A: android:authorities(0x01010018)="{package}.files;{package}.init"
      E: meta-data
        A: android:name(0x01010003)="shared.metadata"
'''


class ManifestIsolationTests(unittest.TestCase):
    def test_scopes_only_declarations(self):
        authorities, permissions = declarations(tree('experimental'))
        self.assertEqual(authorities, {'experimental.files', 'experimental.init'})
        self.assertEqual(permissions, {'experimental.DYNAMIC_RECEIVER'})

    def test_rejects_shared_uid(self):
        with self.assertRaises(ValueError):
            declarations('A: android:sharedUserId="shared"')

    def test_rejects_conflicting_provider_or_permission(self):
        original = "package: name='com.example.audiobook_app' versionCode='135'"
        experimental = "package: name='com.example.audiobook_app.experimental' versionCode='138'\napplication-label:'Dog Reader 2.0'\nic_launcher_experimental\nlaunchable-activity: name='com.example.audiobook_app.MainActivity'"
        self.assertIn('Distinct package', verify(original, experimental, tree('original'), tree('experimental'), '138'))
        for conflict in [tree('experimental').replace('experimental.files', 'original.files'),
                         tree('experimental').replace('experimental.DYNAMIC_RECEIVER', 'original.DYNAMIC_RECEIVER')]:
            with self.assertRaises(ValueError):
                verify(original, experimental, tree('original'), conflict, '138')


if __name__ == '__main__':
    unittest.main()
