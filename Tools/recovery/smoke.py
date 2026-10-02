"""Real recovery-helper integration, using a temporary application bundle.

Usage: python3 Tools/recovery/smoke.py PATH_TO_HELPER [--sandbox]
Registers a temporary test login item, tests actual crashes, then unregisters it.
Requires an interactive macOS session; macOS may require login-item approval.
"""
from pathlib import Path
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def wait_for(fn, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError('Timed out waiting for test app')


def main():
    root = Path(__file__).resolve().parents[2]
    helper = Path(sys.argv[1]).resolve()
    sandbox = '--sandbox' in sys.argv[2:]
    identifier = 'org.swift-app-lifecycle.recovery-test.' + uuid.uuid4().hex[:8]
    home = Path.home()
    if sandbox:
        home = home / 'Library/Containers' / identifier / 'Data'
    state_dir = home / 'Library/Application Support' / identifier
    with tempfile.TemporaryDirectory(prefix='app-lifecycle-recovery-') as temporary:
        app = Path(temporary) / 'RecoveryFixture.app'
        macos = app / 'Contents/MacOS'
        macos.mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'RecoveryFixture',
            'CFBundleName': 'App Lifecycle Recovery Test', 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'LSUIElement': True,
        }))
        subprocess.run(['swiftc', '-swift-version', '6', str(root / 'Tools/recovery/Fixture.swift'),
                        str(root / 'Sources/AppLifecycle/CrashRecovery.swift'),
                        str(root / 'Sources/AppLifecycle/LoginItem.swift'),
                        '-o', str(macos / 'RecoveryFixture')], check=True)
        shutil.copy2(helper, macos / 'AppLifecycleRecoveryHelper')
        sign = ['codesign', '--force', '--sign', '-']
        helper_args = ['--identifier', identifier + '.helper']
        if sandbox:
            helper_args += ['--entitlements', str(root / 'Support/RecoveryHelper.entitlements')]
        subprocess.run(sign + helper_args + [str(macos / 'AppLifecycleRecoveryHelper')], check=True)
        entitlements = Path(temporary) / 'sandbox.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
        subprocess.run(sign + (['--entitlements', str(entitlements)] if sandbox else []) + [str(app)], check=True)

        def state():
            try:
                return json.loads((state_dir / 'state.json').read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                return None

        def launch(count, armed=True):
            subprocess.run(['open', str(app)], check=True)
            return wait_for(lambda: (s := state()) and s['launchCount'] >= count and (s['armed'] or not armed) and s)

        def command(value):
            (state_dir / 'command').write_text(value)
            wait_for(lambda: not (state_dir / 'command').exists())

        def no_restart(count):
            wait_for(lambda: not alive(state()['pid']) and not alive(state()['helperPID']))
            until = time.monotonic() + 4
            while time.monotonic() < until:
                assert state()['launchCount'] == count, state()
                assert not alive(state()['pid']), state()
                time.sleep(0.1)

        try:
            current = launch(1)
            assert current['armed'], current
            assert current['status'] == 1, f'Login item approval required: {current}'
            command('disable')
            wait_for(lambda: not state()['armed'] and state()['status'] == 0)
            command('enable')
            current = wait_for(lambda: state()['armed'] and state())
            print('PASS: existing login user is armed; disable/re-enable changes monitoring live', flush=True)
            old_helper = current['helperPID']
            os.kill(old_helper, signal.SIGKILL)
            current = wait_for(lambda: state()['armed'] and state()['helperPID'] != old_helper and state(), timeout=40)
            print('PASS: failed helper is replaced', flush=True)
            command('logout')
            wait_for(lambda: not state()['armed'])
            current = wait_for(lambda: state()['armed'] and state(), timeout=40)
            print('PASS: cancelled logout resumes monitoring', flush=True)
            # End-to-end: three real crashes reopen the same bundle and persist the budget.
            for count in range(2, 5):
                os.kill(current['pid'], signal.SIGTRAP)
                current = wait_for(lambda: (s := state()) and s['launchCount'] == count and s['armed'] and s)
                assert current['armed'], current
            os.kill(current['pid'], signal.SIGTRAP)
            no_restart(4)
            print('PASS: crashes relaunch; fourth crash stops the loop', flush=True)
            # The following negative cases must not pass merely because the budget is exhausted.
            (state_dir / 'crash-recovery.json').unlink(missing_ok=True)
            (state_dir / 'crash-on-start').touch()
            current = launch(6)  # Fifth launch crashes immediately after recovery startup.
            print('PASS: crash immediately after startup handshake is recovered', flush=True)
            (state_dir / 'crash-recovery.json').unlink(missing_ok=True)
            command('quit')
            no_restart(6)
            print('PASS: clean Quit stays closed', flush=True)
            current = launch(7)
            os.kill(current['pid'], signal.SIGKILL)
            no_restart(7)
            print('PASS: Force Quit stays closed', flush=True)
            current = launch(8)
            command('disarm')
            os.kill(current['pid'], signal.SIGTRAP)
            no_restart(8)
            print('PASS: disarmed crash stays closed (update/quit guard)', flush=True)
            current = launch(9)
            command('revoke')  # Bypass refresh: helper must also check the OS setting.
            os.kill(current['pid'], signal.SIGTRAP)
            no_restart(9)
            print('PASS: revoked login registration prevents restart', flush=True)
        finally:
            # Reopen the isolated fixture solely to unregister its login item.
            before = (state() or {}).get('launchCount', 0)
            try:
                subprocess.run(['open', str(app)], check=True)
                wait_for(lambda: state() and (state()['launchCount'] > before or alive(state()['pid'])))
                command('cleanup')
                time.sleep(0.5)
            finally:
                shutil.rmtree(state_dir, ignore_errors=True)


def alive(pid):
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


if __name__ == '__main__':
    main()
