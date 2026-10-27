#!/usr/bin/env python3
"""Test-only stand-in for Chef's model, for the iOS verify skill.

Answers POST /api/chef/chat with a canned AI SDK stream, paced so a capture
can see it arrive, and makes the one change it reports through the real API:
it adds "Verify Chef Lemons" to the list on screen (or the first list). It
answers POST /api/chef/actions/<id>/undo for that change itself, with 409
when the item has since been checked or deleted, as the server's Undo does.
Every other request is passed to the real API unchanged.

A message containing "fail" gets a reply that stops with an error event.

    chef-stub.py <port> <upstream base URL>
"""
import json
import re
import sys
import time
import urllib.error
import urllib.request
import os
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2].rstrip("/")
ITEM = "Verify Chef Lemons"
# Seconds between steps of a reply, scaled so each step outlasts a capture (about 4 s).
PACE = float(os.environ.get("OMLETE_IOS_VERIFY_CHEF_STUB_PACE", "1"))
# undo id -> (list id, item id, summary)
actions: dict[str, tuple[str, str, str]] = {}


def upstream(method, path, body=None):
    request = urllib.request.Request(
        UPSTREAM + path, data=None if body is None else json.dumps(body).encode(), method=method,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read() or b"null")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))
        sys.stderr.flush()

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_POST(self):
        if self.path == "/api/chef/chat":
            return self.chat(json.loads(self.body()))
        if m := re.fullmatch(r"/api/chef/actions/([^/]+)/undo", self.path):
            if m.group(1) in actions:
                self.body()
                return self.undo(m.group(1))
        self.proxy()

    def do_GET(self):
        self.proxy()

    def do_PUT(self):
        self.proxy()

    def do_PATCH(self):
        self.proxy()

    def do_DELETE(self):
        self.proxy()

    def proxy(self):
        data = self.body() if self.command in ("POST", "PUT", "PATCH") else None
        request = urllib.request.Request(UPSTREAM + self.path, data=data, method=self.command)
        if self.headers.get("Content-Type"):
            request.add_header("Content-Type", self.headers["Content-Type"])
        try:
            with urllib.request.urlopen(request, timeout=200) as response:
                self.answer(response.status, response.read(), response.headers.get("Content-Type"))
        except urllib.error.HTTPError as error:
            self.answer(error.code, error.read(), error.headers.get("Content-Type"))

    def answer(self, status, payload, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type or "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def chat(self, request):
        path = (request.get("page") or {}).get("path") or "/"
        last = request["messages"][-1]
        said = " ".join(p.get("text", "") for p in last["parts"] if p.get("type") == "text")
        photos = sum(1 for p in last["parts"] if p.get("type") == "file")
        self.log_message("chat from %s: %r with %d photo(s), %d message(s)", path, said, photos,
                         len(request["messages"]))

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def send(event, pause=0.0):
            raw = f"data: {event if isinstance(event, str) else json.dumps(event)}\n\n".encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(raw), raw))
            self.wfile.flush()
            time.sleep(pause * PACE)

        send({"type": "start", "messageId": f"stub-{uuid.uuid4().hex[:8]}"})
        send({"type": "text-start", "id": "t1"})
        for word in ["Let ", "me ", "find ", "that."]:
            send({"type": "text-delta", "id": "t1", "delta": word}, 1.5)
        send({"type": "text-end", "id": "t1"})
        if "fail" in said.lower():
            send({"type": "error", "errorText": "The stub was asked to fail"})
        else:
            send({"type": "tool-input-start", "toolCallId": "ws1", "toolName": "web_search",
                  "providerExecuted": True}, 8)
            send({"type": "tool-output-available", "toolCallId": "ws1", "output": [],
                  "providerExecuted": True})
            send({"type": "tool-input-start", "toolCallId": "c1", "toolName": "add_item"}, 8)
            m = re.match(r"^/(?:list|shop)/([0-9a-f]{24})", path)
            list_id = m.group(1) if m else upstream("GET", "/api/lists/")[0]["id"]
            item_id = str(uuid.uuid4())
            send({"type": "tool-input-available", "toolCallId": "c1", "toolName": "add_item",
                  "input": {"list_id": list_id, "name": ITEM, "amount": 3}})
            upstream("POST", f"/api/lists/{list_id}/items",
                     {"id": item_id, "name": ITEM, "amount": 3, "unit": None, "category": "Fresh Produce"})
            name = upstream("GET", f"/api/lists/{list_id}")["name"]
            undo = f"stub{uuid.uuid4().hex[:8]}"
            summary = f"Added {ITEM} to {name}"
            actions[undo] = (list_id, item_id, summary)
            self.log_message("added %s (%s) to %s, undo %s", ITEM, item_id, list_id, undo)
            send({"type": "tool-output-available", "toolCallId": "c1",
                  "output": {"done": summary, "undo": undo, "list_id": list_id}}, 8)
            send({"type": "text-start", "id": "t2"})
            for word in ["Done. ", "They're ", f"on {name}."]:
                send({"type": "text-delta", "id": "t2", "delta": word}, 1.5)
            send({"type": "text-end", "id": "t2"})
        send({"type": "finish"})
        send("[DONE]")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        self.log_message("finished the reply")

    def undo(self, undo):
        list_id, item_id, summary = actions[undo]
        items = {i["id"]: i for i in upstream("GET", f"/api/lists/{list_id}")["items"]}
        item = items.get(item_id)
        if item is None or item.get("checked"):
            self.log_message("undo %s refused: the item has changed since", undo)
            return self.answer(409, json.dumps({"detail": "That has changed since, so it can't be undone"}).encode())
        upstream("DELETE", f"/api/lists/{list_id}/items/{item_id}")
        self.log_message("undo %s: deleted %s", undo, item_id)
        self.answer(200, json.dumps({"id": undo, "summary": summary, "undone": True}).encode())


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
