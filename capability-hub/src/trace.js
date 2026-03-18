/**
 * [IN] Dependencies/Inputs:
 *  - Node.js crypto runtime (for span ID generation).
 * [OUT] Outputs:
 *  - createTrace(traceId, metadata): creates a trace context with nested span support.
 *  - Trace object with startSpan(), toJSON() methods.
 *  - Span object with end(), startChild() methods.
 * [POS] Position in the system:
 *  - Lightweight structured tracing utility for M5 dispatch instrumentation.
 *  - Replaces flat JSONL log entries with nested span trees (LangSmith Run-compatible shape).
 *  - Does NOT depend on OpenTelemetry or any external tracing SDK.
 */
import crypto from "node:crypto";

/**
 * Generates a short random span ID.
 */
function genSpanId() {
  return crypto.randomBytes(8).toString("hex");
}

/**
 * Computes a dotted_order string for hierarchical span ordering.
 * Format: "YYYYMMDDTHHMMSSFFFZ" + spanId, chained by "." for children.
 */
function makeDottedOrder(parentDottedOrder, startedAt, spanId) {
  const ts = startedAt
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.(\d{3})Z$/, "$1Z");
  const segment = `${ts}${spanId}`;
  return parentDottedOrder ? `${parentDottedOrder}.${segment}` : segment;
}

/**
 * Creates a Span object that records timing, type, input/output, and token usage.
 *
 * @param {object} opts
 * @param {string} opts.name - Span name (e.g. "validate_input", "route_subtasks")
 * @param {string} opts.type - Span type: "orchestration" | "llm" | "regex" | "http" | "validation"
 * @param {string} opts.spanId - Unique span identifier
 * @param {string|null} opts.parentSpanId - Parent span ID (null for root spans)
 * @param {string} opts.dottedOrder - Hierarchical ordering key
 * @param {*} opts.input - Input data for the span
 * @param {function} opts.onEnd - Callback invoked when span ends, receives the finalized span record
 */
function createSpan({ name, type, spanId, parentSpanId, dottedOrder, input, onEnd }) {
  const startedAt = new Date();
  const record = {
    span_id: spanId,
    parent_span_id: parentSpanId,
    name,
    type,
    started_at: startedAt.toISOString(),
    ended_at: null,
    duration_ms: null,
    status: "running",
    input: input ?? null,
    output: null,
    token_usage: null,
    dotted_order: dottedOrder,
  };

  return {
    /** @returns {string} The span ID */
    get id() {
      return spanId;
    },

    /** @returns {object} The raw span record (live reference) */
    get record() {
      return record;
    },

    /**
     * Ends the span, recording status, output, and optional extras.
     * @param {"ok"|"error"|"skipped"} status
     * @param {*} [output]
     * @param {{ token_usage?: object }} [extra]
     */
    end(status, output, extra) {
      if (record.ended_at) return; // already ended
      const endedAt = new Date();
      record.ended_at = endedAt.toISOString();
      record.duration_ms = endedAt.getTime() - startedAt.getTime();
      record.status = status;
      record.output = output ?? null;
      if (extra?.token_usage) {
        record.token_usage = extra.token_usage;
      }
      onEnd(record);
    },

    /**
     * Creates a child span nested under this span.
     * @param {string} childName
     * @param {string} childType
     * @param {{ input?: * }} [opts]
     * @returns {object} Child Span object
     */
    startChild(childName, childType, opts) {
      const childSpanId = genSpanId();
      const childDottedOrder = makeDottedOrder(dottedOrder, new Date(), childSpanId);
      return createSpan({
        name: childName,
        type: childType,
        spanId: childSpanId,
        parentSpanId: spanId,
        dottedOrder: childDottedOrder,
        input: opts?.input,
        onEnd,
      });
    },
  };
}

/**
 * Creates a Trace context that collects spans into a single serializable object.
 *
 * @param {string} traceId - Unique trace identifier (typically a UUID)
 * @param {object} [metadata] - Arbitrary metadata attached to the trace
 * @returns {{ startSpan: Function, toJSON: Function }}
 */
export function createTrace(traceId, metadata) {
  const spans = [];
  const createdAt = new Date().toISOString();

  function onSpanEnd(record) {
    spans.push(record);
  }

  return {
    /** @returns {string} The trace ID */
    get id() {
      return traceId;
    },

    /**
     * Starts a new root-level span in this trace.
     * @param {string} name - Span name
     * @param {string} type - Span type
     * @param {{ input?: * }} [opts]
     * @returns {object} Span object
     */
    startSpan(name, type, opts) {
      const spanId = genSpanId();
      const dottedOrder = makeDottedOrder(null, new Date(), spanId);
      return createSpan({
        name,
        type,
        spanId,
        parentSpanId: null,
        dottedOrder,
        input: opts?.input,
        onEnd: onSpanEnd,
      });
    },

    /**
     * Serializes the trace into a JSON-compatible object.
     * Spans are sorted by dotted_order for deterministic output.
     */
    toJSON() {
      const sorted = [...spans].sort((a, b) =>
        (a.dotted_order || "").localeCompare(b.dotted_order || ""),
      );
      return {
        trace_id: traceId,
        created_at: createdAt,
        metadata: metadata ?? null,
        spans: sorted,
      };
    },
  };
}
