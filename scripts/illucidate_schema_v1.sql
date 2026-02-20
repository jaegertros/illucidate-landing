-- =============================================================================
-- Illucidate Database Schema v1.0
-- PostgreSQL / Supabase
-- Author: Caleb L. Waddell — Purdue University Food Science
-- =============================================================================
-- Run this in the Supabase SQL Editor (Project → SQL Editor → New query)
-- Tables are created in dependency order — do not reorder.
-- =============================================================================


-- =============================================================================
-- ENUMS
-- =============================================================================

CREATE TYPE perturbation_type AS ENUM (
    'phage',
    'antibiotic',
    'chemical',
    'environmental',
    'genetic'
);

CREATE TYPE perturbation_role AS ENUM (
    'baseline',    -- e.g. lysogen: phage is already integrated, no dose
    'treatment',   -- e.g. phage added at known PFU
    'induction'    -- e.g. UV-C or Mitomycin C to trigger prophage
);


-- =============================================================================
-- 1. BIOLOGICAL SYSTEM
-- What organism exists before anything is done to it.
-- Lysogeny does NOT belong here — it is a perturbation.
-- =============================================================================

CREATE TABLE biological_system (
    system_id       SERIAL PRIMARY KEY,

    -- Taxonomy (plain text + optional NCBI anchor)
    genus           TEXT NOT NULL,
    species         TEXT NOT NULL,
    serotype        TEXT,                   -- e.g. 'O157:H7'  (nullable)
    strain          TEXT,                   -- e.g. 'C7927'    (nullable)
    ncbi_taxid      INTEGER,               -- e.g. 83334 for E. coli O157:H7
                                            -- look up at: https://www.ncbi.nlm.nih.gov/taxonomy

    baseline_notes  TEXT,                   -- anything that doesn't fit above

    -- Prevent silent duplicates
    UNIQUE (genus, species, serotype, strain)
);

COMMENT ON TABLE biological_system IS
    'The host organism in its unperturbed state. Lysogeny is recorded in experiment_perturbation.';
COMMENT ON COLUMN biological_system.ncbi_taxid IS
    'NCBI Taxonomy ID. Look up at https://www.ncbi.nlm.nih.gov/taxonomy. '
    'Enables cross-lab organism matching independent of text formatting.';


-- =============================================================================
-- 2. PERTURBATION
-- Anything applied to the biological system. Generic and extensible.
-- The same phage, antibiotic, or chemical can appear across many experiments.
-- =============================================================================

CREATE TABLE perturbation (
    perturbation_id SERIAL PRIMARY KEY,

    type            perturbation_type NOT NULL,
    name            TEXT NOT NULL,          -- e.g. 'ΦV10::nLuc', 'NaCl', 'UV-C'
    description     TEXT,                   -- optional long-form detail

    UNIQUE (type, name)
);

COMMENT ON TABLE perturbation IS
    'A reusable catalog of things that can be applied to a biological system. '
    'Phage is one entry type among many.';


-- =============================================================================
-- 3. INSTRUMENT
-- The plate reader or device that collected the data.
-- =============================================================================

CREATE TABLE instrument (
    instrument_id   SERIAL PRIMARY KEY,

    make            TEXT NOT NULL,          -- e.g. 'PerkinElmer'
    model           TEXT NOT NULL,          -- e.g. 'Victor Nivo'
    location        TEXT,                   -- e.g. 'Purdue Food Science 3B'
    serial_number   TEXT,

    UNIQUE (make, model, serial_number)
);

COMMENT ON TABLE instrument IS
    'The physical device used to collect measurements. '
    'Instrument differences can affect baseline readings — important for cross-lab comparison.';


-- =============================================================================
-- 4. MEASUREMENT TYPE
-- What was measured and in what unit.
-- =============================================================================

CREATE TABLE measurement_type (
    measurement_type_id SERIAL PRIMARY KEY,

    name            TEXT NOT NULL,          -- e.g. 'OD600', 'Luminescence', 'Temperature'
    unit            TEXT NOT NULL,          -- e.g. 'AU', 'RLU', 'CFU/mL', '°C'
    description     TEXT,

    UNIQUE (name, unit)
);

COMMENT ON COLUMN measurement_type.unit IS
    'The literal unit of the value stored in measurement.value. '
    'Examples: AU (absorbance units), RLU (relative light units), CFU/mL, °C.';


