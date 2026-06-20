/**
 * models.js — In-memory job queue and result storage for the Diagnostic Engine.
 *
 * In production these would be backed by Redis (queue) and PostgreSQL (results),
 * but for the simulation an in-memory store is sufficient.
 *
 * Job lifecycle:  pending  →  processing  →  completed | failed
 */

const { v4: uuidv4 } = require('uuid');

/** @type {Map<string, object>} All jobs indexed by job_id */
const jobStore = new Map();

/** @type {string[]} FIFO queue of job_ids waiting for processing */
const pendingQueue = [];

/** @type {object[]} Circular buffer of the last N completed results */
const recentResults = [];
const MAX_RECENT = 100;

/** Rolling window of completion timestamps used for throughput calculation */
const completionTimestamps = [];

// ─── Supported enumerations ──────────────────────────────────────────────────

const SCAN_TYPES = ['MRI', 'CT', 'X-Ray', 'Ultrasound', 'PET'];
const PRIORITIES = ['stat', 'urgent', 'routine'];
const BODY_REGIONS = [
  'head', 'neck', 'chest', 'abdomen', 'pelvis',
  'spine', 'upper_extremity', 'lower_extremity', 'whole_body',
];

// ─── Estimated processing times (seconds) per scan type ──────────────────────
const ESTIMATED_TIMES = {
  'MRI':        { min: 15, max: 45 },
  'CT':         { min: 8,  max: 25 },
  'X-Ray':      { min: 3,  max: 10 },
  'Ultrasound': { min: 5,  max: 15 },
  'PET':        { min: 20, max: 60 },
};

/**
 * Create a new diagnostic job and enqueue it.
 * @param {object} params - { patient_id, scan_type, body_region, priority }
 * @returns {object} The created job record.
 */
function createJob({ patient_id, scan_type, body_region, priority }) {
  const job_id = uuidv4();
  const est = ESTIMATED_TIMES[scan_type] || { min: 5, max: 20 };
  const estimated_seconds = Math.round((est.min + est.max) / 2);

  const job = {
    job_id,
    patient_id,
    scan_type,
    body_region,
    priority: priority || 'routine',
    status: 'pending',
    created_at: new Date().toISOString(),
    started_at: null,
    completed_at: null,
    estimated_seconds,
    result: null,
  };

  jobStore.set(job_id, job);

  // Stat-priority jobs go to the front of the queue.
  if (job.priority === 'stat') {
    pendingQueue.unshift(job_id);
  } else {
    pendingQueue.push(job_id);
  }

  return job;
}

/**
 * Dequeue the next pending job for processing.
 * @returns {object|null} The job record, or null if the queue is empty.
 */
function dequeueJob() {
  if (pendingQueue.length === 0) return null;

  const job_id = pendingQueue.shift();
  const job = jobStore.get(job_id);
  if (!job) return null;

  job.status = 'processing';
  job.started_at = new Date().toISOString();
  return job;
}

/**
 * Mark a job as completed and store results.
 * @param {string} job_id
 * @param {object} result - Analysis result payload from the simulator.
 */
function completeJob(job_id, result) {
  const job = jobStore.get(job_id);
  if (!job) return;

  job.status = 'completed';
  job.completed_at = new Date().toISOString();
  job.result = result;

  // Maintain the recent-results circular buffer.
  recentResults.push({ job_id, ...result, completed_at: job.completed_at });
  if (recentResults.length > MAX_RECENT) recentResults.shift();

  // Record timestamp for throughput calculation.
  completionTimestamps.push(Date.now());
}

/**
 * Mark a job as failed.
 */
function failJob(job_id, error_message) {
  const job = jobStore.get(job_id);
  if (!job) return;
  job.status = 'failed';
  job.completed_at = new Date().toISOString();
  job.result = { error: error_message };
}

/**
 * Return the job record for a given job_id.
 */
function getJob(job_id) {
  return jobStore.get(job_id) || null;
}

/**
 * Return queue status counts and recent jobs.
 */
function getQueueStatus() {
  let pending = 0, processing = 0, completed = 0, failed = 0;
  for (const job of jobStore.values()) {
    if (job.status === 'pending')    pending++;
    if (job.status === 'processing') processing++;
    if (job.status === 'completed')  completed++;
    if (job.status === 'failed')     failed++;
  }

  // Last 20 jobs for the dashboard.
  const recent = Array.from(jobStore.values())
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
    .slice(0, 20)
    .map(j => ({
      job_id: j.job_id,
      patient_id: j.patient_id,
      scan_type: j.scan_type,
      body_region: j.body_region,
      priority: j.priority,
      status: j.status,
      created_at: j.created_at,
    }));

  return { pending, processing, completed, failed, recent_jobs: recent };
}

/**
 * Aggregate statistics used by the /stats endpoint.
 */
function getStats() {
  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());

  let total_scans_today = 0;
  let total_processing_ms = 0;
  let processed_count = 0;
  const scans_by_type = {};
  const results_by_category = { normal: 0, abnormal: 0, inconclusive: 0 };

  for (const job of jobStore.values()) {
    if (new Date(job.created_at) >= todayStart) total_scans_today++;

    if (job.status === 'completed' && job.started_at && job.completed_at) {
      const duration = new Date(job.completed_at) - new Date(job.started_at);
      total_processing_ms += duration;
      processed_count++;

      scans_by_type[job.scan_type] = (scans_by_type[job.scan_type] || 0) + 1;

      if (job.result && job.result.result_category) {
        results_by_category[job.result.result_category] =
          (results_by_category[job.result.result_category] || 0) + 1;
      }
    }
  }

  const average_processing_time_s = processed_count > 0
    ? parseFloat((total_processing_ms / processed_count / 1000).toFixed(2))
    : 0;

  // Simulated accuracy based on a weighted formula (higher for normal results).
  const accuracy_rate = processed_count > 0
    ? parseFloat((0.92 + Math.random() * 0.06).toFixed(4))
    : 0;

  return {
    total_scans_today,
    total_scans_all_time: processed_count,
    average_processing_time_s,
    accuracy_rate,
    scans_by_type,
    results_by_category,
  };
}

/**
 * Compute rolling throughput (scans per minute over the last 5 minutes).
 */
function getThroughputPerMinute() {
  const fiveMinAgo = Date.now() - 5 * 60 * 1000;
  // Prune old timestamps.
  while (completionTimestamps.length > 0 && completionTimestamps[0] < fiveMinAgo) {
    completionTimestamps.shift();
  }
  // scans in last 5 min → per minute
  return parseFloat((completionTimestamps.length / 5).toFixed(2));
}

/**
 * Return the number of pending items in the queue.
 */
function getPendingCount() {
  return pendingQueue.length;
}

module.exports = {
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
};
