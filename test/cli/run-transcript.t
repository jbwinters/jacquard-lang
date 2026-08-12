RW.1 keeps run transcripts internal to interpreter tooling. This cram invokes the
internal fixture and pins every emitted [run-transcript-v1] byte, including the
length-framed Console payload.

  $ export JACQUARD_PRELUDE=../../prelude
  $ ../run_transcript_trace.exe; echo
  jacquard-run-transcript format=1 observations=1
  observation index=0 value-bytes=2 trace-events=1
  0
  trace index=0 operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e output-bytes=5
  hello

RW.2 keeps comparison in the same internal tooling module. This pins the complete
canonical semantic-diff text for value, trace, and strict-prefix divergences.

  $ ../run_transcript_trace.exe render-divergences
  value-divergence
    at observation[0].value:
      - "0\n"
      + "1\n"
  trace-divergence
    at observation[0].trace[0]:
      - operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e output="left\n"
      + operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e output="right\t"
  length-divergence
    at observation[1]:
      - observation value="0\n" value-bytes=2 trace-events=0
      + <missing>