-- =============================================================================
-- 5. EXPERIMENT
-- One biological context, one plate run, one file upload.
-- Intentionally simple — everything interesting attaches below.
-- =============================================================================

CREATE TABLE experiment (
    experiment_id   SERIAL PRIMARY KEY,

    system_id       INTEGER NOT NULL
                        REFERENCES biological_system(system_id)
                        ON DELETE RESTRICT,

    instrument_id   INTEGER
                        REFERENCES instrument(instrument_id)
                        ON DELETE SET NULL,

    -- Identity
    title           TEXT,
    description     TEXT,

    -- Provenance
    performed_at    TIMESTAMP WITH TIME ZONE,
    operator        TEXT,                   -- person who ran the experiment
    lab             TEXT,                   -- e.g. 'Purdue Bhatt Lab'
    institution     TEXT,

    -- Sharing
    -- user_id      UUID REFERENCES auth.users(id),   -- uncomment when Supabase Auth enabled
    is_public       BOOLEAN NOT NULL DEFAULT false,

    -- File storage (Supabase Storage bucket paths)
    raw_file_path   TEXT,                   -- e.g. 'experiments/42/raw.xlsx'
    processed_json_path TEXT,              -- e.g. 'experiments/42/dataset.json'

    created_at      TIMESTAMP WITH TIME ZONE DEFAULT now()
);

COMMENT ON TABLE experiment IS
    'One experimental run. One biological system, one plate, one file. '
    'Set is_public = true to share with the community.';
COMMENT ON COLUMN experiment.processed_json_path IS
    'Path in Supabase Storage to the parsed JSON file that illucidate.js loads directly. '
    'Format matches demo-dataset.json in the web app.';


-- =============================================================================
-- 6. EXPERIMENT PERTURBATION  ← the heart of the model
-- Records every intervention applied during this experiment.
-- One row per perturbation-role combination.
-- =============================================================================

CREATE TABLE experiment_perturbation (
    experiment_perturbation_id  SERIAL PRIMARY KEY,

    experiment_id   INTEGER NOT NULL
                        REFERENCES experiment(experiment_id)
                        ON DELETE CASCADE,

    perturbation_id INTEGER NOT NULL
                        REFERENCES perturbation(perturbation_id)
                        ON DELETE RESTRICT,

    role            perturbation_role NOT NULL,

    -- Quantification (all optional — fill what applies)
    quantity_value  DOUBLE PRECISION,       -- numeric amount
    quantity_unit   TEXT,                   -- 'PFU', 'mM', 'MOI', 'J/m²'
    volume_ul       DOUBLE PRECISION,       -- volume added in µL
    timepoint_min   DOUBLE PRECISION,       -- when it was applied (minutes into run)

    notes           TEXT
);

COMMENT ON TABLE experiment_perturbation IS
    'Every intervention applied in this experiment. '
    'Lysogen → role=baseline, quantity=NULL. '
    'Phage dose → role=treatment, quantity_value=1e5, quantity_unit=PFU. '
    'UV induction → role=induction, quantity_value=20, quantity_unit=J/m².';


-- =============================================================================
-- 7. EXPERIMENT CONDITION
-- Static environmental parameters that are NOT the variable being tested.
-- e.g. "ran in TSB at 37°C" — these are background facts, not perturbations.
-- =============================================================================

CREATE TABLE experiment_condition (
    condition_id    SERIAL PRIMARY KEY,

    experiment_id   INTEGER NOT NULL
                        REFERENCES experiment(experiment_id)
                        ON DELETE CASCADE,

    parameter       TEXT NOT NULL,          -- 'Temperature', 'pH', 'Media', 'NaCl'
    value           TEXT NOT NULL           -- '37°C', '7.4', 'TSB', '150 mM'
);

COMMENT ON TABLE experiment_condition IS
    'Static background conditions (not the variable being tested). '
    'If NaCl concentration IS the variable, use experiment_perturbation instead. '
    'If it is just the buffer you always use, record it here.';


-- =============================================================================
-- 8. WELL
-- One well on the plate. Links experimental conditions to measurements.
-- =============================================================================

CREATE TABLE well (
    well_id         SERIAL PRIMARY KEY,

    experiment_id   INTEGER NOT NULL
                        REFERENCES experiment(experiment_id)
                        ON DELETE CASCADE,

    well_position   TEXT NOT NULL,          -- 'A1', 'B4', 'H12'
    group_label     TEXT,                   -- 'Control', 'E. coli 1e5 CFU', 'PBS'
    replicate_number INTEGER,              -- 1, 2, 3

    notes           TEXT,

    UNIQUE (experiment_id, well_position)
);

