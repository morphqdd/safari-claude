# Minimal stdio MCP server "safari" exposing one tool: ping.
import sys, json, os
for line in sys.stdin:
    m = json.loads(line)
    mid = m.get("id"); meth = m.get("method")
    def reply(r): sys.stdout.write(json.dumps({"jsonrpc":"2.0","id":mid,"result":r})+"\n"); sys.stdout.flush()
    if meth == "initialize": reply({"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"stub","version":"0"}})
    elif meth == "tools/list": reply({"tools":[{"name":"ping","description":"Returns pong and the SC_CHAT_KEY env presence.","inputSchema":{"type":"object","properties":{}}}]})
    elif meth == "tools/call": reply({"content":[{"type":"text","text":"pong key=%s" % ("set" if os.environ.get("SC_CHAT_KEY") else "missing")}]})
    elif mid is not None: reply({})
