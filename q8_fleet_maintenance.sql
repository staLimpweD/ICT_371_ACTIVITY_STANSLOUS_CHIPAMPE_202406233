CREATE SCHEMA IF NOT EXISTS q8;
SET search_path TO q8, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    registration VARCHAR(20) UNIQUE NOT NULL,
    current_odometer NUMERIC(12,2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12,2) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id SERIAL PRIMARY KEY,
    vehicle_id INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer NUMERIC(12,2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(12,2) NOT NULL CHECK (end_odometer > start_odometer)
);
CREATE TABLE service_alerts (
    vehicle_id INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12,2) NOT NULL,
    flagged_on DATE NOT NULL DEFAULT CURRENT_DATE
);

INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
 ('V1', 20000, 19000),    -- 1000 since service
 ('V2', 30000, 24000),    -- 6000 since service (due)
 ('V3', 10000, 10000);    -- 0 since service

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_km NUMERIC;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
      FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id; END IF;
    RETURN v_km >= 5000;
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT, p_trip_on DATE, p_start NUMERIC, p_end NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
    END IF;
    IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer must be greater than start_odometer';
    END IF;
    INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, COALESCE(p_trip_on, CURRENT_DATE), p_start, p_end);
    -- vehicle odometer updated by trigger
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_trips_bi() RETURNS TRIGGER AS $$
DECLARE v_cur NUMERIC;
BEGIN
    SELECT current_odometer INTO v_cur FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF v_cur IS NULL THEN RAISE EXCEPTION 'Unknown vehicle %', NEW.vehicle_id; END IF;
    IF NEW.start_odometer <> v_cur THEN
        RAISE EXCEPTION 'start_odometer % must equal current_odometer %',
            NEW.start_odometer, v_cur;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'end_odometer must exceed start_odometer';
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trips_bi
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trips_bi();

-- Seed six trips via procedure
CALL pr_record_trip(1, CURRENT_DATE-5, 20000, 20500);
CALL pr_record_trip(1, CURRENT_DATE-3, 20500, 21000);
CALL pr_record_trip(1, CURRENT_DATE-1, 21000, 21500);
CALL pr_record_trip(2, CURRENT_DATE-4, 30000, 30300);
CALL pr_record_trip(2, CURRENT_DATE-2, 30300, 30600);
CALL pr_record_trip(3, CURRENT_DATE-1, 10000, 10100);

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
  FROM vehicles
 WHERE current_odometer - last_service_odometer >= 5000;

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

-- EXPLAIN SELECT * FROM trips WHERE vehicle_id = 1
--   AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- Upsert alerts for due vehicles
    INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
      FROM vehicles
     WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
      SET km_since_service = EXCLUDED.km_since_service,
          flagged_on       = EXCLUDED.flagged_on;

    -- Remove alerts for vehicles no longer due
    DELETE FROM service_alerts sa
     USING vehicles v
     WHERE sa.vehicle_id = v.vehicle_id
       AND v.current_odometer - v.last_service_odometer < 5000;
END; $$;

-- SELECT cron.schedule('q8_alerts','0 6 * * 1', $$CALL q8.pr_refresh_service_alerts()$$);