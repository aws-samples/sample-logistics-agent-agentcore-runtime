-- Seed Data for Logistics Database
-- Run this after schema.sql

-- Locations (Major ports and cities)
INSERT INTO logistics.locations (name, unlocode, country_code, tz, lat, lon) VALUES
('New York', 'USNYC', 'US', 'America/New_York', 40.7128, -74.0060),
('Los Angeles', 'USLAX', 'US', 'America/Los_Angeles', 34.0522, -118.2437),
('Rotterdam', 'NLRTM', 'NL', 'Europe/Amsterdam', 51.9244, 4.4777),
('Shanghai', 'CNSHA', 'CN', 'Asia/Shanghai', 31.2304, 121.4737),
('Singapore', 'SGSIN', 'SG', 'Asia/Singapore', 1.3521, 103.8198),
('Hamburg', 'DEHAM', 'DE', 'Europe/Berlin', 53.5511, 9.9937),
('Long Beach', 'USLGB', 'US', 'America/Los_Angeles', 33.7701, -118.1937),
('Savannah', 'USSAV', 'US', 'America/New_York', 32.0809, -81.0912);

-- Carriers
INSERT INTO logistics.carriers (name, scac) VALUES
('Maersk', 'MAEU'),
('MSC', 'MSCU'),
('CMA CGM', 'CMDU'),
('Hapag-Lloyd', 'HLCU'),
('ONE', 'ONEY');

-- Customers
INSERT INTO logistics.customers (name, account_code, contact_email) VALUES
('Customer Retail', 'CUST01', 'ops@customer.example'),
('Global Electronics', 'GLBL01', 'shipping@globalelec.example'),
('Fashion Forward', 'FASH01', 'logistics@fashionforward.example'),
('Auto Parts Inc', 'AUTO01', 'supply@autoparts.example');

-- Vessels
INSERT INTO logistics.vessels (name, imo_number, mmsi, carrier_id) 
SELECT 'Emma Maersk', '9321483', '219018671', carrier_id FROM logistics.carriers WHERE scac = 'MAEU'
UNION ALL
SELECT 'MSC Oscar', '9703291', '636092425', carrier_id FROM logistics.carriers WHERE scac = 'MSCU'
UNION ALL
SELECT 'CMA CGM Antoine', '9454436', '228339600', carrier_id FROM logistics.carriers WHERE scac = 'CMDU';

-- Containers
INSERT INTO logistics.containers (container_no, type, owner_carrier_id)
SELECT 'MSKU1234567', 'DRY'::logistics.container_type, carrier_id FROM logistics.carriers WHERE scac = 'MAEU'
UNION ALL
SELECT 'MSKU1234568', 'DRY'::logistics.container_type, carrier_id FROM logistics.carriers WHERE scac = 'MAEU'
UNION ALL
SELECT 'MSCU9876543', 'REEFER'::logistics.container_type, carrier_id FROM logistics.carriers WHERE scac = 'MSCU'
UNION ALL
SELECT 'CMAU5555555', 'DRY'::logistics.container_type, carrier_id FROM logistics.carriers WHERE scac = 'CMDU'
UNION ALL
SELECT 'HLCU7777777', 'DRY'::logistics.container_type, carrier_id FROM logistics.carriers WHERE scac = 'HLCU';

-- Shipment 1: CUST-REF-1001 (In Transit - Shanghai to LA)
INSERT INTO logistics.shipments (customer_id, reference_no, origin_id, destination_id, status, etd_origin, eta_final, current_location_id)
SELECT 
  c.customer_id, 
  'CUST-REF-1001', 
  lo1.location_id, 
  lo2.location_id, 
  'IN_TRANSIT', 
  now() - interval '5 days',
  now() + interval '9 days',
  lo1.location_id
FROM logistics.customers c, 
     logistics.locations lo1, 
     logistics.locations lo2
WHERE c.account_code='CUST01' 
  AND lo1.unlocode='CNSHA' 
  AND lo2.unlocode='USLAX';

