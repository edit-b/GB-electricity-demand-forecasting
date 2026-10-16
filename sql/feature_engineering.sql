
DROP VIEW IF EXISTS model_features;

CREATE VIEW model_features AS

WITH


-- CTE 1: calendar_extras
---------------------------------------------------------------

--"Days since the last bank holiday" and "days until the next one".

calendar_extras AS (
    SELECT
        c.calendar_date,

        CAST(
            julianday(c.calendar_date) - julianday((
                SELECT MAX(b.calendar_date)
                FROM calendar_info b   
                WHERE b.is_bank_holiday=1
                    AND b.calendar_date <= c.calendar_date
            ))
        AS INTEGER) AS days_since_bank_holiday,

        CAST(
            julianday((
                SELECT MIN(b.calendar_date)
                FROM calendar_info b  
                WHERE b.is_bank_holiday=1
                    AND b.calendar_date >= c.calendar_date
            )) - julianday(c.calendar_date)
        AS INTEGER) AS days_to_bank_holiday

    FROM calendar_info c   
),



-- CTE 2: base
---------------------------------------------------------------------------
-- Stitching the star schema back into one wide row per half-hourly reading.

base AS (
    SELECT
        -------Keys-------------------------
        d.settlement_date,
        d.settlement_period,

        -------Target-----------------------
        d.tsd_mw,

        -----Other demand measures----------
        d.nd_mw,
        d.embedded_wind_mw,
        d.embedded_solar_mw,
        d.pump_storage_mw,

        ---Time of day features-------------
        t.hour,
        t.hour_decimal,
        t.time_label,
        t.period_of_day,
        t.is_peak,

        -----Calendar features--------------
        c.year,
        c.month,
        c.day_of_week,
        c.day_name,
        c.day_of_year,
        c.season,
        c.is_weekend,
        c.is_bank_holiday,
        c.is_school_holiday,
        c.is_working_day,
        c.is_clock_change_day,

        ce.days_since_bank_holiday,
        ce.days_to_bank_holiday,

        ----Weather--------------------------
        w.temperature_c,
        w.wind_speed,
        w.humidity_pct,
        w.precipitation_mm,
        w.cloud_cover_pct,
        w.solar_radiation

    FROM demand_readings d   

    JOIN calendar_info c ON d.settlement_date = c.calendar_date
    JOIN time_periods  t ON d.settlement_period = t.settlement_period
    JOIN calendar_extras ce ON d.settlement_date = ce.calendar_date

    LEFT JOIN weather_hourly w  
            ON w.weather_date=d.settlement_date
            AND w.hour = t.hour

    -- Dropping periods 49-50 to avoid misleading lag values
    WHERE t.is_clock_change_only=0
),





    -- CTE 3: with_lags
    ------------------------------------------------------------
    -- Using ROWS BETWEEN 7 PRECEDING AND 1 instead of 6 PRECDING AND CURRENT ROW.
    -- In that case, the average would contain the value we're trying to predict 
    -- --> target leakage

    with_lags AS (
    SELECT
        base.*,

        -- ---- Demand lags: same time of day, N CALENDAR days ago ----------
        -- Note this uses a RANGE frame, not LAG(). See the long note above.
        MAX(tsd_mw) OVER (w RANGE BETWEEN  1 PRECEDING AND  1 PRECEDING) AS demand_lag_1d,
        MAX(tsd_mw) OVER (w RANGE BETWEEN  2 PRECEDING AND  2 PRECEDING) AS demand_lag_2d,
        MAX(tsd_mw) OVER (w RANGE BETWEEN  7 PRECEDING AND  7 PRECEDING) AS demand_lag_7d,
        MAX(tsd_mw) OVER (w RANGE BETWEEN 14 PRECEDING AND 14 PRECEDING) AS demand_lag_14d,

        -- ---- Rolling stats over the last 7 / 28 days (today EXCLUDED) ----
        AVG(tsd_mw) OVER (w RANGE BETWEEN  7 PRECEDING AND 1 PRECEDING) AS demand_roll_7d_avg,
        AVG(tsd_mw) OVER (w RANGE BETWEEN 28 PRECEDING AND 1 PRECEDING) AS demand_roll_28d_avg,
        MIN(tsd_mw) OVER (w RANGE BETWEEN  7 PRECEDING AND 1 PRECEDING) AS demand_roll_7d_min,
        MAX(tsd_mw) OVER (w RANGE BETWEEN  7 PRECEDING AND 1 PRECEDING) AS demand_roll_7d_max,

        -- ---- Weather lags ------------------------------------------------
        MAX(temperature_c) OVER (w RANGE BETWEEN 1 PRECEDING AND 1 PRECEDING) AS temperature_lag_1d,
        AVG(temperature_c) OVER (w RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING) AS temperature_roll_3d_avg

    FROM base
    -- One named window, reused by every function above via "OVER (w RANGE ...)".
    -- ORDER BY julianday() converts the date to a number, which is what makes
    -- RANGE arithmetic possible.
    WINDOW w AS (PARTITION BY settlement_period ORDER BY julianday(settlement_date))
)




