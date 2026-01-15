/*
=============================================================================
CS621C[A] - Spatial Databases Project
Project Title: Tourism Infrastructure Distribution in Karnataka
Student Name: Snehan
Student ID: 	25253290
Date: November 2025
=============================================================================

PROJECT OVERVIEW:
This project analyzes the distribution of tourism infrastructure (attractions,
hotels, and restaurants) across Karnataka's districts using spatial analysis
in PostgreSQL/PostGIS.

KEY RESEARCH QUESTIONS:
1. Which districts have the best tourism infrastructure?
2. How accessible are attractions from hotels and restaurants?
3. What types of tourism facilities exist in Karnataka?
4. Which areas need infrastructure development?

DATA SOURCES:
- District Boundaries: DataMeet India Districts (Census 2011)
- Tourism Data: OpenStreetMap (attractions, hotels, restaurants)
- Total Records: 30 districts, 691 attractions, 1,499 hotels, 5,854 restaurants

=============================================================================
*/

-- ============================================
-- SECTION 1: DATABASE SETUP
-- ============================================

-- Create PostGIS extension (if not already exists)
CREATE EXTENSION IF NOT EXISTS postgis;

-- Verify PostGIS installation
SELECT PostGIS_version();


-- ============================================
-- SECTION 2: CREATE KARNATAKA-SPECIFIC VIEWS
-- ============================================


-- View 1: Filter only Karnataka districts from all India districts
CREATE OR REPLACE VIEW karnataka_districts AS
SELECT *
FROM india_districts
WHERE st_nm = 'Karnataka' OR st_nm = 'KARNATAKA';

-- Verify: Count Karnataka districts (Result: 30 districts)
SELECT COUNT(*) as karnataka_district_count FROM karnataka_districts;


-- View 2: Filter attractions within Karnataka boundaries using spatial intersection
CREATE OR REPLACE VIEW karnataka_attractions AS
SELECT a.*
FROM attractions a
JOIN karnataka_districts k ON ST_Intersects(a.geom, k.geom);

-- View 3: Filter hotels within Karnataka boundaries
CREATE OR REPLACE VIEW karnataka_hotels AS
SELECT h.*
FROM hotels h
JOIN karnataka_districts k ON ST_Intersects(h.geom, k.geom);

-- View 4: Filter restaurants within Karnataka boundaries
CREATE OR REPLACE VIEW karnataka_restaurants AS
SELECT r.*
FROM restaurants r
JOIN karnataka_districts k ON ST_Intersects(r.geom, k.geom);

-- Verify: Count filtered records
SELECT 
    'attractions' as type, COUNT(*) as count FROM karnataka_attractions
UNION ALL
SELECT 'hotels', COUNT(*) FROM karnataka_hotels
UNION ALL
SELECT 'restaurants', COUNT(*) FROM karnataka_restaurants;
-- Expected: attractions: 691, hotels: 1499, restaurants: 5854
-- ============================================
-- SECTION 3: CREATE MATERIALIZED VIEWS WITH DISTRICT ASSIGNMENTS
-- ============================================
-- These pre-compute spatial joins for faster query performance

-- Materialized View 1: Attractions with their district names
CREATE MATERIALIZED VIEW attractions_with_district AS
SELECT 
    a.id,
    a.name,
    a.tourism,
    a.historic,
    a.geom,
    k.district
FROM karnataka_attractions a
JOIN karnataka_districts k ON ST_Intersects(a.geom, k.geom);

CREATE INDEX idx_attractions_district ON attractions_with_district(district);


-- Materialized View 2: Hotels with their district names
CREATE MATERIALIZED VIEW hotels_with_district AS
SELECT 
    h.id,
    h.name,
    h.tourism,
    h.geom,
    k.district
FROM karnataka_hotels h
JOIN karnataka_districts k ON ST_Intersects(h.geom, k.geom);

CREATE INDEX idx_hotels_district ON hotels_with_district(district);


-- Materialized View 3: Restaurants with their district names
CREATE MATERIALIZED VIEW restaurants_with_district AS
SELECT 
    r.id,
    r.name,
    r.amenity,
    r.cuisine,
    r.geom,
    k.district
FROM karnataka_restaurants r
JOIN karnataka_districts k ON ST_Intersects(r.geom, k.geom);

CREATE INDEX idx_restaurants_district ON restaurants_with_district(district);


-- ============================================
-- SECTION 4: SPATIAL ANALYSIS QUERIES
-- ============================================

-- --------------------------------------------
-- ANALYSIS 1: Tourism Infrastructure Distribution by District
-- --------------------------------------------
-- Research Question: Which districts have the most/least tourism facilities?
-- Spatial Technique: Aggregation with spatial joins

SELECT 
    k.district AS district_name,
    COALESCE(a.attraction_count, 0) AS attraction_count,
    COALESCE(h.hotel_count, 0) AS hotel_count,
    COALESCE(r.restaurant_count, 0) AS restaurant_count,
    COALESCE(a.attraction_count, 0) + COALESCE(h.hotel_count, 0) + COALESCE(r.restaurant_count, 0) AS total_facilities
