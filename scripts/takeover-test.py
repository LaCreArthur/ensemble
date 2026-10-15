#!/usr/bin/env python3
"""Two-Mac test of the takeover (the newest sound wins and pauses the other Mac), with stand-in music
apps that cannot be heard (duet-lab nowplaying: 30 Hz at -60 dBFS; a pause leaves the output open with
zeros, as browsers do), and a non-media tone played with afplay. Needs Ensemble running and connected on both Macs, `ssh macb`, and duet-lab
at /tmp/duet-lab on Mac B. Checks each Mac's log and the stand-ins' received commands; exits 1 on any failure."""
import subprocess, time, sys, datetime
LAB = subprocess.run(['swift', 'build', '--product', 'duet-lab', '--show-bin-path'], capture_output=True, text=True).stdout.strip() + '/duet-lab'
B = ['ssh', '-o', 'BatchMode=yes', 'macb']
fails = 0

def now(): return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
def log(on_b, since, text):
    cmd = f"/usr/bin/log show --start '{since}' --style compact --predicate 'subsystem == \"com.lacrearthur.duet\" AND eventMessage CONTAINS \"{text}\"'"
    out = subprocess.run((B + [cmd]) if on_b else ['sh', '-c', cmd], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if text in l]
def sharing(on_b):
    cmd = 'defaults read com.lacrearthur.duet on'
    return subprocess.run((B + [cmd]) if on_b else ['sh', '-c', cmd], capture_output=True, text=True).stdout.strip() == '1'
def check(what, ok):
    global fails
    print(('PASS ' if ok else 'FAIL ') + what, flush=True)
    fails += not ok
def standin(on_b, name, *args):
    cmd = f"/tmp/duet-lab nowplaying {' '.join(args)} > /tmp/{name}.log 2>&1" if on_b else f"{LAB} nowplaying {' '.join(args)} > /tmp/{name}.log 2>&1"
    return subprocess.Popen((B + [cmd]) if on_b else ['sh', '-c', cmd])
def standin_log(on_b, name):
    return subprocess.run((B if on_b else []) + ['cat', f'/tmp/{name}.log'], capture_output=True, text=True).stdout

# Refuse while someone's music plays: a takeover pauses the other Mac's now-playing app.
NOW = "ObjC.import('Foundation'); $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load; const R = $.NSClassFromString('MRNowPlayingRequest'); const c = R.localNowPlayingPlayerPath.client; (R.localIsPlaying ? 'playing ' : 'paused ') + (c.isNil() ? '' : c.bundleIdentifier.js)"
for mac, on_b in [('A', False), ('B', True)]:
    state = subprocess.run((B if on_b else []) + ['osascript', '-l', 'JavaScript', '-e', f'"{NOW}"' if on_b else NOW], capture_output=True, text=True).stdout.strip()
    if state.startswith('playing') and 'com.lacrearthur.duet' not in state: sys.exit(f'{mac}: {state}: not testing over it')
# S is the Mac that shares at the start, O the other one (True = Mac B).
S = sharing(True)
O = not S
if sharing(O) or not sharing(S): sys.exit('start state: exactly one Mac must share')
print(f"S = Mac {'B' if S else 'A'} (shares), O = Mac {'B' if O else 'A'}", flush=True)

print('1. S plays its own music while it shares; then music starts on O', flush=True)
t1 = now()
b = standin(S, 'standin-s', '--seconds', '75', '--resume-after', '20')
time.sleep(4)
check('S plays its own sound without taking anything (it already shares)', log(S, t1, 'a sound started here') == [])
def np(on_b): return subprocess.run((B if on_b else []) + ['osascript', '-l', 'JavaScript', '-e', f'"{NOW}"' if on_b else NOW], capture_output=True, text=True).stdout.strip()
def lab(on_b, *args): return subprocess.run((B if on_b else []) + [('/tmp/duet-lab' if on_b else LAB), *args], capture_output=True, text=True).stdout
check("O's Control Center shows S's music playing", np(O) == 'playing com.lacrearthur.duet')
if 'duet-lab' not in np(S): sys.exit("S's now-playing app is not the stand-in: not sending it media keys")
lab(S, 'media', 'pause'); time.sleep(1.5)
check("S's music paused, its output still open: O shows it paused", np(O) == 'paused com.lacrearthur.duet')
lab(S, 'media', 'play'); time.sleep(1.5)
check("O shows it playing again", np(O) == 'playing com.lacrearthur.duet')
t2 = now()
a = standin(O, 'standin-o', '--seconds', '70')
time.sleep(5)
check('O takes over within 5 s', len(log(O, t2, 'a sound started here')) == 1 and sharing(O) and not sharing(S))
check("S's music got a pause", 'RECEIVED pause' in standin_log(S, 'standin-s'))
print('2. S stays paused (output open with zeros) for 15 s: no takeover back', flush=True)
time.sleep(13)
check('S does not take sharing back', log(S, t2, 'a sound started here') == [] and sharing(O))
check("O's music was never paused", 'RECEIVED' not in standin_log(O, 'standin-o'))
print('3. S resumes its music (as a user pressing play)', flush=True)
time.sleep(10)
check('S takes over after its music resumes', len(log(S, t2, 'a sound started here')) == 1 and sharing(S) and not sharing(O))
check("O's music got a pause", 'RECEIVED pause' in standin_log(O, 'standin-o'))
t3 = now()
time.sleep(10)
check('O does not take sharing back', log(O, t3, 'a sound started here') == [] and sharing(S))
a.wait(); b.wait()
print('4. A sound that is not media (an alert, a game) on O while S shares', flush=True)
t4 = now()
tone = '/tmp/takeover-tone.wav'   # 3 s of 30 Hz at -60 dBFS: inaudible
subprocess.run(['python3', '-c', f"import wave,struct,math; w=wave.open('{tone}','wb'); w.setparams((1,2,48000,0,'NONE','')); w.writeframes(b''.join(struct.pack('<h', int(32.767*math.sin(2*math.pi*30*i/48000))) for i in range(144000)))"])
if O: subprocess.run(['scp', '-q', tone, f'macb:{tone}'])
subprocess.run((B if O else []) + ['afplay', tone])
time.sleep(2)
check('a sound that is not media does not take over', log(O, t4, 'a sound started here') == [] and sharing(S))
print('stand-in O:\n' + standin_log(O, 'standin-o') + 'stand-in S:\n' + standin_log(S, 'standin-s'))
sys.exit(1 if fails else 0)
