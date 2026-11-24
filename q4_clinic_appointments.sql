CREATE SCHEMA IF NOT EXISTS q4;
SET search_path TO q4, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id  INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time  TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
    status     VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
               CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);
CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INTEGER NOT NULL DEFAULT 0,
    attended_count INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO patients(full_name) VALUES ('P1'),('P2'),('P3');
INSERT INTO doctors(full_name) VALUES ('Dr A'),('Dr B'),('Dr C');

INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1,1,CURRENT_DATE,'09:00','BOOKED'),
 (2,1,CURRENT_DATE,'10:00','BOOKED'),
 (3,2,CURRENT_DATE,'09:00','BOOKED'),
 (1,2,CURRENT_DATE,'11:00','CANCELLED'),
 (2,3,CURRENT_DATE,'09:00','ATTENDED'),
 (3,3,CURRENT_DATE,'12:00','BOOKED');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor %', p_doctor_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM appointments
     WHERE doctor_id = p_doctor_id AND appointment_day = p_day
       AND status <> 'CANCELLED';
    RETURN v_count;
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor %', p_doctor_id;
    END IF;
    IF p_day < CURRENT_DATE THEN RAISE EXCEPTION 'Cannot book in the past'; END IF;
    IF p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot %', p_slot;
    END IF;
    INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
    -- clash prevention enforced by trigger below
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_appt_clash() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'CANCELLED' THEN RETURN NEW; END IF;
    IF EXISTS (
        SELECT 1 FROM appointments
         WHERE doctor_id = NEW.doctor_id
           AND appointment_day = NEW.appointment_day
           AND slot_time = NEW.slot_time
           AND status <> 'CANCELLED'
           AND appointment_id <> COALESCE(NEW.appointment_id, -1)
    ) THEN
        RAISE EXCEPTION 'Slot % on % for doctor % already booked',
            NEW.slot_time, NEW.appointment_day, NEW.doctor_id;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appt_clash_biu
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appt_clash();

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient, d.full_name AS doctor, a.slot_time
  FROM appointments a
  JOIN patients p ON p.patient_id = a.patient_id
  JOIN doctors  d ON d.doctor_id  = a.doctor_id
 WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

-- EXPLAIN SELECT * FROM appointments
--   WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status='BOOKED'),
           COUNT(*) FILTER (WHERE status='ATTENDED'),
           COUNT(*) FILTER (WHERE status='CANCELLED')
      FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
      SET booked_count    = EXCLUDED.booked_count,
          attended_count  = EXCLUDED.attended_count,
          cancelled_count = EXCLUDED.cancelled_count;
END; $$;

-- SELECT cron.schedule('q4_summary','0 1 * * *',
--   $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);