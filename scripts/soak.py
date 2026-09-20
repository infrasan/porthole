#!/usr/bin/env python3
"""Three-minute local soak of the built app using disposable loopback servers."""
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(__file__).resolve().parents[1]
area = root / 'build/verification/soak'
area.mkdir(parents=True, exist_ok=True)
fixture = area / 'http-server-fixture.py'
fixture.write_text('''import http.server, subprocess, threading, time, sys
children = []
stopping = threading.Event()
def churn():
    while not stopping.wait(1):
        child = subprocess.Popen([sys.executable, '-c', 'import time; until=time.monotonic()+0.3\\nwhile time.monotonic()<until: pass'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children.append(child)
        child.wait()
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Quiet)
print(server.server_port, flush=True)
thread = threading.Thread(target=churn, daemon=True); thread.start()
try: server.serve_forever(poll_interval=0.1)
except KeyboardInterrupt: pass
finally:
    stopping.set(); server.server_close()
    for child in children:
        if child.poll() is None: child.terminate()
    thread.join(timeout=2)
''')
binary = root / 'build/Porthole.app/Contents/MacOS/Porthole'
children = []
app = None
started = time.monotonic()
checks = 0
stops = 0
def spawn():
    process = subprocess.Popen(['/usr/bin/python3', str(fixture)], cwd=area, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    port = int(process.stdout.readline())
    children.append((process, port))
    return process, port
try:
    with (area / 'app.log').open('w') as log:
        app = subprocess.Popen([str(binary)], stdout=log, stderr=log)
        current = [spawn(), spawn()]
        while time.monotonic() - started < 180:
            assert app.poll() is None, 'App exited during soak'
            scan = subprocess.run([str(binary), '--json'], capture_output=True, text=True, timeout=15, check=True)
            rows = json.loads(scan.stdout)['servers']
            for process, port in current:
                assert process.poll() is None
                assert any(any(p['port'] == port for p in row['ports']) and row['id'].startswith(str(process.pid) + '-') for row in rows), 'Fixture listener not attributed to its process'
            checks += 1
            if checks % 3 == 0:
                process, port = current[0]
                result = subprocess.run([str(binary), '--stop', str(port)], capture_output=True, text=True, timeout=15)
                assert result.returncode == 0, result.stdout + result.stderr
                process.wait(timeout=5)
                assert current[1][0].poll() is None, 'Sibling was stopped'
                stops += 1
                current[0] = spawn()
            time.sleep(3)
        report = {'seconds': round(time.monotonic() - started, 1), 'appStayedRunning': app.poll() is None, 'inventoryChecks': checks, 'disposableStopsAndRelaunches': stops, 'siblingSurvived': True}
        (area / 'result.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report), flush=True)
finally:
    for process, port in children:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
    if app is not None and app.poll() is None:
        app.terminate(); app.wait(timeout=10)
