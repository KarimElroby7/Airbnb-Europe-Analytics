/* =====================================================================
   GOLD LAYER - Normalized relational schema
   ---------------------------------------------------------------------
   Source : silver.listings, silver.neighbourhood_features
   Output : 5 dimension tables + 1 fact table, linked by primary and
            foreign keys (normalized to third normal form).

   gold.dim_city            1 row per city
   gold.dim_neighbourhood   1 row per neighbourhood  (FK -> dim_city)
   gold.dim_room_type       1 row per room type
   gold.dim_day_type        weekdays / weekends
   gold.dim_host_type       individual / small / professional host
   gold.fact_listings       1 row per listing (FK -> every dimension)

   The script can be re-run: it drops and rebuilds the Gold tables.
   ===================================================================== */

USE AirbnbEurope;
GO


/* ---------------------------------------------------------------------
   STEP 0: Drop old Gold tables.
   The fact table goes first, because it points at the dimensions
   (SQL Server refuses to drop a table that another table references).
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS gold.fact_listings;
DROP TABLE IF EXISTS gold.dim_neighbourhood;
DROP TABLE IF EXISTS gold.dim_city;
DROP TABLE IF EXISTS gold.dim_room_type;
DROP TABLE IF EXISTS gold.dim_day_type;
DROP TABLE IF EXISTS gold.dim_host_type;
GO


/* ---------------------------------------------------------------------
   STEP 1: dim_city
   Each city name is stored once. Every other table refers to it by number.
   --------------------------------------------------------------------- */
CREATE TABLE gold.dim_city (
    city_id     INT IDENTITY(1,1) NOT NULL,
    city_name   NVARCHAR(50)      NOT NULL,
    country     NVARCHAR(50)      NOT NULL,
    CONSTRAINT pk_dim_city      PRIMARY KEY (city_id),
    CONSTRAINT uq_dim_city_name UNIQUE (city_name)
);

INSERT INTO gold.dim_city (city_name, country)
SELECT DISTINCT
    CAST(city AS NVARCHAR(50)),
    CASE city
        WHEN N'Amsterdam' THEN N'Netherlands'
        WHEN N'Athens'    THEN N'Greece'
        WHEN N'Barcelona' THEN N'Spain'
        WHEN N'Berlin'    THEN N'Germany'
        WHEN N'Budapest'  THEN N'Hungary'
        WHEN N'Lisbon'    THEN N'Portugal'
        WHEN N'London'    THEN N'United Kingdom'
        WHEN N'Paris'     THEN N'France'
        WHEN N'Rome'      THEN N'Italy'
        WHEN N'Vienna'    THEN N'Austria'
    END
FROM silver.listings;
GO


/* ---------------------------------------------------------------------
   STEP 2: dim_room_type
   --------------------------------------------------------------------- */
CREATE TABLE gold.dim_room_type (
    room_type_id    INT IDENTITY(1,1) NOT NULL,
    room_type_name  NVARCHAR(30)      NOT NULL,
    CONSTRAINT pk_dim_room_type      PRIMARY KEY (room_type_id),
    CONSTRAINT uq_dim_room_type_name UNIQUE (room_type_name)
);

INSERT INTO gold.dim_room_type (room_type_name)
SELECT DISTINCT CAST(room_type AS NVARCHAR(30))
FROM silver.listings;
GO


/* ---------------------------------------------------------------------
   STEP 3: dim_day_type
   --------------------------------------------------------------------- */
CREATE TABLE gold.dim_day_type (
    day_type_id     INT IDENTITY(1,1) NOT NULL,
    day_type_name   NVARCHAR(20)      NOT NULL,
    is_weekend      BIT               NOT NULL,
    CONSTRAINT pk_dim_day_type      PRIMARY KEY (day_type_id),
    CONSTRAINT uq_dim_day_type_name UNIQUE (day_type_name)
);

INSERT INTO gold.dim_day_type (day_type_name, is_weekend)
SELECT DISTINCT
    CAST(day_type AS NVARCHAR(20)),
    CASE WHEN day_type = N'weekends' THEN 1 ELSE 0 END
FROM silver.listings;
GO


/* ---------------------------------------------------------------------
   STEP 4: dim_host_type
   Replaces the two yes/no columns host_has_2_to_4_listings and
   host_has_over_4_listings with one clear category.
   The ids are fixed, so they are written by hand instead of IDENTITY.
   --------------------------------------------------------------------- */
