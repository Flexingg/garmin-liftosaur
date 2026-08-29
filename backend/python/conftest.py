# Ensures the backend package root is on sys.path so tests can import both
# `app.*` and `tests.*` when run from this directory (pytest picks up the
# rootdir because of this file).
