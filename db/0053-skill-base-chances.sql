-- Inclusive attribute bands shared by every skill. These remain rows rather
-- than code because a campaign can configure its starting skill chances.
CREATE TABLE skill_base_chances (
    min_value INTEGER PRIMARY KEY CHECK (min_value >= 1),
    max_value INTEGER NOT NULL CHECK (max_value <= 18),
    base_chance INTEGER NOT NULL CHECK (base_chance BETWEEN 1 AND 18),
    CHECK (min_value <= max_value),
    EXCLUDE USING gist (int4range(min_value, max_value, '[]') WITH &&)
);
