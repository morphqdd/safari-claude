# Drives claude -p over stdin/stdout: send a long task, interrupt after the first delta, then a second message.
import subprocess, json, sys, time, threading
args = sys.argv[1:]
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd="ws")
def user(t): p.stdin.write(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"text","text":t}]}})+"\n"); p.stdin.flush()
user("Count from 1 to 300, one number per line, no other text.")
deltas = 0; interrupted = False; results = 0; t0 = time.time()
for line in p.stdout:
    d = json.loads(line); t = d.get("type")
    if t == "stream_event" and d["event"].get("type") == "content_block_delta":
        deltas += 1
        if deltas == 3 and not interrupted:
            interrupted = True
            p.stdin.write(json.dumps({"type":"control_request","request_id":"int-1","request":{"subtype":"interrupt"}})+"\n"); p.stdin.flush()
            print("%.1fs sent interrupt" % (time.time()-t0))
    elif t in ("control_response",):
        print("%.1fs control_response" % (time.time()-t0), json.dumps(d)[:200])
    elif t == "result":
        results += 1
        print("%.1fs result" % (time.time()-t0), d.get("subtype"), d.get("stop_reason"), "is_error=", d.get("is_error"), "alive=", p.poll() is None, "deltas=", deltas)
        if results == 1: user("Reply with just: second ok")
        else: break
    elif t == "assistant" and results == 1:
        print("assistant2:", json.dumps(d["message"]["content"])[:120])
p.stdin.close(); p.wait(timeout=30); print("exit", p.returncode)
