# Release tooling

These Python scripts support the release workflows in `.github/workflows/`.
They resolve release versions and publishing intent, check Docker access, publish
and verify the retained Docker archive, and generate the Homebrew cask update.
The scripts keep this logic testable outside GitHub Actions.

Run the automated checks from the repository root:

```sh
python3 -m pip install -r scripts/release/requirements-workflow-tests.txt
python3 -m unittest discover -s scripts/release -p 'test_*.py' -v
python3 -m unittest discover -s installers/docker -p 'test_*.py' -v
```

The test suites use synthetic fixtures and mocked registry requests; they do not
publish releases or images. The optional `check_docker_oci_copy.py` check uses
Skopeo with temporary local OCI layouts and also performs no registry writes.

Publication scripts and `migrate_docker_tags.py --copy` write to external
registries. Follow the [release process](../../docs/ReleaseProcess.md) and inspect
the command's inputs before running them. Historical tag migration is separate
from an ordinary release and requires a fresh, reviewed plan.

Keep generated plans, logs, reports, and observed configuration outside git, using
CI artifacts or a temporary directory. Commit reusable scripts, tests, desired
configuration, and instructions.
