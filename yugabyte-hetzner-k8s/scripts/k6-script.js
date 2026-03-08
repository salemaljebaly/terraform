/**
 * k6-script.js — YugabyteDB bottleneck finder using k6 + xk6-sql-driver-postgres
 *
 * Workload modes (set via WORKLOAD env var):
 *   insert  — pure INSERT with UUID keys (finds max write TPS)
 *   read    — pure SELECT by score range (finds max read TPS)
 *   mixed   — 70% writes / 30% reads (simulates real app)
 *
 * Used by benchmark-k6.sh progressive load test:
 *   50 VUs -> 100 -> 200 -> 400 -> find the plateau = bottleneck
 *
 * Run from Mac:
 *   k6 run scripts/k6-script.js \
 *     -e DB_HOST=<worker-ip> \
 *     -e DB_PORT=<nodeport> \
 *     -e WORKLOAD=insert
 */

import sql from 'k6/x/sql'
import { check } from 'k6'
import { Counter, Rate, Trend } from 'k6/metrics'

// ── config ────────────────────────────────────────────────────────────────────
const DB_HOST  = __ENV.DB_HOST  || 'yb-tservers.yugabyte.svc.cluster.local'
const DB_PORT  = __ENV.DB_PORT  || '5433'
const VUS      = parseInt(__ENV.VUS      || '100')
const DURATION = __ENV.DURATION || '60s'
const WORKLOAD = __ENV.WORKLOAD || 'insert'  // insert | read | mixed

export const options = {
  scenarios: {
    load: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
    },
  },
  thresholds: {
    'op_latency': ['p(95)<1000'],
    'errors':     ['rate<0.05'],
  },
}

// ── metrics ───────────────────────────────────────────────────────────────────
const opLatency  = new Trend('op_latency', true)
const errors     = new Rate('errors')
const opsCounter = new Counter('ops_total')

// ── one connection per VU (DNS round-robin distributes across tservers) ───────
const db = sql.open(
  'postgres',
  `host=${DB_HOST} port=${DB_PORT} user=yugabyte dbname=yugabyte sslmode=disable`
)

// ── setup: create table once ──────────────────────────────────────────────────
export function setup() {
  const setupDb = sql.open(
    'postgres',
    `host=${DB_HOST} port=${DB_PORT} user=yugabyte dbname=yugabyte sslmode=disable`
  )
  setupDb.exec(`
    CREATE TABLE IF NOT EXISTS k6_load (
      id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      vu_id      INT  NOT NULL,
      iteration  INT  NOT NULL,
      score      INT  NOT NULL,
      payload    TEXT NOT NULL,
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `)
  setupDb.close()
  console.log(`Workload: ${WORKLOAD} | VUs: ${VUS} | Duration: ${DURATION}`)
}

// ── main workload ─────────────────────────────────────────────────────────────
export default function () {
  const start = Date.now()
  const score = Math.floor(Math.random() * 10000)

  try {
    if (WORKLOAD === 'insert') {
      // Pure write — unique row per request, zero contention
      db.exec(
        `INSERT INTO k6_load (vu_id, iteration, score, payload)
         VALUES (${__VU}, ${__ITER}, ${score}, 'vu${__VU}_i${__ITER}')`
      )

    } else if (WORKLOAD === 'read') {
      // Pure read — range query on distributed score column
      db.query(
        `SELECT id, score, payload FROM k6_load
         WHERE score > ${score} LIMIT 20`
      )

    } else {
      // Mixed: 70% insert / 30% read
      if (Math.random() < 0.7) {
        db.exec(
          `INSERT INTO k6_load (vu_id, iteration, score, payload)
           VALUES (${__VU}, ${__ITER}, ${score}, 'vu${__VU}_i${__ITER}')`
        )
      } else {
        db.query(
          `SELECT id, score FROM k6_load WHERE score > ${score} LIMIT 20`
        )
      }
    }

    opLatency.add(Date.now() - start)
    opsCounter.add(1)
    check(true, { 'op ok': v => v })

  } catch (e) {
    errors.add(1)
  }
}

// ── teardown ──────────────────────────────────────────────────────────────────
export function teardown() {
  db.close()
}
