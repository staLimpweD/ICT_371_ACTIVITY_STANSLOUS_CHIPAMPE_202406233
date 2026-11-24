CREATE SCHEMA IF NOT EXISTS q7;
SET search_path TO q7, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL CHECK (reading_month = date_trunc('month', reading_month)::date),
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
    UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    reading_id INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on DATE NOT NULL,
    CONSTRAINT chk_paid CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(14,2) NOT NULL
);

INSERT INTO customers(full_name) VALUES ('C1'),('C2'),('C3');

INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, date_trunc('month',CURRENT_DATE)::date, 100, 100),  -- 0 units
 (1, date_trunc('month',CURRENT_DATE - INTERVAL '1 month')::date, 90, 100), -- 10
 (2, date_trunc('month',CURRENT_DATE)::date, 200, 215),  -- 15
 (2, date_trunc('month',CURRENT_DATE - INTERVAL '1 month')::date, 180, 195), -- 15
 (3, date_trunc('month',CURRENT_DATE)::date, 50, 60),    -- 10
 (3, date_trunc('month',CURRENT_DATE - INTERVAL '1 month')::date, 30, 45);   -- 15

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v NUMERIC;
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Units must be non-negative';
    END IF;
    IF p_units <= 10 THEN
        v := p_units * 5;
    ELSE
        v := 10*5 + (p_units-10)*8;
    END IF;
    RETURN ROUND(v, 2);
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_units NUMERIC; v_charge NUMERIC;
BEGIN
    SELECT current_reading - previous_reading INTO v_units
      FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading %', p_reading_id; END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    v_charge := fn_water_charge(v_units);
    INSERT INTO bills(reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_readings_check() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading % below previous_reading %',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_readings_biu
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_readings_check();

-- Generate bills for seed data
SELECT pr_generate_bill(reading_id, CURRENT_DATE + 15) FROM readings;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, (b.charge - b.amount_paid) AS outstanding
  FROM bills b
  JOIN readings r ON r.reading_id = b.reading_id
  JOIN customers c ON c.customer_id = r.customer_id
 WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_bills_due_unpaid
    ON bills (due_on) WHERE amount_paid < charge;

-- EXPLAIN SELECT * FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot(snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid),0)
      FROM bills WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END; $$;

-- SELECT cron.schedule('q7_receivables','30 0 * * *', $$CALL q7.pr_refresh_receivables()$$);