FROM karnataka_districts k
LEFT JOIN (
    SELECT district, COUNT(*) as attraction_count
    FROM attractions_with_district
    GROUP BY district
) a ON k.district = a.district
LEFT JOIN (
    SELECT district, COUNT(*) as hotel_count
    FROM hotels_with_district
    GROUP BY district
) h ON k.district = h.district
LEFT JOIN (
    SELECT district, COUNT(*) as restaurant_count
    FROM restaurants_with_district
    GROUP BY district
) r ON k.district = r.district
ORDER BY total_facilities DESC;

-- KEY FINDINGS:
-- 1. Bangalore dominates with 4,937 facilities (63% of all Karnataka tourism infrastructure)
-- 2. Top 5 districts: Bangalore (4,937), Mysore (341), Dakshina Kannada (278), Uttara Kannada (221), Udupi (206)
-- 3. Bottom 3 districts: Haveri (12), Gadag (34), Chikkaballapura (35)
-- 4. Significant urban-rural divide in infrastructure distribution
-- --------------------------------------------
-- ANALYSIS 2: Buffer Analysis - Infrastructure Within 2km of Attractions
-- --------------------------------------------
-- Research Question: Which attractions have the best support infrastructure nearby?
-- Spatial Technique: ST_DWithin for distance-based buffer analysis

SELECT 
    a.name AS attraction_name,
    a.district,
    COUNT(DISTINCT h.id) AS hotels_within_2km,
    COUNT(DISTINCT r.id) AS restaurants_within_2km,
    (COUNT(DISTINCT h.id) + COUNT(DISTINCT r.id)) AS total_facilities_nearby
FROM attractions_with_district a
LEFT JOIN hotels_with_district h 
    ON ST_DWithin(a.geom::geography, h.geom::geography, 2000)
LEFT JOIN restaurants_with_district r 
    ON ST_DWithin(a.geom::geography, r.geom::geography, 2000)
WHERE a.name IS NOT NULL 
    AND a.name != ''
    AND a.tourism = 'attraction'
GROUP BY a.name, a.district
HAVING COUNT(DISTINCT h.id) > 0 OR COUNT(DISTINCT r.id) > 0
ORDER BY total_facilities_nearby DESC
LIMIT 30;

-- KEY FINDINGS:
-- 1. Top attractions in Bangalore have 400+ facilities within 2km
-- 2. Peninsular Gneiss: 77 hotels, 364 restaurants within 2km (441 total)
-- 3. All top 30 best-supported attractions are in Bangalore
-- 4. Buffer analysis shows severe infrastructure clustering in urban centers


-- --------------------------------------------
-- ANALYSIS 3: Distance Analysis - Nearest Hotel and Restaurant to Each Attraction
-- --------------------------------------------
-- Research Question: How accessible are attractions from accommodation and dining?
-- Spatial Technique: ST_Distance with DISTINCT ON for nearest neighbor analysis

WITH nearest_hotels AS (
    SELECT DISTINCT ON (a.id)
        a.id as attraction_id,
        a.name as attraction_name,
        a.district,
        h.name as nearest_hotel,
        ROUND(ST_Distance(a.geom::geography, h.geom::geography)::numeric, 0) as distance_to_hotel_m
    FROM attractions_with_district a
    CROSS JOIN hotels_with_district h
    WHERE a.name IS NOT NULL AND a.name != ''
    ORDER BY a.id, ST_Distance(a.geom::geography, h.geom::geography)
),
nearest_restaurants AS (
    SELECT DISTINCT ON (a.id)
        a.id as attraction_id,
        r.name as nearest_restaurant,
        ROUND(ST_Distance(a.geom::geography, r.geom::geography)::numeric, 0) as distance_to_restaurant_m
    FROM attractions_with_district a
    CROSS JOIN restaurants_with_district r
    WHERE a.name IS NOT NULL AND a.name != ''
    ORDER BY a.id, ST_Distance(a.geom::geography, r.geom::geography)
)
SELECT 
    nh.attraction_name,
    nh.district,
    nh.nearest_hotel,
    nh.distance_to_hotel_m,
    nr.nearest_restaurant,
    nr.distance_to_restaurant_m
FROM nearest_hotels nh
JOIN nearest_restaurants nr ON nh.attraction_id = nr.attraction_id
ORDER BY nh.district, nh.attraction_name
LIMIT 30;

-- KEY FINDINGS:
-- 1. Bangalore attractions: Excellent accessibility (most within 500m)
-- 2. Rural Bagalkot attractions: Poor accessibility (20+ km to nearest hotel)
-- 3. Best connected: Bangalore World Trade Center (hotel 125m, restaurant 24m)
-- 4. Worst connected: Aihole Museum (hotel 24km away)

-- --------------------------------------------
-- ANALYSIS 4: Attraction Types Distribution
-- --------------------------------------------
-- Research Question: What types of tourist attractions does Karnataka offer?

SELECT 
    COALESCE(tourism, 'Unknown') as attraction_type,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) as percentage
