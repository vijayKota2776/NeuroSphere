/**
 * metrics.js — Prometheus metrics for the Diagnostic Engine Service.
 *
 * Exposes healthcare-specific counters, gauges, and histograms that track
 * queue depth, scan throughput, analysis latency, and diagnostic accuracy.
 */

const promClient = require('prom-client');

// Collect default Node.js runtime metrics (GC, event loop, heap, etc.)
promClient.collectDefaultMetrics({ prefix: 'diagnostic_engine_' });

/**
 * Gauge: current number of items waiting in the diagnostic queue.
 * Labels: priority (stat, urgent, routine)
 */
const queueDepth = new promClient.Gauge({
  name: 'diagnostic_queue_depth',
  help: 'Current number of diagnostic jobs waiting in the processing queue',
  labelNames: ['priority'],
});

/**
 * Histogram: wall-clock processing time for each scan analysis.
 * Buckets chosen to reflect realistic AI inference + post-processing times.
 * Labels: scan_type (MRI, CT, X-Ray, Ultrasound, PET)
 */
const analysisDuration = new promClient.Histogram({
  name: 'diagnostic_analysis_duration_seconds',
  help: 'Time taken to complete a diagnostic analysis in seconds',
  labelNames: ['scan_type'],
  buckets: [1, 2, 3, 5, 8, 10, 15, 20, 30, 45, 60],
});

/**
 * Counter: total scans processed, partitioned by scan type and result category.
 * result is one of: normal, abnormal, inconclusive
 */
const scansTotal = new promClient.Counter({
  name: 'diagnostic_scans_total',
  help: 'Total number of diagnostic scans processed',
  labelNames: ['scan_type', 'result'],
});

/**
 * Gauge: rolling accuracy rate (0–1) of the diagnostic engine.
 * Simulated — in production this would be computed against radiologist reviews.
 */
const accuracyRate = new promClient.Gauge({
  name: 'diagnostic_accuracy_rate',
  help: 'Current estimated accuracy rate of the diagnostic AI engine',
});

/**
 * Gauge: throughput expressed as completed scans per minute (rolling window).
 */
const throughputPerMinute = new promClient.Gauge({
  name: 'diagnostic_throughput_per_minute',
  help: 'Number of diagnostic scans processed per minute (rolling)',
});

module.exports = {
  promClient,
  queueDepth,
  analysisDuration,
  scansTotal,
  accuracyRate,
  throughputPerMinute,
};
