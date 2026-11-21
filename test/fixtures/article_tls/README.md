Self-signed localhost-only certificate and public test key for loopback HTTPS
regression tests. These are test fixtures, not application signing credentials.
The certificate deliberately has no numeric-IP SAN, so the test checks hostname
validation independently of CA trust. Production connections use default system
trust; these files are not included in the APK's assets.
