# Request benchmark

`Tests/MacRemoteTests/RequestBenchmark.swift` times `tools/list` and
`tools/call` against a real `LocalMCPServer` on loopback, serving a saved
catalog. It is inert unless `MR_BENCH=1`, so a normal `swift test` skips it.

Copy your catalog first; the benchmark never reads the live file:

```bash
cp ~/Library/Application\ Support/MacRemote/tools.json /path/to/scratch/tools.json
# Optional: the tools you have not shared, as a JSON array of IDs.

MR_BENCH=1 MR_BENCH_TOOLS=/path/to/scratch/tools.json \
MR_BENCH_DISABLED=/path/to/scratch/disabled.json \
MR_BENCH_N=100 MR_BENCH_OUT=/path/to/scratch/result.json \
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test -c release -Xswiftc -enable-testing --filter requestBenchmark
```

It prints `MR_BENCH_RESULT` with the median, p10, and p90 milliseconds, CPU
milliseconds per request, and the response size for each method. The client
is a 2025-06-18 client with MCP Apps, and result cards are off. Compare runs
on one Mac, back to back; a busy Mac moves the numbers by a few percent.

On 2026-11-18, with 381 shared tools on an M5 Ultra, `tools/list` went from a
median of 43.5 ms to 6.1 ms (the descriptors and their serialized bytes are
built once per catalog change). `tools/call` of `/bin/echo` takes about 5 ms.
