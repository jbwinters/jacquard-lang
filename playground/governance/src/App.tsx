import { useEffect, useRef, useState } from "react";
import { DecisionChainView } from "./DecisionChainView";
import { sampleDecision } from "./fixtures";
import { MAX_INPUT_BYTES, type Validation, validateDecisionChain } from "./schema";
import "./styles.css";

const initialText = JSON.stringify(sampleDecision, null, 2);

/** Local-only loader. It reads pasted or selected JSON and never sends or stores it. */
export default function App() {
  const [source, setSource] = useState(initialText);
  const [result, setResult] = useState<Validation | null>(() => validateDecisionChain(initialText));
  const errorRef = useRef<HTMLDivElement>(null);
  const editorRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (result?.ok === false) errorRef.current?.focus();
  }, [result]);

  const load = () => setResult(validateDecisionChain(source));
  const onFile = async (file: File | undefined) => {
    if (!file) return;
    if (file.size > MAX_INPUT_BYTES) {
      setResult({ ok: false, errors: [`Input exceeds the ${MAX_INPUT_BYTES} byte limit.`] });
      return;
    }
    setSource(await file.text());
    setResult(null);
  };
  return (
    <main>
      <section className="loader" aria-labelledby="loader-title">
        <h1 id="loader-title">Offline governance viewer</h1>
        <p>This page does not fetch, persist, or transmit decision artifacts.</p>
        <label htmlFor="artifact">Normalized decision artifact JSON</label>
        <textarea
          id="artifact"
          ref={editorRef}
          value={source}
          onChange={(event) => {
            setSource(event.target.value);
            setResult(null);
          }}
          spellCheck={false}
          rows={12}
        />
        <div className="controls">
          <button type="button" onClick={load}>
            Validate and render
          </button>
          <button
            type="button"
            onClick={() => {
              setSource("");
              setResult(null);
              editorRef.current?.focus();
            }}
          >
            Reset loaded data
          </button>
          <label className="file-button">
            Select local JSON
            <input
              type="file"
              accept="application/json,.json"
              onChange={(event) => void onFile(event.target.files?.[0])}
            />
          </label>
        </div>
        {result?.ok === false ? (
          <div ref={errorRef} className="error" role="alert" tabIndex={-1}>
            <h2>Artifact rejected</h2>
            <ul>
              {result.errors.map((error) => (
                <li key={error}>{error}</li>
              ))}
            </ul>
          </div>
        ) : null}
      </section>
      {result?.ok === true ? <DecisionChainView artifact={result.value} /> : null}
    </main>
  );
}
