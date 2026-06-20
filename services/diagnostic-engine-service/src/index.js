/**
 * index.js — NeuroSphere Diagnostic Engine Service
 *
 * Express-based microservice that simulates an AI diagnostic image-processing
 * pipeline. Accepts scan analysis requests, queues them, processes via a
 * background loop, and exposes results with Prometheus-compatible metrics.
 *
 * Endpoints:
 *   POST /api/diagnostics/analyze      — Submit a new diagnostic request
 *   GET  /api/diagnostics/queue        — Queue status dashboard
 *   GET  /api/diagnostics/results/:id  — Fetch results for a job
 *   GET  /api/diagnostics/stats        — Aggregate statistics
 *   GET  /health                       — Liveness probe
 *   GET  /ready                        — Readiness probe
 *   GET  /metrics                      — Prometheus metrics
 */

const express = require('express');
const cors = require('cors');
const winston = require('winston');

const {
  SCAN_TYPES,
  PRIORITIES,
  BODY_REGIONS,
  createJob,
  dequeueJob,
  completeJob,
  failJob,
  getJob,
  getQueueStatus,
  getStats,
  getThroughputPerMinute,
  getPendingCount,
} = require('./models');

const { generateDiagnosticResult } = require('./simulator');

const {
  promClient,
  queueDepth,
  analysisDuration,
  scansTotal,
  accuracyRate,
  throughputPerMinute,
} = require('./metrics');

// ─── Logger ──────────────────────────────────────────────────────────────────

const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json(),
  ),
  defaultMeta: { service: 'diagnostic-engine-service' },
  transports: [new winston.transports.Console()],
});

// ─── Express app ─────────────────────────────────────────────────────────────

const app = express();
app.use(cors());
app.use(express.json());

// Track service readiness — false until background processor is running.
let isReady = false;

// ─── Routes ──────────────────────────────────────────────────────────────────

/**
 * POST /api/diagnostics/analyze
 * Submit a diagnostic scan for AI analysis.
 */
app.post('/api/diagnostics/analyze', (req, res) => {
  const { patient_id, scan_type, body_region, priority } = req.body;

  // ── Validation ──
  if (!patient_id || typeof patient_id !== 'string') {
    return res.status(400).json({
      error: 'patient_id is required and must be a string',
    });
  }

  if (!scan_type || !SCAN_TYPES.includes(scan_type)) {
    return res.status(400).json({
      error: `scan_type must be one of: ${SCAN_TYPES.join(', ')}`,
    });
  }

  if (body_region && !BODY_REGIONS.includes(body_region)) {
    return res.status(400).json({
      error: `body_region must be one of: ${BODY_REGIONS.join(', ')}`,
    });
  }

  if (priority && !PRIORITIES.includes(priority)) {
    return res.status(400).json({
      error: `priority must be one of: ${PRIORITIES.join(', ')}`,
    });
  }

  const job = createJob({
    patient_id,
    scan_type,
    body_region: body_region || 'chest',
    priority: priority || 'routine',
  });

  // Update queue depth metric.
  updateQueueMetrics();

  logger.info('Diagnostic job submitted', {
    job_id: job.job_id,
    patient_id,
    scan_type,
    body_region: job.body_region,
    priority: job.priority,
  });

  res.status(202).json({
    message: 'Diagnostic analysis queued successfully',
    job_id: job.job_id,
    estimated_time_seconds: job.estimated_seconds,
    priority: job.priority,
    queue_position: getPendingCount(),
  });
});

/**
 * GET /api/diagnostics/queue
 * Return current queue status with counts and recent jobs.
 */
app.get('/api/diagnostics/queue', (_req, res) => {
  const status = getQueueStatus();
  res.json(status);
});

/**
 * GET /api/diagnostics/results/:jobId
 * Return analysis results for a completed (or in-progress) job.
 */
