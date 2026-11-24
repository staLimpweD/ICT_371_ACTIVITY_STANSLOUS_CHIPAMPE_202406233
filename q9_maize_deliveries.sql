CREATE SCHEMA IF NOT EXISTS q9;
SET search_path TO q9, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE farmers (
    farmer_id SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id SERIAL PRIMARY KEY,
    farmer_id INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg NUMERIC(12,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate NUMERIC(10,2) NOT NULL,
    total_value NUMERIC(14,2) NOT NULL,
    delivered_on DATE NOT NULL DEFAULT CURRENT_DATE,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_value  NUMERIC(16,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers(farmer_number, full_name) VALUES
 ('F1','Farmer One'),('F2','Farmer Two'),('F3','Farmer Three');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
BEGIN
    IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
        RAISE EXCEPTION 'Unsupported grade %', p_grade;
    END IF;
    RETURN CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 ELSE 3.00 END;
END; $$;

-- (d) Trigger (install BEFORE loading seed deliveries) ----------------------
CREATE OR REPLACE FUNCTION trg_deliveries_price() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'weight_kg must be positive';
    END IF;
    NEW.unit_rate  := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_deliveries_biu
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_deliveries_price();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'weight must be positive';
    END IF;
    INSERT INTO deliveries(farmer_id, grade, weight_kg,
                           unit_rate, total_value, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, 0, 0,
            COALESCE(p_date, CURRENT_DATE), FALSE);
END; $$;

-- Six deliveries through procedure (trigger fills pricing)
CALL pr_receive_delivery(1,'A', 100, CURRENT_DATE-2);
CALL pr_receive_delivery(1,'B', 50,  CURRENT_DATE-1);
CALL pr_receive_delivery(2,'C', 80,  CURRENT_DATE-1);
CALL pr_receive_delivery(2,'A', 30,  CURRENT_DATE);
CALL pr_receive_delivery(3,'B', 120, CURRENT_DATE);
CALL pr_receive_delivery(3,'C', 60,  CURRENT_DATE);
-- mark some paid
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1,4);

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
  FROM farmers f
  LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
 GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

-- EXPLAIN SELECT * FROM deliveries WHERE farmer_id = 1
--   AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases(purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg),0), COALESCE(SUM(total_value),0)
      FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
      SET total_weight = EXCLUDED.total_weight,
          total_value  = EXCLUDED.total_value;
END; $$;

-- SELECT cron.schedule('q9_purchases','30 1 * * *',
--   $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$);