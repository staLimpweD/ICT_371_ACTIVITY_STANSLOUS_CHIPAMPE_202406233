CREATE SCHEMA IF NOT EXISTS q3;
SET search_path TO q3, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id      SERIAL PRIMARY KEY,
    book_id      INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on  DATE NOT NULL,
    due_on       DATE NOT NULL,
    returned_on  DATE NULL,
    fine_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id    SERIAL PRIMARY KEY,
    loan_id     INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine    NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO books(title) VALUES ('Database Systems'), ('Algorithms'), ('Networks');

INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
 (1,'A. Mwansa', CURRENT_DATE-20, CURRENT_DATE-6, NULL, 0),        -- open overdue
 (2,'B. Zulu',   CURRENT_DATE-10, CURRENT_DATE-1, NULL, 0),        -- open overdue
 (3,'C. Tembo',  CURRENT_DATE-5,  CURRENT_DATE+5, NULL, 0),        -- open, not due
 (1,'D. Chanda', CURRENT_DATE-15, CURRENT_DATE-5, CURRENT_DATE-5, 0),  -- on time
 (2,'E. Lungu',  CURRENT_DATE-30, CURRENT_DATE-20, CURRENT_DATE-10, 20), -- returned late
 (3,'F. Nkosi',  CURRENT_DATE-3,  CURRENT_DATE+7, NULL, 0);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_return DATE; v_end DATE; v_days INT;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_return FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan %', p_loan_id; END IF;

    -- Use earlier of as-of and returned_on
    v_end := LEAST(p_as_of, COALESCE(v_return, p_as_of));

    v_days := GREATEST(v_end - v_due, 0);
    RETURN v_days * 2.00;
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrow DATE; v_return DATE; v_fine NUMERIC(12,2);
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrow, v_return
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan %', p_loan_id; END IF;
    IF v_return IS NOT NULL THEN RAISE EXCEPTION 'Loan % already returned', p_loan_id; END IF;
    IF p_returned_on < v_borrow THEN
        RAISE EXCEPTION 'Return date % is before borrowed_on %', p_returned_on, v_borrow;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
     WHERE loan_id = p_loan_id;
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_loans_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loans_after_update
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loans_audit();

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
  FROM loans l JOIN books b ON b.book_id = l.book_id
 WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_loans_book_returned
    ON loans (book_id, returned_on);

-- Justification: unreturned loans for a book = book_id filter with returned_on IS NULL.
-- EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)),0)
      FROM loans
     WHERE returned_on IS NULL AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
      SET overdue_count = EXCLUDED.overdue_count,
          total_fine    = EXCLUDED.total_fine;
END; $$;

-- SELECT cron.schedule('q3_overdue','10 0 * * *',
--   $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$);