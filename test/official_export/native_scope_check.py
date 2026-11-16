#!/usr/bin/env python3
"""One Android JVM test class; called only inside boat-run's Edge shell."""
import glob
import os
import pathlib
import re
import subprocess
import sys
import urllib.request
import hashlib

root = pathlib.Path('/home/user/runs/export-official/android')
if '--standalone' in sys.argv:
    # Compile the actual production bridge. The Activity-owner stub only
    # supplies the unrelated CompanionBridge type, never a scope/I/O policy.
    cache = '/home/user/.gradle/caches/modules-2/files-2.1'
    def jars(pattern):
        return sorted(glob.glob(cache + '/' + pattern, recursive=True))
    compiler = jars('org.jetbrains.kotlin/kotlin-compiler-embeddable/2.2.20/**/*.jar')
    if not compiler:
        raise SystemExit('No cached Kotlin compiler 2.2.20')
    dependencies = []
    for pattern in [
        'org.jetbrains.kotlin/kotlin-stdlib/2.2.20/**/*.jar',
        'org.jetbrains.kotlin/kotlin-script-runtime/2.2.20/**/*.jar',
        'org.jetbrains.kotlin/kotlin-reflect/**/*.jar',
        'org.jetbrains.kotlin/kotlin-daemon-embeddable/2.2.20/**/*.jar',
        'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/**/*.jar',
        'org.jetbrains.intellij.deps/trove4j/**/*.jar',
        'org.jetbrains/annotations/**/*.jar',
    ]:
        dependencies.extend(jars(pattern))
    junit = jars('junit/junit/4.13.2/**/*.jar')
    hamcrest = jars('org.hamcrest/hamcrest-core/**/*.jar')
    dependency_dir=root.parent / 'build/native-scope-deps'
    dependency_dir.mkdir(parents=True,exist_ok=True)
    def maven_jar(coordinate):
        url='https://repo.maven.apache.org/maven2/' + coordinate
        path=dependency_dir / coordinate.split('/')[-1]
        with urllib.request.urlopen(url,timeout=30) as response:
            content=response.read()
        with urllib.request.urlopen(url+'.sha1',timeout=30) as response:
            expected=response.read().decode().strip().split()[0]
        if hashlib.sha1(content).hexdigest()!=expected:
            raise SystemExit('JUnit dependency checksum mismatch')
        path.write_bytes(content)
        return str(path)
    if not junit:
        junit=[maven_jar('junit/junit/4.13.2/junit-4.13.2.jar')]
    if not hamcrest:
        hamcrest=[maven_jar('org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar')]
    sdk = pathlib.Path(os.environ['ANDROID_HOME']) / 'platforms/android-35/android.jar'
    flutter = pathlib.Path(os.environ['FLUTTER_ROOT']) / 'bin/cache/artifacts/engine/android-arm64/flutter.jar'
    if not flutter.exists():
        raise SystemExit('Flutter Android embedding jar is not cached')
    output = root.parent / 'build/native-scope'
    output.mkdir(parents=True, exist_ok=True)
    stub = output / 'CompanionBridge.kt'
    stub.write_text('package wtf.openstrap.openstrap_edge\nobject CompanionBridge { var currentActivity: android.app.Activity? = null }\n')
    classpath = ':'.join(dependencies + junit + hamcrest + [str(sdk), str(flutter)])
    production = root / 'app/src/main/kotlin/wtf/openstrap/openstrap_edge/BackupFolderBridge.kt'
    test = root / 'app/src/test/kotlin/wtf/openstrap/openstrap_edge/BackupFolderBridgeTest.kt'
    subprocess.run([
        'java', '-Xmx1g', '-cp', ':'.join(compiler + dependencies),
        'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
        '-jvm-target', '17', '-classpath', classpath, '-d', str(output),
        str(production), str(test), str(stub),
    ], check=True)
    raise SystemExit(subprocess.run([
        'java', '-cp', str(output) + ':' + classpath,
        'org.junit.runner.JUnitCore',
        'wtf.openstrap.openstrap_edge.BackupFolderBridgeTest',
    ]).returncode)

properties = root / 'gradle/wrapper/gradle-wrapper.properties'
version = re.search(r'gradle-([0-9.]+)-', properties.read_text()).group(1)
executables = glob.glob(f'/home/user/.gradle/wrapper/dists/gradle-{version}-*/**/bin/gradle', recursive=True)
if not executables:
    raise SystemExit(f'No cached Gradle {version} distribution for targeted native test')
(root / 'local.properties').write_text(
    f"flutter.sdk={os.environ['FLUTTER_ROOT']}\nsdk.dir={os.environ['ANDROID_HOME']}\n"
)
raise SystemExit(subprocess.run([
    executables[0], '--no-daemon', '--max-workers=2', '--console=plain', '--stacktrace', '--info',
    ':app:testDebugUnitTest', '--tests',
    'wtf.openstrap.openstrap_edge.BackupFolderBridgeTest',
], cwd=root).returncode)
