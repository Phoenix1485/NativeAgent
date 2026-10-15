"""Offline stdio fixture: no network or filesystem tools."""
import json
import sys
import time

if "--ignore-input" in sys.argv:
    time.sleep(30)
    sys.exit(0)

initialized = False
for line in sys.stdin:
    request = json.loads(line)
    assert request["jsonrpc"] == "2.0"
    method = request.get("method")
    if method == "notifications/initialized":
        initialized = True
        continue
    if "id" not in request:
        continue
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}
    elif method == "tools/list":
        assert initialized
        second = request.get("params", {}).get("cursor") == "page2"
        result = {"tools": [{"name": "second" if second else "echo", "description": "Echo fixture", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}
        if not second:
            result["nextCursor"] = "page2"
    elif method == "tools/call":
        assert initialized
        if request["params"]["arguments"].get("text") == "wait-without-reply":
            continue
        result = {"content": [{"type": "text", "text": request["params"]["arguments"].get("text", "")}], "isError": False}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