app.get('/api/diagnostics/results/:jobId', (req, res) => {
  const job = getJob(req.params.jobId);

  if (!job) {
    return res.status(404).json({ error: 'Job not found' });
  }

  if (job.status === 'pending' || job.status === 'processing') {
    return res.status(200).json({
      job_id: job.job_id,
      status: job.status,
      message: job.status === 'pending'
        ? 'Job is waiting in the queue'
        : 'Analysis is currently in progress',
      estimated_time_seconds: job.estimated_seconds,
    });
  }

  // completed or failed
  res.json({
    job_id: job.job_id,
    patient_id: job.patient_id,
    scan_type: job.scan_type,
    body_region: job.body_region,
    status: job.status,
    created_at: job.created_at,
    started_at: job.started_at,
    completed_at: job.completed_at,
    result: job.result,
  });
});

/**
 * GET /api/diagnostics/stats
 * Aggregate statistics for the dashboard.
 */
app.get('/api/diagnostics/stats', (_req, res) => {
  const stats = getStats();
  res.json(stats);
});

// ─── Health / Readiness ──────────────────────────────────────────────────────

app.get('/health', (_req, res) => {
  res.json({
    status: 'healthy',
    service: 'diagnostic-engine-service',
    timestamp: new Date().toISOString(),
    uptime_seconds: Math.floor(process.uptime()),
  });
});

app.get('/ready', (_req, res) => {
  if (!isReady) {
    return res.status(503).json({
      status: 'not_ready',
      message: 'Background processing loop has not started',
    });
  }
  res.json({
    status: 'ready',
    service: 'diagnostic-engine-service',
    queue_depth: getPendingCount(),
  });
});

// ─── Prometheus /metrics ─────────────────────────────────────────────────────

app.get('/metrics', async (_req, res) => {
  try {
    // Refresh gauge-type metrics before scrape.
    updateQueueMetrics();
    const stats = getStats();
    accuracyRate.set(stats.accuracy_rate);
    throughputPerMinute.set(getThroughputPerMinute());

    res.set('Content-Type', promClient.register.contentType);
    const metricsOutput = await promClient.register.metrics();
    res.end(metricsOutput);
  } catch (err) {
    logger.error('Failed to generate metrics', { error: err.message });
    res.status(500).end();
  }
});

// ─── Queue-depth metric updater ──────────────────────────────────────────────

function updateQueueMetrics() {
  const qs = getQueueStatus();
  // Reset then set per-priority (simplified: report total as 'all').
  queueDepth.set({ priority: 'all' }, qs.pending);
}

// ─── Background Processing Loop ─────────────────────────────────────────────
// Simulates the AI inference pipeline: dequeue → process → store result.
// Processing interval is randomised between 2–8 seconds to mimic GPU inference
// time variability.

function scheduleNextProcessing() {
  const delayMs = 2000 + Math.random() * 6000; // 2–8 s
  setTimeout(processNextJob, delayMs);
}

function processNextJob() {
  const job = dequeueJob();

  if (job) {
    logger.info('Processing diagnostic job', {
      job_id: job.job_id,
      scan_type: job.scan_type,
      body_region: job.body_region,
    });

    try {
      const result = generateDiagnosticResult(job);

      completeJob(job.job_id, result);

      // Record Prometheus metrics.
      analysisDuration.observe({ scan_type: job.scan_type }, result.processing_time_s);
      scansTotal.inc({ scan_type: job.scan_type, result: result.result_category });
      updateQueueMetrics();

      logger.info('Diagnostic analysis completed', {
        job_id: job.job_id,
        result_category: result.result_category,
        confidence: result.confidence_score,
        processing_time_s: result.processing_time_s,
      });
    } catch (err) {
      failJob(job.job_id, err.message);
      logger.error('Diagnostic analysis failed', {
        job_id: job.job_id,
        error: err.message,
      });
    }
  }

  // Schedule next iteration regardless of whether a job was processed.
  scheduleNextProcessing();
}

// ─── Server bootstrap ────────────────────────────────────────────────────────

const PORT = parseInt(process.env.PORT, 10) || 3000;

// Allow external consumers to use the app without starting the server
// (useful for testing).
if (require.main === module) {
  app.listen(PORT, () => {
    isReady = true;
    logger.info(`Diagnostic Engine Service listening on port ${PORT}`);
    logger.info('Background processing loop started');
    scheduleNextProcessing();
  });
}

// Export for testing.
module.exports = { app, setReady: (v) => { isReady = v; } };
