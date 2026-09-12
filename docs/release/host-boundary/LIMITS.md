# Host boundary limits

These limits are part of the HB.3 publication, not a future-work appendix.
Each names the condition for its removal. Silence never widens a claim.

| Limit | What we do not claim | Removal gate |
|---|---|---|
| First-party programs | safety for hostile uploaded Jacquard code | separate-process or equivalent isolation design, hostile resource tests, reviewed threat model |
| Trusted adapter and operating system (D78) | protection from a lying host or broader OS credentials | independently enforced isolation and authentication plus external security review |
| Experimental provisional carrier (D79) | a stable foreign-host ABI or low-overhead embedding | two independent adapters and one real serial integration passing the kit before any v1 claim |
| One independent adapter (jacquard-host, Python) | interoperability beyond one language | a second independent adapter (jacquard-host's Rust track) passes the same kit before any v1 claim |
| One serial invocation, one outstanding request | concurrency, streaming, callbacks, throughput | demonstrated need, then the C4 scheduler contract and resource evidence |
| No automatic side-effect retry (D83) | transparent recovery from ambiguous completion | per-operation idempotency, receipts, and a crash/recovery contract |
| Controlled replay fixtures (D84) | production traffic replay | explicit privacy, retention, redaction, and evidence-store authority |
| Coarse Core 0.2 grants | domain, path, port, or database-row containment | the host authority report, then Task 202's reviewed attenuation algebra |
| No deadline or memory ceiling in the worker | protection from a runaway target | host process limits (jacquard-host) and Core fuel/allocation limits |
| Startup configuration failures exit 1 | a protocol status for a missing or unpopulated store | a later protocol version or a documented host-side classification |
| Diagnostic prose is not normative | byte-equal diagnostics across Core versions | a reviewed decision to refresh the vector prose or freeze prose in the spec |
| One recorded vector divergence | a fully conforming hostile corpus | the E1603/E1601 decision in DECISION.md |
| Linux-first evidence | a portable host-runtime claim | CI, lifecycle, cleanup, and packaging evidence per added platform |
| No HTTP, sockets, SQLite, or RPC in Core | a bundled web framework or hosted service | intentionally not a removal target |

The kit's fake host is evidence tooling in the test tree; it is not an
adapter, an embedding contract, or a supported library surface.
