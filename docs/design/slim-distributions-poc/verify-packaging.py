#!/usr/bin/env python3
"""Compare real Docker images and installed Debian packages for each distribution."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

from verify import (CHECK_PROJECT, PACKAGES, PROJECT, PROVIDERS, ROOT, VERSION,
                    check_dependencies, check_migration_states, require, run)

UBUNTU = "ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852"
FIXTURE_SQL = ("CREATE TABLE widgets (id INTEGER PRIMARY KEY, name VARCHAR(50) NOT NULL);\n"
               "INSERT INTO widgets VALUES (1, 'Slim PoC');\n")


def container_path(path):
    return str(Path('/src') / path.relative_to(ROOT))


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()


def fixture(directory, provider, sqlite_path, prefix):
    (directory / 'sql/up').mkdir(parents=True)
    for name in ('output', 'state'):
        (directory / name).mkdir()
    (directory / 'sql/up/001_widgets.sql').write_text(FIXTURE_SQL)
    if provider == 'SQLite':
        return (f'Data Source={sqlite_path}',
                f'Data Source={container_path(directory / "state/migration.db")}')
    template = os.environ[f'GRATE_POC_{provider.upper()}']
    database = f'{prefix}_{directory.parent.name}_{directory.name}'.replace('-', '_')
    connection = template.replace('{database}', database)
    return connection, connection


def query(args, checker, provider, connection, log):
    output = run(['docker', 'exec', '-w', '/src', '-e',
                  f'GRATE_POC_CHECK_CONNECTION={connection}', args.sdk,
                  'dotnet', container_path(checker), provider], log)
    return json.loads(output)


def remove_container(name):
    subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)


def docker_invocation(args, image, name, work, extra=(), environment=(), entrypoint=None):
    command = ['docker', 'run', '--rm', '--name', name, '--platform', 'linux/amd64',
               '--network', args.network, '--label', f'io.grate.poc.network={args.network}',
               '-v', f'{work / "sql"}:/db:ro', '-v', f'{work / "output"}:/output',
               '-v', f'{work / "state"}:/state']
    for item in environment:
        command += ['-e', item]
    if entrypoint:
        command += ['--entrypoint', entrypoint]
    return [*command, image, *extra]


def smoke_image(args, image, work, distribution, checker, prefix):
    providers = ('SQLite', 'SQLServer', 'MariaDB') if distribution == 'All' else (distribution,)
    for provider in providers:
        directory = work / 'docker-smoke' / provider
        connection, check_connection = fixture(directory, provider, '/state/migration.db', f'{prefix}_{distribution.lower()}')
        name = f'{prefix}-{distribution.lower()}-{provider.lower()}'
        base_env = [f'APP_CONNSTRING={connection}', f'VERSION={VERSION}']
        initial_env = base_env + ([f'DATABASE_TYPE={provider}'] if distribution == 'All' else [])
        try:
            run(docker_invocation(args, image, name, directory, ['--commandtimeout=31'], initial_env),
                directory / 'first.log')
            first = query(args, checker, provider, check_connection, directory / 'state-first.json')
            run(docker_invocation(args, image, name, directory, ['--commandtimeout=31'],
                                  base_env + [f'DATABASE_TYPE={provider}']), directory / 'rerun.log')
            second = query(args, checker, provider, check_connection, directory / 'state-rerun.json')
            check_migration_states(first, second)
        finally:
            remove_container(name)

    directory = work / 'docker-smoke' / providers[0]
    extraction = work / 'docker-extraction'
    skills = work / 'docker-skills'
    extraction.mkdir()
    skills.mkdir()
    name = f'{prefix}-{distribution.lower()}-direct'
    common = ['docker', 'run', '--rm', '--name', name, '--platform', 'linux/amd64',
              '--label', f'io.grate.poc.network={args.network}', '--entrypoint', '/app/grate',
              '-v', f'{extraction}:/bundle', '-e', 'DOTNET_BUNDLE_EXTRACT_BASE_DIR=/bundle']
    try:
        help_text = run([*common, image, '--help'], work / 'docker-help.log')
        if distribution != 'All':
            require(f'[default: {distribution}]' in help_text, 'Incorrect image provider default')
            rejected = 'SQLite' if distribution == 'SQLServer' else 'SQLServer'
            text = run([*common, '-v', f'{directory / "state"}:/state', image,
                        '--databasetype', rejected, '--connectionstring',
                        'Data Source=/state/rejected.db', '--silent'],
                       work / 'docker-unsupported.log', expected_success=False)
            require(f'This build supports {distribution} only.' in text,
                    'Missing image unsupported-provider diagnostic')
            require(not (directory / 'state/rejected.db').exists(), 'Rejected image created a database')
        run([*common, '-v', f'{skills}:/skills', image, 'skills', 'install',
             '--local', '--path', '/skills'], work / 'docker-skills.log')
        require((skills / '.agents/skills/use-grate/SKILL.md').is_file(), 'Image skill missing')
        manifests = list(extraction.rglob('grate.deps.json'))
        if manifests:
            for manifest in manifests:
                check_dependencies(json.loads(manifest.read_text()), distribution)
        else:
            present = {path.stem for path in extraction.rglob('grate.*.dll')} & PROVIDERS
            expected = PROVIDERS if distribution == 'All' else {f'grate.{distribution.lower()}'}
            require(present == expected, f'Unexpected extracted image providers: {present}')
    finally:
        remove_container(name)


def save_image(image, archive, log):
    with log.open('w') as errors:
        process = subprocess.Popen(['docker', 'image', 'save', image], stdout=subprocess.PIPE,
                                   stderr=errors)
        with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=6,
                                                    mtime=0, filename='') as compressed:
            shutil.copyfileobj(process.stdout, compressed)
        process.stdout.close()
        require(process.wait() == 0, f'Docker image save failed. See {log}')


def inspect_deb(args, package, distribution, log):
    text = run(['docker', 'exec', args.packager, 'dpkg-deb', '--field', container_path(package)], log)
    fields = dict(line.split(': ', 1) for line in text.splitlines() if line and not line[0].isspace())
    require(fields['Package'] == PACKAGES[distribution], 'Incorrect Debian package name')
    require(fields['Version'] == f'{VERSION}-1' and fields['Architecture'] == 'amd64',
            'Incorrect Debian version or architecture')
    conflicts = set(fields.get('Conflicts', '').split(', '))
    require(conflicts == set(PACKAGES.values()) - {PACKAGES[distribution]}, 'Incorrect Debian conflicts')
    require(not fields.get('Provides'), 'Unexpected Debian Provides')


def smoke_deb(args, package, baseline, published, work, distribution, checker, prefix):
    name = f'{prefix}-deb-{distribution.lower()}'
    proof = work / 'deb-smoke'
    proof.mkdir()
    providers = ('SQLite', 'SQLServer', 'MariaDB') if distribution == 'All' else (distribution,)
    cases = []
    for provider in providers:
        directory = proof / provider
        target = f'/proof/{provider}'
        connection, check_connection = fixture(directory, provider, f'{target}/state/migration.db', f'{prefix}_{distribution.lower()}')
        cases.append((provider, directory, target, connection, check_connection))
    try:
        run(['docker', 'run', '-d', '--name', name, '--platform', 'linux/amd64',
             '--network', args.network, '--label', f'io.grate.poc.network={args.network}',
             '-v', f'{package.parent}:/packages:ro', '-v', f'{baseline}:/baseline/all.deb:ro',
             '-v', f'{proof}:/proof', UBUNTU, 'sleep', 'infinity'], work / 'deb-start.log')
        run(['docker', 'exec', '-e', 'DEBIAN_FRONTEND=noninteractive', name, 'sh', '-c',
             'apt-get update -qq && apt-get install -y --no-install-recommends "$1"',
             'sh', f'/packages/{package.name}'], work / 'deb-install.log')
        run(['docker', 'exec', name, 'test', '!', '-d', '/usr/share/dotnet'], work / 'deb-no-dotnet.log')
        payload_hash = run(['docker', 'exec', name, 'sha256sum', '/usr/bin/grate'],
                           work / 'deb-payload.log').split()[0]
        require(payload_hash == digest(published), 'Installed Debian executable differs from published input')
        help_text = run(['docker', 'exec', name, '/usr/bin/grate', '--help'], work / 'deb-help.log')
        if distribution != 'All':
            require(f'[default: {distribution}]' in help_text, 'Incorrect installed provider default')
            text = run(['docker', 'exec', name, 'dpkg', '--install', '/baseline/all.deb'],
                       work / 'deb-conflict.log', expected_success=False)
            require('conflict' in text.lower(), 'Conflicting package failed for another reason')
            after = run(['docker', 'exec', name, 'sha256sum', '/usr/bin/grate'],
                        work / 'deb-after-conflict.log').split()[0]
            require(after == payload_hash, 'Conflicting installation replaced the installed command')
        for provider, directory, target, connection, check_connection in cases:
            command = ['docker', 'exec', name, 'timeout', '120', '/usr/bin/grate',
                       '--connectionstring', connection, '--files', f'{target}/sql',
                       '--output', f'{target}/output', '--version', VERSION, '--silent']
            initial = command + (['--databasetype', provider] if distribution == 'All' else [])
            run(initial, directory / 'first.log')
            first = query(args, checker, provider, check_connection, directory / 'state-first.json')
            run(command + ['--databasetype', provider], directory / 'rerun.log')
            second = query(args, checker, provider, check_connection, directory / 'state-rerun.json')
            check_migration_states(first, second)
        run(['docker', 'exec', name, '/usr/bin/grate', 'skills', 'install', '--local',
             '--path', '/proof/skills'], work / 'deb-skills.log')
        require((proof / 'skills/.agents/skills/use-grate/SKILL.md').is_file(), 'Installed Debian skill missing')
        run(['docker', 'exec', '-e', 'DEBIAN_FRONTEND=noninteractive', name,
             'apt-get', 'purge', '-y', PACKAGES[distribution]], work / 'deb-purge.log')
        run(['docker', 'exec', name, 'test', '!', '-e', '/usr/bin/grate'], work / 'deb-removed.log')
        for provider, directory, _, _, check_connection in cases:
            after = query(args, checker, provider, check_connection, directory / 'state-after-purge.json')
            before = json.loads((directory / 'state-rerun.json').read_text())
            require(after == before, 'Debian purge changed migration database state')
    finally:
        remove_container(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sdk', required=True, help='Running pinned Linux x64 SDK container with /src bind')
    parser.add_argument('--packager', required=True, help='Running native Linux PowerShell/dpkg container with /src bind')
    parser.add_argument('--network', required=True, help='Docker network containing the disposable database servers')
    args = parser.parse_args()
    require(not args.output.is_absolute(), 'Output must be repository-relative')
    output = (ROOT / args.output).resolve()
    require(output.is_relative_to(ROOT) and output != ROOT and not output.exists(),
            'Use a fresh repository-relative output directory')
    for provider in ('SQLSERVER', 'MARIADB'):
        require('{database}' in os.environ.get(f'GRATE_POC_{provider}', ''),
                f'GRATE_POC_{provider} needs a disposable-server connection with {{database}}')
    output.mkdir(parents=True)
    sdk = run(['docker', 'exec', '-w', '/src', args.sdk, 'dotnet', '--version'],
              output / 'sdk-version.log').strip()
    require(sdk == json.loads((ROOT / 'global.json').read_text())['sdk']['version'], 'Incorrect SDK pin')
    run(['docker', 'exec', '-w', '/src', args.sdk, 'dotnet', 'build', container_path(CHECK_PROJECT),
         '-c', 'Release', f'-p:ArtifactsPath={container_path(output / "check-build")}'],
        output / 'build-checker.log')
    checker, = (output / 'check-build/bin/VerifyDatabase').glob('*/VerifyDatabase.dll')
    prefix = 'gratepkg_' + uuid.uuid4().hex[:10]
    measurements = {}
    images = {}
    baseline = None
    for distribution, package_id in PACKAGES.items():
        print(f'Building and checking Docker and Debian {distribution}', flush=True)
        work = output / distribution.lower()
        work.mkdir()
        image = f'grate-packaging-poc-{prefix}:{distribution.lower()}'
        images[distribution] = image
        run(['docker', 'buildx', 'build', '--platform', 'linux/amd64', '--load',
             '--file', str(ROOT / 'installers/docker/Dockerfile'), '--tag', image,
             '--build-arg', f'GRATE_DISTRIBUTION={distribution}', '--build-arg', f'VERSION={VERSION}',
             str(ROOT)], work / 'docker-build.log')
        info, = json.loads(run(['docker', 'image', 'inspect', image], work / 'docker-inspect.json'))
        require(info['Architecture'] == 'amd64' and info['Os'] == 'linux', 'Incorrect image architecture')
        smoke_image(args, image, work, distribution, checker, prefix)
        image_archive = work / f'{package_id}-docker-save.tar.gz'
        save_image(image, image_archive, work / 'docker-save.log')
        info, = json.loads(run(['docker', 'image', 'inspect', image], work / 'docker-inspect.json'))
        build = work / 'standalone-build'
        published = work / 'published'
        run(['docker', 'exec', '-w', '/src', args.sdk, 'dotnet', 'publish', container_path(PROJECT),
             '-c', 'Release', '-f', 'net11.0', '-r', 'linux-x64', '--self-contained',
             '-p:TargetFrameworks=net11.0', f'-p:Version={VERSION}', f'-p:GrateDistribution={distribution}',
             f'-p:ArtifactsPath={container_path(build)}', '-o', container_path(published)], work / 'publish.log')
        deps, = build.glob('bin/grate/**/grate.deps.json')
        check_dependencies(json.loads(deps.read_text()), distribution)
        deb_directory = work / 'deb'
        run(['docker', 'exec', '-w', '/src', args.packager, 'pwsh', '-NoProfile', '-File',
             '/src/installers/deb/Create-Package.ps1', '-grateExe', container_path(published / 'grate'),
             '-version', VERSION, '-arch', 'amd64', '-Distribution', distribution,
             '-OutputDirectory', container_path(deb_directory)], work / 'deb-build.log')
        package = deb_directory / f'{package_id}_{VERSION}-1_amd64.deb'
        require(package.is_file(), 'Expected Debian artifact missing')
        inspect_deb(args, package, distribution, work / 'deb-metadata.log')
        if distribution == 'All':
            baseline = package
        smoke_deb(args, package, baseline, published / 'grate', work, distribution, checker, prefix)
        measurements[distribution] = {
            'docker_reported_image_bytes': info['Size'],
            'docker_save_gzip6_bytes': image_archive.stat().st_size,
            'debian_package_bytes': package.stat().st_size,
        }
        print(f'{distribution} Docker and Debian passed', flush=True)
    savings = {
        distribution: {
            metric: {'bytes': measurements['All'][metric] - value,
                     'percent': round(100 * (measurements['All'][metric] - value) /
                                      measurements['All'][metric], 2)}
            for metric, value in measured.items() if metric != 'docker_reported_image_bytes'}
        for distribution, measured in measurements.items() if distribution != 'All'}
    report = {'sdk': sdk, 'rid': 'linux-x64', 'docker_platform': 'linux/amd64', 'version': VERSION,
              'docker_metric': 'Local docker-save archive compressed with gzip level 6, not registry download bytes',
              'docker_reported_metric': 'Docker image inspect Size after execution, dependent on Docker engine storage accounting',
              'debian_base': UBUNTU, 'images': images, 'measurements': measurements, 'savings': savings}
    (output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    main()
