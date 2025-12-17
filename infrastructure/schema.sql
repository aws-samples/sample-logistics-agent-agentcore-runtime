-- Logistics Database Schema for AgentCore Runtime Demo
-- Database: company_logistics_db
-- User: agent (read-only permissions recommended)

-- Schema
CREATE SCHEMA IF NOT EXISTS logistics;

-- Reference types
CREATE TYPE logistics.shipment_status AS ENUM (
  'CREATED','BOOKED','IN_TRANSIT','AT_PORT','CUSTOMS_HOLD','CUSTOMS_CLEARED',
  'OUT_FOR_DELIVERY','DELIVERED','CANCELLED','EXCEPTION'
);

CREATE TYPE logistics.leg_status AS ENUM (
  'PENDING','DEPARTED','ARRIVED','DELAYED','CANCELLED'
);

CREATE TYPE logistics.event_type AS ENUM (
  'CREATED','BOOKED','DEPARTED_PORT','ARRIVED_PORT','DISCHARGED',
  'GATE_IN','GATE_OUT','CUSTOMS_HOLD','CUSTOMS_RELEASE','HANDOFF',
  'OUT_FOR_DELIVERY','DELIVERED','DELAY','ETA_UPDATE','EXCEPTION_NOTE'
);

CREATE TYPE logistics.container_type AS ENUM ('DRY','REEFER','OPEN_TOP','TANK');

