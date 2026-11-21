# App Store release

## Release authority

After the required verification passes, contributors may prepare a local archive without further approval. For every release, obtain the owner’s explicit approval separately before each of these actions, in order:

1. Upload the build to App Store Connect.
2. Submit the release for App Review.
3. Release it publicly.

When the owner’s personal iPhone is available, automatically install the newest build from `main` that passed automated checks. Only builds from `main` qualify. After installation, run any [required physical iPhone verification](device-testing.md#required-physical-iphone-verification) before marking the affected change complete. The local release-candidate workflow documents direct installation for crash fixes. General automatic delivery remains an implementation item.
