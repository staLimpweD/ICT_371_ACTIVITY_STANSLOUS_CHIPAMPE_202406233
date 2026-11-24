CREATE SCHEMA IF NOT EXISTS q2;
SET search_path TO q2, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE students (
    student_id    SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name     VARCHAR(100) NOT NULL,
    fee_due       NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id  SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0,
    total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
 ('STU001','Alice Banda', 5000.00),
 ('STU002','Bob Phiri',   3000.00),
 ('STU003','Carol Mwale', 2000.00);   -- no payments

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_due FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student %', p_student_id; END IF;
    SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payments
     WHERE student_id = p_student_id;
    RETURN v_due - v_paid;
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive';
    END IF;
    v_balance := fn_fee_balance(p_student_id);   -- raises on unknown student
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;
    INSERT INTO payments(student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_payments_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit(payment_id, student_id, amount)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount);
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payments_audit();

-- Seed six payments via procedure (audit rows come only from the trigger)
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  800.00, CURRENT_DATE);
CALL pr_receive_payment(2,  200.00, CURRENT_DATE);

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(p.total,0) AS outstanding
  FROM students s
  LEFT JOIN (SELECT student_id, SUM(amount) total FROM payments GROUP BY student_id) p
    ON p.student_id = s.student_id
 WHERE s.fee_due - COALESCE(p.total,0) > 0;

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_payments_student_paidon
    ON payments (student_id, paid_on);

-- Justification: composite index serves queries filtering a student and a
-- date range. EXPLAIN:
-- EXPLAIN SELECT * FROM payments WHERE student_id = 1
--   AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections(collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount),0)
      FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
      SET payment_count = EXCLUDED.payment_count,
          total_amount  = EXCLUDED.total_amount;
END; $$;

-- SELECT cron.schedule('q2_daily_collections','0 1 * * *',
--   $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$);