set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Build aria2c, then run the engine tests against that binary.
test:
    scripts/test-engine.sh

# Sign, notarize, and publish a vX.Y.Z tag on this Mac. Not for GitHub Actions.
release tag:
    scripts/release/publish.sh '{{tag}}'
