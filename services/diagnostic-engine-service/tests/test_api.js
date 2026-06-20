/**
 * test_api.js — Unit tests for the Diagnostic Engine Service.
 *
 * Uses the Node.js 20+ built-in test runner (`node:test`) and `node:assert`.
 * No external test framework required.
 *
 * Run with:  npm test            (or  node --test tests/test_api.js)
 */

const { describe, it, before } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');

const { app, setReady } = require('../src/index');

// ─── Helper: lightweight HTTP request against the Express app ────────────────

let server;
let baseUrl;

/**
 * Start the Express app on an ephemeral port before tests run.
 */
before(async () => {
  setReady(true); // mark service as ready for /ready probe
  await new Promise((resolve) => {
    server = app.listen(0, () => {
      const { port } = server.address();
      baseUrl = `http://127.0.0.1:${port}`;
      resolve();
    });
  });
});

/**
 * Tiny fetch-like helper so we avoid a dependency on node-fetch / undici for
 * the tests. Uses the global fetch available in Node 20+.
 */
async function request(method, path, body) {
  const options = {
    method,
    headers: { 'Content-Type': 'application/json' },
  };
  if (body) options.body = JSON.stringify(body);
  const res = await fetch(`${baseUrl}${path}`, options);
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: res.status, json, text };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

describe('Health & Readiness', () => {
  it('GET /health returns 200 with healthy status', async () => {
    const { status, json } = await request('GET', '/health');
    assert.equal(status, 200);
    assert.equal(json.status, 'healthy');
    assert.equal(json.service, 'diagnostic-engine-service');
    assert.ok(json.timestamp);
    assert.ok(typeof json.uptime_seconds === 'number');
  });

  it('GET /ready returns 200 when service is ready', async () => {
    const { status, json } = await request('GET', '/ready');
    assert.equal(status, 200);
    assert.equal(json.status, 'ready');
  });
});

describe('POST /api/diagnostics/analyze', () => {
  it('accepts a valid diagnostic request and returns 202 with job_id', async () => {
    const { status, json } = await request('POST', '/api/diagnostics/analyze', {
      patient_id: 'PT-2026-00421',
      scan_type: 'MRI',
      body_region: 'head',
      priority: 'urgent',
    });

    assert.equal(status, 202);
    assert.ok(json.job_id, 'response should contain a job_id');
    assert.equal(json.priority, 'urgent');
    assert.ok(json.estimated_time_seconds > 0);
    assert.ok(json.message.includes('queued'));
  });

  it('rejects request with missing patient_id (400)', async () => {
    const { status, json } = await request('POST', '/api/diagnostics/analyze', {
      scan_type: 'CT',
    });

    assert.equal(status, 400);
    assert.ok(json.error.includes('patient_id'));
  });

  it('rejects request with invalid scan_type (400)', async () => {
    const { status, json } = await request('POST', '/api/diagnostics/analyze', {
      patient_id: 'PT-2026-00422',
      scan_type: 'INVALID_SCAN',
    });

    assert.equal(status, 400);
    assert.ok(json.error.includes('scan_type'));
  });

  it('rejects request with invalid priority (400)', async () => {
    const { status, json } = await request('POST', '/api/diagnostics/analyze', {
      patient_id: 'PT-2026-00423',
      scan_type: 'X-Ray',
      priority: 'super-urgent',
    });

    assert.equal(status, 400);
    assert.ok(json.error.includes('priority'));
  });
});

describe('GET /api/diagnostics/queue', () => {
  it('returns queue status with counts and recent_jobs array', async () => {
    const { status, json } = await request('GET', '/api/diagnostics/queue');

    assert.equal(status, 200);
    assert.ok(typeof json.pending === 'number');
    assert.ok(typeof json.processing === 'number');
    assert.ok(typeof json.completed === 'number');
    assert.ok(Array.isArray(json.recent_jobs));
  });
});

describe('GET /api/diagnostics/results/:jobId', () => {
  it('returns 404 for a non-existent job', async () => {
    const { status, json } = await request(
      'GET',
      '/api/diagnostics/results/00000000-0000-0000-0000-000000000000',
    );
    assert.equal(status, 404);
    assert.ok(json.error.includes('not found'));
  });

  it('returns job status for a pending/processing job', async () => {
    // Submit a job first.
    const submit = await request('POST', '/api/diagnostics/analyze', {
      patient_id: 'PT-2026-00430',
      scan_type: 'CT',
      body_region: 'chest',
      priority: 'routine',
    });
    const jobId = submit.json.job_id;

    // Immediately query — it should still be pending.
    const { status, json } = await request(
      'GET',
      `/api/diagnostics/results/${jobId}`,
    );
    assert.equal(status, 200);
    assert.ok(['pending', 'processing'].includes(json.status));
  });
});

describe('GET /api/diagnostics/stats', () => {
  it('returns aggregate statistics', async () => {
    const { status, json } = await request('GET', '/api/diagnostics/stats');

    assert.equal(status, 200);
    assert.ok(typeof json.total_scans_today === 'number');
    assert.ok(typeof json.average_processing_time_s === 'number');
    assert.ok(typeof json.accuracy_rate === 'number');
    assert.ok(typeof json.scans_by_type === 'object');
  });
});

describe('GET /metrics', () => {
  it('returns Prometheus-formatted metrics', async () => {
    const { status, text } = await request('GET', '/metrics');

    assert.equal(status, 200);
    assert.ok(text.includes('diagnostic_queue_depth'));
    assert.ok(text.includes('diagnostic_scans_total'));
    assert.ok(text.includes('diagnostic_analysis_duration_seconds'));
    assert.ok(text.includes('diagnostic_accuracy_rate'));
    assert.ok(text.includes('diagnostic_throughput_per_minute'));
  });
});
