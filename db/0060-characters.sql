-- A new character's pool of attribute points comes from configs at the moment
-- the row is inserted, so changing the config later reaches new characters
-- without a migration. A DEFAULT cannot contain a subquery, but it can call a
-- function, and the function may run one. STRICT turns a missing
-- 'attribute_points_default' row into an error that names it.
CREATE FUNCTION configured_attribute_points() RETURNS INTEGER AS $fn$
DECLARE
    points INTEGER;
BEGIN
    SELECT value::INTEGER INTO STRICT points
    FROM configs
    WHERE name = 'attribute_points_default';

    RETURN points;
END;
$fn$ LANGUAGE plpgsql;

CREATE TABLE characters (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    level INTEGER NOT NULL,
    kin INTEGER NOT NULL,
    age INTEGER NOT NULL,
    attribute_points INTEGER NOT NULL DEFAULT configured_attribute_points(),
    CHECK (level >= 1 AND level <= 100),
    CHECK (name <> ''),
    FOREIGN KEY (kin) REFERENCES kins(id),
    FOREIGN KEY (age) REFERENCES ages(id),
    CHECK (attribute_points >= 0)
);