-- Parties and locations
CREATE TABLE logistics.customers (
  customer_id      BIGSERIAL PRIMARY KEY,
  name             TEXT NOT NULL,
  account_code     TEXT UNIQUE,
  contact_email    TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE logistics.carriers (
  carrier_id       BIGSERIAL PRIMARY KEY,
  name             TEXT NOT NULL,
  scac             TEXT UNIQUE,     -- Standard Carrier Alpha Code
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE logistics.locations (
  location_id      BIGSERIAL PRIMARY KEY,
  name             TEXT NOT NULL,
  unlocode         TEXT UNIQUE,     -- UN/LOCODE (e.g., USNYC)
  country_code     CHAR(2),
  tz               TEXT,            -- IANA timezone id
  lat              DOUBLE PRECISION,
  lon              DOUBLE PRECISION
);

CREATE TABLE logistics.vessels (
  vessel_id        BIGSERIAL PRIMARY KEY,
  name             TEXT NOT NULL,
  imo_number       TEXT UNIQUE,     -- IMO registry
  mmsi             TEXT UNIQUE,
  carrier_id       BIGINT REFERENCES logistics.carriers(carrier_id),
  active           BOOLEAN NOT NULL DEFAULT TRUE
);

-- Shipments and containers
CREATE TABLE logistics.shipments (
  shipment_id      BIGSERIAL PRIMARY KEY,
  customer_id      BIGINT REFERENCES logistics.customers(customer_id) NOT NULL,
  reference_no     TEXT UNIQUE,     -- customer or internal tracking reference
  origin_id        BIGINT REFERENCES logistics.locations(location_id) NOT NULL,
  destination_id   BIGINT REFERENCES logistics.locations(location_id) NOT NULL,
  incoterm         TEXT,            -- e.g., FOB, CIF
  status           logistics.shipment_status NOT NULL DEFAULT 'CREATED',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  eta_final        TIMESTAMPTZ,     -- most recent best ETA to destination
  etd_origin       TIMESTAMPTZ,
  current_location_id BIGINT REFERENCES logistics.locations(location_id)  -- Quick lookup
);

CREATE TABLE logistics.containers (
  container_id     BIGSERIAL PRIMARY KEY,
  container_no     TEXT UNIQUE NOT NULL,  -- e.g., MSKU1234567
  type             logistics.container_type NOT NULL,
  owner_carrier_id BIGINT REFERENCES logistics.carriers(carrier_id),
  reefer_setpoint_c NUMERIC(5,2),         -- optional for reefer
  active           BOOLEAN NOT NULL DEFAULT TRUE
);

-- Shipment legs (ocean, rail, truck). A shipment can have many legs.
CREATE TABLE logistics.shipment_legs (
  leg_id           BIGSERIAL PRIMARY KEY,
  shipment_id      BIGINT REFERENCES logistics.shipments(shipment_id) ON DELETE CASCADE,
  sequence_no      INT NOT NULL,
  mode             TEXT NOT NULL,         -- 'OCEAN','RAIL','TRUCK','AIR'
  carrier_id       BIGINT REFERENCES logistics.carriers(carrier_id),
  vessel_id        BIGINT REFERENCES logistics.vessels(vessel_id),
  origin_id        BIGINT REFERENCES logistics.locations(location_id) NOT NULL,
  destination_id   BIGINT REFERENCES logistics.locations(location_id) NOT NULL,
  etd              TIMESTAMPTZ,
  eta              TIMESTAMPTZ,
  ata              TIMESTAMPTZ,
  status           logistics.leg_status NOT NULL DEFAULT 'PENDING',
  UNIQUE (shipment_id, sequence_no)
);

-- Join table because a shipment can have many containers
CREATE TABLE logistics.shipment_containers (
  shipment_id      BIGINT REFERENCES logistics.shipments(shipment_id) ON DELETE CASCADE,
  container_id     BIGINT REFERENCES logistics.containers(container_id),
  PRIMARY KEY (shipment_id, container_id)
);

-- Append-only event stream that drives real-time state
-- Consider time-based partitioning in production
CREATE TABLE logistics.tracking_events (
  event_id         BIGSERIAL PRIMARY KEY,
  occurred_at      TIMESTAMPTZ NOT NULL,
  ingested_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  shipment_id      BIGINT REFERENCES logistics.shipments(shipment_id),
  leg_id           BIGINT REFERENCES logistics.shipment_legs(leg_id),
  container_id     BIGINT REFERENCES logistics.containers(container_id),
  vessel_id        BIGINT REFERENCES logistics.vessels(vessel_id),
  location_id      BIGINT REFERENCES logistics.locations(location_id),
  event            logistics.event_type NOT NULL,
  status_hint      logistics.shipment_status, -- optional direct hint
  details          JSONB,                     -- freeform payload from sensors or EDI
  UNIQUE (shipment_id, occurred_at, event)    -- dedupe guard
);

-- Customs and exceptions
CREATE TABLE logistics.customs_clearance (
  clearance_id     BIGSERIAL PRIMARY KEY,
  shipment_id      BIGINT REFERENCES logistics.shipments(shipment_id) ON DELETE CASCADE,
  port_id          BIGINT REFERENCES logistics.locations(location_id),
  status           TEXT NOT NULL,        -- 'SUBMITTED','HOLD','RELEASED'
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  notes            TEXT
);

CREATE TABLE logistics.exceptions (
  exception_id     BIGSERIAL PRIMARY KEY,
  shipment_id      BIGINT REFERENCES logistics.shipments(shipment_id) ON DELETE CASCADE,
  severity         TEXT NOT NULL,        -- 'LOW','MEDIUM','HIGH'
  category         TEXT NOT NULL,        -- 'DELAY','DAMAGE','DOCUMENTS','CUSTOMS','WEATHER'
  opened_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_at        TIMESTAMPTZ,
  summary          TEXT,
  details          JSONB
);

-- Indexes for common agent lookups
CREATE INDEX idx_shipments_reference ON logistics.shipments (reference_no);
CREATE INDEX idx_shipments_customer_status ON logistics.shipments (customer_id, status);
CREATE INDEX idx_shipments_customer_created ON logistics.shipments (customer_id, created_at DESC);
CREATE INDEX idx_shipments_current_location ON logistics.shipments (current_location_id);

CREATE INDEX idx_shipment_legs_shipment ON logistics.shipment_legs (shipment_id, sequence_no);
CREATE INDEX idx_shipment_legs_destination_eta ON logistics.shipment_legs (destination_id, eta);
CREATE INDEX idx_shipment_legs_vessel ON logistics.shipment_legs (vessel_id, etd);

CREATE INDEX idx_tracking_events_shipment ON logistics.tracking_events (shipment_id, occurred_at DESC);
CREATE INDEX idx_tracking_events_container ON logistics.tracking_events (container_id, occurred_at DESC);
CREATE INDEX idx_tracking_events_vessel ON logistics.tracking_events (vessel_id, occurred_at DESC);
CREATE INDEX idx_tracking_events_details ON logistics.tracking_events USING GIN (details);

CREATE INDEX idx_customs_status ON logistics.customs_clearance (status, updated_at DESC);
CREATE INDEX idx_exceptions_shipment ON logistics.exceptions (shipment_id, opened_at DESC);
CREATE INDEX idx_exceptions_open ON logistics.exceptions (closed_at) WHERE closed_at IS NULL;

-- View: latest event per shipment (agent friendly)
CREATE VIEW logistics.v_shipment_latest_event AS
SELECT DISTINCT ON (te.shipment_id)
  te.shipment_id,
  te.event,
  te.status_hint,
  te.location_id,
  te.occurred_at,
  te.details
FROM logistics.tracking_events te
ORDER BY te.shipment_id, te.occurred_at DESC;

-- View: current leg with ETA and status
CREATE VIEW logistics.v_shipment_progress AS
SELECT
  s.shipment_id,
  s.reference_no,
  s.status,
  l.leg_id,
  l.sequence_no,
  lo1.unlocode AS origin_unlocode,
  lo2.unlocode AS dest_unlocode,
  l.etd,
  l.eta,
  l.ata,
  l.status AS leg_status
FROM logistics.shipments s
JOIN LATERAL (
  SELECT sl.*
  FROM logistics.shipment_legs sl
  WHERE sl.shipment_id = s.shipment_id
  ORDER BY sl.sequence_no DESC
  LIMIT 1
) l ON TRUE
JOIN logistics.locations lo1 ON lo1.location_id = l.origin_id
JOIN logistics.locations lo2 ON lo2.location_id = l.destination_id;

-- Materialized view: on-time risk (simple example)
CREATE MATERIALIZED VIEW logistics.mv_eta_risk AS
SELECT
  s.shipment_id,
  s.reference_no,
  s.destination_id,
  l.eta,
  s.eta_final,
  CASE
    WHEN l.eta IS NULL THEN 'UNKNOWN'
    WHEN s.eta_final IS NOT NULL AND l.eta > s.eta_final THEN 'AT_RISK'
    ELSE 'ON_TRACK'
  END AS eta_status
FROM logistics.shipments s
LEFT JOIN LATERAL (
  SELECT sl.*
  FROM logistics.shipment_legs sl
  WHERE sl.shipment_id = s.shipment_id
  ORDER BY sl.sequence_no DESC
  LIMIT 1
) l ON TRUE;

-- Create index on materialized view
CREATE INDEX idx_mv_eta_risk_status ON logistics.mv_eta_risk (eta_status, eta);

-- Grant read-only permissions to agent user
GRANT USAGE ON SCHEMA logistics TO agent;
GRANT SELECT ON ALL TABLES IN SCHEMA logistics TO agent;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA logistics TO agent;
ALTER DEFAULT PRIVILEGES IN SCHEMA logistics GRANT SELECT ON TABLES TO agent;