-- Leg for shipment 1
INSERT INTO logistics.shipment_legs (shipment_id, sequence_no, mode, carrier_id, vessel_id, origin_id, destination_id, etd, eta, status)
SELECT 
  s.shipment_id, 
  1, 
  'OCEAN', 
  ca.carrier_id, 
  v.vessel_id, 
  lo1.location_id, 
  lo2.location_id,
  now() - interval '5 days', 
  now() + interval '9 days', 
  'DEPARTED'
FROM logistics.shipments s
JOIN logistics.carriers ca ON ca.scac='MAEU'
JOIN logistics.vessels v ON v.imo_number='9321483'
JOIN logistics.locations lo1 ON lo1.unlocode='CNSHA'
JOIN logistics.locations lo2 ON lo2.unlocode='USLAX'
WHERE s.reference_no='CUST-REF-1001';

-- Link container to shipment 1
INSERT INTO logistics.shipment_containers (shipment_id, container_id)
SELECT s.shipment_id, c.container_id
FROM logistics.shipments s, logistics.containers c
WHERE s.reference_no='CUST-REF-1001' AND c.container_no='MSKU1234567';

-- Events for shipment 1
INSERT INTO logistics.tracking_events (occurred_at, shipment_id, leg_id, container_id, location_id, event, status_hint, details)
SELECT 
  now() - interval '7 days', 
  s.shipment_id, 
  l.leg_id, 
  c.container_id,
  lo.location_id,
  'BOOKED'::logistics.event_type, 
  'BOOKED'::logistics.shipment_status,
  jsonb_build_object('note','Booking confirmed', 'booking_ref', 'BK123456')
FROM logistics.shipments s
JOIN logistics.shipment_legs l ON l.shipment_id = s.shipment_id AND l.sequence_no = 1
JOIN logistics.containers c ON c.container_no = 'MSKU1234567'
JOIN logistics.locations lo ON lo.unlocode = 'CNSHA'
WHERE s.reference_no='CUST-REF-1001'

UNION ALL

SELECT 
  now() - interval '5 days', 
  s.shipment_id, 
  l.leg_id, 
  c.container_id,
  lo.location_id,
  'DEPARTED_PORT'::logistics.event_type, 
  'IN_TRANSIT'::logistics.shipment_status,
  jsonb_build_object('note','Vessel departed Shanghai', 'vessel', 'Emma Maersk')
FROM logistics.shipments s
JOIN logistics.shipment_legs l ON l.shipment_id = s.shipment_id AND l.sequence_no = 1
JOIN logistics.containers c ON c.container_no = 'MSKU1234567'
JOIN logistics.locations lo ON lo.unlocode = 'CNSHA'
WHERE s.reference_no='CUST-REF-1001';

-- Shipment 2: GLBL-REF-2001 (Customs Hold - Arrived at NY)
INSERT INTO logistics.shipments (customer_id, reference_no, origin_id, destination_id, status, etd_origin, eta_final, current_location_id)
SELECT 
  c.customer_id, 
  'GLBL-REF-2001', 
  lo1.location_id, 
  lo2.location_id, 
  'CUSTOMS_HOLD'::logistics.shipment_status, 
  now() - interval '20 days',
  now() - interval '2 days',
  lo2.location_id
FROM logistics.customers c, 
     logistics.locations lo1, 
     logistics.locations lo2
WHERE c.account_code='GLBL01' 
  AND lo1.unlocode='NLRTM' 
  AND lo2.unlocode='USNYC';

-- Leg for shipment 2
INSERT INTO logistics.shipment_legs (shipment_id, sequence_no, mode, carrier_id, vessel_id, origin_id, destination_id, etd, eta, ata, status)
SELECT 
  s.shipment_id, 
  1, 
  'OCEAN', 
  ca.carrier_id, 
  v.vessel_id, 
  lo1.location_id, 
  lo2.location_id,
  now() - interval '20 days', 
  now() - interval '3 days',
  now() - interval '2 days',
  'ARRIVED'
