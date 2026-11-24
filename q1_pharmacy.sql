CREATE SCHEMA IF NOT EXISTS q1;
SET search_path TO q1, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(12,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 100),
 ('Amoxicillin 250mg', 8.00,  50),
 ('Ibuprofen 400mg',   3.75,   8);   -- low stock for view test

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(12,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive integer';
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;
    RETURN v_price * p_quantity;
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(12,2); v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;
    -- lock the medicine row to prevent overselling under concurrency
    SELECT unit_price, stock_qty INTO v_price, v_stock
      FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine %', p_medicine_id; END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: available %, requested %', v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, COALESCE(p_sold_on, CURRENT_DATE));

    UPDATE medicines SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
    -- If any statement fails, the whole procedure rolls back (single transaction),
    -- so sales and medicines remain unchanged.
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_medicines_stock_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit(medicine_id, old_qty, new_qty)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_medicines_after_update
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_medicines_stock_audit();

-- Seed the six valid sales via the procedure
CALL pr_record_sale(1, 5,  CURRENT_DATE - 1);
CALL pr_record_sale(1, 3,  CURRENT_DATE);
CALL pr_record_sale(2, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 2,  CURRENT_DATE);
CALL pr_record_sale(3, 2,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 1,  CURRENT_DATE);

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
  FROM medicines
 WHERE stock_qty < 10;

-- Query after a sale:
-- CALL pr_record_sale(3, 1, CURRENT_DATE);
-- SELECT * FROM v_low_stock;

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);

-- Justification: queries filter one medicine within a date range; a composite
-- (medicine_id, sold_on) index lets Postgres seek by medicine_id then range-scan
-- sold_on. EXPLAIN:
-- EXPLAIN SELECT * FROM sales WHERE medicine_id = 1
--   AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales(sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity),0), COALESCE(SUM(quantity*unit_price),0)
      FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
      SET total_qty = EXCLUDED.total_qty,
          total_amount = EXCLUDED.total_amount;
END; $$;

-- schedule (pg_cron): daily 00:15 for previous day
-- SELECT cron.schedule('q1_daily_sales','15 0 * * *',
--   $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$);