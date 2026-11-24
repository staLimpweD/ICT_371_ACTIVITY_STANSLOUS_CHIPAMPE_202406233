CREATE SCHEMA IF NOT EXISTS q10;
SET search_path TO q10, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on DATE NOT NULL DEFAULT CURRENT_DATE,
    status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
           CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(10),
    new_status VARCHAR(10),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO students(student_number, full_name) VALUES
 ('SN1','S One'),('SN2','S Two'),('SN3','S Three');

INSERT INTO applications(student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
 (1, 20, 2500, 75, CURRENT_DATE-10),  -- qualifies
 (1, 18, 3000, 70, CURRENT_DATE-9),   -- boundary qualifies
 (2, 17, 2000, 80, CURRENT_DATE-8),   -- age too low
 (2, 26, 2000, 80, CURRENT_DATE-7),   -- age too high
 (3, 22, 3500, 75, CURRENT_DATE-6),   -- income too high
 (3, 23, 2500, 65, CURRENT_DATE-5);   -- mark too low

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL';
    END IF;
    IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive'; END IF;
    IF p_income < 0 THEN RAISE EXCEPTION 'Income cannot be negative'; END IF;
    IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark out of range'; END IF;
    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_eligible BOOLEAN;
BEGIN
    SELECT * INTO r FROM applications
     WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown application %', p_application_id; END IF;
    IF r.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % already assessed (%)', p_application_id, r.status;
    END IF;
    v_eligible := fn_scholarship_eligible(r.age_at_application, r.monthly_income, r.average_mark);
    UPDATE applications
       SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_app_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit(application_id, old_status, new_status)
        VALUES (OLD.application_id, OLD.status, NEW.status);
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_app_after_update
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_app_audit();

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
  FROM applications a JOIN students s ON s.student_id = a.student_id
 WHERE a.status = 'APPROVED';

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_applications_status_submitted
    ON applications (status, submitted_on);

-- EXPLAIN SELECT * FROM applications WHERE status='PENDING'
--   AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications WHERE status = 'PENDING' LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END; $$;

-- SELECT cron.schedule('q10_assess','0 8 * * 1', $$CALL q10.pr_assess_pending()$$);