FROM logistics.shipments s
JOIN logistics.carriers ca ON ca.scac='MSCU'
JOIN logistics.vessels v ON v.imo_number='9703291'
JOIN logistics.locations lo1 ON lo1.unlocode='NLRTM'
JOIN logistics.locations lo2 ON lo2.unlocode='USNYC'
WHERE s.reference_no='GLBL-REF-2001';

-- Link container to shipment 2
INSERT INTO logistics.shipment_containers (shipment_id, container_id)
SELECT s.shipment_id, c.container_id
FROM logistics.shipments s, logistics.containers c
WHERE s.reference_no='GLBL-REF-2001' AND c.container_no='MSCU9876543';

-- Events for shipment 2
INSERT INTO logistics.tracking_events (occurred_at, shipment_id, leg_id, container_id, location_id, event, status_hint, details)
SELECT 
  now() - interval '2 days', 
  s.shipment_id, 
  l.leg_id, 
  c.container_id,
  lo.location_id,
  'ARRIVED_PORT'::logistics.event_type, 
  'AT_PORT'::logistics.shipment_status,
  jsonb_build_object('note','Arrived at New York', 'vessel', 'MSC Oscar')
FROM logistics.shipments s
JOIN logistics.shipment_legs l ON l.shipment_id = s.shipment_id AND l.sequence_no = 1
JOIN logistics.containers c ON c.container_no = 'MSCU9876543'
JOIN logistics.locations lo ON lo.unlocode = 'USNYC'
WHERE s.reference_no='GLBL-REF-2001'

UNION ALL

SELECT 
  now() - interval '1 day', 
  s.shipment_id, 
  l.leg_id, 
  c.container_id,
  lo.location_id,
  'CUSTOMS_HOLD'::logistics.event_type, 
  'CUSTOMS_HOLD'::logistics.shipment_status,
  jsonb_build_object('note','Held for inspection', 'reason', 'Random inspection')
FROM logistics.shipments s
JOIN logistics.shipment_legs l ON l.shipment_id = s.shipment_id AND l.sequence_no = 1
JOIN logistics.containers c ON c.container_no = 'MSCU9876543'
JOIN logistics.locations lo ON lo.unlocode = 'USNYC'
WHERE s.reference_no='GLBL-REF-2001';

-- Customs clearance record for shipment 2
INSERT INTO logistics.customs_clearance (shipment_id, port_id, status, notes)
SELECT 
  s.shipment_id,
  lo.location_id,
  'HOLD',
  'Random inspection - awaiting documentation'
FROM logistics.shipments s
JOIN logistics.locations lo ON lo.unlocode = 'USNYC'
WHERE s.reference_no='GLBL-REF-2001';

-- Exception for shipment 2
INSERT INTO logistics.exceptions (shipment_id, severity, category, summary, details)
SELECT 
  s.shipment_id,
  'MEDIUM',
  'CUSTOMS',
  'Customs hold at New York port',
  jsonb_build_object('port', 'USNYC', 'reason', 'Random inspection', 'expected_release', now() + interval '2 days')
FROM logistics.shipments s
WHERE s.reference_no='GLBL-REF-2001';

-- Shipment 3: FASH-REF-3001 (Delivered)
INSERT INTO logistics.shipments (customer_id, reference_no, origin_id, destination_id, status, etd_origin, eta_final, current_location_id)
SELECT 
  c.customer_id, 
  'FASH-REF-3001', 
  lo1.location_id, 
  lo2.location_id, 
  'DELIVERED'::logistics.shipment_status, 
  now() - interval '30 days',
  now() - interval '5 days',
  lo2.location_id
FROM logistics.customers c, 
     logistics.locations lo1, 
     logistics.locations lo2
WHERE c.account_code='FASH01' 
  AND lo1.unlocode='SGSIN' 
  AND lo2.unlocode='USSAV';

