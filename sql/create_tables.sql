
DROP TABLE IF EXISTS anomalies;
DROP TABLE IF EXISTS model_predictions;
DROP TABLE IF EXISTS demand_readings;
DROP TABLE IF EXISTS weather_hourly;
DROP TABLE IF EXISTS calendar_info;
DROP TABLE IF EXISTS time_periods;


-- DIMENSION: time_periods
--------------------------------------------------------------
-- Maps a settlement period number to a readable time of day.
-- 48 rows for a normal day (by 30 minutes)
-- 2 clock change days a year:
--      * Last Sunday in March (clock forward) -> 46 periods
--      * Last Sunday in October (clock back) -> 50 periods

CREATE TABLE time_periods(
    settlement_period   INTEGER PRIMARY KEY
                        CHECK (settlement_period BETWEEN 1 AND 50),

    hour                INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23),
    minute              INTEGER NOT NULL CHECK (minute IN (0,30)),

    time_label          TEXT    NOT NULL,

    hour_decimal        REAL    NOT NULL,
    period_of_day       TEXT    NOT NULL
                        CHECK(period_of_day IN ('Night', 'Morning', 'Afternoon','Evening')),



    -- Peak flag
    is_peak             INTEGER NOT NULL CHECK (is_peak IN (0,1)),

    -- 1 for periods 49-50, which only appear on the October clock-change day
    is_clock_change_only  INTEGER NOT NULL DEFAULT 0 CHECK (is_clock_change_only IN (0,1))

);


-- DIMENSION: calendar_info
--------------------------------------------------------------------
CREATE TABLE calendar_info (
    calendar_date       TEXT PRIMARY KEY,

    year                INTEGER NOT NULL,
    month               INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    month_name          TEXT NOT NULL,
    day_of_month        INTEGER NOT NULL,
    day_of_year         INTEGER NOT NULL,

    -- 0=Monday...6=Sunday
    day_of_week         INTEGER NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    day_name            TEXT NOT NULL,

    -- Meteorological seasons (Dec-Feb winter etc.)
    season              TEXT NOT NULL
                        CHECK (season in('Winter', 'Spring','Summer','Autumn')),

    is_weekend          INTEGER NOT NULL CHECK (is_weekend IN (0,1)),
    is_bank_holiday     INTEGER NOT NULL CHECK (is_bank_holiday IN (0,1)),
    bank_holiday_name   TEXT, --NULL when not a bank holiday
    is_school_holiday   INTEGER NOT NULL CHECK (is_school_holiday IN (0,1)),

    --Flagging a normal working day
    is_working_day      INTEGER NOT NULL CHECK (is_working_day IN (0,1)),

    -- 1 on the two clock change days per year
    is_clock_change_day INTEGER NOT NULL DEFAULT 0 CHECK (is_clock_change_day IN (0,1))

);


-- DIMENSION: wetaher_hourly
--------------------------------------------------------------------------------
CREATE TABLE weather_hourly (
    weather_date        TEXT    NOT NULL,
    hour                INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23),

    -- temperature_2m, degrees C
    temperature_c       REAL,
    wind_speed          REAL,
    humidity_pct        REAL,
    precipitation_mm    REAL,
    cloud_cover_pct     REAL,
    solar_radiation     REAL,

    PRIMARY KEY (weather_date, hour)

);



-- FACT: demand readings
---------------------------------------------------------------
CREATE TABLE demand_readings (
    settlement_date         TEXT    NOT NULL,
    settlement_period       INTEGER NOT NULL CHECK (settlement_period BETWEEN 1 AND 50),

    --Target variable: Transmission system demand, MW
    tsd_mw                  REAL,

    --Alternative demand measures 
    nd_mw                   REAL,
    england_wales_demand_mw REAL,

    embedded_wind_mw        REAL,
    embedded_solar_mw       REAL,

    pump_storage_mw         REAL,

    PRIMARY KEY (settlement_date, settlement_period),

    FOREIGN KEY (settlement_date)   REFERENCES calendar_info (calendar_date),
    FOREIGN KEY (settlement_period) REFERENCES time_periods (settlement_period)

);








-- OUTPUT: model_predictions
---------------------------------------------------------------
CREATE TABLE model_predictions (
    settlement_date     TEXT    NOT NULL,
    settlement_period   INTEGER NOT NULL,
    model_name          TEXT    NOT NULL,
    predicted_demand_mw REAL,

--Storing the split label
    data_split          TEXT CHECK (data_split IN ( 'train', 'validation', 'test')),

    created_at          TEXT DEFAULT (datetime('now')),

    PRIMARY KEY (settlement_date, settlement_period, model_name),
    FOREIGN KEY (settlement_date, settlement_period)
        REFERENCES demand_readings (settlement_date, settlement_period)

);


-- OUTPUT: anomalies
---------------------------------------------------------------
--One row per flagged period per detection method

CREATE TABLE anomalies (
    settlement_date     TEXT    NOT NULL,
    settlement_period   INTEGER NOT NULL,
    method              TEXT    NOT NULL,

    actual_demand_mw    REAL,
    expected_demand_mw  REAL,
    residual_mw         REAL,
    anomaly_score       REAL,
    is_anomaly          INTEGER CHECK (is_anomaly IN (0,1)),
    created_at          TEXT DEFAULT (datetime('now')),

    PRIMARY KEY (settlement_date, settlement_period, method),
    FOREIGN KEY (settlement_date, settlement_period)
        REFERENCES demand_readings (settlement_date, settlement_period)

);


-- INDEXES
CREATE INDEX idx_predictions_model ON model_predictions (model_name);
CREATE INDEX idx_anomalies_method ON anomalies (method);
CREATE INDEX idx_calendar_season ON calendar_info (season, is_working_day);