CREATE TABLE gold.dim_host_type (
    host_type_id    INT          NOT NULL,
    host_type_name  NVARCHAR(20) NOT NULL,
    listings_range  NVARCHAR(10) NOT NULL,
    CONSTRAINT pk_dim_host_type      PRIMARY KEY (host_type_id),
    CONSTRAINT uq_dim_host_type_name UNIQUE (host_type_name)
);

INSERT INTO gold.dim_host_type (host_type_id, host_type_name, listings_range)
VALUES
    (1, N'Individual',   N'1'),
    (2, N'Small',        N'2-4'),
    (3, N'Professional', N'5+');
GO


/* ---------------------------------------------------------------------
   STEP 5: dim_neighbourhood
   One row per neighbourhood with its Inside Airbnb features.
   The features belong to the NEIGHBOURHOOD, not to each listing, so they
   are stored here once instead of being repeated on every listing.
   A neighbourhood belongs to a city -> foreign key to dim_city.
   Neighbourhoods that have listings but no Inside Airbnb features are
   kept, with NULL features (LEFT JOIN).
   --------------------------------------------------------------------- */
CREATE TABLE gold.dim_neighbourhood (
    neighbourhood_id        INT IDENTITY(1,1) NOT NULL,
    city_id                 INT               NOT NULL,
    neighbourhood_name      NVARCHAR(200)     NOT NULL,
    nb_listings             INT               NULL,
    nb_median_reviews       FLOAT             NULL,
    nb_avg_rating           FLOAT             NULL,
    nb_superhost_share      FLOAT             NULL,
    nb_median_amenities     FLOAT             NULL,
    nb_median_availability  FLOAT             NULL,
    nb_avg_host_listings    FLOAT             NULL,
    nb_entire_home_share    FLOAT             NULL,
    CONSTRAINT pk_dim_neighbourhood      PRIMARY KEY (neighbourhood_id),
    CONSTRAINT fk_dim_neighbourhood_city FOREIGN KEY (city_id) REFERENCES gold.dim_city (city_id),
    CONSTRAINT uq_dim_neighbourhood      UNIQUE (city_id, neighbourhood_name)
);

WITH all_neighbourhoods AS (
    SELECT CAST(city AS NVARCHAR(50))           AS city,
           CAST(neighbourhood AS NVARCHAR(200)) AS neighbourhood
    FROM silver.neighbourhood_features
    UNION
    SELECT CAST(city AS NVARCHAR(50)),
           CAST(neighbourhood AS NVARCHAR(200))
    FROM silver.listings
    WHERE neighbourhood IS NOT NULL
)
INSERT INTO gold.dim_neighbourhood (
    city_id, neighbourhood_name,
    nb_listings, nb_median_reviews, nb_avg_rating, nb_superhost_share,
    nb_median_amenities, nb_median_availability, nb_avg_host_listings, nb_entire_home_share
)
SELECT
    c.city_id,
    a.neighbourhood,
    f.nb_listings, f.nb_median_reviews, f.nb_avg_rating, f.nb_superhost_share,
    f.nb_median_amenities, f.nb_median_availability, f.nb_avg_host_listings, f.nb_entire_home_share
FROM all_neighbourhoods AS a
JOIN gold.dim_city AS c
    ON c.city_name = a.city
LEFT JOIN silver.neighbourhood_features AS f
    ON f.city = a.city
   AND f.neighbourhood = a.neighbourhood;
GO


/* ---------------------------------------------------------------------
   STEP 6: fact_listings
   One row per listing: its measures (price, size, ratings, location) and
   a foreign key to each dimension instead of repeated text.
   city_id is NOT stored here: the city is already known through the
   neighbourhood (third normal form).
   CHECK constraints stop impossible values from ever being inserted.
   --------------------------------------------------------------------- */