-- Leg for shipment 3
INSERT INTO logistics.shipment_legs (shipment_id, sequence_no, mode, carrier_id, vessel_id, origin_id, destination_id, etd, eta, ata, status)
SELECT 
  s.shipment_id, 
  1, 
  'OCEAN', 
  ca.carrier_id, 
  v.vessel_id, 
  lo1.location_id, 
  lo2.location_id,
  now() - interval '30 days', 
  now() - interval '6 days',
  now() - interval '5 days',
  'ARRIVED'
FROM logistics.shipments s
JOIN logistics.carriers ca ON ca.scac='CMDU'
JOIN logistics.vessels v ON v.imo_number='9454436'
JOIN logistics.locations lo1 ON lo1.unlocode='SGSIN'
JOIN logistics.locations lo2 ON lo2.unlocode='USSAV'
WHERE s.reference_no='FASH-REF-3001';

-- Link container to shipment 3
INSERT INTO logistics.shipment_containers (shipment_id, container_id)
SELECT s.shipment_id, c.container_id
FROM logistics.shipments s, logistics.containers c
WHERE s.reference_no='FASH-REF-3001' AND c.container_no='CMAU5555555';

-- Events for shipment 3 (delivered successfully)
INSERT INTO logistics.tracking_events (occurred_at, shipment_id, leg_id, container_id, location_id, event, status_hint, details)
SELECT 
  now() - interval '5 days', 
  s.shipment_id, 
  l.leg_id, 
  c.container_id,
  lo.location_id,
  'ARRIVED_PORT'::logistics.event_type, 
  'AT_PORT'::logistics.shipment_status,
  jsonb_build_object('note','Arrived at Savannah')
FROM logistics.shipments s
JOIN logistics.shipment_legs l ON l.shipment_id = s.shipment_id AND l.sequence_no = 1
JOIN logistics.containers c ON c.container_no = 'CMAU5555555'
JOIN logistics.locations lo ON lo.unlocode = 'USSAV'
WHERE s.reference_no='FASH-REF-3001'

UNION ALL

SELECT 
  now() - interval '4 days', 
  s.shipment_id, 
  l.leg_id, 
  c.container_id,
  lo.location_id,
  'CUSTOMS_RELEASE'::logistics.event_type, 
  'CUSTOMS_CLEARED'::logistics.shipment_status,
  jsonb_build_object('note','Customs cleared')
FROM logistics.shipments s
JOIN logistics.shipment_legs l ON l.shipment_id = s.shipment_id AND l.sequence_no = 1
JOIN logistics.containers c ON c.container_no = 'CMAU5555555'
JOIN logistics.locations lo ON lo.unlocode = 'USSAV'
WHERE s.reference_no='FASH-REF-3001'

UNION ALL

SELECT 
  now() - interval '3 days', 
  s.shipment_id, 
  l.leg_id, 
  c.container_id,
  lo.location_id,
  'DELIVERED'::logistics.event_type, 
  'DELIVERED'::logistics.shipment_status,
  jsonb_build_object('note','Delivered to customer', 'signed_by', 'J. Smith')
FROM logistics.shipments s
JOIN logistics.shipment_legs l ON l.shipment_id = s.shipment_id AND l.sequence_no = 1
JOIN logistics.containers c ON c.container_no = 'CMAU5555555'
JOIN logistics.locations lo ON lo.unlocode = 'USSAV'
WHERE s.reference_no='FASH-REF-3001';

-- Refresh materialized view
REFRESH MATERIALIZED VIEW logistics.mv_eta_risk;

-- Summary
SELECT 'Seed data loaded successfully!' AS status;
SELECT COUNT(*) AS location_count FROM logistics.locations;
SELECT COUNT(*) AS carrier_count FROM logistics.carriers;
SELECT COUNT(*) AS customer_count FROM logistics.customers;
SELECT COUNT(*) AS vessel_count FROM logistics.vessels;
SELECT COUNT(*) AS container_count FROM logistics.containers;
SELECT COUNT(*) AS shipment_count FROM logistics.shipments;
SELECT COUNT(*) AS event_count FROM logistics.tracking_events;
