#!/usr/bin/env python3
"""Check packaged-app startup, which --dump and preview stores do not exercise."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1]).resolve()
with (app / 'Contents/Info.plist').open('rb') as stream:
    executable = plistlib.load(stream)['CFBundleExecutable']
with tempfile.TemporaryFile() as log:
    child = subprocess.Popen([str(app / 'Contents/MacOS' / executable)], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if child.poll() is not None:
                log.seek(0)
                sys.stderr.write(log.read().decode('utf-8', errors='replace'))
                raise SystemExit('Packaged app exited during startup (status %s)' % child.returncode)
            time.sleep(0.25)
        print('Packaged app stayed running for 10 seconds')
    finally:
        # Only the child created here is closed. Existing Porthole instances stay open.
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
