CREATE SCHEMA IF NOT EXISTS q6;
SET search_path TO q6, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
    payroll_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL CHECK (pay_month = date_trunc('month', pay_month)::date),
    gross_pay NUMERIC(12,2) NOT NULL,
    net_pay   NUMERIC(12,2) NOT NULL,
    UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2),
    new_salary NUMERIC(12,2),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
 ('E1', 5000, 500, 300, TRUE),
 ('E2', 7000, 700, 500, TRUE),
 ('E3', 4000, 400, 200, FALSE);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
      FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee %', p_employee_id; END IF;
    IF v_net < 0 THEN RAISE EXCEPTION 'Negative net pay for %', p_employee_id; END IF;
    RETURN v_net;
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_gross NUMERIC; v_net NUMERIC;
BEGIN
    IF p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be first day of a month';
    END IF;
    FOR r IN SELECT * FROM employees WHERE active LOOP
        -- Fail fast: invalid employee aborts the whole transaction
        v_gross := r.basic_salary + r.allowance;
        v_net   := fn_net_pay(r.employee_id);
        INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END; $$;

-- Seed two months
CALL pr_process_payroll(date_trunc('month', CURRENT_DATE - INTERVAL '2 month')::date);
CALL pr_process_payroll(date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date);

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_emp_salary_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit(employee_id, old_salary, new_salary)
        VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_emp_after_update
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_emp_salary_audit();

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
  FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_payroll_month ON payroll (pay_month);

-- (g) Scheduled job --------------------------------------------------------
-- pg_cron: 02:00 on 1st of every month, previous month start
-- SELECT cron.schedule('q6_payroll','0 2 1 * *',
--   $$CALL q6.pr_process_payroll(
--       date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date)$$);

-- Inspect jobs / history:
-- SELECT * FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;