CREATE TABLE gold.fact_listings (
    listing_id          INT           NOT NULL,
    neighbourhood_id    INT           NOT NULL,
    room_type_id        INT           NOT NULL,
    day_type_id         INT           NOT NULL,
    host_type_id        INT           NOT NULL,
    host_is_superhost   BIT           NOT NULL,
    price_eur           DECIMAL(10,2) NOT NULL,
    person_capacity     TINYINT       NOT NULL,
    bedrooms            TINYINT       NOT NULL,
    cleanliness_rating  DECIMAL(4,1)  NOT NULL,
    guest_satisfaction  DECIMAL(5,1)  NOT NULL,
    dist_center_km      DECIMAL(8,3)  NOT NULL,
    dist_metro_km       DECIMAL(8,3)  NOT NULL,
    attraction_index    DECIMAL(8,3)  NOT NULL,
    restaurant_index    DECIMAL(8,3)  NOT NULL,
    latitude            DECIMAL(9,6)  NOT NULL,
    longitude           DECIMAL(9,6)  NOT NULL,
    CONSTRAINT pk_fact_listings               PRIMARY KEY (listing_id),
    CONSTRAINT fk_fact_listings_neighbourhood FOREIGN KEY (neighbourhood_id) REFERENCES gold.dim_neighbourhood (neighbourhood_id),
    CONSTRAINT fk_fact_listings_room_type     FOREIGN KEY (room_type_id)     REFERENCES gold.dim_room_type (room_type_id),
    CONSTRAINT fk_fact_listings_day_type      FOREIGN KEY (day_type_id)      REFERENCES gold.dim_day_type (day_type_id),
    CONSTRAINT fk_fact_listings_host_type     FOREIGN KEY (host_type_id)     REFERENCES gold.dim_host_type (host_type_id),
    CONSTRAINT ck_fact_listings_price         CHECK (price_eur > 0),
    CONSTRAINT ck_fact_listings_capacity      CHECK (person_capacity BETWEEN 1 AND 16)
);

INSERT INTO gold.fact_listings (
    listing_id, neighbourhood_id, room_type_id, day_type_id, host_type_id,
    host_is_superhost, price_eur, person_capacity, bedrooms,
    cleanliness_rating, guest_satisfaction,
    dist_center_km, dist_metro_km, attraction_index, restaurant_index,
    latitude, longitude
)
SELECT
    l.listing_id,
    n.neighbourhood_id,
    r.room_type_id,
    d.day_type_id,
    CASE
        WHEN l.host_has_over_4_listings = 1 THEN 3
        WHEN l.host_has_2_to_4_listings = 1 THEN 2
        ELSE 1
    END,
    l.host_is_superhost,
    l.price_eur,
    l.person_capacity,
    l.bedrooms,
    l.cleanliness_rating,
    l.guest_satisfaction,
    l.dist_center_km,
    l.dist_metro_km,
    l.attraction_index,
    l.restaurant_index,
    l.latitude,
    l.longitude
FROM silver.listings AS l
JOIN gold.dim_city AS c
    ON c.city_name = l.city
JOIN gold.dim_neighbourhood AS n
    ON n.city_id = c.city_id
   AND n.neighbourhood_name = l.neighbourhood
JOIN gold.dim_room_type AS r
    ON r.room_type_name = l.room_type
JOIN gold.dim_day_type AS d
    ON d.day_type_name = l.day_type;
GO


/* ---------------------------------------------------------------------
   STEP 7: Verify
   gold.fact_listings must have exactly as many rows as silver.listings.
   If it has fewer, a JOIN above did not find a match and dropped rows.
   --------------------------------------------------------------------- */
SELECT 'silver.listings'        AS table_name, COUNT(*) AS row_count FROM silver.listings
UNION ALL SELECT 'gold.fact_listings',     COUNT(*) FROM gold.fact_listings
UNION ALL SELECT 'gold.dim_city',          COUNT(*) FROM gold.dim_city
UNION ALL SELECT 'gold.dim_neighbourhood', COUNT(*) FROM gold.dim_neighbourhood
UNION ALL SELECT 'gold.dim_room_type',     COUNT(*) FROM gold.dim_room_type
UNION ALL SELECT 'gold.dim_day_type',      COUNT(*) FROM gold.dim_day_type
UNION ALL SELECT 'gold.dim_host_type',     COUNT(*) FROM gold.dim_host_type;


/* ---------------------------------------------------------------------
   STEP 8: Use the model
   The text is no longer repeated, so queries JOIN the tables back
   together through their keys. Average price per city and room type:
   --------------------------------------------------------------------- */
SELECT
    c.city_name,
    r.room_type_name,
    COUNT(*)                     AS listings,
    CAST(AVG(f.price_eur) AS DECIMAL(10,2)) AS avg_price_eur
FROM gold.fact_listings AS f
JOIN gold.dim_neighbourhood AS n ON n.neighbourhood_id = f.neighbourhood_id
JOIN gold.dim_city          AS c ON c.city_id          = n.city_id
JOIN gold.dim_room_type     AS r ON r.room_type_id     = f.room_type_id
GROUP BY c.city_name, r.room_type_name
ORDER BY c.city_name, avg_price_eur DESC;