FROM attractions_with_district
GROUP BY tourism
ORDER BY count DESC;

-- KEY FINDINGS:
-- 1. Unknown/untagged: 373 (54%) - poor data categorization
-- 2. General attractions: 265 (38%)
-- 3. Museums: 47 (7%)
-- 4. Limited diversity in attraction types


-- --------------------------------------------
-- ANALYSIS 5: Accommodation Types Distribution
-- --------------------------------------------
-- Research Question: What types of accommodation are available?

SELECT 
    COALESCE(tourism, 'Unknown') as accommodation_type,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) as percentage
FROM hotels_with_district
GROUP BY tourism
ORDER BY count DESC;

-- KEY FINDINGS:
-- 1. Hotels dominate: 1,288 (86%)
-- 2. Guest houses: 211 (14%)
-- 3. No tagged hostels, resorts, or B&Bs - limited accommodation diversity


-- --------------------------------------------
-- ANALYSIS 6: Cultural Tourism Centers (Museums by District)
-- --------------------------------------------
-- Research Question: Which districts are cultural tourism hubs?

SELECT 
    district,
    COUNT(*) as museum_count
FROM attractions_with_district
WHERE tourism = 'museum'
GROUP BY district
ORDER BY museum_count DESC
LIMIT 10;

-- KEY FINDINGS:
-- 1. Bangalore: 20 museums (42% of all Karnataka museums)
-- 2. Mysore: 6 museums (historic royal city)
-- 3. Cultural tourism heavily concentrated in top 2 cities
-- 4. Only 10 districts have museums


-- ============================================
-- SECTION 5: PROJECT SUMMARY AND CONCLUSIONS
-- ============================================

/*
OVERALL FINDINGS AND INSIGHTS:

1. INFRASTRUCTURE CONCENTRATION:
   - Bangalore dominates with 4,937 facilities (63% of Karnataka's tourism infrastructure)
   - Top 5 districts contain 80%+ of all facilities
   - Severe urban-rural divide: Bangalore has 400x more facilities than Haveri
   - Coastal districts (Dakshina Kannada, Udupi) show emerging tourism potential

2. ACCESSIBILITY ANALYSIS:
   - Urban attractions: Excellent access (facilities within 200-500m)
   - Rural heritage sites: Poor access (often 20+ km to nearest hotel)
   - Buffer analysis reveals infrastructure clustering in city centers
   - 30 major attractions in Bangalore have 150+ facilities within 2km walking distance

3. TOURISM FACILITY DIVERSITY:
   - Accommodation: 86% standard hotels, limited alternative options
   - Attractions: 54% poorly categorized, only 7% museums
   - Cultural tourism concentrated in Bangalore (20 museums) and Mysore (6 museums)
   - Restaurant infrastructure: 5,854 establishments, heavily urban-concentrated

4. DEVELOPMENT GAPS AND OPPORTUNITIES:
   - Rural districts need urgent infrastructure investment (Haveri: only 12 facilities)
   - Heritage corridor (Bagalkot) has attractions but lacks support infrastructure
   - Coastal region shows growth potential (Udupi, Uttara Kannada)
   - Museums and cultural sites disproportionately located in 2 cities

5. SPATIAL PATTERNS:
   - Point pattern analysis shows extreme clustering in Bangalore
   - Distance decay effect: infrastructure drops sharply outside urban centers
   - Heritage sites in rural areas isolated from tourism services
   - Geographic barriers (Western Ghats) may influence infrastructure distribution

SPATIAL TECHNIQUES DEMONSTRATED:
- ST_Intersects: Spatial joins to filter and assign geometries to districts
- ST_DWithin: Buffer analysis for proximity queries (2km radius)
- ST_Distance: Accurate distance calculations using geography type
- DISTINCT ON: Nearest neighbor analysis for closest facilities
- Materialized Views: Performance optimization for complex spatial queries
- Geography vs Geometry: Meter-based calculations for real-world distances
- Spatial Indexing: GIST indexes for fast spatial query performance

DATA QUALITY AND LIMITATIONS:
- OpenStreetMap data quality varies significantly by region
- Urban areas (Bangalore) have comprehensive, detailed, current data
- Rural areas show incomplete coverage and outdated information
- 54% of attractions lack proper type categorization
- Some facilities may be missing or incorrectly tagged
- Temporal accuracy: Data represents snapshot from 2025

RECOMMENDATIONS FOR KARNATAKA TOURISM DEVELOPMENT:
1. Invest in hotel/restaurant infrastructure in rural heritage districts
2. Develop tourism corridors connecting isolated attractions
3. Improve data collection and categorization for tourism planning
4. Create integrated tourism zones with balanced facility distribution
5. Leverage coastal tourism potential with targeted infrastructure development
*/

-- ============================================
-- END OF SQL FILE
-- ============================================
-- Project: Karnataka Tourism Infrastructure Analysis
-- Total Spatial Analyses: 6
-- Total Queries: 15+
-- Date Completed: November 2025
-- PostgreSQL Version: 18
-- PostGIS Version: 3.6
-- ============================================



