-- Every character has one row per attribute, starting at the configured
-- default with nothing spent, adjusted by what its age does to that attribute.
-- The adjustment lands in `modifier`, the rules' column, so it costs no points
-- and the range check in 0072 sees the adjusted total at once. STRICT turns a
-- missing 'attribute_default' row into an error that names it, rather than a
-- NULL that fails further down as a NOT NULL violation.
CREATE FUNCTION seed_character_attributes() RETURNS TRIGGER AS $fn$
DECLARE
    default_value INTEGER;
BEGIN
    SELECT value::INTEGER INTO STRICT default_value
    FROM configs
    WHERE name = 'attribute_default';

    INSERT INTO character_attributes (character, attribute, base, modifier)
    SELECT NEW.id, a.id, default_value, COALESCE(aa.modifier, 0)
    FROM attributes a
    LEFT JOIN age_attributes aa ON aa.age = NEW.age AND aa.attribute = a.id;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER characters_seed_attributes
AFTER INSERT ON characters
FOR EACH ROW
EXECUTE FUNCTION seed_character_attributes();