-- FINAL SELECT
-------------------------------------------------------------------
--Arithmetic features that need the lag columns to already exists,
-- plus the final column ordering
SELECT  

    -------------- KEYS -----------------------------------------
    settlement_date,
    settlement_period,
    time_label,

    -------------- TARGET ---------------------------------------
    tsd_mw,

    -------------- TIME OF DAY ----------------------------------
    hour,
    hour_decimal,
    period_of_day,
    is_peak,

    -------------- CALENDAR -------------------------------------
    year,
    month,
    day_of_week,
    day_name,
    day_of_year,
    season,
    is_weekend,
    is_bank_holiday,
    is_school_holiday,
    is_working_day,
    is_clock_change_day,
    days_since_bank_holiday,
    days_to_bank_holiday,


    -------------- INTERACTIONS ------------------------------------
    -- A single integer identifying which slot of the week is this. 
    --- (Monday 00:00 is 1, Sunday 23:30 is 336)

    (day_of_week *48) + settlement_period AS week_slot,

    -- Flagging working_day evening (when eak is the highest)
    CASE WHEN is_working_day=1 AND is_peak=1 THEN 1 ELSE 0 END AS is_working_peak,


    -------------Weather ------------------------------------------
    temperature_c,
    temperature_lag_1d,
    temperature_roll_3d_avg,
    wind_speed,
    humidity_pct,
    precipitation_mm,
    cloud_cover_pct,
    solar_radiation,


    ------------ Degree days ---------------------------------------
    --- Splitting temperatures into 2 one sided variables (as the relationship
    --- between demand and temperature is not linear. Demand rises as it gets colder 
    --- (heating) and as it gets hotter (cooling).
    CASE WHEN temperature_c < 15.5 THEN 15.5 - temperature_c ELSE 0 END AS heating_degrees,
    CASE WHEN temperature_c > 22.0 THEN temperature_c - 22.0 ELSE 0 END AS cooling_degrees,



    ----------- Lags & Rolling ---------------------------------------
    demand_lag_1d,
    demand_lag_2d,
    demand_lag_7d,
    demand_lag_14d,
    demand_roll_7d_avg,
    demand_roll_28d_avg,
    demand_roll_7d_min,
    demand_roll_7d_max,

    -- The spread of the last week at this slot. A wide range means this
    -- slot has been volatile recently (for the anomalies)
    demand_roll_7d_max - demand_roll_7d_min AS demand_roll_7d_range,

    -- How far yesterday sat above or below the recent norm for this slot
    demand_lag_1d - demand_roll_7d_avg AS demand_lag_1d_vs_avg,

    -- Wek-on-week change at this slot: trend signal
    demand_lag_1d - demand_lag_7d AS demand_wow_change,




    -------------- Embedded generation --------------------------------
    -- Behind-the-meter solar and wind do not appear as generation on the
    -- transmission system ( ABSENT DEMAND). Adding them back to reconstruct
    -- what consumption would have been without them
    embedded_wind_mw,
    embedded_solar_mw,
    pump_storage_mw,
    tsd_mw + COALESCE(embedded_wind_mw, 0) + COALESCE(embedded_solar_mw, 0)
        AS underlying_demand_mw,

    nd_mw


FROM with_lags;
