CREATE SCHEMA IF NOT EXISTS q5;
SET search_path TO q5, public;

-- (a) Database and seed data ------------------------------------------------
CREATE TABLE students (
    student_id    SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL DEFAULT CURRENT_DATE,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
    CONSTRAINT chk_release CHECK (
        (status='ACTIVE' AND released_on IS NULL) OR
        (status='ENDED'  AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students(student_number, full_name) VALUES
 ('S1','S1'),('S2','S2'),('S3','S3');
INSERT INTO rooms(room_number, capacity) VALUES ('R1',2),('R2',3),('R3',1);

INSERT INTO allocations(student_id, room_id, allocated_on, status) VALUES
 (1,1,CURRENT_DATE-30,'ACTIVE'),
 (2,1,CURRENT_DATE-20,'ACTIVE'),   -- R1 full
 (3,2,CURRENT_DATE-10,'ACTIVE'),   -- R2 partly occupied
 (1,3,CURRENT_DATE-60,'ENDED');    -- ended does not consume a bed
UPDATE allocations SET released_on = CURRENT_DATE - 15 WHERE allocation_id = 4;

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_used INT;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room %', p_room_id; END IF;
    SELECT COUNT(*) INTO v_used FROM allocations
     WHERE room_id = p_room_id AND status = 'ACTIVE';
    RETURN v_cap - v_used;
END; $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student %', p_student_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        RAISE EXCEPTION 'Unknown room %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
                WHERE student_id = p_student_id AND status='ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations(student_id, room_id, allocated_on, status)
    VALUES (p_student_id, p_room_id, COALESCE(p_allocated_on, CURRENT_DATE), 'ACTIVE');
END; $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_alloc_check() RETURNS TRIGGER AS $$
DECLARE v_cap INT; v_active INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id;
        SELECT COUNT(*) INTO v_active FROM allocations
         WHERE room_id = NEW.room_id
           AND status='ACTIVE'
           AND allocation_id <> COALESCE(NEW.allocation_id, -1);
        IF v_active + 1 > v_cap THEN
            RAISE EXCEPTION 'Room % capacity % exceeded', NEW.room_id, v_cap;
        END IF;

        IF EXISTS (SELECT 1 FROM allocations
                    WHERE student_id = NEW.student_id
                      AND status='ACTIVE'
                      AND allocation_id <> COALESCE(NEW.allocation_id, -1)) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;
    END IF;
    RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_alloc_biu
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_alloc_check();

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_number, r.capacity,
       COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE') AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE') AS free_beds
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id
 GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Index ----------------------------------------------------------------
CREATE INDEX idx_alloc_active_room
    ON allocations (room_id) WHERE status = 'ACTIVE';

-- EXPLAIN SELECT COUNT(*) FROM allocations WHERE room_id = 1 AND status='ACTIVE';

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, r.room_id,
           COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE'),
           r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status='ACTIVE')
      FROM rooms r LEFT JOIN allocations a ON a.room_id = r.room_id
     GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
      SET occupied_beds = EXCLUDED.occupied_beds,
          free_beds     = EXCLUDED.free_beds;
END; $$;

-- SELECT cron.schedule('q5_occupancy','55 23 * * *', $$CALL q5.pr_refresh_occupancy()$$);