#!/usr/bin/env python3
"""Sharing benchmark for the DRA tests (2026-10-30): the gw-bench.py prompt sent straight to llama-server
(no gateway, no token) through kubectl port-forward. Per port alone: one streaming request (TTFT, tok/s), then PAR
parallel non-streaming requests. With two ports: PAR parallel on each port at the same time (the sharing case).
Usage: python3 dra-bench.py 8080 [8081]     env: PAR=4, TOK=400, HOST=127.0.0.1"""
import json, os, sys, time, urllib.request, concurrent.futures as cf

HOST = os.environ.get("HOST", "127.0.0.1")
PAR = int(os.environ.get("PAR", 4)); TOK = int(os.environ.get("TOK", 400))
PORTS = [int(p) for p in sys.argv[1:]] or [8080]
PROMPT = ("Write a detailed, well structured essay of at least 600 words about how a platform team should run a "
          "shared GPU pool for several internal teams: scheduling, isolation, cost allocation, observability and "
          "the trade-offs between time-slicing, MPS and virtual GPUs.")

def body(variant, stream):
    return json.dumps({"model": "x", "max_tokens": TOK, "stream": stream, "temperature": 0.7,
                       "messages": [{"role": "user", "content": f"{PROMPT} (variant {variant})"}]}).encode()

def call(port, variant, stream=False, tries=5):
    for t in range(tries):
        try:
            return _call(port, variant, stream)
        except (ConnectionError, urllib.error.URLError, OSError) as e:
            if t == tries - 1: raise
            time.sleep(2)

def _call(port, variant, stream=False):
    req = urllib.request.Request(f"http://{HOST}:{port}/v1/chat/completions", data=body(variant, stream),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time(); ttft = None; chunks = 0; ct = 0
    with urllib.request.urlopen(req, timeout=600) as r:
        if stream:
            for line in r:
                if not line.startswith(b"data:"): continue
                if ttft is None: ttft = time.time() - t0
                d = line[5:].strip()
                if d == b"[DONE]": break
                chunks += 1
                u = json.loads(d).get("usage")
                if u: ct = u.get("completion_tokens", 0)
        else:
            d = json.loads(r.read()); ct = d["usage"]["completion_tokens"]
    return {"ttft": ttft, "total": time.time() - t0, "tokens": ct or chunks}

def single(port):
    s = call(port, "s", stream=True)
    gen = s["tokens"] / (s["total"] - s["ttft"]) if s["ttft"] else 0
    print(f"  port {port} single stream: TTFT {s['ttft']:.2f} s, {s['tokens']} tokens in {s['total']:.1f} s, {gen:.1f} tok/s after first token")

def parallel(ports, n):
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=n * len(ports)) as ex:
        futs = [(p, ex.submit(call, p, f"{p}-{i}")) for p in ports for i in range(n)]
        res = [(p, f.result()) for p, f in futs]
    dt = time.time() - t0
    for p in ports:
        tot = sum(r["tokens"] for q, r in res if q == p)
        print(f"  port {p}: {n} parallel, {tot} tokens in {dt:.1f} s = {tot/dt:.1f} tok/s aggregate, {tot/dt/n:.1f} per request")
    tot = sum(r["tokens"] for _, r in res)
    if len(ports) > 1: print(f"  all ports together: {tot} tokens, {tot/dt:.1f} tok/s aggregate")

print(f"host {HOST}, ports {PORTS}, max_tokens {TOK}, parallel {PAR}\n")
for p in PORTS:
    print(f"--- {p} alone"); single(p); parallel([p], 1); parallel([p], PAR)
if len(PORTS) > 1:
    print(f"--- both at the same time"); parallel(PORTS, 1); parallel(PORTS, PAR)
