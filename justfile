set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Build aria2c, then run the engine tests against that binary.
test:
    scripts/test-engine.sh