COMMENT ON TABLE well IS
    'One physical well on the plate. '
    'group_label maps to the group field in the processed JSON the web app consumes.';


-- =============================================================================
-- 9. MEASUREMENT
-- Individual time-series readings. One row per well × timepoint × measurement type.
-- This table will be the largest — use BIGSERIAL.
-- =============================================================================

CREATE TABLE measurement (
    measurement_id      BIGSERIAL PRIMARY KEY,

    well_id             INTEGER NOT NULL
                            REFERENCES well(well_id)
                            ON DELETE CASCADE,

    measurement_type_id INTEGER NOT NULL
                            REFERENCES measurement_type(measurement_type_id)
                            ON DELETE RESTRICT,

    timepoint_min       DOUBLE PRECISION NOT NULL,  -- minutes from start of run
    value               DOUBLE PRECISION NOT NULL
);

COMMENT ON TABLE measurement IS
    'Raw time-series readings. One row per well × timepoint × measurement type. '
    'For a 96-well plate with 2 measurement types and 37 timepoints: 96 × 2 × 37 = 7,104 rows per experiment.';

-- Index for fast queries by experiment (via well join) and time
CREATE INDEX idx_measurement_well     ON measurement (well_id);
CREATE INDEX idx_measurement_type     ON measurement (measurement_type_id);
CREATE INDEX idx_measurement_time     ON measurement (timepoint_min);


-- =============================================================================
-- SEED DATA — measurement types you already use
-- =============================================================================

INSERT INTO measurement_type (name, unit) VALUES
    ('OD600',         'AU'),
    ('OD560',         'AU'),
    ('OD450',         'AU'),
    ('Luminescence',  'RLU'),
    ('Temperature',   '°C');


-- =============================================================================
-- SEED DATA — perturbations from your existing work
-- =============================================================================

INSERT INTO perturbation (type, name, description) VALUES
    ('phage',        'ΦV10::nLuc',    'E. coli O157:H7 phage with NanoLuc reporter'),
    ('phage',        'ΦV10::lux',     'E. coli O157:H7 phage with lux reporter'),
    ('chemical',     'Mitomycin C',   'Prophage inducer — DNA crosslinker'),
    ('environmental','UV-C',          'Prophage inducer — 254nm ultraviolet');


-- =============================================================================
-- EXAMPLE INSERT — your PBS outer experiment
-- =============================================================================

-- 1. Biological system
INSERT INTO biological_system (genus, species, serotype, strain, ncbi_taxid)
VALUES ('Escherichia', 'coli', 'O157:H7', 'C7927', 83334);

-- 2. Instrument
INSERT INTO instrument (make, model, location)
VALUES ('PerkinElmer', 'Victor Nivo', 'Purdue Food Science');

-- 3. Experiment
INSERT INTO experiment (system_id, instrument_id, title, operator, lab, is_public)
VALUES (1, 1, 'PBS outer — OD600 + Luminescence kinetics', 'Caleb Waddell', 'Purdue Food Science', false);

-- 4. Lysogen as baseline perturbation (no quantity — it is already integrated)
INSERT INTO experiment_perturbation (experiment_id, perturbation_id, role)
VALUES (1, 1, 'baseline');

-- 5. Static background conditions
INSERT INTO experiment_condition (experiment_id, parameter, value) VALUES
    (1, 'Media',       'TSB'),
    (1, 'Temperature', '37°C'),
    (1, 'Matrix',      'PBS outer');


-- =============================================================================
-- QUICK SANITY QUERY
-- Run this after seeding to verify foreign keys are wired correctly.
-- =============================================================================

/*
SELECT
    e.title,
    bs.genus || ' ' || bs.species || ' ' || COALESCE(bs.serotype, '') AS organism,
    p.type::TEXT AS perturbation_type,
    p.name AS perturbation_name,
    ep.role::TEXT AS role,
    ep.quantity_value,
    ep.quantity_unit
FROM experiment e
JOIN biological_system bs ON e.system_id = bs.system_id
JOIN experiment_perturbation ep ON ep.experiment_id = e.experiment_id
JOIN perturbation p ON ep.perturbation_id = p.perturbation_id;
*/
